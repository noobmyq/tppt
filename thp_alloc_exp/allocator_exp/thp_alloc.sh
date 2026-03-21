#!/bin/bash

MODE=$1
NUM_EXPERIMENT_RUNS=${2:-1}
COMPACT_BETWEEN_CASES=${COMPACT_BETWEEN_CASES:-1}
PCP_HIGH_FRACTION=${PCP_HIGH_FRACTION:-1024}
PCP_DRAIN_BEFORE_CASE=${PCP_DRAIN_BEFORE_CASE:-1}
# there are three kinds of modes: tp_compact, tp, vanilla
if [ -z "$MODE" ]; then
    echo "Usage: $0 <mode> [num_runs]"
    echo "Modes: tp_compact, tp, vanilla"
    echo "num_runs: positive integer (default: 1)"
    exit 1
fi
# sanity check mode
if [[ "$MODE" != "tp_compact" && "$MODE" != "tp" && "$MODE" != "vanilla" ]]; then
    echo "Error: invalid mode '$MODE'. Valid modes are: tp_compact, tp, vanilla"
    exit 1
fi
if ! [[ "$NUM_EXPERIMENT_RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: num_runs must be a positive integer (got '$NUM_EXPERIMENT_RUNS')"
    exit 1
fi
if ! [[ "$COMPACT_BETWEEN_CASES" =~ ^[01]$ ]]; then
    echo "Error: COMPACT_BETWEEN_CASES must be 0 or 1 (got '$COMPACT_BETWEEN_CASES')"
    exit 1
fi
if ! [[ "$PCP_HIGH_FRACTION" =~ ^[0-9]+$ ]]; then
    echo "Error: PCP_HIGH_FRACTION must be a non-negative integer (got '$PCP_HIGH_FRACTION')"
    exit 1
fi
if ! [[ "$PCP_DRAIN_BEFORE_CASE" =~ ^[01]$ ]]; then
    echo "Error: PCP_DRAIN_BEFORE_CASE must be 0 or 1 (got '$PCP_DRAIN_BEFORE_CASE')"
    exit 1
fi

setup_pcp_controls() {
    if [ "$PCP_HIGH_FRACTION" -gt 0 ]; then
        sudo sysctl -w "vm.percpu_pagelist_high_fraction=${PCP_HIGH_FRACTION}" >/dev/null
        echo "PCP config: percpu_pagelist_high_fraction=${PCP_HIGH_FRACTION}"
    else
        echo "PCP config: percpu_pagelist_high_fraction unchanged"
    fi
}

drain_pcp_once() {
    local reason="$1"
    echo "PCP drain (${reason}): compact_memory=1"
    echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
}

# for vanilla mode, we need to do setup
if [ "$MODE" = "vanilla" ]; then
    echo "Setting up vanilla mode environment..."
    # enable always thp
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
    # enable defrag always
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
    # best-effort suppression of background compaction for costly high-order allocations
    echo 0 | sudo tee /proc/sys/vm/compaction_proactiveness
    echo 1000 | sudo tee /proc/sys/vm/extfrag_threshold
    # reduce other MM noise sources in vanilla measurements
    if [ -w /proc/sys/kernel/numa_balancing ]; then
        echo 0 | sudo tee /proc/sys/kernel/numa_balancing
    else
        echo "Notice: /proc/sys/kernel/numa_balancing unavailable; skipping NUMA balancing knob"
    fi
    sudo swapoff -a || true
    if [ -w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag ]; then
        echo 0 | sudo tee /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
    fi
    if [ -w /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs ]; then
        echo 60000 | sudo tee /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs
    fi
    if [ -w /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs ]; then
        echo 60000 | sudo tee /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs
    fi
    # enable migratepages tracing
    echo 1 | sudo tee /sys/kernel/debug/tracing/events/compaction/mm_compaction_migratepages/enable
else 
    echo "Running in mode: $MODE"
    echo 1 | sudo tee /sys/kernel/tracing/events/tp_mosaic/tp_mosaic_migrate/enable
fi
setup_pcp_controls

NUMA_MEMBIND_PREFIX=""
if [ "$MODE" = "vanilla" ]; then
    if command -v numactl >/dev/null 2>&1; then
        NUMA_MEMBIND_PREFIX="numactl --membind=1"
        echo "Vanilla mode: binding alloctest and tp_frag memory to NUMA node1"
    else
        echo "Warning: numactl not found; vanilla mode will run without membind"
    fi
fi

# a list of candidate fragmentation sizes (in GB)
CAND_HOLD_SIZE=(3 4 5)
CAND_PIN_DENSITY=(8 16 32 64 128 256)
# Use a non-2MB-aligned cap so Phase B cannot satisfy target by full-chunk drops only.
ALLOCTEST_ALLOC_SIZE="${ALLOCTEST_ALLOC_SIZE:-9501M}"
ALLOCTEST_FREE_POLICY="${ALLOCTEST_FREE_POLICY:-pins_first}"
EXP_BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. >/dev/null 2>&1 && pwd)"
ALLOCTEST="${EXP_BASE}/alloctest"
if [ ! -f "$ALLOCTEST" ]; then
    echo "Error: $ALLOCTEST not found!"
    exit 1
fi

# this command use xsbench, working set is around 4GB
APP_BASE_CMD="${EXP_BASE}/tp_frag -t 1 -g 8000 -p 40000"
if [ "$MODE" = "vanilla" ] && [ -n "$NUMA_MEMBIND_PREFIX" ]; then
    APP_COMMAND="$NUMA_MEMBIND_PREFIX $APP_BASE_CMD"
else
    APP_COMMAND="$APP_BASE_CMD"
fi

# clean up previous state, check if it is 0 in deref table

# Function: check_iceberg_empty
# Usage: check_iceberg_empty [/path/to/iceberg]
# Returns 0 if Utilization is 0; otherwise prints the file and returns non-zero.
check_iceberg_empty() {
    if [ "$MODE" = "vanilla" ]; then
        echo "Vanilla mode: skipping iceberg deref table check"
        return 0
    fi
    local ICEBERG=${1:-/proc/iceberg}
    if [ ! -r "$ICEBERG" ]; then
        echo "Error: $ICEBERG not readable or does not exist"
        return 1
    fi

    # Expected first line like: "Utilization: 0/2600960"
    local first_line
    first_line=$(sed -n '1p' "$ICEBERG")
    if [[ $first_line =~ Utilization:[[:space:]]*([0-9]+)/ ]]; then
        local used=${BASH_REMATCH[1]}
        if [ "$used" -ne 0 ]; then
            echo "Error: deref table not empty (Utilization: $used). Dumping $ICEBERG:"
            sed -n '1,200p' "$ICEBERG"
            return 1
        fi
    else
        echo "Warning: could not parse Utilization from $ICEBERG (first line: '$first_line'). Dumping file:" 
        sed -n '1,200p' "$ICEBERG"
        return 1
    fi

    return 0
}



# Start ALLOCTEST_CMD in background, capture stdout to a log and wait for
# the marker string "FRAGMENTATION LOCKED" to appear. Timeout in seconds.
# Usage: start_alloctest_and_wait "<cmd...>" "<log_path>" [timeout_seconds]
# Exports: ALLOCTEST_PID, ALLOCTEST_LOG
start_alloctest_and_wait() {
    local cmd="$1"
    local log_path="$2"
    local timeout=${3:-30}
    ALLOCTEST_LOG="$log_path"

    # Start the command with stdout/stderr redirected to the log
    bash -c "$cmd" >"$ALLOCTEST_LOG" 2>&1 &
    ALLOCTEST_PID=$!

    # Wait for the marker to appear with a timeout
    local waited=0
    local interval=10
    while [ $waited -lt $timeout ]; do
        if grep -q "FRAGMENTATION LOCKED" "$ALLOCTEST_LOG"; then
            echo "alloctest locked fragmentation (pid=$ALLOCTEST_PID), log=$ALLOCTEST_LOG"
            return 0
        fi
        echo "Waiting for fragmentation lock... ($waited/$timeout seconds)"
        # tail 5 lines of log for progress indication
        sleep $interval
        waited=$((waited + interval))
    done

    echo "Timeout waiting for FRAGMENTATION LOCKED (pid=$ALLOCTEST_PID). Dumping last 200 lines of log ($ALLOCTEST_LOG):"
    tail -n 200 "$ALLOCTEST_LOG"
    return 1
}


# Read /proc/vmstat and export THP_FAULT_ALLOC and THP_FAULT_FALLBACK
# Usage: get_thp_counters [/path/to/vmstat]
get_thp_counters() {
    local VMSTAT=${1:-/proc/vmstat}
    if [ ! -r "$VMSTAT" ]; then
        echo "Error: $VMSTAT not readable or does not exist"
        return 1
    fi

    # Initialize defaults
    THP_FAULT_ALLOC=0
    THP_FAULT_FALLBACK=0

    while read -r key val; do
        case "$key" in
            thp_fault_alloc)
                THP_FAULT_ALLOC=$val
                ;;
            thp_fault_fallback)
                THP_FAULT_FALLBACK=$val
                ;;
        esac
    done < "$VMSTAT"

    export THP_FAULT_ALLOC THP_FAULT_FALLBACK
    return 0
}

