#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/common.bash"
BIN_DIR="$ROOT_DIR/bin"

RTSYN="$BIN_DIR/rtsyn"
HR_MODULE="$BIN_DIR/librthybrid-hindmarsh-rose-1984-neuron-v2.so"
DURATION_SECONDS="${1:-30}"
PERIOD_NS="${2:-${RTSYN_PERIOD_NS:-100000}}"
rtsyn_validate_period "$PERIOD_NS" || exit 1
PERIOD_TAG="$(rtsyn_period_tag "$PERIOD_NS")"
DATA_DIR="$ROOT_DIR/data/runtime-baseline/$PERIOD_TAG"
RT_PRIORITY="${RTSYN_RT_PRIORITY:-90}"
DEADLINE_TOLERANCE_NS="${RTSYN_DEADLINE_TOLERANCE_NS:-5000}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CSV_PATH="${RTSYN_CSV_PATH:-$DATA_DIR/no-device-$TIMESTAMP-$PERIOD_TAG.csv}"

HR_DESCRIPTOR="rthybrid_hindmarsh_rose_1984_neuron_v2"
HR_VM_V_PORT=2

require_file() {
    if [[ ! -f "$1" ]]; then
        printf 'error: missing %s; run %s/setup.bash first\n' "$1" "$ROOT_DIR" >&2
        exit 1
    fi
}

require_file "$RTSYN"
require_file "$HR_MODULE"

if ((EUID == 0)); then
    printf '%s\n' 'error: run this test as your normal user, not through sudo.' >&2
    exit 1
fi

soft_memlock="$(ulimit -Sl)"
soft_rtprio="$(ulimit -Sr)"
if [[ "$soft_memlock" != "unlimited" ]] \
    || [[ ! "$soft_rtprio" =~ ^[0-9]+$ ]] \
    || ((soft_rtprio < RT_PRIORITY)); then
    printf 'error: realtime limits are insufficient (memlock=%s, rtprio=%s; need unlimited and >= %s)\n' \
        "$soft_memlock" "$soft_rtprio" "$RT_PRIORITY" >&2
    exit 1
fi

if [[ ! "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || ((DURATION_SECONDS < 1)); then
    printf 'error: duration must be a positive integer number of seconds\n' >&2
    exit 1
fi

resolved_rtsyn="$(readlink -f "$RTSYN")"
mount_options="$(findmnt -n -o OPTIONS -T "$resolved_rtsyn" 2>/dev/null || true)"
if [[ ",$mount_options," == *,nosuid,* ]]; then
    printf 'error: RTSyn capability target %s is on a nosuid filesystem\n' "$resolved_rtsyn" >&2
    exit 1
fi

if "$RTSYN" --no-gui health >/dev/null 2>&1; then
    printf '%s\n' 'error: an RTSyn daemon is already running; stop it explicitly before the isolated baseline.' >&2
    exit 1
fi

mkdir -p "$(dirname "$CSV_PATH")"

cleanup() {
    set +e
    "$RTSYN" --no-gui engine pause >/dev/null 2>&1
    if [[ -n "${HR_NODE_ID:-}" ]]; then
        "$RTSYN" --no-gui plugin stop "$HR_NODE_ID" >/dev/null 2>&1
    fi
    "$RTSYN" --no-gui daemon stop >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

printf 'Starting no-device RTSyn timing baseline: duration=%ss period=%sns priority=%s\n' \
    "$DURATION_SECONDS" "$PERIOD_NS" "$RT_PRIORITY"
printf 'No Comedi module is loaded; output CSV: %s\n' "$CSV_PATH"
printf 'Deadline tolerance: %s ns\n' "$DEADLINE_TOLERANCE_NS"

"$RTSYN" --no-gui daemon start
"$RTSYN" --no-gui health
"$RTSYN" --no-gui runtime period "$PERIOD_NS"
"$RTSYN" --no-gui runtime priority "$RT_PRIORITY"
"$RTSYN" --no-gui runtime deadline-tolerance "$DEADLINE_TOLERANCE_NS"

"$RTSYN" --no-gui plugin load "$HR_MODULE"
hr_response="$("$RTSYN" --no-gui plugin add "$HR_DESCRIPTOR")"
printf '%s\n' "$hr_response"
HR_NODE_ID="$(printf '%s\n' "$hr_response" \
    | sed -n 's/.*"node_id":\([0-9][0-9]*\).*/\1/p' | head -n 1)"
if [[ -z "$HR_NODE_ID" || "$HR_NODE_ID" == "4294967295" ]]; then
    printf 'error: could not obtain runtime node id from: %s\n' "$hr_response" >&2
    exit 1
fi

"$RTSYN" --no-gui subscribe ports "$HR_NODE_ID" on 0x4
"$RTSYN" --no-gui telemetry csv "$CSV_PATH" hindmarsh_rose_vm_v:"$HR_VM_V_PORT" \
    --measurement-fields period_ns,actual_period_ns,latency_ns,wake_lateness_ns,skipped_cycle_count,deadline_missed,devices_read_ns,plugins_time_ns,devices_write_ns

"$RTSYN" --no-gui plugin start "$HR_NODE_ID"
"$RTSYN" --no-gui engine resume
sleep "$DURATION_SECONDS"
"$RTSYN" --no-gui engine pause
"$RTSYN" --no-gui measurements
"$RTSYN" --no-gui plugin stop "$HR_NODE_ID"
"$RTSYN" --no-gui daemon stop
trap - EXIT INT TERM

printf 'No-device baseline complete: %s\n' "$CSV_PATH"
