#!/usr/bin/env bash
# gen_coverage_ts.sh — generate 60-min-interval branch-coverage timeseries for
# every (target, fuzzer, trial) we have local corpus data for, in parallel.
#
# Output: /20TB/miao/icse2027/coverage_ts/<target>/<fuzzer>/trial<N>/coverage_timeseries.csv
set -euo pipefail

TARGETS=(bloaty lcms libpng libxml2)
FUZZERS=(naive naive_ctx naive_ngram4 fast minimizer mopt grimoire cmplog value_profile value_profile_cmplog)
TRIALS=10
INTERVAL=60
JOBS="${JOBS:-40}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKER="${HERE}/cov_ts_worker.sh"

# Build the (target fuzzer trial) job list, smallest targets first for fast feedback.
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
xargs -P "$JOBS" -L1 -a "$list" "$WORKER" 2>&1 \
    | awk '{print; fflush()}' \
    || true
rm -f "$list"
echo "==> all jobs dispatched"
