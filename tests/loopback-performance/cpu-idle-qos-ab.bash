#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/common.bash"
NO_DEVICE_TEST="$ROOT_DIR/tests/loopback-performance/no-device-runtime.bash"
DATA_ROOT="$ROOT_DIR/data/cpu-idle-qos-ab"
DURATION_SECONDS="${1:-30}"
REPEATS="${2:-3}"
PERIOD_NS="${3:-${RTSYN_PERIOD_NS:-100000}}"
rtsyn_validate_period "$PERIOD_NS" || exit 1
PERIOD_TAG="$(rtsyn_period_tag "$PERIOD_NS")"
RT_PRIORITY="${RTSYN_RT_PRIORITY:-90}"
DEADLINE_TOLERANCE_NS="${RTSYN_DEADLINE_TOLERANCE_NS:-5000}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BATCH_DIR="$DATA_ROOT/${TIMESTAMP}-${PERIOD_TAG}"

if ((EUID == 0)); then
    printf '%s\n' 'error: run this test as your normal user; sudo is used only to hold the PM QoS request.' >&2
    exit 1
fi
if [[ ! -x "$NO_DEVICE_TEST" ]]; then
    printf 'error: missing executable test script: %s\n' "$NO_DEVICE_TEST" >&2
    exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
    printf '%s\n' 'error: this runner requires sudo.' >&2
    exit 1
fi
if [[ ! -e /dev/cpu_dma_latency ]]; then
    printf '%s\n' 'error: /dev/cpu_dma_latency is unavailable; cannot request or compare CPU idle-latency QoS.' >&2
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
if [[ ! "$RT_PRIORITY" =~ ^[0-9]+$ ]] || ((RT_PRIORITY < 1 || RT_PRIORITY > 99)); then
    printf '%s\n' 'error: RTSYN_RT_PRIORITY must be an integer from 1 through 99.' >&2
    exit 1
