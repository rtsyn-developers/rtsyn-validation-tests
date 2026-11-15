#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$ROOT_DIR/tests/loopback-performance"
SYNAPSE_TEST="$ROOT_DIR/tests/synapse-performance/monodirectional-electrical-synapse.bash"
PLOT_DIR="$ROOT_DIR/plot-tests"
DURATION_SECONDS="${1:-60}"
REPEATS="${2:-3}"
PERIOD_NS=100000
START_EPOCH="$(date +%s)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_LOG_DIR="$ROOT_DIR/data/run-logs"
FAILED_TESTS=()
DISABLE_DEFAULT_QOS=0

mkdir -p "$RUN_LOG_DIR"

usage() {
    printf 'Usage: %s [duration_seconds [repeat_pairs]]\n' "${0##*/}"
    printf 'Defaults: duration_seconds=60, repeat_pairs=3; period is fixed at 100000 ns (100 us)\n'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ((EUID == 0)); then
    printf '%s\n' 'error: run this orchestrator as your normal user, not through sudo.' >&2
    exit 1
fi

if [[ ! "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || ((DURATION_SECONDS < 1)); then
    printf '%s\n' 'error: duration_seconds must be a positive integer.' >&2
    usage >&2
    exit 2
fi

if [[ ! "$REPEATS" =~ ^[0-9]+$ ]] || ((REPEATS < 1)); then
    printf '%s\n' 'error: repeat_pairs must be a positive integer.' >&2
    usage >&2
    exit 2
fi
if [[ -n "${3:-}" && "$3" != "$PERIOD_NS" ]]; then
    printf 'error: the validation period is fixed at %s ns (100 us).\n' "$PERIOD_NS" >&2
    exit 2
fi
if [[ -n "${RTSYN_PERIOD_NS:-}" && "$RTSYN_PERIOD_NS" != "$PERIOD_NS" ]]; then
    printf 'error: RTSYN_PERIOD_NS must be unset or %s for validation.\n' "$PERIOD_NS" >&2
    exit 2
fi

for required in \
    "$TEST_DIR/ni-pci-6024e.bash" \
    "$TEST_DIR/no-device-runtime.bash" \
    "$TEST_DIR/repeated-comparison.bash" \
    "$TEST_DIR/cpu-idle-qos-ab.bash" \
    "$SYNAPSE_TEST"; do
    if [[ ! -f "$required" ]]; then
        printf 'error: missing test runner: %s\n' "$required" >&2
        exit 1
    fi
done

if ! command -v uv >/dev/null 2>&1; then
    printf '%s\n' 'error: uv is required to generate plots; install uv and run setup in plot-tests/.' >&2
    exit 1
fi

run_test() {
    local label="$1"
    local slug log_path
    shift
    slug="${label,,}"
    slug="${slug// /-}"
    slug="${slug//[^a-z0-9-]/}"
    log_path="$RUN_LOG_DIR/${RUN_ID}-${slug}.log"
    printf '\n========== %s ==========\n' "$label"
    printf 'Step log: %s\n' "$log_path"
    "$@" 2>&1 | tee "$log_path"
    local -a command_status=("${PIPESTATUS[@]}")
    if ((command_status[0] == 0 && command_status[1] == 0)); then
        printf 'Completed: %s\n' "$label"
    else
        local status="${command_status[0]}"
        if ((status == 0)); then
            status="${command_status[1]}"
        fi
        printf 'FAILED (%s): %s\n' "$status" "$label" >&2
        FAILED_TESTS+=("$label (exit $status)")
    fi
}

printf 'Running RTSyn validation suites: %ss per individual run, %s repeat pairs, period=%sns.\n' \
    "$DURATION_SECONDS" "$REPEATS" "$PERIOD_NS"
printf '%s\n' 'Each suite keeps its own logs, manifest, and CSVs under data/.'
printf 'Per-step console logs: %s\n' "$RUN_LOG_DIR/$RUN_ID-*.log"

if [[ ! -w /dev/cpu_dma_latency ]]; then
    printf '%s\n' \
        'Warning: /dev/cpu_dma_latency is not writable by this user.' \
        'Ordinary baselines will explicitly set RTSYN_CPU_DMA_LATENCY_US=off so they can run.' \
        'The separate QoS A/B test still requests QoS0 through its sudo helper.' \
        'This run will not validate RTSyn default-on QoS; grant device access to test that behavior.' >&2
    DISABLE_DEFAULT_QOS=1
fi

run_baseline() {
    if ((DISABLE_DEFAULT_QOS)); then
        RTSYN_CPU_DMA_LATENCY_US=off "$@"
    else
        "$@"
    fi
}

# Individual captures complement the paired comparison artifacts.
run_test 'NI PCI-6024E physical AO0-to-AI0 loopback' \
    run_baseline bash "$TEST_DIR/ni-pci-6024e.bash" "$DURATION_SECONDS" "$PERIOD_NS"
run_test 'No-device RTSyn runtime baseline' \
    run_baseline bash "$TEST_DIR/no-device-runtime.bash" "$DURATION_SECONDS" "$PERIOD_NS"

# This suite includes both no-device and physical-loopback captures plus
# separate cyclictest/rtla reference runs.
run_test 'Repeated no-device / physical-loopback comparison' \
    run_baseline bash "$TEST_DIR/repeated-comparison.bash" "$DURATION_SECONDS" "$REPEATS" "$PERIOD_NS"

# The backend's default is QoS 0. Explicitly disable its own request in both
# A/B profiles; qos0 is supplied by the runner's separate held-open request.
run_test 'CPU idle-latency QoS A/B comparison' \
    env RTSYN_CPU_DMA_LATENCY_US=off \
    bash "$TEST_DIR/cpu-idle-qos-ab.bash" "$DURATION_SECONDS" "$REPEATS" "$PERIOD_NS"

run_test 'Monodirectional electrical synapse: excitatory and inhibitory' \
    run_baseline bash "$SYNAPSE_TEST" "$DURATION_SECONDS" "$PERIOD_NS"

printf '\n========== Plot captures from this invocation ==========\n'
mapfile -d '' -t CSV_FILES < <(
    find "$ROOT_DIR/data" -type f -name '*.csv' -newermt "@$START_EPOCH" -print0 2>/dev/null
)

if ((${#CSV_FILES[@]} == 0)); then
    printf '%s\n' 'No new CSV files were produced; there is nothing to plot.' >&2
    FAILED_TESTS+=("plotting (no new CSV captures)")
else
    PLOT_FAILURES=0
    for csv_path in "${CSV_FILES[@]}"; do
        printf '\nPlotting: %s\n' "${csv_path#"$ROOT_DIR/"}"
        if (cd "$PLOT_DIR" && uv run plot-tests generate "$csv_path"); then
            :
        else
            status=$?
            printf 'Plot generation failed (%s): %s\n' "$status" "$csv_path" >&2
            ((PLOT_FAILURES += 1))
        fi
    done
    if ((PLOT_FAILURES > 0)); then
        FAILED_TESTS+=("plotting ($PLOT_FAILURES CSV file(s) failed)")
    fi
fi

printf '\nArtifacts and plots are under: %s/data/\n' "$ROOT_DIR"
if ((${#FAILED_TESTS[@]} > 0)); then
    printf '\nSome steps failed:\n' >&2
    printf '  - %s\n' "${FAILED_TESTS[@]}" >&2
    exit 1
fi

printf '%s\n' 'All measurement suites completed and their new CSV captures were plotted.'
