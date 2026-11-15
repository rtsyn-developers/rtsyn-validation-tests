#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/common.bash"
BIN_DIR="$ROOT_DIR/bin"

RTSYN="$BIN_DIR/rtsyn"
COMEDI_LOOPBACK="$BIN_DIR/comedi-loopback"
HR_MODULE="$BIN_DIR/librthybrid-hindmarsh-rose-1984-neuron-v2.so"
COMEDI_MODULE="$BIN_DIR/librtsyn-comedi.so"

DEVICE="${COMEDI_DEVICE:-/dev/comedi0}"
DURATION_SECONDS="${1:-30}"
PERIOD_NS="${2:-${RTSYN_PERIOD_NS:-100000}}"
rtsyn_validate_period "$PERIOD_NS" || exit 1
PERIOD_TAG="$(rtsyn_period_tag "$PERIOD_NS")"
DATA_DIR="$ROOT_DIR/data/loopback-performance/$PERIOD_TAG"
RT_PRIORITY="${RTSYN_RT_PRIORITY:-90}"
DEADLINE_TOLERANCE_NS="${RTSYN_DEADLINE_TOLERANCE_NS:-5000}"
PREFLIGHT_TOLERANCE_V="${COMEDI_PREFLIGHT_TOLERANCE_V:-0.15}"
OUTPUT_GAIN="${COMEDI_AO0_GAIN:-1.0}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CSV_PATH="${RTSYN_CSV_PATH:-$DATA_DIR/ni-pci-6024e-hindmarsh-rose-$TIMESTAMP-$PERIOD_TAG.csv}"

# Descriptor and port IDs from the two module ABIs.
HR_DESCRIPTOR="rthybrid_hindmarsh_rose_1984_neuron_v2"
HR_VM_MV_PORT=3
COMEDI_DESCRIPTOR="comedi"
COMEDI_AO0_PORT=0
COMEDI_AI0_PORT=10
COMEDI_DEVICE_PATH_PARAM=0
COMEDI_AO0_GAIN_PARAM=1
COMEDI_AI0_GAIN_PARAM=3

require_file() {
    if [[ ! -f "$1" ]]; then
        printf 'error: missing %s; run %s/setup.bash first\n' "$1" "$ROOT_DIR" >&2
        exit 1
    fi
}

for required in "$RTSYN" "$COMEDI_LOOPBACK" "$HR_MODULE" "$COMEDI_MODULE"; do
    require_file "$required"
done

if ! command -v comedi_calibrate >/dev/null 2>&1; then
    printf 'error: comedi_calibrate is required but was not found in PATH\n' >&2
    exit 1
fi

if ((EUID == 0)); then
    printf 'error: do not run this test with sudo or as root.\n' >&2
    printf 'run setup.bash as your normal user; it stages the capability-enabled RTSyn executable automatically.\n' >&2
    exit 1
fi

soft_memlock="$(ulimit -Sl)"
soft_rtprio="$(ulimit -Sr)"
if [[ "$soft_memlock" != "unlimited" ]] \
    || [[ ! "$soft_rtprio" =~ ^[0-9]+$ ]] \
    || ((soft_rtprio < RT_PRIORITY)); then
    printf 'error: this login session does not have the required realtime limits.\n' >&2
    printf '  current soft memlock: %s (required: unlimited)\n' "$soft_memlock" >&2
    printf '  current soft rtprio:  %s (required: at least %s)\n' \
        "$soft_rtprio" "$RT_PRIORITY" >&2
    printf '%s\n' 'Run rtsyn/scripts/configure_realtime_limits.bash, then completely log out' >&2
    printf '%s\n' 'of the graphical desktop and log back in. Opening a terminal is not enough.' >&2
    exit 1
fi

