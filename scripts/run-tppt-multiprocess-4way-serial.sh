#!/usr/bin/env bash
set -euo pipefail

# Bounded capture producers feed independent default simulation workers.
# No locks: run only one driver against these output roots at a time.
readonly ROOT=${TPPT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
readonly QEMU_ROOT=${ROOT}/qemu-linux
readonly DYNAMORIO_ROOT=${ROOT}/tp-emt-dynamorio
readonly EMT_ROOT=${ROOT}/emt-baselines/build
readonly NUM_INST=1000000000
readonly SIM_JOBS=${TPPT_SIM_JOBS:-12}
readonly MAX_QEMU=${TPPT_MAX_QEMU:-1}
readonly MIN_AVAILABLE_GIB=${TPPT_QEMU_MIN_AVAILABLE_GIB:-64}
readonly GRAPHBIG_PAYLOAD=${TPPT_GRAPHBIG_PAYLOAD:-}
readonly TP_KERNEL_FILE=${TPPT_TP_KERNEL_FILE:-${ROOT}/linux-tp/arch/x86/boot/bzImage}
read -r -a MODES <<< "${TPPT_MODES:-tp vanilla fpt ecpt tp-fb}"
readonly MODES
read -r -a WORKLOADS <<< "${TPPT_WORKLOADS:-postgres post-marker-redis bfs_p2 cc_p2 sssp_p2}"
readonly WORKLOADS

dry_run=false
case $#:$* in
    0:) ;;
    1:--dry-run) dry_run=true ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

die() { echo "ERROR: $*" >&2; exit 1; }
exists() { [[ -e $1 || -L $1 ]]; }
[[ ${SIM_JOBS} =~ ^[1-9][0-9]*$ ]] || die "TPPT_SIM_JOBS must be a positive integer"
[[ ${MAX_QEMU} =~ ^[1-9][0-9]*$ && ${MIN_AVAILABLE_GIB} =~ ^[0-9]+$ ]] || die "Invalid QEMU admission settings"
for mode in "${MODES[@]}"; do
    case ${mode} in tp|vanilla|fpt|ecpt|tp-fb) ;; *) die "Unknown mode: ${mode}" ;; esac
done

capture_failed()
{
    [[ -f $1 ]] && grep -Eq 'Assertion .* failed[.]|Kernel panic - not syncing:|BUG: unable to handle|Oops:' "$1"
}

capture_complete()
{
    [[ -s $1 ]] || return 1
    ! capture_failed "$1" || return 1
    if [[ ${2:-} == tp-fb ]]; then
        grep -Fq 'tppt: LUT fallback enabled (own LUT0 only)' "$1" || return 1
    fi
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
    local workload=$1 mode=$2 trace_root result_root legacy
    case ${workload} in
        postgres|post-marker-redis|bfs_p2|cc_p2|sssp_p2)
            trace_root=${QEMU_ROOT}/results_mp_4way
            result_root=${DYNAMORIO_ROOT}/results/linux_mp_4way/default ;;
        *) die "Unknown workload: ${workload}" ;;
    esac
    trace="${trace_root}/${workload}_${mode}_${NUM_INST}.bin"
    legacy="${trace%.bin}.log"
    if exists "${legacy}"; then
        ! exists "${trace}" || die "Both .bin and .log traces exist: ${trace}"
        trace=${legacy}
    fi
    partial="${trace_root}/${workload}_${mode}_${NUM_INST}.partial"
    console="${trace_root}/logs/qemu_${workload}_${mode}_${NUM_INST}.log"
    output="${result_root}/${mode}/${workload}.txt"
}

