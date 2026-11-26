#!/usr/bin/env bash
set -euo pipefail

# A bounded capture producer overlaps four analysis workers (eight simulations).
# Completed default/mmu_to_l2 pairs are reused, including historical results
# whose capture logs are no longer available. Each TP trace feeds both
# 8 MiB and 2 MiB TLB simulations. Retain traces after all analyses validate.
# No locks: coordinate competing capture drivers explicitly.
readonly ROOT=${TPPT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
readonly QEMU_ROOT=${ROOT}/qemu-linux
readonly DYNAMORIO_ROOT=${ROOT}/tp-emt-dynamorio
readonly EMT_ROOT=${ROOT}/emt-baselines/build
# Flatten L4+L3 only so FPT retains normal PMD huge-page leaves.
readonly FPT_KERNEL_DIR=${EMT_ROOT}/linux-fpt-l4l3-thp
readonly VANILLA_KERNEL_DIR=${TPPT_VANILLA_LINUX_FOLDER:-${ROOT}/linux-6.8}
readonly TRACE_ROOT=${TPPT_TRACE_ROOT:-${QEMU_ROOT}/results_thp_tcmalloc_fragmented_4way}
readonly RESULT_ROOT=${TPPT_RESULT_ROOT:-${DYNAMORIO_ROOT}/results/linux_thp_tcmalloc_fragmented_4way}
readonly NUM_INST=${TPPT_NUM_INST:-1000000000}
readonly DISK_IMAGE=${DISK_IMAGE:-${ROOT}/disk.img}
read -r -a MODES <<< "${TPPT_MODES:-tp vanilla fpt ecpt}"
readonly MODES
(( ${#MODES[@]} > 0 )) || { echo 'TPPT_MODES is empty' >&2; exit 2; }
seen_modes=' '
for mode in "${MODES[@]}"; do
    case ${mode} in
        tp|vanilla|fpt|ecpt) ;;
        *) echo "Unknown TPPT_MODES entry: ${mode}" >&2; exit 2 ;;
    esac
    [[ ${seen_modes} != *" ${mode} "* ]] || {
        echo "Duplicate TPPT_MODES entry: ${mode}" >&2; exit 2;
    }
    seen_modes+="${mode} "
done
readonly MAX_WORKERS=4
readonly MAX_QEMU=${TPPT_MAX_QEMU:-1}
readonly MIN_AVAILABLE_GIB=${TPPT_QEMU_MIN_AVAILABLE_GIB:-180}
# 160 GiB requested TP pool rounds down to 161 complete 1016 MiB Huge-Bins.
# Use the same materialized/retained byte counts in all four configurations.
readonly FRAGMENT_BUDGET_MIB=163576
readonly FRAGMENT_FILL=90
readonly FRAGMENT_KEEP=10
readonly FRAGMENT_PIN_STRIDE=${TPPT_FRAGMENT_PIN_STRIDE:-256}
case ${FRAGMENT_PIN_STRIDE} in
    0|128|256) ;;
    *) echo 'TPPT_FRAGMENT_PIN_STRIDE must be 0 (random only), 128, or 256' >&2; exit 2 ;;
esac

[[ ${NUM_INST} =~ ^[1-9][0-9]*$ ]] || {
    echo "TPPT_NUM_INST must be a positive integer" >&2
    exit 2
}
[[ ${MAX_QEMU} =~ ^[1-9][0-9]*$ && ${MIN_AVAILABLE_GIB} =~ ^(0|[1-9][0-9]*)$ ]] || {
    echo "TPPT_MAX_QEMU must be positive; TPPT_QEMU_MIN_AVAILABLE_GIB must be nonnegative" >&2
    exit 2
}

dry_run=false
case $#:$* in
    0:) ;;
    1:--dry-run) dry_run=true ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

for path in "${DISK_IMAGE}" \
    "${QEMU_ROOT}/build/qemu-system-x86_64" \
    "${QEMU_ROOT}/build/contrib/plugins/libdynamorio.so" \
    "${DYNAMORIO_ROOT}/build_linux/bin64/drrun"; do
    [[ -s ${path} ]] || { echo "Missing build artifact: ${path}" >&2; exit 1; }
