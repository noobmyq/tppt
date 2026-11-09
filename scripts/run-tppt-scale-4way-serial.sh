#!/usr/bin/env bash
set -euo pipefail

# One serial capture producer feeds independent default simulation workers.
# No locks: run only one driver against these output roots at a time.
readonly ROOT=${TPPT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
readonly QEMU_ROOT=${ROOT}/qemu-linux
readonly DYNAMORIO_ROOT=${ROOT}/tp-emt-dynamorio
readonly EMT_ROOT=${ROOT}/emt-baselines/build
readonly TRACE_ROOT=${TPPT_TRACE_ROOT:-${QEMU_ROOT}/results_scale}
readonly RESULT_ROOT=${TPPT_RESULT_ROOT:-${DYNAMORIO_ROOT}/results/linux_scale}
readonly NUM_INST=1000000000
readonly SIM_JOBS=${TPPT_SIM_JOBS:-12}
readonly MODES=(tp vanilla ecpt fpt)
readonly SIZES=(1 2 4 8 16 32 64 128)

dry_run=false
case $#:$* in
    0:) ;;
    1:--dry-run) dry_run=true ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

die() { echo "ERROR: $*" >&2; exit 1; }
exists() { [[ -e $1 || -L $1 ]]; }
[[ ${SIM_JOBS} =~ ^[1-9][0-9]*$ ]] || die "TPPT_SIM_JOBS must be a positive integer"

capture_complete()
{
    [[ -s $1 ]] || return 1
    awk -v budget="${NUM_INST}" '
        /\[Sim Plugin\] Reached[[:space:]]+[0-9]+ user instrs/ {
            if ($4 == budget) reached = 1
        }
        /\[Sim Plugin\] Total simulated [0-9]+ user instrs/ {
            if ($5 >= budget) reached = 1
        }
        /\[Sim Plugin\] Closed binary log file descriptor/ { closed = 1 }
        END { exit !(reached && closed) }
    ' "$1"
}

analysis_complete()
{
    [[ -s $1 ]] || return 1
    awk -v budget="${NUM_INST}" '
        /^num_requests[[:space:]]*:/ {
            if ($NF ~ /^[0-9]+$/ && $NF > 0) requests = 1
        }
        /^~~~~~~ detailed perf stats ~~~~~~/ { perf = 1 }
        /^user memory references:/ { user_line = NR }
        user_line && NR > user_line && NR <= user_line + 4 {
            sub(/\r$/, "")
            if ($0 == "16," budget) instructions = 1
        }
        END { exit !(requests && perf && instructions) }
    ' "$1"
}

paths()
{
    trace="${TRACE_ROOT}/${1}_${2}_${NUM_INST}.log"
    partial="${trace%.log}.partial"
    console="${TRACE_ROOT}/logs/qemu_${1}_${2}_${NUM_INST}.log"
    output="${RESULT_ROOT}/default/${2}/${1}.txt"
}

classify()
{
    local path
    paths "$1" "$2"
    for path in "${trace}" "${partial}" "${console}" "${output}" "${output}.partial"; do
        [[ ! -L ${path} ]] || die "Refusing symlink: ${path}"
        ! exists "${path}" || [[ -f ${path} ]] || die "Not a regular file: ${path}"
    done
    if exists "${trace}" && exists "${partial}"; then
        die "Both final and partial traces exist; inspect ${trace} and ${partial}"
    fi
    if exists "${output}" && ! analysis_complete "${output}"; then
        die "Invalid final simulator output; will not overwrite: ${output}"
    fi
    if capture_complete "${console}"; then
        if analysis_complete "${output}"; then
            action=SKIP
        elif [[ -s ${trace} ]]; then
            action=SIMULATE
        elif [[ -s ${partial} ]]; then
            # Recover interruption between capture completion and rename.
            action=PROMOTE_SIMULATE
        else
            die "Completed QEMU log but no trace or valid simulation: ${console}"
        fi
    else
        for path in "${trace}" "${partial}" "${console}" "${output}" "${output}.partial"; do
            ! exists "${path}" || die "No completed capture; inspect existing artifact: ${path}"
        done
        action=CAPTURE
    fi
}

