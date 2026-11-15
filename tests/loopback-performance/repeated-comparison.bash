#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/common.bash"
NO_DEVICE_TEST="$ROOT_DIR/tests/loopback-performance/no-device-runtime.bash"
PHYSICAL_TEST="$ROOT_DIR/tests/loopback-performance/ni-pci-6024e.bash"
DATA_ROOT="$ROOT_DIR/data/repeated-comparison"

DURATION_SECONDS="${1:-30}"
REPEATS="${2:-3}"
PERIOD_NS="${3:-${RTSYN_PERIOD_NS:-100000}}"
rtsyn_validate_period "$PERIOD_NS" || exit 1
PERIOD_TAG="$(rtsyn_period_tag "$PERIOD_NS")"
RT_PRIORITY="${RTSYN_RT_PRIORITY:-90}"
DEADLINE_TOLERANCE_NS="${RTSYN_DEADLINE_TOLERANCE_NS:-5000}"
RT_CPU="${RTSYN_RT_CPU:-${RTSYN_TEST_CPU:-}}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BATCH_DIR="$DATA_ROOT/${TIMESTAMP}-${PERIOD_TAG}"
MANIFEST="$BATCH_DIR/manifest.tsv"
RTSYN="$ROOT_DIR/bin/rtsyn"

for test_script in "$NO_DEVICE_TEST" "$PHYSICAL_TEST"; do
    if [[ ! -x "$test_script" ]]; then
        printf 'error: test script is missing or not executable: %s\n' "$test_script" >&2
        exit 1
    fi
done
if [[ ! -x "$RTSYN" ]]; then
    printf 'error: missing executable %s; run setup.bash first\n' "$RTSYN" >&2
    exit 1
fi
if ((EUID == 0)); then
    printf '%s\n' 'error: run the comparison as your normal user, not through sudo.' >&2
    exit 1
