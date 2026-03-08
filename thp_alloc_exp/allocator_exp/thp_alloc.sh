#!/bin/bash

MODE=$1
# there are three kinds of modes: tp_compact, tp, vanilla
if [ -z "$MODE" ]; then
    echo "Usage: $0 <mode>"
    echo "Modes: tp_compact, tp, vanilla"
    exit 1
fi
# sanity check mode
if [[ "$MODE" != "tp_compact" && "$MODE" != "tp" && "$MODE" != "vanilla" ]]; then
    echo "Error: invalid mode '$MODE'. Valid modes are: tp_compact, tp, vanilla"
    exit 1
fi

# for vanilla mode, we need to do setup
if [ "$MODE" = "vanilla" ]; then
    echo "Setting up vanilla mode environment..."
    # enable defrag always
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
    # do not do background compaction, only foreground
    echo 0 | sudo tee /proc/sys/vm/compaction_proactiveness
    # enable migratepages tracing
    echo 1 | sudo tee /sys/kernel/debug/tracing/events/compaction/mm_compaction_migratepages/enable
else 
    echo "Running in mode: $MODE"
    echo 1 | sudo tee /sys/kernel/tracing/events/tp_mosaic/tp_mosaic_migrate/enable
fi

# a list of candidate fragmentation sizes (in GB)
CAND_HOLD_SIZE=(3 4 5)
USER=$(whoami)
EXP_BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. >/dev/null 2>&1 && pwd)"
ALLOCTEST="${EXP_BASE}/alloctest"
if [ ! -f $ALLOCTEST ]; then
    echo "Error: $ALLOCTEST not found!"
    exit 1
fi

