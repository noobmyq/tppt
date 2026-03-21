#!/bin/bash
set -euo pipefail

# VM-side probe runner.
# Mode exclusivity:
#   vanilla       -> /proc/buddyinfo only
#   tp,tp_compact -> /proc/iceberg only

MODE=${1:-vanilla}
RUNS=${2:-1}
ALLOC_SIZE=${3:-90%}
TARGET_SIZE=${4:-20%}
PIN_DENSITY=${5:-128}
CYCLES=${6:-5}
NODE=${7:-1}
ZONE=${8:-Normal}
USE_NUMACTL_MEMBIND=${USE_NUMACTL_MEMBIND:-1}
FRAGMENTOR=${FRAGMENTOR:-random}
FRAG_MAX_MAP_COUNT=${FRAG_MAX_MAP_COUNT:-10485760}
FRAG_RANDOM_MODE=${FRAG_RANDOM_MODE:-mixed}
ALLOC_RATIO_PCT=${ALLOC_RATIO_PCT:-}
TARGET_RATIO_PCT=${TARGET_RATIO_PCT:-}
PAUSE_MARK_STEP_PCT=${PAUSE_MARK_STEP_PCT:-10}
PCP_HIGH_FRACTION=${PCP_HIGH_FRACTION:-1024}
PCP_DRAIN_BEFORE_RUN=${PCP_DRAIN_BEFORE_RUN:-1}
PCP_DRAIN_BEFORE_SNAPSHOT=${PCP_DRAIN_BEFORE_SNAPSHOT:-0}
PCP_DRAIN_BEFORE_FINAL=${PCP_DRAIN_BEFORE_FINAL:-0}
COMPACT_ONCE_BEFORE_RUN=${COMPACT_ONCE_BEFORE_RUN:-1}

# Pause controls passed into frag_probe_pause:
#   fill_pause_hpages / drain_pause_hpages: pause every N hugepages in each phase
#   pause_marks_csv: comma-separated absolute allocated sizes, e.g., 1G,2G,3G
# Default requested behavior:
#   - no step-based pauses
#   - marks at every full GB up to alloc size (e.g., 9G -> 1G..9G)
PAUSE_FILL_EVERY_HP=${PAUSE_FILL_EVERY_HP:-0}
PAUSE_DRAIN_EVERY_HP=${PAUSE_DRAIN_EVERY_HP:-0}
PAUSE_MARKS=${PAUSE_MARKS:-}

FRAG_PID=""
PCP_SYSCTL_KEY=""

log_ts() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

parse_size_to_bytes() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)([KkMmGg]?)$ ]]; then
    local n="${BASH_REMATCH[1]}"
    local u="${BASH_REMATCH[2]}"
    case "$u" in
      ""|[Kk])
        echo $((n * 1024))
        ;;
      [Mm])
        echo $((n * 1024 * 1024))
        ;;
      [Gg])
        echo $((n * 1024 * 1024 * 1024))
        ;;
      *)
        echo 0
        ;;
    esac
  else
    echo 0
  fi
}

extract_free_pages_from_mode_metrics() {
  local metrics_csv="$1"
  if use_iceberg_mode; then
    awk -F',' '{print $12}' <<< "$metrics_csv"
  else
    awk -F',' '{print $6}' <<< "$metrics_csv"
  fi
}

build_default_gb_marks() {
  local bytes="$1"
  local one_gb=$((1024 * 1024 * 1024))
  local max_gb=$((bytes / one_gb))
  local i
  local out=""

  for ((i = 1; i <= max_gb; i++)); do
    if [[ -n "$out" ]]; then
      out+=" ,${i}G"
    else
      out="${i}G"
    fi
  done

  # normalize separators (remove spaces introduced above)
  echo "${out// /}"
}

