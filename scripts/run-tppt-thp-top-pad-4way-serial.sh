#!/usr/bin/env bash
set -euo pipefail

readonly ROOT=/mnt/storage/tppt
readonly QEMU_ROOT=${ROOT}/qemu-linux
readonly DYNAMORIO_ROOT=${ROOT}/tp-emt-dynamorio
readonly EMT_ROOT=${ROOT}/emt-baselines/build
# Flatten L4+L3 only so FPT retains normal PMD huge-page leaves.
readonly FPT_KERNEL_DIR=${EMT_ROOT}/linux-fpt-l4l3-thp
readonly TRACE_ROOT=${QEMU_ROOT}/results_thp_top_pad_64g
readonly RESULT_ROOT=${DYNAMORIO_ROOT}/results/linux_thp_top_pad_64g
readonly PLOT_ROOT=${ROOT}/dmt-simulator/results
readonly NUM_INST=1000000000
readonly TOP_PAD_BYTES=68719476736
readonly SIM_JOBS=${SIM_JOBS:-2}
readonly WORKLOADS=(gups xsbench btree dc dfs tc bfs cc pr sssp)
readonly MODES=(tp vanilla fpt ecpt)

[[ ${SIM_JOBS} =~ ^[1-9][0-9]*$ ]] || {
    echo "SIM_JOBS must be a positive integer" >&2
    exit 2
}

exec 9>/tmp/tppt-thp-top-pad-4way-serial.lock
flock -n 9 || {
    echo "Another top-pad four-way driver is running" >&2
    exit 1
}

for path in \
    "${ROOT}/linux-tp/arch/x86/boot/bzImage" \
    "${ROOT}/linux-6.8/arch/x86/boot/bzImage" \
    "${QEMU_ROOT}/build/qemu-system-x86_64" \
    "${QEMU_ROOT}/build/contrib/plugins/libdynamorio.so" \
    "${DYNAMORIO_ROOT}/build_linux/bin64/drrun" \
    "${FPT_KERNEL_DIR}/arch/x86/boot/bzImage" \
    "${EMT_ROOT}/linux-ecpt/arch/x86/boot/bzImage" \
    "${EMT_ROOT}/qemu-fpt/qemu-system-x86_64" \
    "${EMT_ROOT}/qemu-ecpt/qemu-system-x86_64" \
    "${EMT_ROOT}/qemu-fpt/tests/plugin/libexeclog.so" \
    "${EMT_ROOT}/qemu-ecpt/tests/plugin/libexeclog.so"; do
    [[ -s ${path} ]] || { echo "Missing build artifact: ${path}" >&2; exit 1; }
done
grep -q '^CONFIG_TRANSPARENT_HUGEPAGE=y$' "${ROOT}/linux-6.8/.config" || {
    echo "Vanilla Linux 6.8 lacks THP support" >&2
    exit 1
}
for kernel in "${FPT_KERNEL_DIR}" "${EMT_ROOT}/linux-ecpt"; do
    grep -q '^CONFIG_TRANSPARENT_HUGEPAGE=y$' "${kernel}/.config" || {
        echo "EMT kernel lacks THP support: ${kernel}" >&2
        exit 1
    }
done
for option in X86_64_FPT X86_64_FPT_L4L3; do
    grep -q "^CONFIG_${option}=y$" "${FPT_KERNEL_DIR}/.config" || {
        echo "FPT THP kernel requires CONFIG_${option}=y" >&2
        exit 1
    }
done
if grep -Eq '^CONFIG_X86_64_FPT_(L3L2|L4L3L2L1)=y$' "${FPT_KERNEL_DIR}/.config"; then
    echo "FPT THP kernel must leave L2 and L1 unflattened" >&2
    exit 1
fi
[[ ${DYNAMORIO_ROOT}/build_linux/clients/bin64/drcachesim -nt \
   ${DYNAMORIO_ROOT}/clients/drcachesim/reader/qemu_file_reader.cpp ]] || {
    echo "Rebuild drcachesim after changing its EMT trace reader" >&2
    exit 1
}

mkdir -p "${TRACE_ROOT}/logs" "${RESULT_ROOT}" /tmp/tppt-thp-top-pad-4way
for mode in "${MODES[@]}"; do
    mkdir -p "${RESULT_ROOT}/${mode}"
done
source "${QEMU_ROOT}/run_linux_thp_command.sh"

active_pids=()
active_traces=()
active_outputs=()
current_capture_pid=

