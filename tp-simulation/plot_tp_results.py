#!/usr/bin/env python3
"""Plot load factor vs ops-per-slot from simulation CSV output."""

import argparse

import matplotlib.pyplot as plt
import pandas as pd


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plot x=ops_per_slot (log scale), y=max_load_factor, "
            "with one line per bit_width."
        )
    )
    parser.add_argument(
        "--input",
        default="output.csv",
        help="Path to CSV produced by tp_width_lf_test (default: output.csv)",
    )
    parser.add_argument(
        "--output",
        default="load_factor_vs_ops.png",
        help="Output image path (default: load_factor_vs_ops.png)",
    )
    parser.add_argument(
        "--title",
        default="Load Factor vs Ops Per Slot by Bit Width",
        help="Plot title",
    )
    parser.add_argument(
        "--dpi",
        type=int,
        default=150,
        help="Output image DPI (default: 150)",
    )
    return parser.parse_args()


def load_points(csv_path: str):
    df = pd.read_csv(csv_path)
    required = {"bit_width", "ops_per_slot", "max_load_factor"}
    missing = required.difference(df.columns)
    if missing:
        raise ValueError(f"Missing required CSV columns: {sorted(missing)}")

    df["bit_width"] = pd.to_numeric(df["bit_width"], errors="coerce")
    df["ops_per_slot"] = pd.to_numeric(df["ops_per_slot"], errors="coerce")
    df["max_load_factor"] = pd.to_numeric(df["max_load_factor"], errors="coerce")
    if "ops_per_slot_exponent" in df.columns:
        df["ops_per_slot_exponent"] = pd.to_numeric(df["ops_per_slot_exponent"], errors="coerce")
    df = df.dropna(subset=["bit_width", "ops_per_slot", "max_load_factor"])

    # Accept either fractional load factor [0,1] or percentage [0,100] in CSV.
    load_factor_scale = 100.0 if df["max_load_factor"].max() <= 1.0 else 1.0
    df["max_load_factor_pct"] = df["max_load_factor"] * load_factor_scale

    setup_cols = ["bit_width", "ops_per_slot_exponent"] if "ops_per_slot_exponent" in df.columns else [
        "bit_width", "ops_per_slot"
    ]

    setup_df = (
        df.groupby(setup_cols, as_index=False)
        .agg(
            ops_per_slot=("ops_per_slot", "mean"),
            max_load_factor_mean=("max_load_factor_pct", "mean"),
            max_load_factor_std=("max_load_factor_pct", "std"),
            sample_count=("max_load_factor_pct", "count"),
        )
    )
    setup_df["max_load_factor_std"] = setup_df["max_load_factor_std"].fillna(0.0)

    grouped = {}
    for bit_width, subdf in setup_df.groupby("bit_width"):
        sort_col = "ops_per_slot_exponent" if "ops_per_slot_exponent" in subdf.columns else "ops_per_slot"
        sorted_subdf = subdf.sort_values(sort_col)
        grouped[int(bit_width)] = list(
            zip(
                sorted_subdf["ops_per_slot"].astype(float),
                sorted_subdf["max_load_factor_mean"].astype(float),
                sorted_subdf["max_load_factor_std"].astype(float),
                sorted_subdf["sample_count"].astype(int),
            )
        )
    return grouped


def plot(grouped, output_path: str, title: str, dpi: int) -> None:
    plt.figure(figsize=(8, 5))

    for bit_width in sorted(grouped):
        xs = [p[0] for p in grouped[bit_width]]
        ys = [p[1] for p in grouped[bit_width]]
        yerr = [p[2] if p[3] > 1 else 0.0 for p in grouped[bit_width]]
        line = plt.plot(
            xs,
            ys,
            marker="o",
            linewidth=1.8,
            label=f"bit_width={bit_width}",
            markersize=1,
        )[0]
        line_color = line.get_color()
        if any(err > 0.0 for err in yerr):
            plt.errorbar(
                xs,
                ys,
                yerr=yerr,
                fmt="none",
                ecolor=line_color,
                elinewidth=1.0,
                capsize=3,
                alpha=0.7,
            )

    plt.xscale("log")
    plt.ylim(60, 100)
    plt.xlabel("Ops per Slot (log scale)")
    plt.ylabel("Max Load Factor (%)")
    plt.title(title)
    plt.grid(True, which="both", linestyle="--", linewidth=0.6, alpha=0.6)
    plt.legend(title="Series", loc="best")


    plt.tight_layout()
    plt.savefig(output_path, dpi=dpi)


def main() -> None:
    args = parse_args()
    grouped = load_points(args.input)
    if not grouped:
        raise ValueError("No rows found in input CSV")
    plot(grouped, args.output, args.title, args.dpi)


if __name__ == "__main__":
    main()
