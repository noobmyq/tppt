#!/usr/bin/env python3
import os
import argparse
import glob
import re
import pandas as pd

def parse_pte_stats_file(filepath):
    """
    Parses a single pte_stats file.
    Expected format per line: "flags: <hex> count: <decimal>"
    Returns a dictionary of {flags: count}.
    """
    stats = {}
    try:
        with open(filepath, 'r') as f:
            for line in f:
                if not line.strip():
                    continue
                # Kernel output: "Flags: 0x%lx Count: %ld"
                match = re.search(r"Flags:\s*0x([0-9a-fA-F]+)\s+Count:\s*(\d+)", line)
                if match:
                    flags = int(match.group(1), 16)
                    count = int(match.group(2))
                    stats[flags] = count
    except Exception as e:
        print(f"Error reading {filepath}: {e}")
    return stats

def main():
    parser = argparse.ArgumentParser(description="Analyze PTE stats from a results directory.")
    parser.add_argument("input_dir", help="Directory containing pte_stats_pid* files")
    parser.add_argument("--csv", help="Output results to a CSV file", default=None)
    args = parser.parse_args()

    input_dir = args.input_dir
    if not os.path.exists(input_dir):
        print(f"Error: Directory {input_dir} not found.")
        return

    # Find all stats files
    files = glob.glob(os.path.join(input_dir, "pte_stats_pid*.txt"))
    if not files:
        print(f"No pte_stats files found in {input_dir}")
        return

    print(f"Found {len(files)} files to analyze...")

    # Data collection
    # We want: 
    # 1. Per-process (PID) data: How many distinct configurations (flags) it has.
    # 2. Global data: How many distinct configurations across all processes.
    
    # Structure to hold per-pid stats: {pid: {flags: count, ...}}
    # But wait, we might have multiple samples for the same PID (timestamps).
    # The user asked: "each process has in total how many kinds of configuration"
    # This implies aggregating over time for a single PID, OR taking the max/latest.
    # Since the kernel stats are cumulative (we don't reset them), the latest file for a PID
    # should contain the superset of all configurations seen so far.
    # SO: We should group by PID and take the file with the latest timestamp/largest count?
    # Actually, the filename format is pte_stats_pid<pid>_<sample_count>.txt
    # The sample_count increases. So for each PID, we only care about the file with the highest sample_count.
    
    pid_files = {} # pid -> list of filepaths

    for filepath in files:
        filename = os.path.basename(filepath)
        # Format: pte_stats_pid<pid>_<sample>.txt
        match = re.match(r"pte_stats_pid(\d+)_(\d+)\.txt", filename)
        if match:
            pid = int(match.group(1))
            if pid not in pid_files:
                pid_files[pid] = []
            pid_files[pid].append(filepath)

    print(f"Identified {len(pid_files)} unique processes.")

    process_data = []
    all_flags_seen = set()
    
    for pid, filepaths in pid_files.items():
        # Aggregate stats across all files for this PID
        # Strategy: Union of flags, Max of counts (to capture peak usage/existence)
        aggregated_stats = {}
        
        for filepath in filepaths:
            stats = parse_pte_stats_file(filepath)
            for flag, count in stats.items():
                if flag not in aggregated_stats:
                    aggregated_stats[flag] = count
                else:
                    aggregated_stats[flag] = max(aggregated_stats[flag], count)
        
        # Unique configurations for this process
        unique_configs = len(aggregated_stats)
        
        # Total events (counts) for this process (Sum of max counts)
        total_events = sum(aggregated_stats.values())
        
        # Add to global set
        for flag in aggregated_stats.keys():
            all_flags_seen.add(flag)
            
        process_data.append({
            "PID": pid,
            "Unique_Configurations": unique_configs,
            "Total_Events": total_events,
            "Sample_Files_Count": len(filepaths)
        })

    # Global statistics
    total_unique_combinations_global = len(all_flags_seen)
    
    # Create DataFrame for per-process stats
    df = pd.DataFrame(process_data)
    
    # Sort for better readability
    if not df.empty:
        df = df.sort_values(by="Unique_Configurations", ascending=False)

    print("\n=== Analysis Results ===")
    print(f"Total Unique Combinations (Global across all processes): {total_unique_combinations_global}")
    print("\n--- Per-Process Breakdown ---")
    print(df.to_string(index=False))

    # --- Global Combinations Breakdown ---
    if total_unique_combinations_global > 0:
        print("\n--- Global Unique Combinations Detail ---")
        decoded_list = []
        for flags in sorted(list(all_flags_seen)):
            # x86 PTE bits
            # 0: Present, 1: RW, 2: User, 3: PWT, 4: PCD, 5: Accessed, 6: Dirty, 
            # 7: PAT/PSE, 8: Global, 9-11: Softw, 63: NX
            
            decoded = {
                "Hex": f"0x{flags:x}",
                "P": (flags >> 0) & 1,
                "R/W": (flags >> 1) & 1,
                "U/S": (flags >> 2) & 1,
                "PWT": (flags >> 3) & 1,
                "PCD": (flags >> 4) & 1,
                "A": (flags >> 5) & 1,
                "D": (flags >> 6) & 1,
                "PAT": (flags >> 7) & 1, # Bit 7 is PAT on 4KB pages
                "G": (flags >> 8) & 1,
                "Soft1": (flags >> 9) & 1,
                "Soft2": (flags >> 10) & 1,
                "Soft3": (flags >> 11) & 1,
                "NX": (flags >> 63) & 1
            }
            decoded_list.append(decoded)
            
        df_global = pd.DataFrame(decoded_list)
        # Reorder columns to match user expectation order roughly
        cols = ["Hex", "P", "R/W", "U/S", "PWT", "PCD", "A", "D", "PAT", "G", "Soft1", "Soft2", "Soft3", "NX"]
        # Only include columns present in the dict (all of them)
        print(df_global[cols].to_string(index=False))

    if args.csv:
        print(f"\nSaving results to {args.csv}...")
        df.to_csv(args.csv, index=False)
        
        # Also save the global breakdown?
        # Maybe to a separate file or modify the filename
        base, ext = os.path.splitext(args.csv)
        global_csv = f"{base}_global_flags{ext}"
        print(f"Saving global flag details to {global_csv}...")
        if 'df_global' in locals():
            df_global[cols].to_csv(global_csv, index=False)
        
        print("Done.")

if __name__ == "__main__":
    main()