# Helper to print current THP counters (for logging)
print_thp_counters() {
    echo "THP counters: thp_fault_alloc=$THP_FAULT_ALLOC thp_fault_fallback=$THP_FAULT_FALLBACK"
}

wait_for_quiet_vmstat() {
    local tries=${1:-5}
    local interval=${2:-1}
    local max_delta=${3:-2}
    local i

    for (( i=1; i<=tries; i++ )); do
        local a0 f0 a1 f1 da df
        get_thp_counters || return 1
        a0=$THP_FAULT_ALLOC
        f0=$THP_FAULT_FALLBACK
        sleep "$interval"
        get_thp_counters || return 1
        a1=$THP_FAULT_ALLOC
        f1=$THP_FAULT_FALLBACK
        da=$((a1 - a0))
        df=$((f1 - f0))

        if [ "$da" -le "$max_delta" ] && [ "$df" -le "$max_delta" ]; then
            echo "VM noise guard: quiet window detected (alloc_delta=${da}, fallback_delta=${df})"
            return 0
        fi
        echo "VM noise guard: noisy window (alloc_delta=${da}, fallback_delta=${df}), retry ${i}/${tries}"
    done

    echo "Warning: VM did not become quiet within guard retries; continuing anyway"
    return 0
}

cleanup_mm_state_once() {
    echo "Cleaning MM state: sync -> drop_caches=3 -> compact_memory=1"
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
    sleep 10
}


