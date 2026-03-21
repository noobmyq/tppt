#!/usr/bin/env python3
"""Plot huge-page availability trends for matching vanilla/tp runs.

Default data root is auto-detected from:
  /mnt/storage/tppt/mount.point/home/*/thp_alloc_exp/results

For a matching run (e.g., run_001) in both:
  results/vanilla_pause_probe/run_xxx/pause_metrics.csv
  results/tp_pause_probe/run_xxx/pause_metrics.csv

Primary plot (normalized by pause_idx=0 baseline):
  vanilla_raw          = possible_hugepages
  tp_raw               = iceberg_huge_available
  tp_allow_move1_raw   = iceberg_huge_available + iceberg_huge_if_move1
  y                    = raw(pause_idx) / raw(pause_idx=0)

Optional state-aligned plot:
  x                    = free_pages(pause) / free_pages(pause_idx=0)
  y                    = hugepage_available / hugepage_theory
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import re
import sys
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Tuple


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Plot normalized pause ratios for vanilla vs tp")
    p.add_argument(
        "--results-root",
        default=None,
        help=(
            "Path to results root (contains vanilla_pause_probe and tp_pause_probe). "
            "Default: auto-detect under /mnt/storage/tppt/mount.point/home/*/thp_alloc_exp/results"
        ),
    )
    p.add_argument(
        "--run",
        default=None,
        help="Run directory name to compare, e.g. run_001. Default: latest common run.",
    )
    p.add_argument(
        "--output",
        default=None,
        help="Output PNG path. Default: <results-root>/pause_ratio_<run>.png",
    )
    p.add_argument(
        "--include-final",
        action="store_true",
        help="Include pause_idx=999 final row in the plot (default: exclude).",
    )
    p.add_argument(
        "--show",
        action="store_true",
        help="Also display interactive plot window.",
    )
    p.add_argument(
        "--plot-avail-over-theory",
        action="store_true",
        help=(
            "Also generate an additional plot where y = hugepage_available / hugepage_theory "
            "(vanilla uses buddyinfo ratio; tp uses iceberg available_over_theory)."
        ),
    )
    p.add_argument(
        "--plot-free-ratio-avail-over-theory",
        action="store_true",
        help=(
            "Also generate state-aligned plot with x=free_ratio (vs pause_idx=0) and "
            "y=available/theory."
        ),
    )
    p.add_argument(
        "--plot-available-only",
        action="store_true",
        help=(
            "Also generate an additional plot where y is raw available hugepages "
            "(vanilla possible_hugepages, tp iceberg_huge_available)."
        ),
    )
    p.add_argument(
        "--free-ratio-source",
        choices=["model", "measured"],
        default="model",
        help=(
            "Source for free_ratio in the state-aligned plot. "
            "'model' uses 1 - allocated_pages/base_free_pages (better alignment); "
            "'measured' uses snapshot free pages."
        ),
    )
    return p.parse_args()


def detect_default_results_root() -> Optional[str]:
    candidates = sorted(
        d
        for d in glob.glob("/mnt/storage/tppt/mount.point/home/*/thp_alloc_exp/results")
        if os.path.isdir(d)
    )
    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        print("[warn] multiple mount.point candidates found:", file=sys.stderr)
        for d in candidates:
            print(f"  - {d}", file=sys.stderr)
        print(f"[warn] using first: {candidates[0]}", file=sys.stderr)
        return candidates[0]

    fallback = "/mnt/storage/tppt/thp_alloc_exp/results"
    if os.path.isdir(fallback):
        print(f"[warn] mount.point results not found; fallback to {fallback}", file=sys.stderr)
        return fallback
    return None


def run_key(name: str) -> int:
    m = re.match(r"^run_(\d+)$", name)
    if not m:
        return -1
    return int(m.group(1))


def list_runs(base: str) -> List[str]:
    if not os.path.isdir(base):
        return []
    out = []
    for e in os.listdir(base):
        if run_key(e) >= 0 and os.path.isdir(os.path.join(base, e)):
            out.append(e)
    out.sort(key=run_key)
    return out


def pick_matching_run(results_root: str, requested: Optional[str]) -> str:
    vanilla_runs = set(list_runs(os.path.join(results_root, "vanilla_pause_probe")))
    tp_runs = set(list_runs(os.path.join(results_root, "tp_pause_probe")))
    common = sorted(vanilla_runs & tp_runs, key=run_key)

    if not common:
        raise FileNotFoundError(
            "No matching run_* found in both vanilla_pause_probe and tp_pause_probe"
        )

    if requested:
        if requested not in common:
            raise FileNotFoundError(f"Requested run '{requested}' not found in common runs: {common}")
        return requested

    return common[-1]


def to_float(s: str) -> Optional[float]:
    if s is None:
        return None
    s = s.strip()
    if not s or s.upper() == "NA":
        return None
    try:
        return float(s)
    except ValueError:
        return None


def _snapshot_pause_idx(dirname: str) -> Optional[int]:
    if dirname == "initial":
        return 0
    if dirname == "final":
        return 999
    m = re.match(r"^pause_(\d+)$", dirname)
    if not m:
        return None
    return int(m.group(1))


def _snapshot_file_map(run_dir: str, filename: str) -> Dict[int, str]:
    root = os.path.join(run_dir, "snapshots")
    if not os.path.isdir(root):
        return {}
    out: Dict[int, str] = {}
    for p in glob.glob(os.path.join(root, "*", filename)):
        idx = _snapshot_pause_idx(os.path.basename(os.path.dirname(p)))
        if idx is None:
            continue
        out[idx] = p
    return out


def _float_equal(a: float, b: float, eps: float = 1e-6) -> bool:
    return abs(a - b) <= eps


def _values_mismatch(csv_val: str, snap_val: str) -> bool:
    c = to_float(csv_val)
    s = to_float(snap_val)
    if c is None and s is None:
        return False
    if c is None or s is None:
        return True
    return not _float_equal(c, s)


def _fmt_optional_int(v: Optional[int]) -> str:
    if v is None:
        return "NA"
    return str(int(v))


def _fmt_optional_float(v: Optional[float], digits: int = 9) -> str:
    if v is None:
        return "NA"
    if abs(v - round(v)) <= 1e-12:
        return str(int(round(v)))
    return f"{v:.{digits}f}".rstrip("0").rstrip(".")


def _parse_iceberg_snapshot(path: str) -> Dict[str, str]:
    avail = None
    avail_total = None
    move1 = None
    util_used = None
    util_total = None

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            m = re.match(r"^Utilization:\s*(\d+)\s*/\s*(\d+)", line)
            if m:
                util_used = int(m.group(1))
                util_total = int(m.group(2))
                continue
            m = re.match(r"^Huge pages available:\s*(\d+)\s*/\s*(\d+)", line)
            if m:
                avail = int(m.group(1))
                avail_total = int(m.group(2))
                continue
            m = re.match(r"^Huge pages if moving 1 pages?:\s*(\d+)", line)
            if m:
                move1 = int(m.group(1))

    util_free = None
    theory = None
    avail_over_theory = None
    if util_used is not None and util_total is not None:
        util_free = util_total - util_used
        theory = util_free // 512
        if avail is not None and theory > 0:
            avail_over_theory = avail / theory

    return {
        "iceberg_huge_available": _fmt_optional_int(avail),
        "iceberg_huge_available_total": _fmt_optional_int(avail_total),
        "iceberg_huge_if_move1": _fmt_optional_int(move1),
        "iceberg_util_used_pages": _fmt_optional_int(util_used),
        "iceberg_util_total_pages": _fmt_optional_int(util_total),
        "iceberg_util_free_pages": _fmt_optional_int(util_free),
        "iceberg_theory_hugepages": _fmt_optional_int(theory),
        "iceberg_available_over_theory": _fmt_optional_float(avail_over_theory),
    }


def _parse_buddyinfo_snapshot(path: str) -> Dict[Tuple[int, str], Dict[str, float]]:
    out: Dict[Tuple[int, str], Dict[str, float]] = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            m = re.match(r"^Node\s+(\d+),\s+zone\s+(\S+)\s+(.*)$", line)
            if not m:
                continue
            node = int(m.group(1))
            zone = m.group(2)
            try:
                orders = [int(x) for x in m.group(3).split()]
            except ValueError:
                continue
            total = 0
            for i, cnt in enumerate(orders):
                total += cnt * (2 ** i)
            order9 = orders[9] if len(orders) > 9 else 0
            order10 = orders[10] if len(orders) > 10 else 0
            possible = order9 + 2 * order10
            theory = total // 512
            ratio = (possible / theory) if theory > 0 else 0.0
            out[(node, zone)] = {
                "order9": float(order9),
                "order10": float(order10),
                "possible_hugepages": float(possible),
                "theory_hugepages": float(theory),
                "ratio": float(ratio),
                "total_free_pages": float(total),
            }
    return out


def _log_mismatch(run_dir: str, pause_idx: int, field: str, csv_val: str, snap_val: str) -> None:
    run_name = os.path.basename(run_dir)
    print(
        f"[error] {run_name} pause_idx={pause_idx} field={field} csv={csv_val} snapshot={snap_val}; using snapshot",
        file=sys.stderr,
    )


def _reconcile_tp_rows(rows: List[Dict[str, str]], run_dir: str) -> int:
    snap_map = _snapshot_file_map(run_dir, "iceberg.txt")
    if not snap_map:
        return 0

    fields = [
        "iceberg_huge_available",
        "iceberg_huge_available_total",
        "iceberg_huge_if_move1",
        "iceberg_util_used_pages",
        "iceberg_util_total_pages",
        "iceberg_util_free_pages",
        "iceberg_theory_hugepages",
        "iceberg_available_over_theory",
    ]

    mismatches = 0
    for row in rows:
        idx = int(row["pause_idx"])
        snap_path = snap_map.get(idx)
        if not snap_path:
            continue
        snap = _parse_iceberg_snapshot(snap_path)
        for field in fields:
            csv_val = row.get(field, "NA")
            snap_val = snap.get(field, "NA")
            if _values_mismatch(csv_val, snap_val):
                _log_mismatch(run_dir, idx, field, csv_val, snap_val)
                mismatches += 1
            row[field] = snap_val
    return mismatches


def _infer_buddy_target(rows: List[Dict[str, str]], snap_map: Dict[int, str]) -> Optional[Tuple[int, str]]:
    if not snap_map:
        return None
    first_idx = min(snap_map.keys())
    first = _parse_buddyinfo_snapshot(snap_map[first_idx])
    if not first:
        return None

    keys = ["order9", "order10", "possible_hugepages", "theory_hugepages", "total_free_pages"]
    candidates = sorted(first.keys())
    cache: Dict[str, Dict[Tuple[int, str], Dict[str, float]]] = {}

    best = None
    best_score = -1
    best_total = -1
    for cand in candidates:
        score = 0
        total = 0
        for row in rows:
            idx = int(row["pause_idx"])
            snap_path = snap_map.get(idx)
            if not snap_path:
                continue
            if snap_path not in cache:
                cache[snap_path] = _parse_buddyinfo_snapshot(snap_path)
            cur = cache[snap_path].get(cand)
            if not cur:
                continue
            for key in keys:
                cv = to_float(row.get(key, ""))
                if cv is None:
                    continue
                total += 1
                if _float_equal(cv, float(cur[key])):
                    score += 1
        if score > best_score or (score == best_score and total > best_total):
            best = cand
            best_score = score
            best_total = total
    return best


def _reconcile_vanilla_rows(rows: List[Dict[str, str]], run_dir: str) -> int:
    snap_map = _snapshot_file_map(run_dir, "buddyinfo.txt")
    if not snap_map:
        return 0

    target = _infer_buddy_target(rows, snap_map)
    if target is None:
        print(f"[warn] {os.path.basename(run_dir)}: unable to infer node/zone for buddy validation", file=sys.stderr)
        return 0

    fields = ["order9", "order10", "possible_hugepages", "theory_hugepages", "ratio", "total_free_pages"]
    cache: Dict[str, Dict[Tuple[int, str], Dict[str, float]]] = {}
    mismatches = 0

    for row in rows:
        idx = int(row["pause_idx"])
        snap_path = snap_map.get(idx)
        if not snap_path:
            continue
        if snap_path not in cache:
            cache[snap_path] = _parse_buddyinfo_snapshot(snap_path)
        cur = cache[snap_path].get(target)
        if not cur:
            continue

        snap_vals = {
            "order9": _fmt_optional_int(int(cur["order9"])),
            "order10": _fmt_optional_int(int(cur["order10"])),
            "possible_hugepages": _fmt_optional_int(int(cur["possible_hugepages"])),
            "theory_hugepages": _fmt_optional_int(int(cur["theory_hugepages"])),
            "ratio": _fmt_optional_float(float(cur["ratio"]), digits=6),
            "total_free_pages": _fmt_optional_int(int(cur["total_free_pages"])),
        }

        for field in fields:
            csv_val = row.get(field, "NA")
            snap_val = snap_vals[field]
            if _values_mismatch(csv_val, snap_val):
                _log_mismatch(run_dir, idx, field, csv_val, snap_val)
                mismatches += 1
            row[field] = snap_val

    return mismatches


def load_rows(csv_path: str, include_final: bool) -> List[Dict[str, str]]:
    if not os.path.isfile(csv_path):
        raise FileNotFoundError(csv_path)

    rows: List[Dict[str, str]] = []
    with open(csv_path, "r", newline="") as f:
        rd = csv.DictReader(f)
        for r in rd:
            pidx = r.get("pause_idx", "")
            if not pidx.isdigit():
                continue
            if not include_final and int(pidx) == 999:
                continue
            rows.append(r)

    rows.sort(key=lambda r: int(r["pause_idx"]))

    run_dir = os.path.dirname(csv_path)
    mismatch_count = 0
    if "tp_pause_probe" in csv_path:
        mismatch_count = _reconcile_tp_rows(rows, run_dir)
    elif "vanilla_pause_probe" in csv_path:
        mismatch_count = _reconcile_vanilla_rows(rows, run_dir)

    if mismatch_count:
        print(
            f"[error] {os.path.basename(run_dir)}: {mismatch_count} CSV/snapshot mismatches detected; plotting with snapshot values",
            file=sys.stderr,
        )

    return rows


def compute_normalized_series(
    rows: List[Dict[str, str]], raw_ratio_fn
) -> Tuple[List[int], List[float], float]:
    raw_by_idx: Dict[int, float] = {}
    for r in rows:
        idx = int(r["pause_idx"])
        v = raw_ratio_fn(r)
        if v is None:
            continue
        raw_by_idx[idx] = v

    if 0 not in raw_by_idx:
        raise ValueError("Missing valid baseline at pause_idx=0")

    baseline = raw_by_idx[0]
    if baseline == 0:
        raise ValueError("Baseline ratio at pause_idx=0 is zero; cannot normalize")

    xs = sorted(raw_by_idx.keys())
    ys = [raw_by_idx[x] / baseline for x in xs]
    return xs, ys, baseline


def compute_direct_series(rows: List[Dict[str, str]], raw_ratio_fn) -> Tuple[List[int], List[float]]:
    raw_by_idx: Dict[int, float] = {}
    for r in rows:
        idx = int(r["pause_idx"])
        v = raw_ratio_fn(r)
        if v is None:
            continue
        raw_by_idx[idx] = v
    xs = sorted(raw_by_idx.keys())
    ys = [raw_by_idx[x] for x in xs]
    return xs, ys


def compute_free_ratio_xy_series(
    rows: List[Dict[str, str]], free_pages_fn, y_ratio_fn, ratio_source: str
) -> Tuple[List[float], List[float], float]:
    free0: Optional[float] = None
    for r in rows:
        if int(r["pause_idx"]) != 0:
            continue
        free_pages = free_pages_fn(r)
        if free_pages is not None:
            free0 = free_pages
            break

    if free0 is None:
        raise ValueError("Missing valid free-pages baseline at pause_idx=0")

    if free0 <= 0:
        raise ValueError("Free-pages baseline at pause_idx=0 is zero; cannot compute free_ratio")

    xs: List[float] = []
    ys: List[float] = []
    for r in rows:
        y = y_ratio_fn(r)
        if y is None:
            continue

        if ratio_source == "model":
            alloc_pages = to_float(r.get("allocated_pages", ""))
            if alloc_pages is None:
                continue
            x = 1.0 - (alloc_pages / free0)
        else:
            free_pages = free_pages_fn(r)
            if free_pages is None:
                continue
            x = free_pages / free0

        if x < 0:
            x = 0.0
        elif x > 1:
            x = 1.0
        xs.append(x)
        ys.append(y)

    return xs, ys, free0


def vanilla_raw_ratio(row: Dict[str, str]) -> Optional[float]:
    possible = to_float(row.get("possible_hugepages", ""))
    if possible is None:
        return None
    return possible


def tp_raw_ratio(row: Dict[str, str]) -> Optional[float]:
    avail = to_float(row.get("iceberg_huge_available", ""))
    if avail is None:
        return None
    return avail


def tp_allow_move1_raw_ratio(row: Dict[str, str]) -> Optional[float]:
    avail = to_float(row.get("iceberg_huge_available", ""))
    move1 = to_float(row.get("iceberg_huge_if_move1", ""))
    if avail is None or move1 is None:
        return None
    return avail + move1


def vanilla_avail_over_theory(row: Dict[str, str]) -> Optional[float]:
    ratio = to_float(row.get("ratio", ""))
    if ratio is not None:
        return ratio

    possible = to_float(row.get("possible_hugepages", ""))
    theory = to_float(row.get("theory_hugepages", ""))
    if possible is None or theory is None or theory <= 0:
        return None
    return possible / theory


def tp_avail_over_theory(row: Dict[str, str]) -> Optional[float]:
    v = to_float(row.get("iceberg_available_over_theory", ""))
    if v is not None:
        return v

    avail = to_float(row.get("iceberg_huge_available", ""))
    theory = to_float(row.get("iceberg_theory_hugepages", ""))
    if avail is None or theory is None or theory <= 0:
        return None
    return avail / theory


def tp_move1_over_theory(row: Dict[str, str]) -> Optional[float]:
    move1 = to_float(row.get("iceberg_huge_if_move1", ""))
    theory = to_float(row.get("iceberg_theory_hugepages", ""))
    if move1 is None or theory is None or theory <= 0:
        return None

    avail = to_float(row.get("iceberg_huge_available", ""))
    if avail is None:
        return None
    return (avail + move1) / theory


def vanilla_free_pages(row: Dict[str, str]) -> Optional[float]:
    return to_float(row.get("total_free_pages", ""))


def tp_free_pages(row: Dict[str, str]) -> Optional[float]:
    free_pages = to_float(row.get("iceberg_util_free_pages", ""))
    if free_pages is not None:
        return free_pages

    theory = to_float(row.get("iceberg_theory_hugepages", ""))
    if theory is None:
        return None
    return theory * 512.0


def main() -> int:
    args = parse_args()

    results_root = args.results_root or detect_default_results_root()
    if not results_root:
        print("[error] could not find results root; pass --results-root", file=sys.stderr)
        return 2

    run_name = pick_matching_run(results_root, args.run)
    vanilla_csv = os.path.join(results_root, "vanilla_pause_probe", run_name, "pause_metrics.csv")
    tp_csv = os.path.join(results_root, "tp_pause_probe", run_name, "pause_metrics.csv")

    vanilla_rows = load_rows(vanilla_csv, include_final=args.include_final)
    tp_rows = load_rows(tp_csv, include_final=args.include_final)

    vx, vy, v0 = compute_normalized_series(vanilla_rows, vanilla_raw_ratio)
    tx, ty, t0 = compute_normalized_series(tp_rows, tp_raw_ratio)
    tx1, ty1, t10 = compute_normalized_series(tp_rows, tp_allow_move1_raw_ratio)
    out_png = args.output or os.path.abspath(f"pause_ratio_{run_name}.png")
    out_dir = os.path.dirname(out_png)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    try:
        import matplotlib.pyplot as plt
    except Exception as e:
        print(f"[error] matplotlib import failed: {e}", file=sys.stderr)
        print("[hint] install matplotlib or run in env that has it.", file=sys.stderr)
        return 3

    plt.figure(figsize=(10, 5.8))
    plt.plot(vx, vy, marker="o", linewidth=1.8, label="vanilla (normalized)")
    plt.plot(tx, ty, marker="s", linewidth=1.8, label="tp (normalized)")
    plt.plot(tx1, ty1, marker="^", linewidth=1.8, label="tp + allow move1 (normalized)")

    plt.xlabel("pause_idx")
    plt.ylabel("normalized hugepage available (vs pause_idx=0)")
    plt.title(f"Hugepage Available vs pause_idx ({run_name})")
    plt.grid(True, alpha=0.35)
    plt.legend()
    plt.tight_layout()
    try:
        plt.savefig(out_png, dpi=180)
    except PermissionError as e:
        print(f"[error] cannot write output '{out_png}': {e}", file=sys.stderr)
        print("[hint] pass --output to a writable path (for example ./pause_ratio.png)", file=sys.stderr)
        return 4

    # Additional zoomed graph:
    #   x-axis: pause_idx > 10
    #   y-axis: [0, 0.2]
    def filter_after_10(xs: List[int], ys: List[float]) -> Tuple[List[int], List[float]]:
        fx: List[int] = []
        fy: List[float] = []
        for x, y in zip(xs, ys):
            if x > 10:
                fx.append(x)
                fy.append(y)
        return fx, fy

    zvx, zvy = filter_after_10(vx, vy)
    ztx, zty = filter_after_10(tx, ty)
    ztx1, zty1 = filter_after_10(tx1, ty1)

    base, ext = os.path.splitext(out_png)
    if not ext:
        ext = ".png"
    zoom_png = f"{base}_zoom_after10_y0_0.2{ext}"

    plt.figure(figsize=(10, 5.8))
    if zvx:
        plt.plot(zvx, zvy, marker="o", linewidth=1.8, label="vanilla (normalized)")
    if ztx:
        plt.plot(ztx, zty, marker="s", linewidth=1.8, label="tp (normalized)")
    if ztx1:
        plt.plot(ztx1, zty1, marker="^", linewidth=1.8, label="tp + allow move1 (normalized)")

    plt.xlabel("pause_idx")
    plt.ylabel("normalized hugepage available (vs pause_idx=0)")
    plt.title(f"Hugepage Available Zoom (pause_idx > 10, y in [0,0.2]) ({run_name})")
    plt.xlim(left=10)
    plt.ylim(0, 0.2)
    plt.grid(True, alpha=0.35)
    plt.legend()
    plt.tight_layout()
    try:
        plt.savefig(zoom_png, dpi=180)
    except PermissionError as e:
        print(f"[error] cannot write zoom output '{zoom_png}': {e}", file=sys.stderr)
        print("[hint] pass --output to a writable path (for example ./pause_ratio.png)", file=sys.stderr)
        return 5

    print(f"results_root: {results_root}")
    print(f"run: {run_name}")
    print(f"vanilla baseline (pause_idx=0): {v0:.6f}")
    print(f"tp baseline (pause_idx=0): {t0:.6f}")
    print(f"tp+move1 baseline (pause_idx=0): {t10:.6f}")
    print(f"output: {out_png}")
    print(f"zoom_output: {zoom_png}")

    available_only_png = ""
    if args.plot_available_only:
        avx, avy = compute_direct_series(vanilla_rows, vanilla_raw_ratio)
        atx, aty = compute_direct_series(tp_rows, tp_raw_ratio)

        available_only_png = f"{base}_available_only{ext}"
        plt.figure(figsize=(10, 5.8))
        if avx:
            plt.plot(avx, avy, marker="o", linewidth=1.8, label="vanilla available")
        if atx:
            plt.plot(atx, aty, marker="s", linewidth=1.8, label="tp available")
        plt.xlabel("pause_idx")
        plt.ylabel("available huge pages")
        plt.title(f"Raw Hugepage Availability ({run_name})")
        plt.grid(True, alpha=0.35)
        plt.legend()
        plt.tight_layout()
        try:
            plt.savefig(available_only_png, dpi=180)
        except PermissionError as e:
            print(f"[error] cannot write available-only output '{available_only_png}': {e}", file=sys.stderr)
            print("[hint] pass --output to a writable path (for example ./pause_ratio.png)", file=sys.stderr)
            return 6

    if available_only_png:
        print(f"available_only_output: {available_only_png}")

    theory_png = ""
    if args.plot_avail_over_theory:
        tvx, tvy = compute_direct_series(vanilla_rows, vanilla_avail_over_theory)
        ttx, tty = compute_direct_series(tp_rows, tp_avail_over_theory)
        ttx1, tty1 = compute_direct_series(tp_rows, tp_move1_over_theory)

        theory_png = f"{base}_avail_over_theory{ext}"
        plt.figure(figsize=(10, 5.8))
        if tvx:
            plt.plot(tvx, tvy, marker="o", linewidth=1.8, label="vanilla avail/theory")
        if ttx:
            plt.plot(ttx, tty, marker="s", linewidth=1.8, label="tp avail/theory")
        if ttx1:
            plt.plot(ttx1, tty1, marker="^", linewidth=1.8, label="tp (avail+move1)/theory")
        plt.xlabel("pause_idx")
        plt.ylabel("hugepage available / hugepage theory")
        plt.title(f"Hugepage Availability Over Theory ({run_name})")
        plt.grid(True, alpha=0.35)
        plt.legend()
        plt.tight_layout()
        try:
            plt.savefig(theory_png, dpi=180)
        except PermissionError as e:
            print(f"[error] cannot write theory output '{theory_png}': {e}", file=sys.stderr)
            print("[hint] pass --output to a writable path (for example ./pause_ratio.png)", file=sys.stderr)
            return 7

    if theory_png:
        print(f"theory_output: {theory_png}")

    free_ratio_png = ""
    if args.plot_free_ratio_avail_over_theory:
        try:
            fr_vx, fr_vy, fr_v0 = compute_free_ratio_xy_series(
                vanilla_rows, vanilla_free_pages, vanilla_avail_over_theory, args.free_ratio_source
            )
            fr_tx, fr_ty, fr_t0 = compute_free_ratio_xy_series(
                tp_rows, tp_free_pages, tp_avail_over_theory, args.free_ratio_source
            )
            fr_tx1, fr_ty1, _ = compute_free_ratio_xy_series(
                tp_rows, tp_free_pages, tp_move1_over_theory, args.free_ratio_source
            )
        except ValueError as e:
            print(f"[warn] skip free-ratio availability plot: {e}", file=sys.stderr)
        else:
            free_ratio_png = f"{base}_free_ratio_vs_avail_over_theory{ext}"
            plt.figure(figsize=(10, 5.8))
            if fr_vx:
                plt.plot(fr_vx, fr_vy, marker="o", linewidth=1.8, label="vanilla avail/theory")
            if fr_tx:
                plt.plot(fr_tx, fr_ty, marker="s", linewidth=1.8, label="tp avail/theory")
            if fr_tx1:
                plt.plot(fr_tx1, fr_ty1, marker="^", linewidth=1.8, label="tp (avail+move1)/theory")
            plt.xlabel("free_ratio (free_pages / free_pages@pause0)")
            plt.ylabel("hugepage available / hugepage theory")
            plt.title(f"State-Aligned Availability ({run_name})")
            plt.grid(True, alpha=0.35)
            plt.legend()
            plt.tight_layout()
            try:
                plt.savefig(free_ratio_png, dpi=180)
            except PermissionError as e:
                print(f"[error] cannot write free-ratio output '{free_ratio_png}': {e}", file=sys.stderr)
                print("[hint] pass --output to a writable path (for example ./pause_ratio.png)", file=sys.stderr)
                return 8
            print(f"vanilla free-pages baseline (pause_idx=0): {fr_v0:.0f}")
            print(f"tp free-pages baseline (pause_idx=0): {fr_t0:.0f}")
            print(f"free_ratio_source: {args.free_ratio_source}")

    if free_ratio_png:
        print(f"free_ratio_output: {free_ratio_png}")

    if args.show:
        plt.show()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