# Scan every combination before mutating anything, including on resume.
source "${QEMU_ROOT}/run_scale_command.sh"
workloads=() modes=() actions=()
declare -A capture_modes=()
skip_count=0 capture_count=0 simulate_count=0 deferred_count=0
for app in gups xsbench; do
    for size in "${SIZES[@]}"; do
        workload=${app}-${size}G
        [[ -n ${linux_workloads_tp[${workload}]:-} &&
           -n ${linux_workloads_vanilla[${workload}]:-} ]] || die "Missing command: ${workload}"
        for mode in "${MODES[@]}"; do
            if [[ ${size} == 128 && ( ${mode} == ecpt || ${mode} == fpt ) ]]; then
                echo "DEFER ${workload}/${mode}; 128G EMT workloads need a separate RAM decision"
                deferred_count=$((deferred_count + 1))
                continue
            fi
            classify "${workload}" "${mode}"
            workloads+=("${workload}") modes+=("${mode}") actions+=("${action}")
            case ${action} in
                SKIP)
                    skip_count=$((skip_count + 1))
                    if exists "${trace}" || exists "${partial}"; then
                        echo "SKIP ${workload}/${mode}; retire validated binary trace"
                    else
                        echo "SKIP ${workload}/${mode}"
                    fi
                    ;;
                CAPTURE)
                    capture_count=$((capture_count + 1))
                    capture_modes[${mode}]=1
                    echo "CAPTURE + SIMULATE ${workload}/${mode}"
                    ;;
                *)
                    simulate_count=$((simulate_count + 1))
                    echo "${action} ${workload}/${mode} (capture already complete)"
                    ;;
            esac
        done
    done
done
echo "Plan: ${skip_count} complete, ${capture_count} new captures, ${simulate_count} retained traces to simulate, ${deferred_count} deferred"
${dry_run} && exit 0

# Check only tools needed for the outstanding work. Never rebuild implicitly.
if (( capture_count + simulate_count > 0 )); then
    for path in "${DYNAMORIO_ROOT}/run_common.sh" "${DYNAMORIO_ROOT}/build_linux/bin64/drrun" \
        "${DYNAMORIO_ROOT}/build_linux/clients/bin64/drcachesim"; do
        [[ -x ${path} ]] || die "Missing executable: ${path}"
    done
    command -v setsid >/dev/null || die "setsid is required"
fi
for mode in "${!capture_modes[@]}"; do
    case ${mode} in
        tp) kernel=${ROOT}/linux-tp; qemu=${QEMU_ROOT}/build/qemu-system-x86_64
            plugin=${QEMU_ROOT}/build/contrib/plugins/libdynamorio.so ;;
        vanilla) kernel=${ROOT}/linux-6.8; qemu=${QEMU_ROOT}/build/qemu-system-x86_64
            plugin=${QEMU_ROOT}/build/contrib/plugins/libdynamorio.so ;;
        fpt|ecpt) kernel=${EMT_ROOT}/linux-${mode}; qemu=${EMT_ROOT}/qemu-${mode}/qemu-system-x86_64
            plugin=${EMT_ROOT}/qemu-${mode}/tests/plugin/libexeclog.so ;;
    esac
    [[ -x ${qemu} && -x ${QEMU_ROOT}/run-qemu-linux.sh ]] || die "Missing capture executable for ${mode}"
    for path in "${kernel}/arch/x86/boot/bzImage" "${plugin}" "${ROOT}/disk.img"; do
        [[ -s ${path} ]] || die "Missing artifact: ${path}"
    done
done

mkdir -p "${TRACE_ROOT}/logs"
for mode in "${MODES[@]}"; do mkdir -p "${RESULT_ROOT}/default/${mode}"; done

