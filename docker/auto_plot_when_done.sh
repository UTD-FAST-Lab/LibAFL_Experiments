#!/usr/bin/env bash
# Waits for the coverage-timeseries batch (gen_coverage_ts.sh) to finish, then
# generates all grouped coverage plots. Fully detached: survives session
# disconnect. Progress/results in cov-autoplot.log; writes a DONE/FAILED marker.
set -uo pipefail

REPO=/home/miao/LibAFL_Experiments
CTS=/20TB/miao/icse2027/coverage_ts
LOG=/20TB/miao/icse2027/_logs/cov-autoplot.log
MARK=/20TB/miao/icse2027/_logs/cov-autoplot.status

echo "[$(date)] watcher started; waiting for batch to finish..." > "$LOG"

# 1. Wait until the batch driver process is gone.
while pgrep -f 'docker/gen_coverage_ts' >/dev/null 2>&1; do
    sleep 30
done
echo "[$(date)] driver gone." >> "$LOG"

# 2. Wait for any straggler cov containers to drain.
while [ "$(docker ps --format '{{.Image}}' | grep -cE 'libafl-(bloaty|lcms|libpng|libxml2)-cov')" -gt 0 ]; do
    sleep 15
done

done=$(find "$CTS" -name coverage_timeseries.csv 2>/dev/null | wc -l)
echo "[$(date)] all containers drained. CSVs present: $done/400" >> "$LOG"

# 3. Generate all grouped plots (12 per-target + 3 grids).
echo "[$(date)] generating plots..." >> "$LOG"
if python3 "$REPO/docker/plot_coverage_all.py" \
        --targets bloaty lcms libpng libxml2 \
        --results-dir "$CTS" \
        --out-dir /20TB/miao/icse2027/coverage_plots \
        --shade >> "$LOG" 2>&1; then
    echo "DONE $done/400 $(date)" > "$MARK"
    echo "[$(date)] plots generated OK." >> "$LOG"
else
    echo "FAILED $done/400 $(date)" > "$MARK"
    echo "[$(date)] PLOTTING FAILED — see log." >> "$LOG"
fi