if [[ ! "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || ((DURATION_SECONDS < 1)); then
    printf 'error: duration must be a positive integer number of seconds\n' >&2
    exit 1
fi

resolved_rtsyn="$(readlink -f "$RTSYN")"
mount_options="$(findmnt -n -o OPTIONS -T "$resolved_rtsyn" 2>/dev/null || true)"
if [[ ",$mount_options," == *,nosuid,* ]]; then
    printf 'error: RTSyn capability target %s is on a nosuid filesystem.\n' \
        "$resolved_rtsyn" >&2
    printf 'rerun setup.bash as your normal user to stage it correctly.\n' >&2
    exit 1
fi

mkdir -p "$DATA_DIR"

average_ai0_voltage() {
    awk '
        /^AI sample [0-9]+:/ {
            for (i = 1; i <= NF; ++i) {
                if ($i ~ /^voltage=/) {
                    value = $i
                    sub(/^voltage=/, "", value)
                    sum += value
                    count += 1
                }
            }
        }
        END {
            if (count == 0) exit 1
            printf "%.9f", sum / count
        }
    '
}

check_voltage() {
    local requested="$1"
    local output measured

    output="$($COMEDI_LOOPBACK "$DEVICE" "$requested" 0 0 ground)"
    measured="$(printf '%s\n' "$output" | average_ai0_voltage)"
    printf 'Loopback preflight: commanded %+g V, AI0 measured %+.6f V\n' \
        "$requested" "$measured"

    awk -v requested="$requested" -v measured="$measured" \
        -v tolerance="$PREFLIGHT_TOLERANCE_V" '
        BEGIN {
            error = measured - requested
            if (error < 0) error = -error
            exit(error <= tolerance ? 0 : 1)
        }
    ' || {
        printf 'error: AO0-to-AI0 loopback differs by more than %s V\n' \
            "$PREFLIGHT_TOLERANCE_V" >&2
        printf 'verify CB-68LP wiring: terminal 22 -> 68 and terminal 55 -> 67\n' >&2
        exit 1
    }
}

node_id_from_response() {
    local response="$1"
    local id
    id="$(printf '%s\n' "$response" | sed -n 's/.*"node_id":\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    if [[ -z "$id" || "$id" == "4294967295" ]]; then
        printf 'error: could not obtain runtime node id from: %s\n' "$response" >&2
        exit 1
    fi
    printf '%s' "$id"
}

cleanup() {
    set +e
    "$RTSYN" --no-gui engine pause >/dev/null 2>&1
    "$RTSYN" --no-gui daemon stop >/dev/null 2>&1
    "$COMEDI_LOOPBACK" "$DEVICE" 0 0 0 ground >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

printf 'Applying Comedi calibration to %s...\n' "$DEVICE"
comedi_calibrate -v -f "$DEVICE"

printf '%s\n' 'Checking physical AO0-to-AI0 loopback before starting RTSyn...'
printf '%s\n' 'Required CB-68LP wiring: 22 (AO0) -> 68 (AI0), 55 (AOGND) -> 67 (AIGND).'
check_voltage 0
check_voltage 1
check_voltage 0

# Use a clean daemon so runtime node IDs and connections cannot collide with an
# earlier GUI or CLI session.
"$RTSYN" --no-gui daemon stop >/dev/null 2>&1 || true
if ! "$RTSYN" --no-gui daemon start; then
    printf '%s\n' '--- RTSyn daemon log ---' >&2
    if [[ -r /tmp/rtsyn-daemon.log ]]; then
        tail -100 /tmp/rtsyn-daemon.log >&2
    else
        printf '%s\n' '/tmp/rtsyn-daemon.log is not readable' >&2
    fi
    exit 1
fi
"$RTSYN" --no-gui health

"$RTSYN" --no-gui runtime period "$PERIOD_NS"
"$RTSYN" --no-gui runtime priority "$RT_PRIORITY"
"$RTSYN" --no-gui runtime deadline-tolerance "$DEADLINE_TOLERANCE_NS"

"$RTSYN" --no-gui plugin load "$HR_MODULE"
hr_response="$("$RTSYN" --no-gui plugin add "$HR_DESCRIPTOR")"
printf '%s\n' "$hr_response"
hr_node_id="$(node_id_from_response "$hr_response")"

"$RTSYN" --no-gui device load "$COMEDI_MODULE"
comedi_response="$("$RTSYN" --no-gui device add "$COMEDI_DESCRIPTOR")"
printf '%s\n' "$comedi_response"
comedi_node_id="$(node_id_from_response "$comedi_response")"

# The COMEDI module instance already defaults to /dev/comedi0. Avoid a
# redundant runtime string-param update for that normal configuration; this
# also keeps the loopback test independent of string-param transport. Preserve
# support for an explicitly selected alternate device path.
if [[ "$DEVICE" != "/dev/comedi0" ]]; then
    "$RTSYN" --no-gui param set "$comedi_node_id" "$COMEDI_DEVICE_PATH_PARAM" \
        string "$DEVICE"
fi
# Send vm_mv directly with AO gain 1. This preserves the previous physical
# range (vm_v * 1000) without depending on the COMEDI output-gain parameter.
"$RTSYN" --no-gui param set "$comedi_node_id" "$COMEDI_AO0_GAIN_PARAM" \
    f64 -- "$OUTPUT_GAIN"
# Keep AI0 capture in physical volts; vm_mv × AO gain is the sent voltage.
"$RTSYN" --no-gui param set "$comedi_node_id" "$COMEDI_AI0_GAIN_PARAM" \
    f64 -- 1.0

"$RTSYN" --no-gui connection add 0 \
    "$hr_node_id" "$HR_VM_MV_PORT" \
    "$comedi_node_id" "$COMEDI_AO0_PORT"
# Subscribing to AI0 activates acquisition without feeding a voltage into the
# neuron's synaptic-current input. The neuron remains an independent source.

# Only subscribed values are exported. AI0 is port 10 on the PCI-6024E:
# 2 AO ports + 8 DIO output ports precede the analog input ports.
"$RTSYN" --no-gui subscribe ports "$hr_node_id" on 0x8
"$RTSYN" --no-gui subscribe ports "$comedi_node_id" on 0x401
"$RTSYN" --no-gui telemetry csv "$CSV_PATH" \
    hindmarsh_rose_vm_mv:3 comedi_ao0_input:0 comedi_ai0_v:10 \
    --measurement-fields period_ns,actual_period_ns,latency_ns,wake_lateness_ns,skipped_cycle_count,deadline_missed,devices_read_ns,plugins_time_ns,devices_write_ns,telemetry_dropped_events

"$RTSYN" --no-gui device start "$comedi_node_id"
"$RTSYN" --no-gui plugin start "$hr_node_id"
"$RTSYN" --no-gui engine resume

printf 'Sending the Hindmarsh-Rose waveform to AO0 for %s seconds...\n' \
    "$DURATION_SECONDS"
printf 'Signal: vm_mv -> AO0 (gain %s); AI0 capture in physical volts (gain 1).\n' "$OUTPUT_GAIN"
printf 'Deadline tolerance: %s ns\n' "$DEADLINE_TOLERANCE_NS"
printf 'Recording source voltage, AO0 input command, and looped-back AI0 in %s\n' "$CSV_PATH"
sleep "$DURATION_SECONDS"

"$RTSYN" --no-gui engine pause
"$RTSYN" --no-gui measurements
"$RTSYN" --no-gui plugin stop "$hr_node_id"
"$RTSYN" --no-gui device stop "$comedi_node_id"
"$RTSYN" --no-gui daemon stop

# The daemon no longer owns the device, so explicitly leave AO0 at zero volts.
"$COMEDI_LOOPBACK" "$DEVICE" 0 0 0 ground >/dev/null
trap - EXIT INT TERM

python3 "$ROOT_DIR/tests/synapse-performance/check_synapse.py" capture "$CSV_PATH" \
    --gain "$OUTPUT_GAIN" --conductance 1 \
    --period-ns "$PERIOD_NS" \
    --tolerance-v "${COMEDI_TRACKING_TOLERANCE_V:-0.1}"

printf 'Validation complete: %s\n' "$CSV_PATH"