# this command use xsbench, working set is around 4GB
APP_COMMAND="${EXP_BASE}/tp_frag -t 1 -g 8000 -p 40000"

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
# Usage: start_alloctest_and_wait "<cmd...>" [timeout_seconds]
# Exports: ALLOCTEST_PID, ALLOCTEST_LOG
start_alloctest_and_wait() {
    local cmd="$1"
    local timeout=${2:-30}
    ALLOCTEST_LOG="alloctest.$(date +%s).log"

    # Start the command with stdout/stderr redirected to the log
    bash -c "$cmd" >"$ALLOCTEST_LOG" 2>&1 &
    ALLOCTEST_PID=$!

    # Wait for the marker to appear with a timeout
    local waited=0
    local interval=10
    while [ $waited -lt $timeout ]; do
        if grep -q "FRAGMENTATION LOCKED" "$ALLOCTEST_LOG"; then
            echo "alloctest locked fragmentation (pid=$ALLOCTEST_PID), log=$ALLOCTEST_LOG"
            rm -f "$ALLOCTEST_LOG"
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


# mkdir the output directory
OUTPUT_DIR="thp_alloc_results_${MODE}_$(date +%Y%m%d_%H%M%S)"
mkdir -p $OUTPUT_DIR
for HOLD_SIZE in "${CAND_HOLD_SIZE[@]}"; do
    # Call the check once before proceeding
    check_iceberg_empty || exit 1
    
    echo "Running test with hold size: ${HOLD_SIZE}GB"

    ALLOCTEST_CMD="$ALLOCTEST 9G ${HOLD_SIZE}G 128 5"
    
    # start alloctest in background and wait for it to stabilize
    # the function will set ALLOCTEST_PID and ALLOCTEST_LOG
    start_alloctest_and_wait "$ALLOCTEST_CMD" 100 || { echo "Error: alloctest failed to lock fragmentation for hold size ${HOLD_SIZE}"; exit 1; }
    sleep 1

    # snapshot /proc/iceberg if it is not vanilla
    if [ "$MODE" != "vanilla" ]; then
        cat /proc/iceberg > "$OUTPUT_DIR/hold_${HOLD_SIZE}_iceberg_snapshot.txt"
    else 
        cat /proc/buddyinfo > "$OUTPUT_DIR/hold_${HOLD_SIZE}_buddyinfo_snapshot.txt"
    fi

    cat /proc/vmstat | grep thp > "$OUTPUT_DIR/hold_${HOLD_SIZE}_vmstat_snapshot.txt"
    cat /proc/vmstat | grep compact >> "$OUTPUT_DIR/hold_${HOLD_SIZE}_vmstat_snapshot.txt"
    cat /proc/vmstat | grep migrate >> "$OUTPUT_DIR/hold_${HOLD_SIZE}_vmstat_snapshot.txt"

    # then we need to check the current thp status using vmstat
    get_thp_counters || { echo "Failed to read /proc/vmstat"; exit 1; }
    print_thp_counters

    # remember baseline counters so we can compute deltas later
    PREV_THP_FAULT_ALLOC=$THP_FAULT_ALLOC
    PREV_THP_FAULT_FALLBACK=$THP_FAULT_FALLBACK

    # save baseline to output dir
    BASELINE_FILE="$OUTPUT_DIR/hold_${HOLD_SIZE}_baseline.txt"
    {
        echo "timestamp=$(date +%s)"
        echo "hold_size_g=${HOLD_SIZE}"
        echo "alloctest_pid=${ALLOCTEST_PID:-}" 
        echo "alloctest_log=${ALLOCTEST_LOG:-}"
        echo "PREV_THP_FAULT_ALLOC=${PREV_THP_FAULT_ALLOC}"
        echo "PREV_THP_FAULT_FALLBACK=${PREV_THP_FAULT_FALLBACK}"
    } > "$BASELINE_FILE"
    echo "Saved baseline to $BASELINE_FILE"

    sleep 1
    # run the app command and wait for it to finish
    echo "Running app command: $APP_COMMAND"
    eval "$APP_COMMAND"

    # after the app command finishes, we collect the thp stats again
    get_thp_counters || { echo "Failed to read /proc/vmstat after app run"; exit 1; }
    print_thp_counters
    # we measure the difference of FAULT_ALLOC and FAULT_FALLBACK
    ALLOC_DIFF=$((THP_FAULT_ALLOC - PREV_THP_FAULT_ALLOC))
    FALLBACK_DIFF=$((THP_FAULT_FALLBACK - PREV_THP_FAULT_FALLBACK))
    echo "Hold Size: ${HOLD_SIZE}GB, THP Allocation: ${ALLOC_DIFF}, THP Fallback: ${FALLBACK_DIFF}"

    # save results
    RESULT_FILE="$OUTPUT_DIR/hold_${HOLD_SIZE}_result.txt"
    {
        echo "timestamp=$(date +%s)"
        echo "hold_size_g=${HOLD_SIZE}"
        echo "PREV_THP_FAULT_ALLOC=${PREV_THP_FAULT_ALLOC}"
        echo "PREV_THP_FAULT_FALLBACK=${PREV_THP_FAULT_FALLBACK}"
        echo "POST_THP_FAULT_ALLOC=${THP_FAULT_ALLOC}"
        echo "POST_THP_FAULT_FALLBACK=${THP_FAULT_FALLBACK}"
        echo "THP_ALLOC_DIFF=${ALLOC_DIFF}"
        echo "THP_FALLBACK_DIFF=${FALLBACK_DIFF}"
    } > "$RESULT_FILE"
    echo "Saved result to $RESULT_FILE"

    # snapshot /proc/iceberg if it is not vanilla
    if [ "$MODE" != "vanilla" ]; then
        cat /proc/iceberg > "$OUTPUT_DIR/hold_${HOLD_SIZE}_iceberg_post_app.txt"
    else 
        cat /proc/buddyinfo > "$OUTPUT_DIR/hold_${HOLD_SIZE}_buddyinfo_post_app.txt"
    fi

    cat /proc/vmstat | grep thp > "$OUTPUT_DIR/hold_${HOLD_SIZE}_vmstat_post_app.txt"
    cat /proc/vmstat | grep compact >> "$OUTPUT_DIR/hold_${HOLD_SIZE}_vmstat_post_app.txt"
    cat /proc/vmstat | grep migrate >> "$OUTPUT_DIR/hold_${HOLD_SIZE}_vmstat_post_app.txt"

    # print the trace logs if any
    TRACE_LOG="/sys/kernel/tracing/trace"

    TRACE_OUTPUT="$OUTPUT_DIR/hold_${HOLD_SIZE}_trace.log"
    sudo cat "$TRACE_LOG" > "$TRACE_OUTPUT"
    echo "Saved trace log to $TRACE_OUTPUT"
    # clear the trace for next iteration
    echo "" | sudo tee "$TRACE_LOG"

    # append a CSV summary
    SUMMARY_CSV="$OUTPUT_DIR/results.csv"
    if [ ! -f "$SUMMARY_CSV" ]; then
        echo "timestamp,hold_size_g,alloc_before,fallback_before,alloc_after,fallback_after,alloc_diff,fallback_diff" > "$SUMMARY_CSV"
    fi
    echo "$(date +%s),${HOLD_SIZE},${PREV_THP_FAULT_ALLOC},${PREV_THP_FAULT_FALLBACK},${THP_FAULT_ALLOC},${THP_FAULT_FALLBACK},${ALLOC_DIFF},${FALLBACK_DIFF}" >> "$SUMMARY_CSV"

    # kill the alloctest process
    echo "Killing alloctest process (pid=$ALLOCTEST_PID)"
    pkill alloctest
    # loop some times
    for i in {1..5}; do
        sleep 5
        pkill alloctest
    done

    # make sure alloctest is killed before next iteration
    wait $ALLOCTEST_PID 2>/dev/null || true
done
