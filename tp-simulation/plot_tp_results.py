#!/usr/bin/env python3
"""Plot checkpoint huge-page availability efficiency from TP fragmentation CSV."""

import argparse

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plot x=pause index, y=available_huge_slots/(available_slots_total/512) "
            "with one line per allocator (tp vs vanilla)."
        )
    )
    parser.add_argument(
        "--input",
        default="tp_allocator_frag_checkpoints.csv",
        help="Path to checkpoint CSV (default: tp_allocator_frag_checkpoints.csv)",
    )
    parser.add_argument(
        "--output",
        default="tp_allocator_frag_huge_efficiency.png",
        help="Output image path (default: tp_allocator_frag_huge_efficiency.png)",
    )
    parser.add_argument(
        "--title",
        default="Huge-Page Availability Efficiency vs Pause Index",
        help="Plot title",
    )
    parser.add_argument(
        "--dpi",
        type=int,
        default=150,
        help="Output image DPI (default: 150)",
    )
    return parser.parse_args()


def load_and_prepare(csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    required = {
        "allocator",
        "cycle",
        "phase",
        "checkpoint_idx",
        "available_slots_total",
        "available_huge_slots",
    }
    missing = required.difference(df.columns)
    if missing:
        raise ValueError(f"Missing required CSV columns: {sorted(missing)}")

    for col in ["cycle", "checkpoint_idx", "available_slots_total", "available_huge_slots"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    df["allocator"] = df["allocator"].astype(str).str.strip().str.lower()
    df["phase"] = df["phase"].astype(str).str.strip().str.lower()
    df = df.dropna(subset=["allocator", "cycle", "phase", "checkpoint_idx", "available_slots_total", "available_huge_slots"])

    # Fill checkpoints happen before drain checkpoints in a cycle.
    phase_order = {"fill": 0, "drain": 1}
    df["phase_order"] = df["phase"].map(phase_order)
    df = df.dropna(subset=["phase_order"]) 

    df = df.sort_values(["allocator", "cycle", "phase_order", "checkpoint_idx"]).copy()
    df["pause_index"] = df.groupby("allocator").cumcount() + 1

    # theory_huge_page = available_slots_total / 512
    df["theory_huge_page"] = df["available_slots_total"] / 512.0
    denom = df["theory_huge_page"].to_numpy(dtype=float)
    numer = df["available_huge_slots"].to_numpy(dtype=float)
    with np.errstate(divide="ignore", invalid="ignore"):
        ratio = np.where(denom > 0.0, numer / denom, np.nan)
    df["huge_efficiency_ratio"] = ratio

    # Keep only the two allocators requested by default view.
    df = df[df["allocator"].isin(["tp", "vanilla"])].copy()
    if df.empty:
        raise ValueError("No tp/vanilla rows found in input CSV")

    return df


def plot(df: pd.DataFrame, output_path: str, title: str, dpi: int) -> None:
    plt.figure(figsize=(9, 5))

    for allocator in ["tp", "vanilla"]:
        sub = df[df["allocator"] == allocator]
        if sub.empty:
            continue
        plt.plot(
            sub["pause_index"],
            sub["huge_efficiency_ratio"],
            marker="o",
            markersize=3,
            linewidth=1.8,
            label=allocator,
        )

    plt.axhline(1.0, color="gray", linestyle="--", linewidth=1.0, alpha=0.7)
    plt.xlabel("Pause index")
    plt.ylabel("avail_huge_page / (avail_slots_total / 512)")
    plt.title(title)
    plt.grid(True, linestyle="--", linewidth=0.6, alpha=0.6)
    plt.legend(title="allocator", loc="best")
    plt.ylim(bottom=0.0)
    plt.tight_layout()
    plt.savefig(output_path, dpi=dpi)


def main() -> None:
    args = parse_args()
    df = load_and_prepare(args.input)
    plot(df, args.output, args.title, args.dpi)


if __name__ == "__main__":
    main()
