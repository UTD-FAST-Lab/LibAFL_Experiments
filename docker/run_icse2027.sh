#!/usr/bin/env bash
# run_icse2027.sh — ICSE 2027 fuzzing campaign launcher.
#
# 10 fuzzers × 8 targets × 10 trials × 24 h, 60-way parallel, priority
# queue by target order so target N's queue drains first.
#
# Phase 1: build any missing per-(fuzzer × target) images (parallel, BUILD_PAR
#          at a time). Pre-existing images are skipped.
# Phase 2: run 800 fuzzing trials. Slot freed → next pending job in
#          (target, fuzzer, trial) priority order is scheduled.
#
# Output: /20TB/miao/icse2027/<target>/<fuzzer>/trial<N>/
# Logs:   /20TB/miao/icse2027/_logs/
#
# Run inside tmux:
#   tmux new -s icse2027
#   ./docker/run_icse2027.sh
#
# Resume after interruption: just re-run. Existing images are skipped, and
# trials whose corpus directory already contains output are skipped.

set -euo pipefail

# ── configuration ───────────────────────────────────────────────────────────
FUZZERS=(naive naive_ctx naive_ngram4 fast minimizer mopt grimoire cmplog value_profile value_profile_cmplog)
TARGETS=(lcms libpng libxml2 bloaty sqlite3 harfbuzz curl openthread)
TRIALS=10
DURATION=86400                          # 24h per trial
PARALLEL=60                             # concurrent containers
BUILD_PAR=6                             # concurrent docker builds
CPU_BASE=4                              # use cores CPU_BASE..CPU_BASE+PARALLEL-1
MEM_PER_JOB=4g

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_DIR=/20TB/miao/icse2027
LOG_DIR="${RESULTS_DIR}/_logs"
# Seeds are baked into each image's /seeds at build time — no host mount.

mkdir -p "$LOG_DIR"

ORCH_LOG="${LOG_DIR}/orchestrator.log"
exec > >(tee -a "$ORCH_LOG") 2>&1

LOG()  { printf '[%(%F %T)T] %s\n' -1 "$*"; }
LOGE() { printf '[%(%F %T)T] [ERR] %s\n' -1 "$*" >&2; }

LOG "==== ICSE 2027 campaign start ===="
LOG "fuzzers: ${FUZZERS[*]}"
LOG "targets: ${TARGETS[*]}"
LOG "trials=${TRIALS} duration=${DURATION}s parallel=${PARALLEL} cpu_base=${CPU_BASE}"
LOG "results dir: ${RESULTS_DIR}"

cd "$REPO_ROOT"

# ── phase 1: ensure libafl-base ─────────────────────────────────────────────
if docker image inspect libafl-base >/dev/null 2>&1; then
    LOG "libafl-base: already built, skipping"
else
    LOG "building libafl-base"
    docker build -f docker/Dockerfile.base -t libafl-base . \
        >"${LOG_DIR}/build-base.log" 2>&1 || { LOGE "base build FAILED — see ${LOG_DIR}/build-base.log"; exit 1; }
fi

# ── phase 1: build 80 target images (skip already-built) ────────────────────
build_one() {
    local target="$1" fuzzer="$2"
    local image="libafl-${target}-${fuzzer}"
    local log="${LOG_DIR}/build-${target}-${fuzzer}.log"
    if docker image inspect "$image" >/dev/null 2>&1; then
        LOG "skip build ${image} (cached)"
        return 0
    fi
    LOG "build ${image}"
    if docker build \
            --build-arg FUZZER="$fuzzer" \
            -f "docker/targets/Dockerfile.${target}" \
            -t "$image" . >"$log" 2>&1; then
        LOG "ok    ${image}"
    else
        LOGE "FAIL  ${image} (see ${log})"
        return 1
    fi
}
export -f build_one LOG LOGE
export LOG_DIR