build_default_pct_marks() {
  local total_bytes="$1"
  local max_pct="$2"
  local step_pct="$3"
  local pct
  local out=""
  local mark_kb
  local prev_kb=0

  if (( total_bytes <= 0 || max_pct <= 0 || step_pct <= 0 )); then
    echo ""
    return
  fi

  for ((pct = step_pct; pct <= max_pct; pct += step_pct)); do
    mark_kb=$(( (total_bytes * pct / 100) / 1024 ))
    if (( mark_kb <= 0 || mark_kb == prev_kb )); then
      continue
    fi
    if [[ -n "$out" ]]; then
      out+=",${mark_kb}K"
    else
      out="${mark_kb}K"
    fi
    prev_kb=$mark_kb
  done

  if (( max_pct % step_pct != 0 )); then
    mark_kb=$(( (total_bytes * max_pct / 100) / 1024 ))
    if (( mark_kb > 0 && mark_kb != prev_kb )); then
      if [[ -n "$out" ]]; then
        out+=",${mark_kb}K"
      else
        out="${mark_kb}K"
      fi
    fi
  fi

  echo "$out"
}

cleanup_on_exit() {
  local rc=$?
  if [[ -n "$FRAG_PID" ]] && kill -0 "$FRAG_PID" 2>/dev/null; then
    log_ts "CLEANUP rc=${rc} pid=${FRAG_PID} sending CONT then TERM"
    kill -CONT "$FRAG_PID" 2>/dev/null || true
    kill -TERM "$FRAG_PID" 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT

if [[ "$MODE" != "vanilla" && "$MODE" != "tp" && "$MODE" != "tp_compact" ]]; then
  echo "Usage: $0 <mode> [runs alloc_size target_size pin_density cycles node zone]"
  echo "mode: vanilla|tp|tp_compact"
  exit 1
fi

if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "RUNS must be positive"
  exit 1
fi

if ! [[ "$PAUSE_FILL_EVERY_HP" =~ ^[0-9]+$ ]]; then
  echo "PAUSE_FILL_EVERY_HP must be a non-negative integer"
  exit 1
fi
if ! [[ "$PAUSE_DRAIN_EVERY_HP" =~ ^[0-9]+$ ]]; then
  echo "PAUSE_DRAIN_EVERY_HP must be a non-negative integer"
  exit 1
fi
if ! [[ "$FRAG_MAX_MAP_COUNT" =~ ^[0-9]+$ ]]; then
  echo "FRAG_MAX_MAP_COUNT must be a non-negative integer"
  exit 1
fi
if ! [[ "$PAUSE_MARK_STEP_PCT" =~ ^[0-9]+$ ]]; then
  echo "PAUSE_MARK_STEP_PCT must be a non-negative integer"
  exit 1
fi
if (( PAUSE_MARK_STEP_PCT < 1 || PAUSE_MARK_STEP_PCT > 100 )); then
  echo "PAUSE_MARK_STEP_PCT must be in [1,100]"
  exit 1
fi
if ! [[ "$PCP_HIGH_FRACTION" =~ ^[0-9]+$ ]]; then
  echo "PCP_HIGH_FRACTION must be a non-negative integer"
  exit 1
fi
if ! [[ "$PCP_DRAIN_BEFORE_RUN" =~ ^[01]$ ]]; then
  echo "PCP_DRAIN_BEFORE_RUN must be 0 or 1"
  exit 1
fi
if ! [[ "$PCP_DRAIN_BEFORE_SNAPSHOT" =~ ^[01]$ ]]; then
  echo "PCP_DRAIN_BEFORE_SNAPSHOT must be 0 or 1"
  exit 1
fi
if ! [[ "$PCP_DRAIN_BEFORE_FINAL" =~ ^[01]$ ]]; then
  echo "PCP_DRAIN_BEFORE_FINAL must be 0 or 1"
  exit 1
fi
if ! [[ "$COMPACT_ONCE_BEFORE_RUN" =~ ^[01]$ ]]; then
  echo "COMPACT_ONCE_BEFORE_RUN must be 0 or 1"
  exit 1
fi

if [[ -z "$ALLOC_RATIO_PCT" && "$ALLOC_SIZE" =~ ^([0-9]+)%$ ]]; then
  ALLOC_RATIO_PCT="${BASH_REMATCH[1]}"
fi
if [[ -z "$TARGET_RATIO_PCT" && "$TARGET_SIZE" =~ ^([0-9]+)%$ ]]; then
  TARGET_RATIO_PCT="${BASH_REMATCH[1]}"
fi

USE_RATIO_BOUNDS=0
if [[ -n "$ALLOC_RATIO_PCT" || -n "$TARGET_RATIO_PCT" ]]; then
  if [[ -z "$ALLOC_RATIO_PCT" || -z "$TARGET_RATIO_PCT" ]]; then
    echo "ALLOC_RATIO_PCT and TARGET_RATIO_PCT must be set together (or pass alloc/target as NN%)"
    exit 1
  fi
  if ! [[ "$ALLOC_RATIO_PCT" =~ ^[0-9]+$ ]]; then
    echo "ALLOC_RATIO_PCT must be an integer percentage"
    exit 1
  fi
  if ! [[ "$TARGET_RATIO_PCT" =~ ^[0-9]+$ ]]; then
    echo "TARGET_RATIO_PCT must be an integer percentage"
    exit 1
  fi
  if (( ALLOC_RATIO_PCT < 1 || ALLOC_RATIO_PCT > 100 )); then
    echo "ALLOC_RATIO_PCT must be in [1,100]"
    exit 1
  fi
  if (( TARGET_RATIO_PCT < 1 || TARGET_RATIO_PCT > 100 )); then
    echo "TARGET_RATIO_PCT must be in [1,100]"
    exit 1
  fi
  if (( TARGET_RATIO_PCT >= ALLOC_RATIO_PCT )); then
    echo "TARGET_RATIO_PCT must be smaller than ALLOC_RATIO_PCT"
    exit 1
  fi
  USE_RATIO_BOUNDS=1
fi

AUTO_PAUSE_MARKS=0
# If PAUSE_MARKS is not explicitly set:
#   - absolute mode: every full GB up to ALLOC_SIZE
#   - ratio mode: every PAUSE_MARK_STEP_PCT up to ALLOC_RATIO_PCT
if [[ -z "$PAUSE_MARKS" ]]; then
  AUTO_PAUSE_MARKS=1
  if (( USE_RATIO_BOUNDS == 0 )); then
    alloc_bytes=$(parse_size_to_bytes "$ALLOC_SIZE")
    if (( alloc_bytes >= 1024 * 1024 * 1024 )); then
      PAUSE_MARKS=$(build_default_gb_marks "$alloc_bytes")
    fi
  fi
fi

EXP_BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. >/dev/null 2>&1 && pwd)"
case "$FRAGMENTOR" in
  grid)
    BIN_SRC="${EXP_BASE}/allocator_exp/frag_probe_pause.c"
    ;;
  random)
    BIN_SRC="${EXP_BASE}/allocator_exp/frag_random_pause.c"
    ;;
  *)
    echo "FRAGMENTOR must be 'grid' or 'random' (got '$FRAGMENTOR')"
    exit 1
    ;;