cleanup()
{
    local pid child pgid own_pgid
    own_pgid=$(ps -o pgid= -p "$$" | tr -d ' ')
    if [[ -n ${current_capture_pid} ]]; then
        for child in $(pgrep -P "${current_capture_pid}" || true) "${current_capture_pid}"; do
            pgid=$(ps -o pgid= -p "${child}" 2>/dev/null | tr -d ' ' || true)
            if [[ -n ${pgid} && ${pgid} != "${own_pgid}" ]]; then
                kill -TERM -- "-${pgid}" 2>/dev/null || true
            fi
        done
        kill -TERM -- "${current_capture_pid}" 2>/dev/null || true
    fi
    for pid in "${active_pids[@]}"; do
        for child in $(pgrep -P "${pid}" || true) "${pid}"; do
            pgid=$(ps -o pgid= -p "${child}" 2>/dev/null | tr -d ' ' || true)
            if [[ -n ${pgid} && ${pgid} != "${own_pgid}" ]]; then
                kill -TERM -- "-${pgid}" 2>/dev/null || true
            fi
        done
        kill -TERM -- "${pid}" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap 'exit 130' INT TERM
trap cleanup EXIT

analysis_complete()
{
    local output=$1
    [[ -s ${output} ]] &&
        grep -q '^num_requests :' "${output}" &&
        grep -q '^~~~~~~ detailed perf stats ~~~~~~' "${output}" &&
        grep -A4 '^user memory references:' "${output}" |
            grep -q '^16,1000000000$'
}

trace_mode()
{
    case $1 in
        tp) echo tppt-thp ;;
        vanilla) echo vanilla-thp ;;
        fpt|ecpt) echo "$1" ;;
    esac
}

capture_trace()
{
    local workload=$1 mode=$2 trace=$3
    local stem console command kernel rc
    local -a env_args

    stem=$(basename "${trace}" .bin)
    console="${TRACE_ROOT}/logs/qemu_${stem}.log"
    if [[ -s ${trace} ]]; then
        grep -Eq "Reached[[:space:]]+${NUM_INST} user instrs" "${console}" &&
            grep -q 'Closed binary log file descriptor' "${console}" || {
            echo "Existing trace lacks a complete capture log: ${trace}" >&2
            return 1
        }
        echo "Reusing complete trace: ${trace}"
        return 0
    fi
    [[ ! -e ${trace} ]] || {
        echo "Empty or incomplete trace exists: ${trace}" >&2
        return 1
    }

    if [[ ${mode} == tp ]]; then
        command=${linux_thp_workloads[${workload}]}
    else
        command=${linux_thp_workloads_vanilla[${workload}]}
    fi
    # The prior successful 800M-element THP btree capture raised this VMA
    # limit; retain that setting for the same aligned-allocation workload.
    if [[ ${workload} == btree ]]; then
        command="echo 262144 > /proc/sys/vm/max_map_count; ${command}"
    fi
    command="echo 1 > /proc/sys/vm/overcommit_memory; export MALLOC_TOP_PAD_=${TOP_PAD_BYTES}; ${command}"
    env_args=(QEMU_MEMORY=200G TPPT_WORKLOAD_PLUGIN_MODE=logAll)

    case ${mode} in
        tp)
            kernel="${ROOT}/linux-tp"
            env_args+=(QEMU_TRACE_FORMAT=tppt-thp TPPT_THP_MODE=on
                TPPT_POOL_MB=163840 TPPT_POOL_BASE_PFN=1048576
                TPPT_BIN_COUNT=329728 TRANSPARENT_HUGEPAGE_MODE=never)
            ;;
        vanilla)
            kernel="${ROOT}/linux-6.8"
            env_args+=(QEMU_TRACE_FORMAT=tppt TPPT_THP_MODE=
                TRANSPARENT_HUGEPAGE_MODE=always)
            ;;
        fpt|ecpt)
            kernel="${EMT_ROOT}/linux-${mode}"
            if [[ ${mode} == fpt ]]; then
                kernel="${FPT_KERNEL_DIR}"
            fi
            env_args+=(QEMU_TRACE_FORMAT=emt TRANSPARENT_HUGEPAGE_MODE=always
                "QEMU_BIN=${EMT_ROOT}/qemu-${mode}/qemu-system-x86_64"
                "TPPT_KERNEL_FILE=${kernel}/arch/x86/boot/bzImage"
                "TPPT_WORKLOAD_PLUGIN=${EMT_ROOT}/qemu-${mode}/tests/plugin/libexeclog.so")
            ;;
    esac

    echo "Capturing ${workload}/${mode}: ${trace}"
    exec {capture_lock}>/tmp/tppt-mem-4way-qemu.lock
    flock "${capture_lock}"
    setsid --wait env "${env_args[@]}" "${QEMU_ROOT}/run-qemu-linux.sh" \
        "${kernel}" "${command}" "${trace}" "${NUM_INST}" \
        >"/tmp/tppt-thp-top-pad-4way/launcher_${stem}.log" 2>&1 9>&- &
    current_capture_pid=$!
    if wait "${current_capture_pid}"; then rc=0; else rc=$?; fi
    current_capture_pid=
    flock -u "${capture_lock}"
    exec {capture_lock}>&-

    [[ -s ${trace} ]] &&
        grep -Eq "Reached[[:space:]]+${NUM_INST} user instrs" "${console}" &&
        grep -q 'Closed binary log file descriptor' "${console}" || {
        echo "Capture incomplete for ${workload}/${mode} (QEMU status ${rc})" >&2
        return 1
    }
    echo "Captured ${workload}/${mode} (QEMU status ${rc})"
}

