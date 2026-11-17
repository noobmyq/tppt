#!/bin/bash

set -euo pipefail

readonly ROOT=${TPPT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
readonly QEMU_ROOT=${ROOT}/qemu-linux
readonly TP_LINUX=${ROOT}/linux-tp
readonly VANILLA_LINUX=${ROOT}/linux-6.8
readonly EMT_ROOT=${ROOT}/emt-baselines/build
readonly DYNAMORIO_ROOT=${ROOT}/tp-emt-dynamorio
readonly TRACE_ROOT=${QEMU_ROOT}/results_tppt_emt_mem_4k_1b
readonly RESULT_ROOT=${DYNAMORIO_ROOT}/results/tppt_emt_mem_4k_1b
readonly NUM_INST=1000000000
readonly MAX_QEMU=${TPPT_MAX_QEMU:-1}
readonly SIM_JOBS=${TPPT_SIM_JOBS:-12}
[[ ${MAX_QEMU} =~ ^[1-9][0-9]*$ && ${SIM_JOBS} =~ ^[1-9][0-9]*$ ]] &&
    (( SIM_JOBS >= 2 )) || {
    echo "TPPT_MAX_QEMU must be positive; TPPT_SIM_JOBS must be at least 2" >&2
    exit 2
}

exec 9>/tmp/tppt-mem-4way-serial.lock
flock -n 9 || {
    echo "Another TPPT memory comparison queue is already running" >&2
    exit 1
}

mkdir -p "${TRACE_ROOT}/logs"
for config in default mmu_to_l2; do
    for mode in tp vanilla fpt ecpt; do
        mkdir -p "${RESULT_ROOT}/${config}/${mode}"
    done
done

source "${QEMU_ROOT}/run_linux_mem_command.sh"

# Process existing large traces first so they are retired early.
workloads=(gups xsbench btree dc pr bfs dfs sssp tc cc memcached canneal)
modes=(fpt ecpt tp vanilla)

without_tppt_exec()
{
    local command=$1
    printf '%s\n' "${command/\/usr\/local\/bin\/tppt_exec /}"
}

capture_trace()
{
    local workload=$1
    local mode=$2
    local tp_command=$3
    local vanilla_command=$4
    local trace=$5
    local rc
    local console="${TRACE_ROOT}/logs/qemu_${workload}_${mode}_${NUM_INST}.log"
    local partial="${trace%.log}.partial"

    if [[ -s "${trace}" ]]; then
        capture_complete "${console}" || {
            echo "Existing trace has no complete capture log: ${trace}" >&2
            return 1
        }
        echo "Reusing existing trace: ${trace}"
        return 0
    fi

    [[ ! -e ${trace} && ! -e ${partial} ]] || {
        echo "Incomplete trace exists; inspect before retrying: ${trace}" >&2
        return 1
    }

    echo "Capturing ${workload}/${mode}: ${trace}"

    set +e
    case "${mode}" in
    tp)
        env \
            TPPT_KERNEL_DEBUG=0 \
            TPPT_THP_MODE=off \
            TRANSPARENT_HUGEPAGE_MODE=never \
            QEMU_TRACE_FORMAT=tppt \
            TPPT_WORKLOAD_PLUGIN_MODE=logAll \
            QEMU_MEMORY=128G \
            "${QEMU_ROOT}/run-qemu-linux.sh" \
                "${TP_LINUX}" "${tp_command}" "${partial}" "${NUM_INST}"
        rc=$?
        ;;
    vanilla)
        env \
            TPPT_KERNEL_DEBUG=0 \
            TPPT_THP_MODE=off \
            TRANSPARENT_HUGEPAGE_MODE=never \
            QEMU_TRACE_FORMAT=tppt \
            TPPT_WORKLOAD_PLUGIN_MODE=logAll \
            QEMU_MEMORY=128G \
            "${QEMU_ROOT}/run-qemu-linux.sh" \
                "${VANILLA_LINUX}" "${vanilla_command}" "${partial}" "${NUM_INST}"
        rc=$?
        ;;
    fpt|ecpt)
        env \
            TRANSPARENT_HUGEPAGE_MODE=never \
            QEMU_TRACE_FORMAT=emt \
            TPPT_WORKLOAD_PLUGIN_MODE=logAll \
            QEMU_MEMORY=128G \
            QEMU_BIN="${EMT_ROOT}/qemu-${mode}/qemu-system-x86_64" \
            TPPT_KERNEL_FILE="${EMT_ROOT}/linux-${mode}/arch/x86/boot/bzImage" \
            TPPT_WORKLOAD_PLUGIN="${EMT_ROOT}/qemu-${mode}/tests/plugin/libexeclog.so" \
            "${QEMU_ROOT}/run-qemu-linux.sh" \
                "${EMT_ROOT}/linux-${mode}" "${vanilla_command}" "${partial}" "${NUM_INST}"
        rc=$?
        ;;
    *)
        echo "Unknown mode: ${mode}" >&2
        exit 2
        ;;
    esac
    set -e

    if (( rc != 0 )); then
        echo "QEMU returned ${rc} for ${workload}/${mode}; checking capture completion"
    fi
    [[ -s "${partial}" ]] && capture_complete "${console}" || {
        echo "Incomplete capture for ${workload}/${mode}; retaining partial and console" >&2
        return 1
    }
    mv -- "${partial}" "${trace}"
}