esac

if [[ "$FRAGMENTOR" == "random" ]]; then
  case "$FRAG_RANDOM_MODE" in
    mixed|regular|regular_only|4k)
      ;;
    *)
      echo "FRAG_RANDOM_MODE must be one of: mixed|regular|regular_only|4k (got '$FRAG_RANDOM_MODE')"
      exit 1
      ;;
  esac
fi

BIN="${EXP_BASE}/alloctest"
RESULT_BASE="${EXP_BASE}/results/${MODE}_pause_probe"

mkdir -p "$RESULT_BASE"

if [[ ! -f "$BIN_SRC" ]]; then
  echo "Missing source: $BIN_SRC"
  exit 1
fi

if [[ ! -x "$BIN" || "$BIN_SRC" -nt "$BIN" ]]; then
  log_ts "BUILD bin=${BIN} src=${BIN_SRC}"
  gcc -O2 -Wall -Wextra "$BIN_SRC" -o "$BIN"
fi

use_iceberg_mode() {
  [[ "$MODE" == "tp" || "$MODE" == "tp_compact" ]]
}

maybe_setup_mode() {
  if [[ "$MODE" == "vanilla" ]]; then
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null
    echo 0 | sudo tee /proc/sys/vm/compaction_proactiveness >/dev/null
    echo 1000 | sudo tee /proc/sys/vm/extfrag_threshold >/dev/null
    if [[ -w /proc/sys/kernel/numa_balancing ]]; then
      echo 0 | sudo tee /proc/sys/kernel/numa_balancing >/dev/null
    fi
    sudo swapoff -a || true
  fi
}

