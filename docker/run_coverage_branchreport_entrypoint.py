#!/usr/bin/env python3
"""
Per-hourly-checkpoint llvm-cov annotated-source branch report.

Replays a LibAFL corpus in chronological order (inputs ordered by file mtime
relative to the earliest input — the trial start). At each hourly checkpoint
runs `llvm-cov show -show-branches=count` to write the annotated source for
the entire target, with per-branch T:N / F:M counts inline.

Output:
    branch_report_h01.txt, branch_report_h02.txt, ... branch_report_h24.txt
        (one file per hourly checkpoint, plain text, full annotated source)

Usage (inside container):
    python3 /run_coverage_branchreport.py /corpus /cov_out [interval_min]

Environment variables:
    FUZZ_BIN         path to instrumented fuzz target (required)
    BATCH_SIZE       max files per binary invocation (default 500)
"""

import os
import subprocess
import sys

CORPUS_DIR = sys.argv[1] if len(sys.argv) > 1 else "/corpus"
OUT_DIR    = sys.argv[2] if len(sys.argv) > 2 else "/cov_out"
INTERVAL_MIN = int(sys.argv[3]) if len(sys.argv) > 3 else 60

FUZZ_BIN   = os.environ["FUZZ_BIN"]
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "500"))

os.makedirs(OUT_DIR, exist_ok=True)
profraw_dir = os.path.join(OUT_DIR, "profraw_ts")
os.makedirs(profraw_dir, exist_ok=True)

# Start fresh — accumulate from scratch in this replay.
_stale = os.path.join(profraw_dir, "running.profdata")
if os.path.exists(_stale):
    os.remove(_stale)


def run_binary(files, profraw_out):
    env = os.environ.copy()
    env["LLVM_PROFILE_FILE"] = profraw_out
    for i in range(0, len(files), BATCH_SIZE):
        batch = files[i : i + BATCH_SIZE]
        subprocess.run(
            [FUZZ_BIN] + batch,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def merge_into_running(new_profraw, running):
    inputs = [new_profraw]
    if os.path.exists(running):
        inputs.append(running)
    subprocess.run(
        ["llvm-profdata-18", "merge", "-sparse"] + inputs + ["-o", running],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def write_branch_report(running, report_path):
    with open(report_path, "w") as f:
        subprocess.run(
            ["llvm-cov-18", "show", FUZZ_BIN,
             f"-instr-profile={running}",
             "-show-branches=count",
             "-use-color=false"],
            stdout=f,
            stderr=subprocess.DEVNULL,
            check=True,
        )


raw = []
for fname in os.listdir(CORPUS_DIR):
    if fname.startswith("."):
        continue
    fpath = os.path.join(CORPUS_DIR, fname)
    if not os.path.isfile(fpath):
        continue
    raw.append((os.path.getmtime(fpath), fpath))

if not raw:
    print("No inputs found.", file=sys.stderr)
    sys.exit(1)

t0 = min(mt for mt, _ in raw)
inputs = sorted((int((mt - t0) * 1000), fpath) for mt, fpath in raw)

max_elapsed_ms = inputs[-1][0]
print(f"Found {len(inputs)} inputs, max elapsed: {max_elapsed_ms/3600000:.2f}h")

interval_ms = INTERVAL_MIN * 60 * 1000
checkpoints = list(range(interval_ms, max_elapsed_ms + interval_ms, interval_ms))

running = os.path.join(profraw_dir, "running.profdata")

prev_idx = 0
batch_num = 0
have_data = False
n_reports = 0

for cp_ms in checkpoints:
    window_files = []
    while prev_idx < len(inputs) and inputs[prev_idx][0] <= cp_ms:
        window_files.append(inputs[prev_idx][1])
        prev_idx += 1

    if window_files:
        profraw_out = os.path.join(profraw_dir, f"batch_{batch_num}.profraw")
        print(f"  t={cp_ms/3600000:.2f}h: +{len(window_files)} inputs", flush=True)
        run_binary(window_files, profraw_out)
        merge_into_running(profraw_out, running)
        os.remove(profraw_out)
        batch_num += 1
        have_data = True

    if have_data:
        hour = cp_ms // (60 * 60 * 1000)
        report = os.path.join(OUT_DIR, f"branch_report_h{hour:02d}.txt")
        write_branch_report(running, report)
        sz = os.path.getsize(report)
        n_reports += 1
        print(f"    t={cp_ms/3600000:.2f}h: wrote {os.path.basename(report)} ({sz/1024/1024:.1f} MB)", flush=True)

print(f"\nWrote {n_reports} branch reports to {OUT_DIR}")