classify()
{
    local path
    paths "$1" "$2"
    # A running pre-rename batch must finish before these keys can be reused.
    if [[ $1 == *_p2 ]]; then
        for path in "${QEMU_ROOT}/results_mp_4way/${1}_r1_${2}_${NUM_INST}."{bin,partial,log} \
            "${QEMU_ROOT}/results_mp_4way/logs/qemu_${1}_r1_${2}_${NUM_INST}.log" \
            "${DYNAMORIO_ROOT}/results/linux_mp_4way/default/${2}/${1}_r1.txt"{,.partial}; do
            ! exists "${path}" || die "Naming migration still pending for $1/$2: ${path}"
        done
    fi
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
    if capture_complete "${console}" "$2"; then
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

# Pin the historical workload settings; the generic app command file differs.
export TPPT_WORKLOAD_USER=${TPPT_WORKLOAD_USER:-myq}
source "${QEMU_ROOT}/run_linux_command.sh"
readonly WORKLOAD_USER
[[ ${WORKLOAD_USER} =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid guest workload user"
pg_prefix="cd /home/${WORKLOAD_USER}/apps/postgres/build_dir/bin; su ${WORKLOAD_USER} -c '"
pg_args="./mosaictest --single -D /home/${WORKLOAD_USER}/apps/postgres/data postgres -c shared_memory_type=mmap -c shared_buffers=64GB -c huge_pages=off -a 1 -R 12000000'"
linux_workloads_vanilla[postgres]="${pg_prefix}${pg_args}"
linux_workloads_tp[postgres]="${pg_prefix}/usr/local/bin/tppt_exec ${pg_args}"
linux_workloads_vanilla[post-marker-redis]="/home/${WORKLOAD_USER}/apps/post-marker-redis/mosaictest"
linux_workloads_tp[post-marker-redis]="/usr/local/bin/tppt_exec ${linux_workloads_vanilla[post-marker-redis]}"

# Scan all selected combinations before mutating anything, including on resume.
workloads=() modes=() actions=()
declare -A capture_modes=()
skip_count=0 capture_count=0 simulate_count=0
for workload in "${WORKLOADS[@]}"; do
    for mode in "${MODES[@]}"; do
        classify "${workload}" "${mode}"
        workloads+=("${workload}") modes+=("${mode}") actions+=("${action}")
        case ${action} in
            SKIP) skip_count=$((skip_count + 1)) ;;
            CAPTURE)
                capture_count=$((capture_count + 1))
                capture_modes[${mode}]=1 ;;
            *) simulate_count=$((simulate_count + 1)) ;;
        esac
        echo "${action} ${workload}/${mode}"
        if ${dry_run}; then
            command=${linux_workloads_vanilla[${workload}]}
            case ${mode} in tp|tp-fb) command=${linux_workloads_tp[${workload}]} ;; esac
            printf '  guest: echo 1 > /proc/sys/vm/overcommit_memory; %s\n' "${command}"
            if [[ ${mode} == tp || ${mode} == tp-fb ]]; then
                printf '  kernel: %s\n' "${TP_KERNEL_FILE}"
                [[ ${mode} != tp-fb ]] || printf '  extra boot argument: tppt.lut_fallback=on\n'
            fi
            printf '  trace: %s\n  console: %s\n  simulation: %s\n' "${trace}" "${console}" "${output}"
        fi
    done
done
echo "Plan: ${skip_count} complete, ${capture_count} new captures, ${simulate_count} retained traces to simulate"
echo "Capture admission: at most ${MAX_QEMU} total QEMUs; ${MIN_AVAILABLE_GIB} GiB available before launch"
if [[ -n ${capture_modes[fpt]:-}${capture_modes[ecpt]:-} ]] || (( simulate_count > 0 )); then
    echo "NOTE: EMT address-space IDs are not yet preserved; completion does not validate multiprocess TLB accuracy." >&2
fi
${dry_run} && exit 0

