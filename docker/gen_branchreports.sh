#!/usr/bin/env bash
# gen_branchreports.sh — llvm-cov annotated branch report at every hourly
# checkpoint for every (target, fuzzer, trial) we have corpus data for.
#
# Output: /20TB/miao/icse2027/coverage_ts/<target>/<fuzzer>/trial<N>/
#         branch_report_h01.txt ... branch_report_h24.txt
#
# Resume-friendly: re-running skips trials whose h24 report already exists.
set -euo pipefail

TARGETS=(bloaty lcms libpng libxml2)
FUZZERS=(naive naive_ctx naive_ngram4 fast minimizer mopt grimoire cmplog value_profile value_profile_cmplog)
TRIALS=10
INTERVAL=60
JOBS="${JOBS:-60}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKER="${HERE}/cov_branchreport_worker.sh"

# smallest targets first for fast feedback; libxml2 (heaviest) last.
list=$(mktemp)
for target in lcms libpng bloaty libxml2; do
    for fuzzer in "${FUZZERS[@]}"; do
        for trial in $(seq 1 "$TRIALS"); do
            echo "$target $fuzzer $trial $INTERVAL"
        done
    done
done > "$list"

total=$(wc -l < "$list")
echo "==> $total jobs, ${JOBS}-way parallel, interval=${INTERVAL}min"
xargs -P "$JOBS" -L1 -a "$list" "$WORKER" 2>&1 | awk '{print; fflush()}' || true
rm -f "$list"
echo "==> all jobs dispatched"