fi
if [[ ! "$DEADLINE_TOLERANCE_NS" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'error: RTSYN_DEADLINE_TOLERANCE_NS must be a non-negative integer.' >&2
    exit 1
fi

RTSYN="$ROOT_DIR/bin/rtsyn"
if [[ ! -x "$RTSYN" ]]; then
    printf 'error: missing executable %s; run setup.bash first.\n' "$RTSYN" >&2
    exit 1
fi
if "$RTSYN" --no-gui health >/dev/null 2>&1; then
    printf '%s\n' 'error: stop the existing RTSyn daemon before starting this isolated test.' >&2
    exit 1
fi

mkdir -p "$BATCH_DIR"
printf 'profile\trepeat\tduration_s\tperiod_ns\tpriority\tdeadline_tolerance_ns\tcsv\tsha256\n' \
    >"$BATCH_DIR/manifest.tsv"
{
    printf 'captured_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'kernel=%s\n' "$(uname -srvm)"
    printf 'cmdline=%s\n' "$(</proc/cmdline)"
    printf 'duration_seconds=%s\nrepeats=%s\nperiod_ns=%s\npriority=%s\ndeadline_tolerance_ns=%s\n' \
        "$DURATION_SECONDS" "$REPEATS" "$PERIOD_NS" "$RT_PRIORITY" "$DEADLINE_TOLERANCE_NS"
    printf 'qos_device=%s\nqos_constraint_us=0\n' /dev/cpu_dma_latency
    printf 'rtsyn_cpu_affinity=not_configured_by_current_engine\n'
} >"$BATCH_DIR/environment.txt"
{
    printf 'governor=%s\n' "$(cat /sys/devices/system/cpu/cpuidle/current_governor 2>/dev/null || printf unknown)"
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [[ -d "$cpu_dir/cpuidle" ]] || continue
        cpu="${cpu_dir##*cpu}"
        for state_dir in "$cpu_dir"/cpuidle/state[0-9]*; do
            [[ -d "$state_dir" ]] || continue
            printf 'cpu=%s state=%s name=%s latency_us=%s disabled=%s\n' \
                "$cpu" "${state_dir##*state}" \
                "$(cat "$state_dir/name" 2>/dev/null || printf unknown)" \
                "$(cat "$state_dir/latency" 2>/dev/null || printf unknown)" \
                "$(cat "$state_dir/disable" 2>/dev/null || printf unknown)"
        done
    done
} >"$BATCH_DIR/cpuidle-states.txt"

printf '# sampled_at_unix_ns\tPID\tTID\tCLASS\tRTPRIO\tPSR\tCOMM\tARGS\n' \
    >"$BATCH_DIR/scheduler-samples.tsv"

sample_scheduler() {
    local sample_time
    sample_time="$(date +%s%N)"
    ps -eLo pid,tid,cls,rtprio,psr,comm,args --no-headers \
        | awk -v t="$sample_time" '($6 ~ /rtsyn/ || $7 ~ /rtsyn/) { printf "%s\t%s\n", t, $0 }' \
        >>"$BATCH_DIR/scheduler-samples.tsv"
}

QOS_REQUEST_PID=""

release_qos_request() {
    if [[ -n "$QOS_REQUEST_PID" ]]; then
        printf 'release\n' >&"${QOS_HOLDER[1]}" 2>/dev/null || true
        wait "$QOS_REQUEST_PID" 2>/dev/null || true
        QOS_REQUEST_PID=""
        unset QOS_HOLDER
    fi
}

trap release_qos_request EXIT

start_qos_request() {
    sudo -v
    coproc QOS_HOLDER {
        sudo -n bash -c '
            set -euo pipefail
            exec 9>/dev/cpu_dma_latency
            printf "\\0\\0\\0\\0" >&9
            printf "ready\\n"
            IFS= read -r _ || true
        '
    }
    QOS_REQUEST_PID="$QOS_HOLDER_PID"
    local ready
    if ! IFS= read -r -t 10 ready <&"${QOS_HOLDER[0]}" || [[ "$ready" != "ready" ]]; then
        release_qos_request
        printf '%s\n' 'error: could not establish the 0 us PM QoS request.' >&2
        return 1
    fi
}

run_one() {
    local profile="$1" repeat="$2"
    local stem="$(printf 'run-%02d-%s' "$repeat" "$profile")"
    local csv_path="$BATCH_DIR/$stem.csv"
    local log_path="$BATCH_DIR/$stem.log"
    local pid

    printf '\n=== %s repeat %02d/%02d (%ss) ===\n' \
        "$profile" "$repeat" "$REPEATS" "$DURATION_SECONDS"
    if [[ "$profile" == "qos0" ]]; then
        start_qos_request
    fi
    env RTSYN_PERIOD_NS="$PERIOD_NS" \
        RTSYN_RT_PRIORITY="$RT_PRIORITY" \
        RTSYN_DEADLINE_TOLERANCE_NS="$DEADLINE_TOLERANCE_NS" \
        RTSYN_CSV_PATH="$csv_path" \
        bash "$NO_DEVICE_TEST" "$DURATION_SECONDS" "$PERIOD_NS" >"$log_path" 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sample_scheduler
        sleep 1
    done
    wait "$pid"
    if [[ "$profile" == "qos0" ]]; then
        release_qos_request
    fi

    if [[ ! -s "$csv_path" ]]; then
        printf 'error: %s run produced no CSV at %s\n' "$profile" "$csv_path" >&2
        tail -n 40 "$log_path" >&2 || true
        return 1
    fi
    local digest
    digest="$(sha256sum "$csv_path" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$profile" "$repeat" "$DURATION_SECONDS" "$PERIOD_NS" "$RT_PRIORITY" \
        "$DEADLINE_TOLERANCE_NS" "${csv_path#"$ROOT_DIR/"}" "$digest" \
        >>"$BATCH_DIR/manifest.tsv"
    printf 'CSV: %s\nLog: %s\n' "$csv_path" "$log_path"
}

printf 'Artifacts: %s\n' "$BATCH_DIR"
printf '%s\n' 'This test changes no persistent setting. The qos0 request is held only for that run and released when its launcher exits.'
printf '%s\n' 'RTSyn engine affinity is not set by this runner; scheduler-samples.tsv records observed CPUs and RT scheduling fields.'

for ((repeat = 1; repeat <= REPEATS; repeat++)); do
    if ((repeat % 2 == 1)); then
        run_one no-qos "$repeat"
        run_one qos0 "$repeat"
    else
        run_one qos0 "$repeat"
        run_one no-qos "$repeat"
    fi
done

printf '\nAll %s no-QoS/QoS pairs completed.\nManifest: %s\nArtifacts: %s\n' \
    "$REPEATS" "$BATCH_DIR/manifest.tsv" "$BATCH_DIR"