finish_oldest_analysis()
{
    local pid=${active_pids[0]}
    local trace=${active_traces[0]}
    local output=${active_outputs[0]}
    local partial="${output}.partial"
    if ! wait "${pid}" || ! analysis_complete "${partial}"; then
        echo "Simulation failed: ${output}; retained trace ${trace}" >&2
        return 1
    fi
    mv -- "${partial}" "${output}"
    rm -- "${trace}"
    echo "Validated ${output}; removed binary trace ${trace}"
    active_pids=("${active_pids[@]:1}")
    active_traces=("${active_traces[@]:1}")
    active_outputs=("${active_outputs[@]:1}")
}

start_analysis()
{
    local workload=$1 mode=$2 trace=$3 output=$4
    local format arch skip partial
    while (( ${#active_pids[@]} >= SIM_JOBS )); do
        finish_oldest_analysis
    done
    [[ ! -e ${output} ]] || {
        echo "Incomplete simulator output exists: ${output}" >&2
        return 1
    }
    partial="${output}.partial"
    rm -f -- "${partial}"
    case ${mode} in
        tp) format=tppt-thp; arch=radix; skip=false ;;
        vanilla) format=tppt; arch=radix; skip=true ;;
        fpt) format=emt; arch=fpt; skip=true ;;
        ecpt) format=emt; arch=ecpt; skip=true ;;
    esac
    echo "Simulating ${workload}/${mode}: ${output}"
    setsid --wait bash -c 'cd "$1"; shift; exec ./run_common.sh "$@"' _ \
        "${DYNAMORIO_ROOT}" "${trace}" "${partial}" "${skip}" false \
        "${DYNAMORIO_ROOT}/build_linux/bin64/drrun" false "${format}" \
        "${arch}" -1 \
        >"/tmp/tppt-thp-top-pad-4way/simulator_${workload}_${mode}.log" 2>&1 9>&- &
    active_pids+=("$!")
    active_traces+=("${trace}")
    active_outputs+=("${output}")
}

for workload in "${WORKLOADS[@]}"; do
    for mode in "${MODES[@]}"; do
        mode_name=$(trace_mode "${mode}")
        trace="${TRACE_ROOT}/${workload}_${mode_name}_${NUM_INST}.bin"
        output="${RESULT_ROOT}/${mode}/${workload}.log"
        if analysis_complete "${output}"; then
            echo "Reusing complete analysis: ${output}"
            continue
        fi
        capture_trace "${workload}" "${mode}" "${trace}"
        start_analysis "${workload}" "${mode}" "${trace}" "${output}"
    done
done

while (( ${#active_pids[@]} > 0 )); do
    finish_oldest_analysis
done

MPLCONFIGDIR=/tmp/tppt-thp-top-pad-4way/matplotlib \
PYTHONPYCACHEPREFIX=/tmp/tppt-thp-top-pad-4way/pycache \
python3 "${PLOT_ROOT}/plot.py" \
    --csv-mode write \
    --base-dir "${RESULT_ROOT}/vanilla" \
    --tp-dir "${RESULT_ROOT}/tp" \
    --fpt-dir "${RESULT_ROOT}/fpt" \
    --ecpt-dir "${RESULT_ROOT}/ecpt" \
    --workloads bfs,btree,cc,dc,dfs,gups,pr,sssp,tc,xsbench \
    --models Baseline,DMT,FPT,ECPT,TP \
    --cycle-model-dir "${DYNAMORIO_ROOT}" \
    --csv-dir "${PLOT_ROOT}/csv_linux_thp_top_pad_64g" \
    --output-dir "${PLOT_ROOT}/linux_thp_top_pad_64g" \
    --output-format png

echo "Top-pad THP four-way capture, simulation, and plots complete"