fi
if [[ ! "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || ((DURATION_SECONDS < 1)); then
    printf '%s\n' 'error: duration must be a positive integer number of seconds.' >&2
    exit 1
fi
if [[ ! "$REPEATS" =~ ^[0-9]+$ ]] || ((REPEATS < 1)); then
    printf '%s\n' 'error: repeats must be a positive integer.' >&2
    exit 1
fi
if [[ ! "$DEADLINE_TOLERANCE_NS" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'error: RTSYN_DEADLINE_TOLERANCE_NS must be a non-negative integer.' >&2
    exit 1
fi
if "$RTSYN" --no-gui health >/dev/null 2>&1; then
    printf '%s\n' 'error: an RTSyn daemon is already running; stop it before starting the batch.' >&2
    exit 1
fi

install_rt_tools() {
    if command -v cyclictest >/dev/null 2>&1 && command -v rtla >/dev/null 2>&1; then
        printf '%s\n' 'cyclictest and rtla are already installed.'
        return
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' 'error: cyclictest and rtla are required; automatic installation supports apt-get.' >&2
        exit 1
    fi
    printf '%s\n' 'Installing Debian packages rt-tests (cyclictest) and rtla...'
    sudo apt-get update
    sudo apt-get install -y rt-tests rtla
    command -v cyclictest >/dev/null 2>&1 || {
        printf '%s\n' 'error: cyclictest is still missing after installing rt-tests.' >&2
        exit 1
    }
    command -v rtla >/dev/null 2>&1 || {
        printf '%s\n' 'error: rtla is still missing after installing rtla.' >&2
        exit 1
    }
}

install_rt_tools
mkdir -p "$BATCH_DIR"
printf 'run\tmode\tduration_s\tperiod_ns\tpriority\tdeadline_tolerance_ns\tcsv\tsha256\n' >"$MANIFEST"
{
    printf 'captured_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'kernel=%s\n' "$(uname -srvm)"
    printf 'cmdline=%s\n' "$(</proc/cmdline)"
    printf 'cyclictest=%s\nrtla=%s\n' "$(command -v cyclictest)" "$(command -v rtla)"
    printf 'duration_seconds=%s\nrepeats_per_mode=%s\nperiod_ns=%s\npriority=%s\ndeadline_tolerance_ns=%s\n' \
        "$DURATION_SECONDS" "$REPEATS" "$PERIOD_NS" "$RT_PRIORITY" "$DEADLINE_TOLERANCE_NS"
    printf 'rt_cpu=%s\n' "${RT_CPU:-unpinned}"
} >"$BATCH_DIR/environment.txt"

# Capture scheduler-side references separately, before the RTSyn A/B runs, so
# these tools do not add load to either comparison configuration. cyclictest's
# -p option configures its measurement thread as SCHED_FIFO at that priority;
# sudo also lets it access /dev/cpu_dma_latency when the device is root-only.
printf '\n=== Independent scheduler references (%ss) ===\n' "$DURATION_SECONDS"
cyclictest_cpu_args=()
if [[ -n "$RT_CPU" ]]; then
    cyclictest_cpu_args=(-a "$RT_CPU")
fi
sudo cyclictest -m -q -N -i "$((PERIOD_NS / 1000))" -p 90 \
    -D "${DURATION_SECONDS}s" "${cyclictest_cpu_args[@]}" \
    >"$BATCH_DIR/cyclictest.log" 2>&1
printf 'cyclictest output: %s\n' "$BATCH_DIR/cyclictest.log"

printf '%s\n' 'Running rtla timerlat hist separately (sudo is used for kernel tracing)...'
rtla_args=(timerlat hist -d "${DURATION_SECONDS}s" -p "$((PERIOD_NS / 1000))" -P f:90)
if [[ -n "$RT_CPU" ]]; then
    rtla_args+=(-c "$RT_CPU")
fi
sudo rtla "${rtla_args[@]}" >"$BATCH_DIR/rtla-timerlat.log" 2>&1
printf 'rtla timerlat log: %s\n' "$BATCH_DIR/rtla-timerlat.log"

run_one() {
    local run_number="$1" mode="$2"
    local csv_path="$BATCH_DIR/run-$(printf '%02d' "$run_number")-$mode.csv"
    local log_path="$BATCH_DIR/run-$(printf '%02d' "$run_number")-$mode.log"
    local script
    case "$mode" in
        no-device) script="$NO_DEVICE_TEST" ;;
        loopback) script="$PHYSICAL_TEST" ;;
    esac

    printf '\n=== Run %02d/%02d: %s (%ss) ===\n' "$run_number" "$((REPEATS * 2))" "$mode" "$DURATION_SECONDS"
    RTSYN_PERIOD_NS="$PERIOD_NS" \
        RTSYN_RT_PRIORITY="$RT_PRIORITY" \
        RTSYN_DEADLINE_TOLERANCE_NS="$DEADLINE_TOLERANCE_NS" \
        RTSYN_RT_CPU="$RT_CPU" \
        RTSYN_CSV_PATH="$csv_path" \
        bash "$script" "$DURATION_SECONDS" "$PERIOD_NS" 2>&1 | tee "$log_path"

    if [[ ! -s "$csv_path" ]]; then
        printf 'error: %s run produced no CSV at %s\n' "$mode" "$csv_path" >&2
        return 1
    fi
    local digest
    digest="$(sha256sum "$csv_path" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$run_number" "$mode" "$DURATION_SECONDS" "$PERIOD_NS" "$RT_PRIORITY" \
        "$DEADLINE_TOLERANCE_NS" "${csv_path#"$ROOT_DIR/"}" "$digest" >>"$MANIFEST"
}

run_number=0
for ((repeat = 1; repeat <= REPEATS; repeat++)); do
    if ((repeat % 2 == 1)); then
        order=(no-device loopback)
    else
        order=(loopback no-device)
    fi
    for mode in "${order[@]}"; do
        run_number=$((run_number + 1))
        run_one "$run_number" "$mode"
    done
done

printf '\nAll %s runs completed.\nManifest: %s\nArtifacts: %s\n' "$run_number" "$MANIFEST" "$BATCH_DIR"