maybe_setup_fragmentor_limits() {
  if (( FRAG_MAX_MAP_COUNT > 0 )); then
    sudo sysctl -w "vm.max_map_count=${FRAG_MAX_MAP_COUNT}" >/dev/null
  fi
}

detect_pcp_sysctl_key() {
  if [[ -w /proc/sys/vm/percpu_pagelist_fraction ]]; then
    PCP_SYSCTL_KEY="vm.percpu_pagelist_fraction"
  elif [[ -w /proc/sys/vm/percpu_pagelist_high_fraction ]]; then
    PCP_SYSCTL_KEY="vm.percpu_pagelist_high_fraction"
  else
    PCP_SYSCTL_KEY=""
  fi
}

setup_pcp_controls() {
  if (( PCP_HIGH_FRACTION > 0 )); then
    if [[ -n "$PCP_SYSCTL_KEY" ]]; then
      sudo sysctl -w "${PCP_SYSCTL_KEY}=${PCP_HIGH_FRACTION}" >/dev/null
    else
      log_ts "PCP_CONFIG_WARN no percpu_pagelist_{fraction,high_fraction} sysctl found"
    fi
  fi
}

compact_memory_once() {
  local reason="$1"
  log_ts "COMPACT reason=${reason} compact_memory=1"
  echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
}

drain_pcp_once() {
  local reason="$1"
  if (( PCP_HIGH_FRACTION > 0 )) && [[ -n "$PCP_SYSCTL_KEY" ]]; then
    # No direct userspace API exists for PCP-only drain in vanilla kernels.
    # Re-applying a very high fraction keeps PCP high/batch tiny to minimize
    # accumulation between snapshots without forcing compaction.
    log_ts "PCP_DRAIN reason=${reason} mode=pcp_sysctl_only key=${PCP_SYSCTL_KEY} value=${PCP_HIGH_FRACTION}"
    sudo sysctl -w "${PCP_SYSCTL_KEY}=${PCP_HIGH_FRACTION}" >/dev/null
  else
    log_ts "PCP_DRAIN reason=${reason} mode=pcp_sysctl_only skipped"
  fi
}