capture_pid=
declare -A simulation_pids=()
queued_simulations=()
cleanup()
{
    local rc=$? pid attempt
    local -a pids=( ${capture_pid:-} "${!simulation_pids[@]}" )
    trap - EXIT INT TERM
    # Each launched child owns a session; terminate only our process groups.
    for pid in "${pids[@]}"; do
        kill -TERM -- "-${pid}" 2>/dev/null || true
        kill -TERM "${pid}" 2>/dev/null || true
    done
    for attempt in {1..50}; do
        if ! kill -0 "${pids[@]}" 2>/dev/null; then break; fi
        sleep 0.1
    done
    for pid in "${pids[@]}"; do
        kill -KILL -- "-${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

service_simulations()
{
    local pid index workload mode trace output
    for pid in "${!simulation_pids[@]}"; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            if ! wait "${pid}"; then
                die "Simulation failed: ${simulation_pids[${pid}]}; retained trace and partial output."
            fi
            unset 'simulation_pids['"${pid}"']'
        fi
    done
    while (( ${#queued_simulations[@]} > 0 && ${#simulation_pids[@]} < SIM_JOBS )); do
        index=${queued_simulations[0]}
        queued_simulations=("${queued_simulations[@]:1}")
        workload=${workloads[index]} mode=${modes[index]}
        trace=${TRACE_ROOT}/${workload}_${mode}_${NUM_INST}.log
        output=${RESULT_ROOT}/default/${mode}/${workload}.txt
        setsid --wait bash -euo pipefail -c 'analyze_trace "$@"' _ \
            "${workload}" "${mode}" "${trace}" "${output}" &
        simulation_pids[$!]=${workload}/${mode}
    done
}

analyze_trace()
{
    local workload=$1 mode=$2 trace=$3 output=$4
    local skip=false format=tppt arch=radix
    case ${mode} in
        vanilla) skip=true ;;
        fpt|ecpt) skip=true; format=emt; arch=${mode} ;;
    esac
    echo "SIMULATE ${workload}/${mode}"
    # Only the simulator partial is disposable; keep the input on failure.
    cd "${DYNAMORIO_ROOT}"
    "${DYNAMORIO_ROOT}/run_common.sh" "${trace}" "${output}.partial" \
        "${skip}" false "${DYNAMORIO_ROOT}/build_linux/bin64/drrun" \
        false "${format}" "${arch}" -1 2>&1
    analysis_complete "${output}.partial" || {
        echo "Invalid simulator output: ${output}.partial" >&2
        return 1
    }
    [[ ! -e ${output} ]] || return 1
    mv -- "${output}.partial" "${output}"
    rm -- "${trace}"
    echo "DONE ${workload}/${mode}; validated simulation, removed binary trace"
}
export DYNAMORIO_ROOT NUM_INST
export -f analyze_trace analysis_complete

capture_trace()
{
    local workload=$1 mode=$2 command kernel rc
    local -a env_args=(QEMU_MEMORY=200G TPPT_WORKLOAD_PLUGIN_MODE=logAll
        "DISK_IMAGE=${ROOT}/disk.img" TPPT_ROOT_DEVICE=/dev/sda
        "QEMU_BIN=${QEMU_ROOT}/build/qemu-system-x86_64"
        "TPPT_WORKLOAD_PLUGIN=${QEMU_ROOT}/build/contrib/plugins/libdynamorio.so"
        QEMU_CPU=max,-la57,+invtsc TPPT_KERNEL_DEBUG=0
        TPPT_THP_MODE=off TRANSPARENT_HUGEPAGE_MODE=never
        TPPT_POOL_MB= TPPT_POOL_BASE_PFN= TPPT_BIN_COUNT=
        QEMU_TRACE_FORMAT=tppt TPPT_OVERWRITE_OUTPUT=0)
    command=${linux_workloads_vanilla[${workload}]}
    case ${mode} in
        tp)
            kernel=${ROOT}/linux-tp
            command=${linux_workloads_tp[${workload}]}
            env_args+=(TPPT_POOL_MB=163840 TPPT_POOL_BASE_PFN=1048576 TPPT_BIN_COUNT=329728)
            ;;
        vanilla) kernel=${ROOT}/linux-6.8 ;;
        fpt|ecpt)
            kernel=${EMT_ROOT}/linux-${mode}
            env_args+=(QEMU_MEMORY=128G QEMU_TRACE_FORMAT=emt
                "QEMU_BIN=${EMT_ROOT}/qemu-${mode}/qemu-system-x86_64"
                "TPPT_WORKLOAD_PLUGIN=${EMT_ROOT}/qemu-${mode}/tests/plugin/libexeclog.so")
            ;;
    esac
    env_args+=("TPPT_KERNEL_FILE=${kernel}/arch/x86/boot/bzImage")
    command="echo 1 > /proc/sys/vm/overcommit_memory; ${command}"
    echo "CAPTURE ${workload}/${mode}"
    # .partial and .log share the console stem used by run-qemu-linux.sh.
    setsid --wait env "${env_args[@]}" "${QEMU_ROOT}/run-qemu-linux.sh" \
        "${kernel}" "${command}" "${partial}" "${NUM_INST}" 2>&1 &
    capture_pid=$!
    while kill -0 "${capture_pid}" 2>/dev/null; do
        service_simulations
        sleep 1
    done
    if wait "${capture_pid}"; then rc=0; else rc=$?; fi
    capture_pid=
    [[ -s ${partial} ]] && capture_complete "${console}" || \
        die "Capture incomplete: ${workload}/${mode} (QEMU status ${rc}); retained partial/logs"
    # EMT can return nonzero after emitting its complete instruction budget.
    echo "CAPTURED ${workload}/${mode} (QEMU status ${rc})"
    mv -- "${partial}" "${trace}"
}

# Retire old, validated captures first, freeing space before any new capture.
for index in "${!actions[@]}"; do
    [[ ${actions[index]} == SKIP ]] || continue
    paths "${workloads[index]}" "${modes[index]}"
    for path in "${trace}" "${partial}"; do
        if [[ -f ${path} ]]; then
            rm -- "${path}"
            echo "Removed previously analyzed binary trace: ${path}"
        fi
    done
done

for index in "${!actions[@]}"; do
    [[ ${actions[index]} != SKIP ]] || continue
    workload=${workloads[index]} mode=${modes[index]}
    paths "${workload}" "${mode}"
    case ${actions[index]} in
        CAPTURE) capture_trace "${workload}" "${mode}" ;;
        PROMOTE_SIMULATE) mv -- "${partial}" "${trace}" ;;
    esac
    queued_simulations+=("${index}")
    service_simulations
done
while (( ${#simulation_pids[@]} > 0 || ${#queued_simulations[@]} > 0 )); do
    service_simulations
    if (( ${#simulation_pids[@]} > 0 )); then sleep 1; fi
done
echo "All ${#actions[@]} selected scaling captures and default simulations complete (${deferred_count} deferred); console logs and simulator results retained"