LOG "Phase 1: building per-(target,fuzzer) images (parallel=${BUILD_PAR})"
build_queue="${LOG_DIR}/build_queue.tsv"
: > "$build_queue"
for target in "${TARGETS[@]}"; do
    for fuzzer in "${FUZZERS[@]}"; do
        printf '%s\t%s\n' "$target" "$fuzzer" >> "$build_queue"
    done
done

# GNU parallel for the build phase
if ! parallel --colsep '\t' -j "$BUILD_PAR" --joblog "${LOG_DIR}/build_joblog.tsv" \
        build_one {1} {2} :::: "$build_queue"; then
    LOG "Some builds failed. See ${LOG_DIR}/build-*.log. Trials for failed images will be skipped automatically."
fi

LOG "Phase 1 complete."

# ── phase 2: run trials ─────────────────────────────────────────────────────
LOG "Phase 2: running trials"

run_one() {
    # args: target fuzzer trial slot
    local target="$1" fuzzer="$2" trial="$3" slot="$4"
    local image="libafl-${target}-${fuzzer}"
    local name="icse2027-${target}-${fuzzer}-t${trial}"
    local corpus="${RESULTS_DIR}/${target}/${fuzzer}/trial${trial}"
    local cpu=$((CPU_BASE + slot - 1))
    local rlog="${LOG_DIR}/${target}-${fuzzer}-t${trial}.log"

    if ! docker image inspect "$image" >/dev/null 2>&1; then
        LOGE "skip-no-image ${name}"
        return 0
    fi

    # Resume-friendly: skip if corpus already has content (prior run completed).
    if [[ -d "$corpus" ]] && [[ -n "$(ls -A "$corpus" 2>/dev/null)" ]]; then
        LOG "skip-done    ${name} (corpus non-empty)"
        return 0
    fi
    mkdir -p "$corpus"

    docker rm -f "$name" >/dev/null 2>&1 || true

    LOG "START ${name} slot=${slot} cpu=${cpu}"
    docker run --rm \
        --name "$name" \
        --cpuset-cpus "$cpu" \
        --memory "$MEM_PER_JOB" \
        -v "${corpus}:/corpus" \
        -e DURATION="$DURATION" \
        "$image" >"$rlog" 2>&1
    local rc=$?
    if (( rc == 0 )); then
        LOG "DONE  ${name} rc=0"
    else
        LOGE "FAIL  ${name} rc=${rc} (see ${rlog})"
    fi
    return 0
}
export -f run_one
export RESULTS_DIR LOG_DIR DURATION MEM_PER_JOB CPU_BASE

# Build job queue in priority order: target → fuzzer → trial
job_queue="${LOG_DIR}/job_queue.tsv"
: > "$job_queue"
for target in "${TARGETS[@]}"; do
    for fuzzer in "${FUZZERS[@]}"; do
        for trial in $(seq 1 "$TRIALS"); do
            printf '%s\t%s\t%s\n' "$target" "$fuzzer" "$trial" >> "$job_queue"
        done
    done
done
total_jobs=$(wc -l < "$job_queue")
LOG "queued ${total_jobs} trials"

# Priority-queue execution:
#   --keep-order with -j PARALLEL processes the file top-to-bottom, but slots
#   that finish early move on to the next pending line. {%} = slot number 1..N
#   which we map to CPU_BASE..CPU_BASE+PARALLEL-1.
# GNU parallel dispatches input lines top-to-bottom by default; --resume-failed
# + joblog lets us re-run the script after interruption and skip work that
# already completed successfully.
parallel --colsep '\t' -j "$PARALLEL" \
    --joblog "${LOG_DIR}/run_joblog.tsv" \
    --resume-failed \
    run_one {1} {2} {3} '{%}' :::: "$job_queue" \
    || LOG "parallel exited non-zero — check ${LOG_DIR}/run_joblog.tsv"

LOG "==== ICSE 2027 campaign complete ===="
