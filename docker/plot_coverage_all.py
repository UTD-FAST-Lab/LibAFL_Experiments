#!/usr/bin/env python3
"""
Coverage-growth plots for the ICSE 2027 campaign.

For each target, emit one plot per mechanism group (naive is the shared baseline
in every group), each showing mean branch coverage over time across all trials,
one line per fuzzer. Also emits a per-group grid across targets.

Usage:
    python3 docker/plot_coverage_all.py \
        --results-dir /20TB/miao/icse2027/coverage_ts \
        --out-dir /20TB/miao/icse2027/coverage_plots \
        --targets bloaty lcms libpng libxml2 --trials 10
"""
import argparse
import csv
import math
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# Mechanism groups; naive is the shared baseline across all three.
GROUPS = {
    "roadblock": ("Roadblock-bypassing",
                  ["naive", "cmplog", "value_profile", "value_profile_cmplog"]),
    "feedback":  ("Feedback mechanism",
                  ["naive", "naive_ctx", "naive_ngram4"]),
    "mutation":  ("Mutation strategy",
                  ["naive", "minimizer", "mopt", "fast", "grimoire"]),
}

# Stable per-fuzzer colors so a fuzzer looks the same in every plot it appears in.
ALL_FUZZERS = ["naive", "naive_ctx", "naive_ngram4", "fast", "minimizer",
               "mopt", "grimoire", "cmplog", "value_profile", "value_profile_cmplog"]
COLORS = dict(zip(ALL_FUZZERS, plt.get_cmap("tab10").colors))

parser = argparse.ArgumentParser()
parser.add_argument("--targets", nargs="+",
                    default=["bloaty", "lcms", "libpng", "libxml2"])
parser.add_argument("--groups", nargs="+", default=list(GROUPS),
                    choices=list(GROUPS))
parser.add_argument("--trials", type=int, default=10)
parser.add_argument("--results-dir", default="/20TB/miao/icse2027/coverage_ts")
parser.add_argument("--out-dir", default="/20TB/miao/icse2027/coverage_plots")
parser.add_argument("--shade", action="store_true",
                    help="shade min/max band per fuzzer")
parser.add_argument("--no-grid", action="store_true",
                    help="skip the per-group cross-target grid figures")
args = parser.parse_args()
os.makedirs(args.out_dir, exist_ok=True)


def read_csv(path):
    rows = []
    with open(path) as f:
        for row in csv.DictReader(f):
            rows.append((int(row["time_s"]) / 3600, int(row["branch_covered"])))
    return rows


def load_target(target):
    """Return {fuzzer: [trial_rows, ...]} and max observed time (hours)."""
    data, max_time = {}, 0.0
    for fuzzer in ALL_FUZZERS:
        trials = []
        for trial in range(1, args.trials + 1):
            p = os.path.join(args.results_dir, target, fuzzer,
                             f"trial{trial}", "coverage_timeseries.csv")
            if not os.path.exists(p) or os.path.getsize(p) == 0:
                continue
            rows = read_csv(p)
            if rows:
                trials.append(rows)
                max_time = max(max_time, max(t for t, _ in rows))
        if trials:
            data[fuzzer] = trials
    return data, max_time


def mean_series(trials, times):
    matrix = []
    for trial in trials:
        d = dict(trial)
        last, row = 0, []
        for t in times:
            if t in d:
                last = d[t]
            row.append(last)
        matrix.append(row)
    m = np.array(matrix)
    return m.mean(axis=0), m.min(axis=0), m.max(axis=0), len(matrix)


def draw_panel(ax, target, data, max_time, fuzzers):
    present = [f for f in fuzzers if f in data]
    if not present:
        ax.text(0.5, 0.5, f"no data\n{target}", ha="center", va="center",
                transform=ax.transAxes)
        ax.set_title(target)
        return
    times = sorted(set(t for f in present for trial in data[f] for t, _ in trial))
    if times and times[-1] < max_time:
        times.append(max_time)
    for fuzzer in fuzzers:
        if fuzzer not in data:
            continue
        mean, lo, hi, n = mean_series(data[fuzzer], times)
        c = COLORS[fuzzer]
        ax.plot(times, mean, label=f"{fuzzer} (n={n})", linewidth=2, color=c)
        if args.shade:
            ax.fill_between(times, lo, hi, alpha=0.12, color=c)
    ax.set_xlabel("Time (hours)")
    ax.set_ylabel("Branches covered")
    ax.grid(True, alpha=0.3)
    ax.set_xlim(0, max_time)
    ax.legend(fontsize=9)


# Load each target once, reuse across groups.
loaded = {t: load_target(t) for t in args.targets}

# ── per-target, per-group figures ─────────────────────────────────────────────
for target in args.targets:
    data, max_time = loaded[target]
    for gkey in args.groups:
        gname, fuzzers = GROUPS[gkey]
        fig, ax = plt.subplots(figsize=(10, 6))
        draw_panel(ax, target, data, max_time, fuzzers)
        ax.set_title(f"Branch coverage over time — {target} ({gname})")
        fig.tight_layout()
        out = os.path.join(args.out_dir, f"coverage_{target}_{gkey}.png")
        fig.savefig(out, dpi=150)
        plt.close(fig)
        have = [f for f in fuzzers if f in data]
        print(f"saved {out}  ({', '.join(have) if have else 'NO DATA'})")

# ── per-group cross-target grid figures ───────────────────────────────────────
if not args.no_grid:
    n = len(args.targets)
    cols = 2 if n > 1 else 1
    rows = math.ceil(n / cols)
    for gkey in args.groups:
        gname, fuzzers = GROUPS[gkey]
        fig, axes = plt.subplots(rows, cols, figsize=(7 * cols, 4.5 * rows),
                                 squeeze=False)
        for idx, target in enumerate(args.targets):
            ax = axes[idx // cols][idx % cols]
            data, max_time = loaded[target]
            draw_panel(ax, target, data, max_time, fuzzers)
            ax.set_title(target)
        for idx in range(n, rows * cols):
            axes[idx // cols][idx % cols].set_visible(False)
        fig.suptitle(f"Branch coverage over time — {gname} (mean over trials)",
                     fontsize=14)
        fig.tight_layout(rect=[0, 0, 1, 0.97])
        out = os.path.join(args.out_dir, f"coverage_grid_{gkey}.png")
        fig.savefig(out, dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"saved {out}")