# output directory layout:
#   <EXP_BASE>/results/<mode>/
#       results.csv
#       run_001_info.txt
#       hold_3g/
#         pin_16/
#           run_001/
#           alloctest.log
#           app.log
#           baseline.txt
#           result.txt
#           trace.log
#           pre/{iceberg|buddyinfo}.txt, vmstat.txt
#           post/{iceberg|buddyinfo}.txt, vmstat.txt

get_latest_run_idx() {
    local base="$1"
    local max_idx=0
    local hold_dir
    local run_dir

    for run_dir in "$base"/hold_*g/pin_*/run_*; do
            [ -d "$run_dir" ] || continue
            local run_name
            run_name=$(basename "$run_dir")
            if [[ "$run_name" =~ ^run_([0-9]+)$ ]]; then
                local idx=$((10#${BASH_REMATCH[1]}))
                if [ "$idx" -gt "$max_idx" ]; then
                    max_idx="$idx"
                fi
            fi
    done

    echo "$max_idx"
}

RESULTS_BASE="${EXP_BASE}/results/${MODE}"
mkdir -p "$RESULTS_BASE"
for HOLD_SIZE in "${CAND_HOLD_SIZE[@]}"; do
    for PIN_DENSITY in "${CAND_PIN_DENSITY[@]}"; do
        mkdir -p "${RESULTS_BASE}/hold_${HOLD_SIZE}g/pin_${PIN_DENSITY}"
    done
done

LAST_RUN_IDX=$(get_latest_run_idx "$RESULTS_BASE")
START_RUN_IDX=$((LAST_RUN_IDX + 1))
END_RUN_IDX=$((START_RUN_IDX + NUM_EXPERIMENT_RUNS - 1))

SUMMARY_CSV="$RESULTS_BASE/results.csv"
SUMMARY_HEADER_OLD="run_idx,hold_size_g,pin_density,alloc_before,fallback_before,alloc_after,fallback_after,alloc_diff,fallback_diff"
SUMMARY_HEADER_NEW="run_idx,hold_size_g,pin_density,alloc_before,fallback_before,alloc_after,fallback_after,alloc_diff,fallback_diff,bg_alloc,bg_fallback,alloc_diff_adj,fallback_diff_adj"
CSV_LEGACY_FORMAT=0
if [ ! -f "$SUMMARY_CSV" ]; then
    echo "$SUMMARY_HEADER_NEW" > "$SUMMARY_CSV"
else
    CURRENT_HEADER=$(head -n 1 "$SUMMARY_CSV")
    if [ "$CURRENT_HEADER" = "$SUMMARY_HEADER_OLD" ]; then
        CSV_LEGACY_FORMAT=1
        echo "Warning: using legacy CSV format for $SUMMARY_CSV"
    fi
fi

echo "Results base: $RESULTS_BASE"
echo "Run indices: $(printf 'run_%03d' "$START_RUN_IDX") .. $(printf 'run_%03d' "$END_RUN_IDX")"

for (( RUN_IDX=START_RUN_IDX; RUN_IDX<=END_RUN_IDX; RUN_IDX++ )); do
    RUN_NAME=$(printf "run_%03d" "$RUN_IDX")
    RUN_INFO_FILE="$RESULTS_BASE/${RUN_NAME}_info.txt"
    {
        echo "mode=${MODE}"
        echo "run_name=${RUN_NAME}"
        echo "app_command=${APP_COMMAND}"
        echo "hold_sizes_g=${CAND_HOLD_SIZE[*]}"
        echo "pin_densities=${CAND_PIN_DENSITY[*]}"
        echo "alloctest_alloc_size=${ALLOCTEST_ALLOC_SIZE}"
        echo "alloctest_free_policy=${ALLOCTEST_FREE_POLICY}"
        echo "compact_between_cases=${COMPACT_BETWEEN_CASES}"
        echo "pcp_high_fraction=${PCP_HIGH_FRACTION}"
        echo "pcp_drain_before_case=${PCP_DRAIN_BEFORE_CASE}"
        echo "cleanup_actions=sync,drop_caches_3,compact_memory_1"
        if [ "$MODE" = "vanilla" ] && [ -n "$NUMA_MEMBIND_PREFIX" ]; then
            echo "numa_membind=node1"
            echo "compaction_proactiveness=0"
            echo "extfrag_threshold=1000"
            echo "numa_balancing=0"
            echo "swap=off"
            echo "khugepaged_defrag=0"
            echo "khugepaged_scan_sleep_millisecs=60000"
            echo "khugepaged_alloc_sleep_millisecs=60000"
        else
            echo "numa_membind=none"
        fi
    } > "$RUN_INFO_FILE"

    echo "Starting ${RUN_NAME}"

    for HOLD_SIZE in "${CAND_HOLD_SIZE[@]}"; do
        for PIN_DENSITY in "${CAND_PIN_DENSITY[@]}"; do
            # Call the check once before proceeding
            check_iceberg_empty || exit 1

            echo "Running ${RUN_NAME} with hold=${HOLD_SIZE}GB pin_density=${PIN_DENSITY}"
            if [ "$PCP_DRAIN_BEFORE_CASE" -eq 1 ]; then
                drain_pcp_once "before_${RUN_NAME}_hold${HOLD_SIZE}_pin${PIN_DENSITY}"
            fi
            HOLD_BASE="$RESULTS_BASE/hold_${HOLD_SIZE}g/pin_${PIN_DENSITY}"
            RUN_DIR="$HOLD_BASE/$RUN_NAME"
            PRE_DIR="$RUN_DIR/pre"
            POST_DIR="$RUN_DIR/post"
            mkdir -p "$PRE_DIR" "$POST_DIR"

            ALLOCTEST_CMD="$ALLOCTEST ${ALLOCTEST_ALLOC_SIZE} ${HOLD_SIZE}G ${PIN_DENSITY} 50 ${ALLOCTEST_FREE_POLICY}"
            if [ "$MODE" = "vanilla" ] && [ -n "$NUMA_MEMBIND_PREFIX" ]; then
                ALLOCTEST_CMD="$NUMA_MEMBIND_PREFIX $ALLOCTEST_CMD"
            fi

        # start alloctest in background and wait for it to stabilize
        # the function will set ALLOCTEST_PID and ALLOCTEST_LOG
            start_alloctest_and_wait "$ALLOCTEST_CMD" "$RUN_DIR/alloctest.log" 1000 || { echo "Error: alloctest failed to lock fragmentation for hold=${HOLD_SIZE} pin_density=${PIN_DENSITY}"; exit 1; }
            sleep 1

        # snapshot /proc/iceberg if it is not vanilla
            if [ "$MODE" != "vanilla" ]; then
                cat /proc/iceberg > "$PRE_DIR/iceberg.txt"
            else
                cat /proc/buddyinfo > "$PRE_DIR/buddyinfo.txt"
            fi

            grep -E 'thp|compact|migrate' /proc/vmstat > "$PRE_DIR/vmstat.txt"

        # then we need to check the current thp status using vmstat
            wait_for_quiet_vmstat 5 1 2 || { echo "Failed during vmstat quiet guard"; exit 1; }
            get_thp_counters || { echo "Failed to read /proc/vmstat"; exit 1; }
            print_thp_counters

        # remember baseline counters so we can compute deltas later
            PREV_THP_FAULT_ALLOC=$THP_FAULT_ALLOC
            PREV_THP_FAULT_FALLBACK=$THP_FAULT_FALLBACK

        # save baseline
            BASELINE_FILE="$RUN_DIR/baseline.txt"
            {
                echo "run_idx=${RUN_IDX}"
                echo "run_name=${RUN_NAME}"
                echo "hold_size_g=${HOLD_SIZE}"
                echo "pin_density=${PIN_DENSITY}"
                echo "alloctest_pid=${ALLOCTEST_PID:-}"
                echo "alloctest_log=${ALLOCTEST_LOG:-}"
                echo "PREV_THP_FAULT_ALLOC=${PREV_THP_FAULT_ALLOC}"
                echo "PREV_THP_FAULT_FALLBACK=${PREV_THP_FAULT_FALLBACK}"
            } > "$BASELINE_FILE"
            echo "Saved baseline to $BASELINE_FILE"

            # estimate ambient vmstat drift before app run (for adjusted deltas)
            sleep 1
            get_thp_counters || { echo "Failed to read /proc/vmstat for background drift"; exit 1; }
            BG_ALLOC=$((THP_FAULT_ALLOC - PREV_THP_FAULT_ALLOC))
            BG_FALLBACK=$((THP_FAULT_FALLBACK - PREV_THP_FAULT_FALLBACK))
            echo "Background drift estimate: alloc=${BG_ALLOC} fallback=${BG_FALLBACK}"

            sleep 1
            # run the app command and wait for it to finish
            echo "Running app command: $APP_COMMAND"
            eval "$APP_COMMAND" > "$RUN_DIR/app.log" 2>&1 || { echo "Error: app command failed for hold=${HOLD_SIZE} pin_density=${PIN_DENSITY}. See $RUN_DIR/app.log"; exit 1; }

        # after the app command finishes, we collect the thp stats again
            get_thp_counters || { echo "Failed to read /proc/vmstat after app run"; exit 1; }
            print_thp_counters
        # we measure the difference of FAULT_ALLOC and FAULT_FALLBACK
            ALLOC_DIFF=$((THP_FAULT_ALLOC - PREV_THP_FAULT_ALLOC))
            FALLBACK_DIFF=$((THP_FAULT_FALLBACK - PREV_THP_FAULT_FALLBACK))
            ALLOC_DIFF_ADJ=$((ALLOC_DIFF - BG_ALLOC))
            FALLBACK_DIFF_ADJ=$((FALLBACK_DIFF - BG_FALLBACK))
            echo "${RUN_NAME}, hold=${HOLD_SIZE}GB pin_density=${PIN_DENSITY}, THP Allocation: ${ALLOC_DIFF}, THP Fallback: ${FALLBACK_DIFF}, BG alloc=${BG_ALLOC}, BG fallback=${BG_FALLBACK}, Adj alloc=${ALLOC_DIFF_ADJ}, Adj fallback=${FALLBACK_DIFF_ADJ}"

        # save results
            RESULT_FILE="$RUN_DIR/result.txt"
            {
                echo "run_idx=${RUN_IDX}"
                echo "run_name=${RUN_NAME}"
                echo "hold_size_g=${HOLD_SIZE}"
                echo "pin_density=${PIN_DENSITY}"
                echo "PREV_THP_FAULT_ALLOC=${PREV_THP_FAULT_ALLOC}"
                echo "PREV_THP_FAULT_FALLBACK=${PREV_THP_FAULT_FALLBACK}"
                echo "POST_THP_FAULT_ALLOC=${THP_FAULT_ALLOC}"
                echo "POST_THP_FAULT_FALLBACK=${THP_FAULT_FALLBACK}"
                echo "THP_ALLOC_DIFF=${ALLOC_DIFF}"
                echo "THP_FALLBACK_DIFF=${FALLBACK_DIFF}"
                echo "BG_ALLOC_EST=${BG_ALLOC}"
                echo "BG_FALLBACK_EST=${BG_FALLBACK}"
                echo "THP_ALLOC_DIFF_ADJ=${ALLOC_DIFF_ADJ}"
                echo "THP_FALLBACK_DIFF_ADJ=${FALLBACK_DIFF_ADJ}"
            } > "$RESULT_FILE"
            echo "Saved result to $RESULT_FILE"

        # snapshot /proc/iceberg if it is not vanilla
            if [ "$MODE" != "vanilla" ]; then
                cat /proc/iceberg > "$POST_DIR/iceberg.txt"
            else
                cat /proc/buddyinfo > "$POST_DIR/buddyinfo.txt"
            fi

            grep -E 'thp|compact|migrate' /proc/vmstat > "$POST_DIR/vmstat.txt"

        # print the trace logs if any
            TRACE_LOG="/sys/kernel/tracing/trace"
            TRACE_OUTPUT="$RUN_DIR/trace.log"
            sudo cat "$TRACE_LOG" > "$TRACE_OUTPUT"
            echo "Saved trace log to $TRACE_OUTPUT"
            # clear the trace for next iteration
            echo "" | sudo tee "$TRACE_LOG"

        # append a CSV summary
            if [ "$CSV_LEGACY_FORMAT" -eq 1 ]; then
                echo "${RUN_IDX},${HOLD_SIZE},${PIN_DENSITY},${PREV_THP_FAULT_ALLOC},${PREV_THP_FAULT_FALLBACK},${THP_FAULT_ALLOC},${THP_FAULT_FALLBACK},${ALLOC_DIFF},${FALLBACK_DIFF}" >> "$SUMMARY_CSV"
            else
                echo "${RUN_IDX},${HOLD_SIZE},${PIN_DENSITY},${PREV_THP_FAULT_ALLOC},${PREV_THP_FAULT_FALLBACK},${THP_FAULT_ALLOC},${THP_FAULT_FALLBACK},${ALLOC_DIFF},${FALLBACK_DIFF},${BG_ALLOC},${BG_FALLBACK},${ALLOC_DIFF_ADJ},${FALLBACK_DIFF_ADJ}" >> "$SUMMARY_CSV"
            fi

        # kill the alloctest process
            echo "Killing alloctest process (pid=$ALLOCTEST_PID)"
            pkill alloctest || true
            # Retry a few times, but stop early if the tracked process is already gone.
            for i in {1..5}; do
                if ! kill -0 "$ALLOCTEST_PID" 2>/dev/null; then
                    break
                fi
                sleep 5
                pkill alloctest || true
            done

            # make sure alloctest is killed before next iteration
            wait "$ALLOCTEST_PID" 2>/dev/null || true

            if [ "$COMPACT_BETWEEN_CASES" -eq 1 ]; then
                cleanup_mm_state_once
            fi
        done
    done
done