for index in "${!actions[@]}"; do
    if [[ ${actions[index]} == CAPTURE && ${workloads[index]} == *_p2 && -n ${GRAPHBIG_PAYLOAD} ]]; then
        [[ -s ${GRAPHBIG_PAYLOAD} && ${GRAPHBIG_PAYLOAD} = /* && ${GRAPHBIG_PAYLOAD} != *,* ]] || \
            die "Invalid TPPT_GRAPHBIG_PAYLOAD (expected an absolute ext4 image path)"
    fi
done

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
        tp|tp-fb) kernel=${ROOT}/linux-tp; qemu=${QEMU_ROOT}/build/qemu-system-x86_64
            plugin=${QEMU_ROOT}/build/contrib/plugins/libdynamorio.so ;;
        vanilla) kernel=${ROOT}/linux-6.8; qemu=${QEMU_ROOT}/build/qemu-system-x86_64
            plugin=${QEMU_ROOT}/build/contrib/plugins/libdynamorio.so ;;
        fpt|ecpt) kernel=${EMT_ROOT}/linux-${mode}; qemu=${EMT_ROOT}/qemu-${mode}/qemu-system-x86_64
            plugin=${EMT_ROOT}/qemu-${mode}/tests/plugin/libexeclog.so ;;
    esac
    [[ -x ${qemu} && -x ${QEMU_ROOT}/run-qemu-linux.sh ]] || die "Missing capture executable for ${mode}"
    kernel_file=${kernel}/arch/x86/boot/bzImage
    case ${mode} in tp|tp-fb) kernel_file=${TP_KERNEL_FILE} ;; esac
    for path in "${kernel_file}" "${plugin}" "${ROOT}/disk.img"; do
        [[ -s ${path} ]] || die "Missing artifact: ${path}"
    done
done

for index in "${!actions[@]}"; do
    paths "${workloads[index]}" "${modes[index]}"
    mkdir -p "$(dirname "${console}")" "$(dirname "${output}")"
done

capture_pid=
declare -A capture_pids=()
declare -A simulation_pids=()
queued_simulations=()
failed_jobs=()
cleanup()
{
    local rc=$? pid attempt
    local -a pids=( ${capture_pid:-} "${!simulation_pids[@]}" "${!capture_pids[@]}" )
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
    local pid index workload mode trace partial console output
    for pid in "${!simulation_pids[@]}"; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            if ! wait "${pid}"; then
                echo "ERROR: Simulation failed: ${simulation_pids[${pid}]}; retained trace and partial output." >&2
                failed_jobs+=("simulate ${simulation_pids[${pid}]}")
            fi
            unset 'simulation_pids['"${pid}"']'
        fi
    done
    while (( ${#queued_simulations[@]} > 0 && ${#simulation_pids[@]} < SIM_JOBS )); do
        index=${queued_simulations[0]}
        queued_simulations=("${queued_simulations[@]:1}")
        workload=${workloads[index]} mode=${modes[index]}
        paths "${workload}" "${mode}"
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

capture_resources_ready()
{
    local pid index
    local -a owned_partials=()
    for pid in "${!capture_pids[@]}"; do
        index=${capture_pids[${pid}]}
        owned_partials+=("${QEMU_ROOT}/results_mp_4way/${workloads[index]}_${modes[index]}_${NUM_INST}.partial")
    done
    python3 - "${MAX_QEMU}" "${MIN_AVAILABLE_GIB}" "${ROOT}" "${owned_partials[@]}" <<'PY'
from pathlib import Path
import os, shutil, sys
partials = [p.encode() for p in sys.argv[4:]]
count = owned = 0
for proc in Path('/proc').iterdir():
    if not proc.name.isdigit():
        continue
    try:
        command = (proc / 'cmdline').read_bytes()
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        continue
    if os.path.basename(command.split(b'\0', 1)[0]).startswith(b'qemu-system-'):
        count += 1
        owned += any(p in command for p in partials)
# Reserve slots for capture children that have not reached exec(QEMU) yet.
count += max(0, len(partials) - owned)
available = int(next(line.split()[1] for line in
    Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:')))
ready = (count < int(sys.argv[1]) and available >= int(sys.argv[2]) * 1024**2
         and shutil.disk_usage(sys.argv[3]).free >= (128 + 512 * (len(partials) + 1)) * 1024**3)
raise SystemExit(0 if ready else 1)
PY
}

capture_trace()
{
    local workload=$1 mode=$2 command kernel kernel_file rc
    local -a env_args=(QEMU_MEMORY=128G TPPT_WORKLOAD_PLUGIN_MODE=logAll
        "DISK_IMAGE=${ROOT}/disk.img" TPPT_ROOT_DEVICE=/dev/sda
        "QEMU_BIN=${QEMU_ROOT}/build/qemu-system-x86_64"
        "TPPT_WORKLOAD_PLUGIN=${QEMU_ROOT}/build/contrib/plugins/libdynamorio.so"
        QEMU_CPU=max,-la57,+invtsc TPPT_KERNEL_DEBUG=0
        TPPT_THP_MODE=off TRANSPARENT_HUGEPAGE_MODE=never
        TPPT_LUT_FALLBACK= QEMU_PAYLOAD_IMAGE=
        TPPT_POOL_MB= TPPT_POOL_BASE_PFN= TPPT_BIN_COUNT=
        QEMU_TRACE_FORMAT=tppt TPPT_OVERWRITE_OUTPUT=0)
    command=${linux_workloads_vanilla[${workload}]}
    case ${mode} in
        tp|tp-fb)
            kernel=${ROOT}/linux-tp
            command=${linux_workloads_tp[${workload}]}
            if [[ ${workload} == *_p2 ]]; then
                env_args+=(QEMU_MEMORY=128G TPPT_POOL_MB=65535 TPPT_POOL_BASE_PFN=1048576 TPPT_BIN_COUNT=131072)
            else
                env_args+=(QEMU_MEMORY=200G TPPT_POOL_MB=163840 TPPT_POOL_BASE_PFN=1048576 TPPT_BIN_COUNT=329728)
            fi
            ;;
        vanilla) kernel=${ROOT}/linux-6.8 ;;
        fpt|ecpt)
            kernel=${EMT_ROOT}/linux-${mode}
            env_args+=(QEMU_MEMORY=128G QEMU_TRACE_FORMAT=emt
                "QEMU_BIN=${EMT_ROOT}/qemu-${mode}/qemu-system-x86_64"
                "TPPT_WORKLOAD_PLUGIN=${EMT_ROOT}/qemu-${mode}/tests/plugin/libexeclog.so")
            ;;
    esac
    kernel_file=${kernel}/arch/x86/boot/bzImage
    case ${mode} in tp|tp-fb) kernel_file=${TP_KERNEL_FILE} ;; esac
    env_args+=("TPPT_KERNEL_FILE=${kernel_file}")
    [[ ${mode} != tp-fb ]] || env_args+=(TPPT_LUT_FALLBACK=on)
    command="echo 1 > /proc/sys/vm/overcommit_memory; ${command}"
    if [[ ${workload} == *_p2 ]]; then
        command="{ test ! -e /sys/kernel/mm/transparent_hugepage/shmem_enabled || echo never > /sys/kernel/mm/transparent_hugepage/shmem_enabled; } && { ${command}; }"
        if [[ -n ${GRAPHBIG_PAYLOAD} ]]; then
            local guest_dir=/home/${WORKLOAD_USER}/mem-apps/graphbig/multiprocess
            env_args+=("QEMU_PAYLOAD_IMAGE=${GRAPHBIG_PAYLOAD}")
            command="mkdir -p ${guest_dir} && mount -t ext4 -o ro,noload /dev/sdb ${guest_dir} && cd ${guest_dir} && { ${command}; }"
        fi
    fi
    echo "CAPTURE ${workload}/${mode}"
    # .partial and .bin share the console stem used by run-qemu-linux.sh.
    setsid --wait env "${env_args[@]}" "${QEMU_ROOT}/run-qemu-linux.sh" \
        "${kernel}" "${command}" "${partial}" "${NUM_INST}" 2>&1 &
    capture_pid=$!
    while kill -0 "${capture_pid}" 2>/dev/null; do
        if capture_failed "${console}"; then
            die "Guest assertion/panic: ${workload}/${mode}; retained partial/logs"
        fi
        if [[ ${mode} == tp-fb && -f ${console} ]] &&
            grep -Fq 'Run /bin/bash as init process' "${console}" &&
            ! grep -Fq 'tppt: LUT fallback enabled (own LUT0 only)' "${console}"; then
            die "Kernel did not enable LUT fallback: ${workload}/${mode}; retained partial/logs"
        fi
        if [[ -f ${partial} ]] && (( $(stat -c %s "${partial}") > 549755813888 )); then
            die "Capture exceeded 512 GiB: ${workload}/${mode}; retained partial/logs"
        fi
        sleep 1
    done
    if wait "${capture_pid}"; then rc=0; else rc=$?; fi
    capture_pid=
    [[ -s ${partial} ]] && capture_complete "${console}" "${mode}" || \
        die "Capture incomplete: ${workload}/${mode} (QEMU status ${rc}); retained partial/logs"
    if [[ ${workload} == *_p2 ]]; then
        grep -Fq '== 1193579 vertices  55656914 edges' "${console}" || die "Unexpected graph in ${console}"
    fi
    # EMT can return nonzero after emitting its complete instruction budget.
    echo "CAPTURED ${workload}/${mode} (QEMU status ${rc})"
    mv -- "${partial}" "${trace}"
}

service_captures()
{
    local pid index
    for pid in "${!capture_pids[@]}"; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            index=${capture_pids[${pid}]}
            if wait "${pid}"; then
                queued_simulations+=("${index}")
            else
                echo "ERROR: Capture failed: ${workloads[index]}/${modes[index]}; retained partial/logs" >&2
                failed_jobs+=("capture ${workloads[index]}/${modes[index]}")
            fi
            unset 'capture_pids['"${pid}"']'
        fi
    done
}

# Retire old, validated captures first, freeing space before any new capture.
pending_captures=()
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
        CAPTURE) pending_captures+=("${index}"); continue ;;
        PROMOTE_SIMULATE) mv -- "${partial}" "${trace}" ;;
    esac
    queued_simulations+=("${index}")
    service_simulations
done
while (( ${#pending_captures[@]} > 0 || ${#capture_pids[@]} > 0 || ${#simulation_pids[@]} > 0 || ${#queued_simulations[@]} > 0 )); do
    service_captures
    service_simulations
    if (( ${#pending_captures[@]} > 0 && ${#capture_pids[@]} < MAX_QEMU )) && capture_resources_ready; then
        index=${pending_captures[0]}
        pending_captures=("${pending_captures[@]:1}")
        workload=${workloads[index]} mode=${modes[index]}
        paths "${workload}" "${mode}"
        (
            capture_pids=(); simulation_pids=(); queued_simulations=(); capture_pid=
            trap cleanup EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM
            capture_trace "${workload}" "${mode}"
        ) &
        capture_pids[$!]=${index}
    fi
    sleep 1
done
if (( ${#failed_jobs[@]} > 0 )); then
    printf 'FAILED: %s\n' "${failed_jobs[@]}" >&2
    exit 1
fi
echo "All ${#actions[@]} multiprocess captures and default simulations complete; console logs and simulator results retained"