capture_complete()
{
    [[ -s $1 ]] &&
        ! grep -Eq 'Kernel panic|Oops:|Assertion .* failed' "$1" &&
        grep -Eq "Reached[[:space:]]+${NUM_INST} user instrs|Total simulated ${NUM_INST} user instrs" "$1" &&
        grep -q 'Closed binary log file descriptor' "$1"
}

analysis_complete()
{
    local output=$1

    [[ -s "${output}" ]] &&
        grep -q '^num_requests :' "${output}" &&
        grep -q '^~~~~~~ detailed perf stats ~~~~~~' "${output}" &&
        grep -A4 '^user memory references:' "${output}" | grep -q '^16,1000000000$'
}

analyze_trace()
{
    local workload=$1
    local mode=$2
    local trace=$3
    local config=$4
    local output="${RESULT_ROOT}/${config}/${mode}/${workload}.txt"
    local partial="${output}.partial"
    local trace_format=tppt
    local arch=radix
    local -a mode_flags=()
    local -a config_flags=()

    case "${mode}" in
    tp)
        ;;
    vanilla)
        mode_flags=(-skip_tiny_pointer_walk)
        ;;
    fpt)
        trace_format=emt
        arch=fpt
        mode_flags=(-skip_tiny_pointer_walk)
        ;;
    ecpt)
        trace_format=emt
        arch=ecpt
        mode_flags=(-cache_correct_only -skip_tiny_pointer_walk)
        ;;
    esac

    if [[ "${config}" == mmu_to_l2 ]]; then
        config_flags=(-mmu_to_l2)
    fi

    if analysis_complete "${output}"; then
        echo "Reusing completed analysis: ${output}"
        return 0
    fi

    rm -f -- "${partial}"
    echo "Analyzing ${workload}/${mode}/${config}: ${output}"
    (
        cd "${DYNAMORIO_ROOT}"
        ./build_linux/bin64/drrun -t drcachesim \
            -qemu_mem_trace "${trace}" \
            -qemu_trace_format "${trace_format}" \
            -max_ref -1 \
            -warmup_refs 300000000 \
            -arch "${arch}" \
            -TLB_L1I_entries 128 \
            -TLB_L1I_assoc 8 \
            -TLB_L1D_entries 64 \
            -TLB_L1D_assoc 4 \
            -TLB_L2_entries 1536 \
            -TLB_L2_assoc 12 \
            -L1I_size 32768 \
            -L1I_assoc 8 \
            -L1D_size 32768 \
            -L1D_assoc 8 \
            -L2_size 1048576 \
            -L2_assoc 16 \
            -LL_size 23068672 \
            -LL_assoc 11 \
            -cores 20 \
            -verbose 0 \
            "${mode_flags[@]}" \
            "${config_flags[@]}" \
            >"${partial}" 2>&1
    )

    grep -q '^num_requests :' "${partial}"
    grep -q '^~~~~~~ detailed perf stats ~~~~~~' "${partial}"
    grep -A4 '^user memory references:' "${partial}" | grep -q '^16,1000000000$'
    mv -- "${partial}" "${output}"
}