done
if [[ " ${MODES[*]} " == *' vanilla '* ]]; then
    grep -q '^CONFIG_TRANSPARENT_HUGEPAGE=y$' "${VANILLA_KERNEL_DIR}/.config" || {
        echo "Vanilla Linux 6.8 lacks THP support" >&2
        exit 1
    }
fi
for mode in "${MODES[@]}"; do
    case ${mode} in
        tp) kernel=${ROOT}/linux-tp ;;
        vanilla) kernel=${VANILLA_KERNEL_DIR} ;;
        fpt) kernel=${FPT_KERNEL_DIR} ;;
        ecpt) kernel=${EMT_ROOT}/linux-ecpt ;;
    esac
    [[ -s ${kernel}/arch/x86/boot/bzImage ]] || {
        echo "Missing kernel: ${kernel}" >&2; exit 1;
    }
    [[ ${mode} == fpt || ${mode} == ecpt ]] || continue
    for path in "${EMT_ROOT}/qemu-${mode}/qemu-system-x86_64" \
        "${EMT_ROOT}/qemu-${mode}/tests/plugin/libexeclog.so"; do
        [[ -s ${path} ]] || { echo "Missing build artifact: ${path}" >&2; exit 1; }
    done
    grep -q '^CONFIG_TRANSPARENT_HUGEPAGE=y$' "${kernel}/.config" || {
        echo "EMT kernel lacks THP support: ${kernel}" >&2
        exit 1
    }
done
if [[ " ${MODES[*]} " == *' fpt '* ]]; then
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
fi
[[ ${DYNAMORIO_ROOT}/build_linux/clients/bin64/drcachesim -nt \
   ${DYNAMORIO_ROOT}/clients/drcachesim/reader/qemu_file_reader.cpp ]] || {
    echo "Rebuild drcachesim after changing its EMT trace reader" >&2
    exit 1
}

source "${QEMU_ROOT}/run_linux_thp_command.sh"
# Associative-array iteration is unordered; use a stable workload order.
if [[ -n ${TPPT_WORKLOADS:-} ]]; then
    read -r -a WORKLOADS <<< "${TPPT_WORKLOADS}"
    for workload in "${WORKLOADS[@]}"; do
        [[ -n ${linux_thp_workloads[${workload}]:-} &&
           -n ${linux_thp_workloads_vanilla[${workload}]:-} ]] || {
            echo "Unknown workload: ${workload}" >&2; exit 2;
        }
    done
else
    mapfile -t WORKLOADS < <(printf '%s\n' "${!linux_thp_workloads[@]}" | LC_ALL=C sort)
fi
readonly WORKLOADS