next_run_idx() {
  local max_idx=0
  local d base="$1"
  for d in "$base"/run_*; do
    [[ -d "$d" ]] || continue
    local b
    b=$(basename "$d")
    if [[ "$b" =~ ^run_([0-9]+)$ ]]; then
      local idx=$((10#${BASH_REMATCH[1]}))
      (( idx > max_idx )) && max_idx=$idx
    fi
  done
  echo $((max_idx + 1))
}

calc_buddy_metrics() {
  local buddy_file="$1"
  local node="$2"
  local zone="$3"

  awk -v node="$node" -v zone="$zone" '
  function to_number(x) { return x + 0 }
  $1 == "Node" {
    n = $2
    gsub(/,/, "", n)
    z = $4
    gsub(/,/, "", z)
    if (to_number(n) == to_number(node) && z == zone) {
      cnt = 0
      total_free_pages = 0
      for (i = 5; i <= NF; i++) {
        ord[cnt] = $i + 0
        total_free_pages += ord[cnt] * (2 ^ cnt)
        cnt++
      }
      order9 = (cnt > 9) ? ord[9] : 0
      order10 = (cnt > 10) ? ord[10] : 0
      possible = order9 + (2 * order10)
      theory = int(total_free_pages / 512)
      ratio = (theory > 0) ? (possible / theory) : 0
      printf "%d,%d,%d,%d,%.6f,%d\n", order9, order10, possible, theory, ratio, total_free_pages
      found = 1
      exit
    }
  }
  END {
    if (!found)
      printf "0,0,0,0,0.000000,0\n"
  }
  ' "$buddy_file"
}

calc_iceberg_metrics() {
  local iceberg_file="$1"
  if [[ ! -r "$iceberg_file" ]]; then
    echo "NA,NA,NA,NA,NA,NA,NA,NA"
    return
  fi

  awk '
  BEGIN {
    avail="NA"; avail_total="NA"; move1="NA"
    util_used="NA"; util_total="NA"; frag_idx="NA"
  }
  /^Utilization:/ {
    split($2, a, "/")
    util_used=a[1]
    util_total=a[2]
  }
  /^Huge pages available:/ {
    split($4, a, "/")
    avail=a[1]
    avail_total=a[2]
  }
  /^Fragmentation index:/ {
    frag_idx=$3
  }
  /^Huge pages if moving 1 pages?:/ {
    move1=$7
  }
  END {
    util_free_pages="NA"
    theory_hugepages="NA"
    avail_over_theory="NA"

    if (util_used != "NA" && util_total != "NA") {
      util_free_pages = (util_total + 0) - (util_used + 0)
      theory_hugepages = int(util_free_pages / 512)
      if (avail != "NA" && theory_hugepages > 0) {
        avail_over_theory = (avail + 0) / theory_hugepages
      }
    }

    printf "%s,%s,%s,%s,%s,%s,%s,%s\n",
           avail, avail_total, move1,
           util_used, util_total, util_free_pages,
           theory_hugepages, avail_over_theory
  }
  ' "$iceberg_file"
}

snapshot_one() {
  local snap_dir="$1"
  mkdir -p "$snap_dir"

  if use_iceberg_mode; then
    if [[ -r /proc/iceberg ]]; then
      cat /proc/iceberg > "$snap_dir/iceberg.txt"
    fi
  else
    cat /proc/buddyinfo > "$snap_dir/buddyinfo.txt"
  fi
}

metrics_for_snapshot() {
  local snap_dir="$1"
  local buddy_csv ice_csv

  if use_iceberg_mode; then
    if [[ -r "$snap_dir/iceberg.txt" ]]; then
      ice_csv=$(calc_iceberg_metrics "$snap_dir/iceberg.txt")
    else
      ice_csv="NA,NA,NA,NA,NA,NA,NA,NA"
    fi
    echo "NA,NA,NA,NA,NA,NA,${ice_csv}"
  else
    buddy_csv=$(calc_buddy_metrics "$snap_dir/buddyinfo.txt" "$NODE" "$ZONE")
    echo "${buddy_csv},NA,NA,NA,NA,NA,NA,NA,NA"
  fi
}

read_vmstat_counter() {
  local key="$1"
  awk -v k="$key" '
  $1 == k { print $2; found = 1; exit }
  END { if (!found) print 0 }
  ' /proc/vmstat 2>/dev/null
}

thp_metrics_for_run() {
  local base_alloc="$1"
  local base_fallback="$2"
  local cur_alloc cur_fallback diff_alloc diff_fallback

  cur_alloc=$(read_vmstat_counter "thp_fault_alloc")
  cur_fallback=$(read_vmstat_counter "thp_fault_fallback")

  if ! [[ "$cur_alloc" =~ ^[0-9]+$ ]]; then
    cur_alloc=0
  fi
  if ! [[ "$cur_fallback" =~ ^[0-9]+$ ]]; then
    cur_fallback=0
  fi

  diff_alloc=$((cur_alloc - base_alloc))
  diff_fallback=$((cur_fallback - base_fallback))
  echo "${cur_alloc},${cur_fallback},${diff_alloc},${diff_fallback}"
}

get_proc_state() {
  local pid="$1"
  awk '/^State:/ {print $2}' "/proc/${pid}/status" 2>/dev/null || true
}

latest_pause_enter_line() {
  local log="$1"
  awk '/^PAUSE_ENTER /{line=$0} END{print line}' "$log" 2>/dev/null || true
}

latest_checkpoint_for_pause() {
  local log="$1"
  local pause_idx="$2"
  awk -v p="$pause_idx" '
  /^CHECKPOINT / {
    for (i=1; i<=NF; i++) {
      if ($i ~ /^pause_idx=/) {
        split($i, a, "=")
        if (a[2] == p) line=$0
        break
      }
    }
  }
  END { print line }
  ' "$log" 2>/dev/null || true
}

extract_kv() {
  local line="$1"
  local key="$2"
  awk -v k="$key" '{
    for(i=1;i<=NF;i++) {
      if($i ~ ("^"k"=")) {
        split($i,a,"=")
        print a[2]
        exit
      }
    }
  }' <<< "$line"
}

maybe_setup_fragmentor_limits
maybe_setup_mode
detect_pcp_sysctl_key
setup_pcp_controls

if use_iceberg_mode; then
  log_ts "MODE=${MODE} source=/proc/iceberg"
else
  log_ts "MODE=${MODE} source=/proc/buddyinfo"
fi
log_ts "FRAGMENTOR=${FRAGMENTOR} source_file=${BIN_SRC}"
log_ts "PAUSE_CONFIG fill_every_hp=${PAUSE_FILL_EVERY_HP} drain_every_hp=${PAUSE_DRAIN_EVERY_HP} marks='${PAUSE_MARKS}'"
if (( PCP_HIGH_FRACTION > 0 )); then
  if [[ -n "$PCP_SYSCTL_KEY" ]]; then
    log_ts "PCP_CONFIG key=${PCP_SYSCTL_KEY} value=${PCP_HIGH_FRACTION}"
  else
    log_ts "PCP_CONFIG key=missing value=${PCP_HIGH_FRACTION}"
  fi
else
  log_ts "PCP_CONFIG unchanged"
fi
log_ts "PCP_DRAIN_CONFIG before_run=${PCP_DRAIN_BEFORE_RUN} before_snapshot=${PCP_DRAIN_BEFORE_SNAPSHOT} before_final=${PCP_DRAIN_BEFORE_FINAL}"
log_ts "COMPACT_CONFIG once_before_run=${COMPACT_ONCE_BEFORE_RUN}"
if [[ "$FRAGMENTOR" == "random" ]]; then
  log_ts "RANDOM_MODE=${FRAG_RANDOM_MODE}"
fi
if (( USE_RATIO_BOUNDS == 1 )); then
  log_ts "BOUNDS_MODE=ratio alloc=${ALLOC_RATIO_PCT}% target=${TARGET_RATIO_PCT}%"
  log_ts "AUTO_MARKS_STEP=${PAUSE_MARK_STEP_PCT}% (ratio mode when PAUSE_MARKS is empty)"
else
  log_ts "BOUNDS_MODE=absolute alloc='${ALLOC_SIZE}' target='${TARGET_SIZE}'"
fi

START_IDX=$(next_run_idx "$RESULT_BASE")
END_IDX=$((START_IDX + RUNS - 1))
log_ts "RUN_RANGE count=${RUNS} start=run_$(printf '%03d' "$START_IDX") end=run_$(printf '%03d' "$END_IDX")"

for ((r=0; r<RUNS; r++)); do
  RUN_IDX=$((START_IDX + r))
  RUN_NAME="run_$(printf '%03d' "$RUN_IDX")"
  RUN_DIR="${RESULT_BASE}/${RUN_NAME}"
  CSV="${RUN_DIR}/pause_metrics.csv"
  LOG="${RUN_DIR}/frag_probe.log"

  mkdir -p "$RUN_DIR"

  log_ts "RUN_START run=${RUN_NAME}"
  if (( COMPACT_ONCE_BEFORE_RUN == 1 )); then
    compact_memory_once "run_start_${RUN_NAME}"
  fi
  if (( PCP_DRAIN_BEFORE_RUN == 1 )); then
    drain_pcp_once "run_start_${RUN_NAME}"
  fi
  thp_alloc_base=$(read_vmstat_counter "thp_fault_alloc")
  thp_fallback_base=$(read_vmstat_counter "thp_fault_fallback")
  echo "run_idx,pause_idx,cycle,phase,allocated_pages,allocated_kb,order9,order10,possible_hugepages,theory_hugepages,ratio,total_free_pages,iceberg_huge_available,iceberg_huge_available_total,iceberg_huge_if_move1,iceberg_util_used_pages,iceberg_util_total_pages,iceberg_util_free_pages,iceberg_theory_hugepages,iceberg_available_over_theory,thp_fault_alloc,thp_fault_fallback,thp_fault_alloc_diff,thp_fault_fallback_diff" > "$CSV"

  initial_snap="${RUN_DIR}/snapshots/initial"
  if (( PCP_DRAIN_BEFORE_SNAPSHOT == 1 )); then
    drain_pcp_once "initial_snapshot_${RUN_NAME}"
  fi
  snapshot_one "$initial_snap"
  mode_metrics=$(metrics_for_snapshot "$initial_snap")
  echo "${RUN_IDX},0,0,initial,0,0,${mode_metrics},$(thp_metrics_for_run "${thp_alloc_base}" "${thp_fallback_base}")" >> "$CSV"

  run_alloc_size="$ALLOC_SIZE"
  run_target_size="$TARGET_SIZE"
  run_pause_marks="$PAUSE_MARKS"

  if (( USE_RATIO_BOUNDS == 1 )); then
    initial_free_pages=$(extract_free_pages_from_mode_metrics "$mode_metrics")
    if ! [[ "$initial_free_pages" =~ ^[0-9]+$ ]] || (( initial_free_pages <= 0 )); then
      echo "Failed to derive initial free pages for ratio bounds (mode=${MODE}, value='${initial_free_pages}')"
      exit 1
    fi

    alloc_bytes=$(( initial_free_pages * 4096 * ALLOC_RATIO_PCT / 100 ))
    target_bytes=$(( initial_free_pages * 4096 * TARGET_RATIO_PCT / 100 ))

    if (( alloc_bytes < 4096 )); then
      echo "Computed alloc_bytes too small: ${alloc_bytes}"
      exit 1
    fi
    if (( target_bytes < 4096 )); then
      target_bytes=4096
    fi
    if (( target_bytes >= alloc_bytes )); then
      target_bytes=$((alloc_bytes - 4096))
    fi
    if (( target_bytes <= 0 )); then
      echo "Computed target_bytes invalid: ${target_bytes}"
      exit 1
    fi

    run_alloc_size="$((alloc_bytes / 1024))K"
    run_target_size="$((target_bytes / 1024))K"
    log_ts "RUN_BOUNDS run=${RUN_NAME} initial_free_pages=${initial_free_pages} alloc=${run_alloc_size} target=${run_target_size}"

    if (( AUTO_PAUSE_MARKS == 1 )); then
      initial_free_bytes=$((initial_free_pages * 4096))
      run_pause_marks=$(build_default_pct_marks "$initial_free_bytes" "$ALLOC_RATIO_PCT" "$PAUSE_MARK_STEP_PCT")
    fi
  fi

  FRAG_CMD=("$BIN" "$run_alloc_size" "$run_target_size" "$PIN_DENSITY" "$CYCLES" "$PAUSE_FILL_EVERY_HP" "$PAUSE_DRAIN_EVERY_HP" "$run_pause_marks")
  if [[ "$FRAGMENTOR" == "random" ]]; then
    FRAG_CMD+=("$FRAG_RANDOM_MODE")
  fi
  if [[ "$USE_NUMACTL_MEMBIND" == "1" ]] && command -v numactl >/dev/null 2>&1; then
    FRAG_CMD=(numactl --membind="$NODE" "${FRAG_CMD[@]}")
  fi

  printf 'Fragmentor command: %q ' "${FRAG_CMD[@]}"
  echo

  "${FRAG_CMD[@]}" > "$LOG" 2>&1 &
  FRAG_PID=$!
  log_ts "FRAG_STARTED run=${RUN_NAME} pid=${FRAG_PID}"

  last_handled_pause=0
  last_state=""
  idle_ticks=0

  while kill -0 "$FRAG_PID" 2>/dev/null; do
    state=$(get_proc_state "$FRAG_PID")

    if [[ "$state" != "$last_state" ]]; then
      log_ts "STATE_CHANGE run=${RUN_NAME} pid=${FRAG_PID} state=${state:-unknown}"
      last_state="$state"
    fi

    pause_line=$(latest_pause_enter_line "$LOG")
    pause_idx_num=$(extract_kv "$pause_line" "pause_idx")

    if [[ "$pause_idx_num" =~ ^[0-9]+$ ]] && (( pause_idx_num > last_handled_pause )); then
      cycle=$(extract_kv "$pause_line" "cycle")
      phase=$(extract_kv "$pause_line" "phase")
      cp_line=$(latest_checkpoint_for_pause "$LOG" "$pause_idx_num")
      allocated_pages=$(extract_kv "$cp_line" "allocated_pages")
      allocated_kb=$(extract_kv "$cp_line" "allocated_kb")
      [[ -z "$allocated_pages" ]] && allocated_pages=0
      [[ -z "$allocated_kb" ]] && allocated_kb=0

      log_ts "PAUSE_DETECTED run=${RUN_NAME} pid=${FRAG_PID} pause_idx=${pause_idx_num} cycle=${cycle:-NA} phase=${phase:-NA}"

      for _ in $(seq 1 25); do
        s2=$(get_proc_state "$FRAG_PID")
        if [[ "$s2" == "T" || "$s2" == "t" ]]; then
          break
        fi
        sleep 0.02
      done

      pause_tag=$(printf 'pause_%03d' "$pause_idx_num")
      snap_dir="${RUN_DIR}/snapshots/${pause_tag}"
      if (( PCP_DRAIN_BEFORE_SNAPSHOT == 1 )); then
        drain_pcp_once "pause_snapshot_${RUN_NAME}_${pause_tag}"
      fi
      snapshot_one "$snap_dir"
      mode_metrics=$(metrics_for_snapshot "$snap_dir")
      echo "${RUN_IDX},${pause_idx_num},${cycle:-NA},${phase:-NA},${allocated_pages},${allocated_kb},${mode_metrics},$(thp_metrics_for_run "${thp_alloc_base}" "${thp_fallback_base}")" >> "$CSV"

      log_ts "RESUME_SEND run=${RUN_NAME} pid=${FRAG_PID} pause_idx=${pause_idx_num}"
      kill -CONT "$FRAG_PID" 2>/dev/null || true
      last_handled_pause=$pause_idx_num
      idle_ticks=0
      sleep 0.05
      continue
    fi

    if [[ "$state" == "T" || "$state" == "t" ]]; then
      idle_ticks=$((idle_ticks + 1))
      if (( idle_ticks % 20 == 0 )); then
        log_ts "STOPPED_NO_NEW_MARKER run=${RUN_NAME} pid=${FRAG_PID} ticks=${idle_ticks} forcing_resume"
        kill -CONT "$FRAG_PID" 2>/dev/null || true
      fi
    else
      idle_ticks=0
    fi

    sleep 0.05
  done

  wait "$FRAG_PID"
  log_ts "FRAG_EXITED run=${RUN_NAME} pid=${FRAG_PID}"
  FRAG_PID=""

  final_snap="${RUN_DIR}/snapshots/final"
  if (( PCP_DRAIN_BEFORE_FINAL == 1 )); then
    drain_pcp_once "final_snapshot_${RUN_NAME}"
  fi
  snapshot_one "$final_snap"
  mode_metrics=$(metrics_for_snapshot "$final_snap")
  echo "${RUN_IDX},999,999,final,0,0,${mode_metrics},$(thp_metrics_for_run "${thp_alloc_base}" "${thp_fallback_base}")" >> "$CSV"

  log_ts "RUN_DONE run=${RUN_NAME} csv=${CSV}"
done
