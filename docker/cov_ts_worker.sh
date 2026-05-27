#!/usr/bin/env bash
# cov_ts_worker.sh — compute a single (target, fuzzer, trial) coverage timeseries.
# Usage: cov_ts_worker.sh <target> <fuzzer> <trial> <interval_min>
# Resume-friendly: skips if the output CSV already exists.
set -euo pipefail

target="$1"; fuzzer="$2"; trial="$3"; interval="${4:-60}"

RESULTS_DIR="/20TB/miao/icse2027"
ENTRYPOINT="/home/miao/LibAFL_Experiments/docker/run_coverage_timeseries_csvonly.py"

corpus="${RESULTS_DIR}/${target}/${fuzzer}/trial${trial}/queue"
out_dir="${RESULTS_DIR}/coverage_ts/${target}/${fuzzer}/trial${trial}"
csv="${out_dir}/coverage_timeseries.csv"

if [ ! -d "$corpus" ]; then
    echo "SKIP  ${target}/${fuzzer}/t${trial}: no queue dir"
    exit 0
fi
if [ -s "$csv" ] && [ "$(wc -l < "$csv")" -gt 1 ]; then
    echo "DONE  ${target}/${fuzzer}/t${trial}: csv exists"
    exit 0
fi

mkdir -p "$out_dir"
start=$(date +%s)
if docker run --rm \
    -v "${corpus}:/corpus:ro" \
    -v "${out_dir}:/cov_out" \
    -v "${ENTRYPOINT}:/run_coverage_timeseries.py:ro" \
    --entrypoint python3 \
    "libafl-${target}-cov" \
    /run_coverage_timeseries.py /corpus /cov_out "$interval" \
    > "${out_dir}/replay.log" 2>&1; then
    n=$(($(wc -l < "$csv") - 1))
    echo "OK    ${target}/${fuzzer}/t${trial}: ${n} points ($(( $(date +%s) - start ))s)"
else
    echo "FAIL  ${target}/${fuzzer}/t${trial}: see ${out_dir}/replay.log"
fi
