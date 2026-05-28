#!/usr/bin/env bash
# cov_branchreport_worker.sh — llvm-cov annotated branch report at each hourly
# checkpoint for a single (target, fuzzer, trial).
# Usage: cov_branchreport_worker.sh <target> <fuzzer> <trial> <interval_min>
# Output dir: ${RESULTS_DIR}/coverage_ts/<target>/<fuzzer>/trial<N>/
#   branch_report_h01.txt ... branch_report_h24.txt
# Resume-friendly: skips a trial whose final-hour report (h24) already exists with content.
set -euo pipefail

target="$1"; fuzzer="$2"; trial="$3"; interval="${4:-60}"

RESULTS_DIR="/20TB/miao/icse2027"
ENTRYPOINT="/home/miao/LibAFL_Experiments/docker/run_coverage_branchreport_entrypoint.py"

corpus="${RESULTS_DIR}/${target}/${fuzzer}/trial${trial}/queue"
out_dir="${RESULTS_DIR}/coverage_ts/${target}/${fuzzer}/trial${trial}"

if [ ! -d "$corpus" ]; then
    echo "SKIP  ${target}/${fuzzer}/t${trial}: no queue dir"
    exit 0
fi
# Resume: trial complete if h24 exists with content (last hourly checkpoint).
if [ -s "${out_dir}/branch_report_h24.txt" ]; then
    echo "DONE  ${target}/${fuzzer}/t${trial}: h24 report exists"
    exit 0
fi

mkdir -p "$out_dir"
start=$(date +%s)
if docker run --rm \
    -v "${corpus}:/corpus:ro" \
    -v "${out_dir}:/cov_out" \
    -v "${ENTRYPOINT}:/run_coverage_branchreport.py:ro" \
    --entrypoint python3 \
    "libafl-${target}-cov" \
    /run_coverage_branchreport.py /corpus /cov_out "$interval" \
    > "${out_dir}/branch_report_replay.log" 2>&1; then
    n=$(ls "${out_dir}"/branch_report_h*.txt 2>/dev/null | wc -l)
    echo "OK    ${target}/${fuzzer}/t${trial}: ${n} reports ($(( $(date +%s) - start ))s)"
else
    echo "FAIL  ${target}/${fuzzer}/t${trial}: see ${out_dir}/branch_report_replay.log"
fi