active_pids=()
capture_pids=()
declare -A capture_workloads=() capture_modes=()
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
    for pid in "${active_pids[@]}" "${capture_pids[@]}"; do
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
    [[ -s ${output} ]] || return 1
    awk -v budget="${NUM_INST}" '
        /^num_requests[[:space:]]*:/ { if ($NF + 0 > 0) requests = 1 }
        /^~~~~~~ detailed perf stats ~~~~~~/ { perf = 1 }
        /^user memory references:/ { user_line = NR }
        user_line && NR > user_line && NR <= user_line + 4 {
            sub(/\r$/, "")
            if ($0 == "16," budget) instructions = 1
        }
        END { exit !(requests && perf && instructions) }
    ' "${output}" || return 1
    if [[ ${output} == */tp-2MB/* ]]; then
        grep -Fxq 'TPPT huge-mapping TLB entry size: 2097152 bytes' "${output}"
    fi
}

capture_resources_busy()
{
    python3 - "${MAX_QEMU}" "${MIN_AVAILABLE_GIB}" "${TRACE_ROOT}" <<'PY'
from pathlib import Path
import os
import sys
count = 0
trace_prefix = b'filename=' + os.fsencode(sys.argv[3]) + b'/'
for proc in Path('/proc').iterdir():
    if not proc.name.isdigit():
        continue
    try:
        argv = (proc / 'cmdline').read_bytes().split(b'\0')
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        continue
    # Other experiments have independent QEMU limits; host RAM is shared.
    if (os.path.basename(argv[0]).startswith(b'qemu-system-') and
            any(trace_prefix in arg for arg in argv[1:])):
        count += 1
available_kib = int(next(line.split()[1] for line in
    Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:')))
busy = count >= int(sys.argv[1]) or available_kib < int(sys.argv[2]) * 1024**2
raise SystemExit(0 if busy else 1)
PY
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
    local stem console command kernel rc partial fragment_command
    local -a env_args

    stem=$(basename "${trace}" .bin)
    console="${TRACE_ROOT}/logs/qemu_${stem}.log"
    partial="${trace%.bin}.partial"
    if [[ -s ${trace} ]]; then
        grep -q '^FRAGMENT_READY ' "${console}" &&
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
    [[ ! -e ${console} ]] || {
        echo "Capture log exists without a reusable trace; inspect: ${console}" >&2
        return 1
    }

    if [[ ${mode} == tp ]]; then
        command=${linux_thp_workloads[${workload}]}
    else
        command=${linux_thp_workloads_vanilla[${workload}]}
    fi
    printf -v fragment_command '%q %q %q %q %q %q %q' \
        "/home/${WORKLOAD_USER}/microbenchmark/unit_thp_fragmentor" \
        "${mode}" "${FRAGMENT_BUDGET_MIB}" "${FRAGMENT_FILL}" \
        "${FRAGMENT_KEEP}" "${FRAGMENT_PIN_STRIDE}" "${command}"
    # Leave ordinary THP defrag/proactive compaction policies at boot defaults.
    # Only the fragmentor's locked native pages are excluded from compaction.
    command="echo 1 > /proc/sys/vm/overcommit_memory && echo 262144 > /proc/sys/vm/max_map_count && echo 0 > /proc/sys/vm/compact_unevictable_allowed && mount -t debugfs debugfs /sys/kernel/debug && ${fragment_command}"
    [[ ! -e ${partial} ]] || {
        echo "Incomplete capture exists; inspect before retrying: ${partial}" >&2
        return 1
    }
    env_args=(QEMU_MEMORY=200G TPPT_WORKLOAD_PLUGIN_MODE=logAll
        "DISK_IMAGE=${DISK_IMAGE}"
        "QEMU_BIN=${QEMU_ROOT}/build/qemu-system-x86_64"
        "TPPT_WORKLOAD_PLUGIN=${QEMU_ROOT}/build/contrib/plugins/libdynamorio.so"
        TPPT_KERNEL_DEBUG=fork TPPT_POOL_MB= TPPT_POOL_BASE_PFN= TPPT_BIN_COUNT=
        TPPT_THP_MODE=off QEMU_CPU=max,-la57,+invtsc)

    case ${mode} in
        tp)
            kernel="${ROOT}/linux-tp"
            env_args+=("TPPT_KERNEL_FILE=${kernel}/arch/x86/boot/bzImage"
                QEMU_TRACE_FORMAT=tppt-thp TPPT_THP_MODE=on
                TPPT_POOL_MB=163840 TPPT_POOL_BASE_PFN=1048576
                TPPT_BIN_COUNT=329728 TRANSPARENT_HUGEPAGE_MODE=never)
            ;;
        vanilla)
            kernel="${VANILLA_KERNEL_DIR}"
            env_args+=(QEMU_MEMORY=160G "TPPT_KERNEL_FILE=${kernel}/arch/x86/boot/bzImage"
                QEMU_TRACE_FORMAT=tppt TPPT_THP_MODE=
                TRANSPARENT_HUGEPAGE_MODE=always)
            ;;
        fpt|ecpt)
            kernel="${EMT_ROOT}/linux-${mode}"
            if [[ ${mode} == fpt ]]; then
                kernel="${FPT_KERNEL_DIR}"
                # The pinned enhanced FPT fault path cannot COW a huge zero
                # page. Keep THP enabled, but allocate private huge pages on
                # read faults rather than installing the shared zero page.
                command="echo 0 > /sys/kernel/mm/transparent_hugepage/use_zero_page && echo FPT THP use_zero_page=0 && ${command}"
            fi
            env_args+=(QEMU_TRACE_FORMAT=emt TRANSPARENT_HUGEPAGE_MODE=always
                "QEMU_BIN=${EMT_ROOT}/qemu-${mode}/qemu-system-x86_64"
                "TPPT_KERNEL_FILE=${kernel}/arch/x86/boot/bzImage"
                "TPPT_WORKLOAD_PLUGIN=${EMT_ROOT}/qemu-${mode}/tests/plugin/libexeclog.so")
            ;;
    esac

    echo "Capturing ${workload}/${mode}: ${trace}"
    while capture_resources_busy; do
        echo "Waiting for a QEMU slot (limit ${MAX_QEMU}) and ${MIN_AVAILABLE_GIB} GiB available before ${workload}/${mode}"
        sleep 15
    done
    setsid --wait env "${env_args[@]}" "${QEMU_ROOT}/run-qemu-linux.sh" \
        "${kernel}" "${command}" "${partial}" "${NUM_INST}" 2>&1 &
    current_capture_pid=$!
    if wait "${current_capture_pid}"; then rc=0; else rc=$?; fi
    current_capture_pid=

    [[ -s ${partial} ]] &&
        grep -q '^FRAGMENT_READY ' "${console}" &&
        grep -Eq "Reached[[:space:]]+${NUM_INST} user instrs" "${console}" &&
        grep -q 'Closed binary log file descriptor' "${console}" || {
        echo "Capture incomplete for ${workload}/${mode} (QEMU status ${rc})" >&2
        return 1
    }
    mv -- "${partial}" "${trace}"
    echo "Captured ${workload}/${mode} (QEMU status ${rc})"
}

analyze_trace()
{
    local workload=$1 mode=$2 trace=$3 config=$4
    local output="${RESULT_ROOT}/${config}/${mode}/${workload}.txt"
    local partial="${output}.partial"
    local format arch
    local -a mode_flags=() config_flags=()

    if analysis_complete "${output}"; then
        echo "Reusing completed analysis: ${output}"
        return 0
    fi
    [[ ! -e ${output} ]] || {
        echo "Incomplete simulator output exists: ${output}" >&2
        return 1
    }
    # An interrupted simulation can be retried from its retained trace.
    rm -f -- "${partial}"
    case ${mode} in
        tp) format=tppt-thp; arch=radix; mode_flags=(-tppt_tlb_page_size 8M) ;;
        tp-2MB) format=tppt-thp; arch=radix; mode_flags=(-tppt_tlb_page_size 2M) ;;
        vanilla) format=tppt; arch=radix; mode_flags=(-skip_tiny_pointer_walk) ;;
        fpt) format=emt; arch=fpt; mode_flags=(-skip_tiny_pointer_walk) ;;
        ecpt) format=emt; arch=ecpt; mode_flags=(-cache_correct_only -skip_tiny_pointer_walk) ;;
    esac
    if [[ ${config} == mmu_to_l2 ]]; then
        config_flags=(-mmu_to_l2)
    fi
    echo "Analyzing ${workload}/${mode}/${config}: ${output}"
    (
        cd "${DYNAMORIO_ROOT}"
        ./build_linux/bin64/drrun -t drcachesim \
            -qemu_mem_trace "${trace}" -qemu_trace_format "${format}" \
            -max_ref -1 -warmup_refs 300000000 -arch "${arch}" \
            -TLB_L1I_entries 128 -TLB_L1I_assoc 8 \
            -TLB_L1D_entries 64 -TLB_L1D_assoc 4 \
            -TLB_L2_entries 1536 -TLB_L2_assoc 12 \
            -L1I_size 32768 -L1I_assoc 8 -L1D_size 32768 -L1D_assoc 8 \
            -L2_size 1048576 -L2_assoc 16 -LL_size 23068672 -LL_assoc 11 \
            -cores 20 -verbose 0 "${mode_flags[@]}" "${config_flags[@]}" \
            >"${partial}" 2>&1
    )
    analysis_complete "${partial}" || {
        echo "Simulation failed validation: ${partial}" >&2
        return 1
    }
    mv -- "${partial}" "${output}"
}

wait_for_worker()
{
    local finished_pid= pid
    local -a remaining_pids=()

    # Bash wait -n can miss statuses of children that already exited before
    # the call. Reap completed children explicitly, checking every second so
    # a failure stops the other workers even while their QEMU is running.
    while [[ -z ${finished_pid} ]]; do
        for pid in "${active_pids[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then
                continue
            fi
            if ! wait "${pid}"; then
                echo "Capture/analysis worker failed; retained unfinished traces" >&2
                return 1
            fi
            finished_pid=${pid}
            break
        done
        [[ -n ${finished_pid} ]] || sleep 1
    done
    for pid in "${active_pids[@]}"; do
        [[ ${pid} == "${finished_pid}" ]] || remaining_pids+=("${pid}")
    done
    active_pids=("${remaining_pids[@]}")
}

# Capture modes and simulator modes are different: TP has two TLB variants.
simulation_modes()
{
    if [[ $1 == tp ]]; then printf '%s\n' tp tp-2MB; else echo "$1"; fi
}

analyses_complete()
{
    local workload=$1 mode=$2 simulation_mode config
    for simulation_mode in $(simulation_modes "${mode}"); do
        for config in default mmu_to_l2; do
            analysis_complete "${RESULT_ROOT}/${config}/${simulation_mode}/${workload}.txt" || return 1
        done
    done
}

process_trace()
{
    local workload=$1 mode=$2
    local trace simulation_mode config

    # Each worker owns its capture and analysis process groups. A failure in
    # another worker reaches this trap and stops these descendants as well.
    active_pids=()
    capture_pids=()
    current_capture_pid=
    trap 'exit 130' INT TERM
    trap cleanup EXIT
    source "${QEMU_ROOT}/run_linux_thp_command.sh"

    trace="${TRACE_ROOT}/${workload}_$(trace_mode "${mode}")_${NUM_INST}.bin"
    if ! analyses_complete "${workload}" "${mode}"; then
        capture_trace "${workload}" "${mode}" "${trace}"
        # Two simulations per worker at a time, with one shared input trace.
        for simulation_mode in $(simulation_modes "${mode}"); do
            for config in default mmu_to_l2; do
                setsid --wait bash -euo pipefail -c 'analyze_trace "$@"' _ \
                    "${workload}" "${simulation_mode}" "${trace}" "${config}" 2>&1 &
                active_pids+=("$!")
            done
            while (( ${#active_pids[@]} > 0 )); do
                wait_for_worker
            done
        done
    fi
    analyses_complete "${workload}" "${mode}"
    if [[ -e ${trace} ]]; then
        echo "All analyses validated; retained trace: ${trace}"
    fi
}

# Reap a finished capture and immediately hand it to the analysis consumers.
wait_for_capture()
{
    local pid state finished_pid= workload mode
    local -a remaining=()
    while [[ -z ${finished_pid} ]]; do
        for pid in "${capture_pids[@]}"; do
            state=$(ps -o stat= -p "${pid}" 2>/dev/null || true)
            if [[ -n ${state} && ${state} != Z* ]]; then
                continue
            fi
            if ! wait "${pid}"; then
                echo "Capture failed; retained unfinished traces" >&2
                return 1
            fi
            finished_pid=${pid}
            break
        done
        [[ -n ${finished_pid} ]] || sleep 1
    done
    workload=${capture_workloads[${finished_pid}]}
    mode=${capture_modes[${finished_pid}]}
    for pid in "${capture_pids[@]}"; do
        [[ ${pid} == "${finished_pid}" ]] || remaining+=("${pid}")
    done
    capture_pids=("${remaining[@]}")
    unset 'capture_workloads['"${finished_pid}"']' 'capture_modes['"${finished_pid}"']'
    while (( ${#active_pids[@]} >= MAX_WORKERS )); do
        wait_for_worker
    done
    setsid --wait bash -euo pipefail -c 'process_trace "$@"' _ \
        "${workload}" "${mode}" &
    active_pids+=("$!")
}

export ROOT QEMU_ROOT EMT_ROOT FPT_KERNEL_DIR VANILLA_KERNEL_DIR DYNAMORIO_ROOT
export TRACE_ROOT RESULT_ROOT NUM_INST DISK_IMAGE
export MAX_QEMU MIN_AVAILABLE_GIB
export FRAGMENT_BUDGET_MIB FRAGMENT_FILL FRAGMENT_KEEP FRAGMENT_PIN_STRIDE
export -f analyze_trace analysis_complete capture_trace trace_mode cleanup
export -f process_trace wait_for_worker capture_resources_busy simulation_modes analyses_complete

# Validate the full plan before any capture or output directory creation.
skipped=0
pending=0
for workload in "${WORKLOADS[@]}"; do
    for mode in "${MODES[@]}"; do
        complete=true
        for simulation_mode in $(simulation_modes "${mode}"); do
            for config in default mmu_to_l2; do
                output="${RESULT_ROOT}/${config}/${simulation_mode}/${workload}.txt"
                if ! analysis_complete "${output}"; then
                    [[ ! -e ${output} ]] || {
                        echo "Invalid final output; will not overwrite: ${output}" >&2
                        exit 1
                    }
                    complete=false
                fi
            done
        done
        if ${complete}; then
            echo "SKIP ${workload}/${mode}: all analyses validated"
            skipped=$((skipped + 1))
        else
            echo "PENDING ${workload}/${mode}"
            pending=$((pending + 1))
        fi
    done
done
echo "Plan: ${skipped} workload/mode groups skipped; ${pending} pending"
echo "Capture admission: fewer than ${MAX_QEMU} experiment QEMUs; at least ${MIN_AVAILABLE_GIB} GiB available"
echo "Captures: ${TRACE_ROOT}; simulations: ${RESULT_ROOT}; disk: ${DISK_IMAGE}"
echo "Fragmentor: ${FRAGMENT_BUDGET_MIB} MiB budget, fill ${FRAGMENT_FILL}%, retain ${FRAGMENT_KEEP}%, pin stride ${FRAGMENT_PIN_STRIDE} pages (0=random only), seed 1"
echo "Guest RAM: vanilla 160 GiB; TP/FPT/ECPT 200 GiB; TP pool request 160 GiB"
echo "Modes: ${MODES[*]}; binary traces retained"
echo "TP: one tppt-thp capture, tp (8 MiB) and tp-2MB (2 MiB) simulations"
${dry_run} && exit 0

mkdir -p "${TRACE_ROOT}/logs"
for config in default mmu_to_l2; do
    for mode in "${MODES[@]}"; do
        for simulation_mode in $(simulation_modes "${mode}"); do
            mkdir -p "${RESULT_ROOT}/${config}/${simulation_mode}"
        done
    done
done

# The producer reserves capture slots before spawning, so even launchers that
# have not reached exec(QEMU) count against the limit. Finish a workload's
# captures before advancing to the next; analyses can continue in parallel.
for workload in "${WORKLOADS[@]}"; do
    for mode in "${MODES[@]}"; do
        if analyses_complete "${workload}" "${mode}"; then
            continue
        fi
        trace="${TRACE_ROOT}/${workload}_$(trace_mode "${mode}")_${NUM_INST}.bin"
        # Retained traces need no QEMU slot; simulations overlap live captures.
        if [[ -s ${trace} ]]; then
            while (( ${#active_pids[@]} >= MAX_WORKERS )); do
                wait_for_worker
            done
            setsid --wait bash -euo pipefail -c 'process_trace "$@"' _ \
                "${workload}" "${mode}" &
            active_pids+=("$!")
            continue
        fi
        while (( ${#capture_pids[@]} >= MAX_QEMU )) || capture_resources_busy; do
            if (( ${#capture_pids[@]} > 0 )); then
                wait_for_capture
            else
                echo "Waiting for a capture slot and ${MIN_AVAILABLE_GIB} GiB available"
                sleep 15
            fi
        done
        setsid --wait bash -euo pipefail -c '
            active_pids=(); capture_pids=(); current_capture_pid=
            trap "exit 130" INT TERM
            trap cleanup EXIT
            source "${QEMU_ROOT}/run_linux_thp_command.sh"
            capture_trace "$@"
        ' _ "${workload}" "${mode}" "${trace}" &
        pid=$!
        capture_pids+=("${pid}")
        capture_workloads[${pid}]=${workload}
        capture_modes[${pid}]=${mode}
    done
    while (( ${#capture_pids[@]} > 0 )); do
        wait_for_capture
    done
done
while (( ${#active_pids[@]} > 0 )); do
    wait_for_worker
done

echo "All ${#WORKLOADS[@]} fragmented TCMalloc THP workloads complete in ${#MODES[@]} modes and both simulation configurations"
