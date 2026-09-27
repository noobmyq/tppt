#!/bin/bash

set -euo pipefail

readonly QEMU_ROOT=/mnt/storage/tppt/qemu-linux
readonly TP_LINUX=/mnt/storage/tppt/linux-tp
readonly VANILLA_LINUX=/mnt/storage/tppt/linux-6.8
readonly EMT_ROOT=/mnt/storage/tppt/emt-baselines/build
readonly DYNAMORIO_ROOT=/mnt/storage/tppt/tp-emt-dynamorio
readonly TRACE_ROOT=${QEMU_ROOT}/results_tppt_emt_mem_4k_1b
readonly RESULT_ROOT=${DYNAMORIO_ROOT}/results/tppt_emt_mem_4k_1b
readonly NUM_INST=1000000000

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
    local capture_lock

    if [[ -s "${trace}" ]]; then
        echo "Reusing existing trace: ${trace}"
        return 0
    fi

    # Mode workers for one workload run concurrently, but QEMU capture is
    # globally serialized. Recheck after taking the lock in case another
    # worker completed the same target while this worker waited.
    exec {capture_lock}>/tmp/tppt-mem-4way-qemu.lock
    flock "${capture_lock}"

    if [[ -s "${trace}" ]]; then
        echo "Reusing trace captured while waiting: ${trace}"
        flock -u "${capture_lock}"
        return 0
    fi

    if [[ -e "${trace}" ]]; then
        echo "Removing empty trace before recapture: ${trace}"
        rm -- "${trace}"
    fi

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
                "${TP_LINUX}" "${tp_command}" "${trace}" "${NUM_INST}"
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
                "${VANILLA_LINUX}" "${vanilla_command}" "${trace}" "${NUM_INST}"
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
                "${EMT_ROOT}/linux-${mode}" "${vanilla_command}" "${trace}" "${NUM_INST}"
        rc=$?
        ;;
    *)
        echo "Unknown mode: ${mode}" >&2
        exit 2
        ;;
    esac
    set -e

    if (( rc != 0 )); then
        echo "QEMU returned ${rc} for ${workload}/${mode}; validating the trace through the simulator"
    fi
    [[ -s "${trace}" ]] || {
        echo "Capture produced no trace for ${workload}/${mode}" >&2
        exit 1
    }
    flock -u "${capture_lock}"
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

process_mode()
{
    local workload=$1
    local mode=$2
    local tp_command=$3
    local vanilla_command=$4
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

    capture_trace "${workload}" "${mode}" "${tp_command}" "${vanilla_command}" "${trace}"

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

for workload in "${workloads[@]}"; do
    tp_command=${linux_mem_workloads[${workload}]}
    vanilla_command=$(without_tppt_exec "${tp_command}")
    mode_pids=()
    mode_names=()
    workload_failed=0

    echo "Starting workload: ${workload}"

    for mode in "${modes[@]}"; do
        process_mode "${workload}" "${mode}" "${tp_command}" "${vanilla_command}" &
        mode_pids+=("$!")
        mode_names+=("${mode}")
    done

    for index in "${!mode_pids[@]}"; do
        if ! wait "${mode_pids[${index}]}"; then
            echo "Mode failed for ${workload}/${mode_names[${index}]}" >&2
            workload_failed=1
        fi
    done

    (( workload_failed == 0 )) || exit 1
    echo "Completed workload: ${workload}"
done

echo "All TPPT/vanilla/FPT/ECPT memory workloads and both analysis configurations completed"
