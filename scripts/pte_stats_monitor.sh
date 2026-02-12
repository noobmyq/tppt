#!/usr/bin/env bash
set -euo pipefail

# PTE Stats Monitor
# Launches the target command (which should be named 'combtest' to trigger kernel stats),
# and periodically dumps the /proc/<pid>/pte_stats for the process tree.

usage() {
    echo "Usage: $0 <command> [args...]" >&2
    echo "Note: The kernel likely requires the command binary to be named 'combtest' to enable stats." >&2
    exit 1
}

if [[ $# -lt 1 ]]; then
    help_arg="$1"
    if [[ "$help_arg" == "--help" || "$help_arg" == "-h" ]]; then
        usage
    fi
    usage
fi

# Run the command in the background
"$@" &
root_pid=$!

# Give the workload a moment to start up.
sleep 0.1

# Configuration
run_window="${RUN_WINDOW:-0.5}"   # Time to let the process run between dumps
pause_window="${PAUSE_WINDOW:-0.1}" # Time to keep paused (minimal, just for consistent read)
out_dir="${OUT_DIR:-./pte_stats_output}"

# Create output directory
mkdir -p "${out_dir}"
echo "Saving stats to ${out_dir}"

collect_descendants() {
    local pid=$1
    echo "${pid}"
    # Recurse through children.
    # Using multiple ps calls for recursion is slightly simpler logic-wise than parsing full ps tree
    for child in $(ps --no-headers -o pid= --ppid "${pid}" 2>/dev/null); do
        collect_descendants "${child}"
    done
}

is_live_non_zombie() {
    local pid=$1
    if ! kill -0 "${pid}" 2>/dev/null; then
        return 1
    fi
    local stat
    stat=$(ps -o stat= -p "${pid}" 2>/dev/null | awk '{print $1}')
    # Check if stat starts with Z (zombie)
    [[ -n "${stat}" && "${stat:0:1}" != "Z" ]]
}

cleanup() {
    # Ensure nothing is left stopped on exit.
    if kill -0 "${root_pid}" 2>/dev/null; then
        # Collect descendants again to be sure
        local descendants
        descendants=$(collect_descendants "${root_pid}" 2>/dev/null || true)
        if [[ -n "$descendants" ]]; then
            # shellcheck disable=SC2086
            kill -CONT $descendants 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT

count=0
echo "Starting monitor for PID ${root_pid}..."

while kill -0 "${root_pid}" 2>/dev/null; do
    # Snapshot the full process tree under the root.
    # We sort -u to handle potential duplicates from race conditions (though rare with this logic)
    timestamp=$(date +%Y%m%d_%H%M%S_%N)
    
    # 1. Let it run for a bit
    # Note: We assume they are running.
    # To keep logic simple/robust: ensure CONT at start of loop (in case we looped back).
    # Re-collect PIDs to catch newly spawned processes
    mapfile -t pids < <(collect_descendants "${root_pid}" | sort -u)
    
    for pid in "${pids[@]}"; do
        kill -CONT "${pid}" 2>/dev/null || true
    done
    
    sleep "${run_window}"

    # 2. Pause the tree to snapshot stats consistently
    # We pause the PIDs we just collected.
    for pid in "${pids[@]}"; do
        kill -STOP "${pid}" 2>/dev/null || true
    done

    echo "=== Sample ${count} at ${timestamp} ==="
    for pid in "${pids[@]}"; do
        if ! is_live_non_zombie "${pid}"; then
            continue
        fi

        stats_file="/proc/${pid}/pte_stats"
        # Only print if file exists and we can read it
        if [[ -r "${stats_file}" ]]; then
            # Save to file
            outfile="${out_dir}/pte_stats_pid${pid}_${count}.txt"
            cat "${stats_file}" > "${outfile}" || echo "(failed to read)" > "${outfile}"
        fi
    done
    echo "Saved sample ${count} to ${out_dir}"
    echo "======================================="

    count=$((count + 1))
    
    # Small pause to keep overhead low/consistent
    sleep "${pause_window}"
done

echo "Monitor finished."