analyze_mode()
{
    local workload=$1
    local mode=$2
    local trace="${TRACE_ROOT}/${workload}_${mode}_${NUM_INST}.log"
    local default_output="${RESULT_ROOT}/default/${mode}/${workload}.txt"
    local l2_output="${RESULT_ROOT}/mmu_to_l2/${mode}/${workload}.txt"
    local default_pid
    local l2_pid
    local failed=0
    local trace_size

    if analysis_complete "${default_output}" && analysis_complete "${l2_output}"; then
        echo "Both analyses already complete for ${workload}/${mode}"
        if [[ -e "${trace}" ]]; then
            trace_size=$(stat -c '%s' "${trace}")
            rm -- "${trace}"
            echo "Removed previously analyzed binary trace (${trace_size} bytes): ${trace}"
        fi
        return 0
    fi

    analyze_trace "${workload}" "${mode}" "${trace}" default &
    default_pid=$!
    analyze_trace "${workload}" "${mode}" "${trace}" mmu_to_l2 &
    l2_pid=$!

    if ! wait "${default_pid}"; then
        echo "Default analysis failed for ${workload}/${mode}" >&2
        failed=1
    fi
    if ! wait "${l2_pid}"; then
        echo "mmu_to_l2 analysis failed for ${workload}/${mode}" >&2
        failed=1
    fi

    (( failed == 0 )) || return 1
    analysis_complete "${default_output}"
    analysis_complete "${l2_output}"

    trace_size=$(stat -c '%s' "${trace}")
    rm -- "${trace}"
    echo "Removed analyzed binary trace (${trace_size} bytes): ${trace}"
}

# Capture slots are released as soon as QEMU exits. Simulation pairs have their
# own limit, so neither a slow simulation nor a workload boundary blocks capture.
pending=()
ready=()
declare -A captures=() simulations=()
failed=0
export QEMU_ROOT TP_LINUX VANILLA_LINUX EMT_ROOT DYNAMORIO_ROOT TRACE_ROOT RESULT_ROOT NUM_INST
export -f capture_trace capture_complete analyze_trace analyze_mode analysis_complete

cleanup()
{
    local pid
    for pid in "${!captures[@]}" "${!simulations[@]}"; do
        kill -TERM -- "-${pid}" 2>/dev/null || true
    done
    for pid in "${!captures[@]}" "${!simulations[@]}"; do
        wait "${pid}" 2>/dev/null || true
    done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for workload in "${workloads[@]}"; do
    for mode in "${modes[@]}"; do
        trace="${TRACE_ROOT}/${workload}_${mode}_${NUM_INST}.log"
        if analysis_complete "${RESULT_ROOT}/default/${mode}/${workload}.txt" &&
           analysis_complete "${RESULT_ROOT}/mmu_to_l2/${mode}/${workload}.txt"; then
            echo "Both analyses already complete for ${workload}/${mode}"
            rm -f -- "${trace}"
        else
            pending+=("${workload}/${mode}")
        fi
    done
done

while (( ${#pending[@]} + ${#captures[@]} + ${#ready[@]} + ${#simulations[@]} > 0 )); do
    for pid in "${!captures[@]}"; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            if wait "${pid}"; then
                ready+=("${captures[${pid}]}")
            else
                echo "Capture failed: ${captures[${pid}]}" >&2
                failed=1
            fi
            unset 'captures['"${pid}"']'
        fi
    done
    for pid in "${!simulations[@]}"; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            if ! wait "${pid}"; then
                echo "Analysis failed: ${simulations[${pid}]}" >&2
                failed=1
            fi
            unset 'simulations['"${pid}"']'
        fi
    done
    while (( ${#ready[@]} > 0 && 2 * (${#simulations[@]} + 1) <= SIM_JOBS )); do
        job=${ready[0]}; ready=("${ready[@]:1}")
        setsid --wait bash -euo pipefail -c 'analyze_mode "$@"' _ "${job%/*}" "${job#*/}" &
        simulations[$!]=${job}
    done
    while (( ${#pending[@]} > 0 && ${#captures[@]} < MAX_QEMU )); do
        job=${pending[0]}; pending=("${pending[@]:1}")
        workload=${job%/*}; mode=${job#*/}
        tp_command=${linux_mem_workloads[${workload}]}
        vanilla_command=$(without_tppt_exec "${tp_command}")
        trace="${TRACE_ROOT}/${workload}_${mode}_${NUM_INST}.log"
        setsid --wait bash -euo pipefail -c 'capture_trace "$@"' _ \
            "${workload}" "${mode}" "${tp_command}" "${vanilla_command}" "${trace}" &
        captures[$!]=${job}
    done
    sleep 1
done

(( failed == 0 )) || exit 1

echo "All TPPT/vanilla/FPT/ECPT memory workloads and both analysis configurations completed"
