#!/usr/bin/env bash

# Validate a one-way electrical synapse whose computed current is transported
# through the NI AO0 -> AI0 physical loopback before reaching the post neuron.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/tests/loopback-performance/common.bash"
BIN_DIR="$ROOT_DIR/bin"
RTSYN="$BIN_DIR/rtsyn"
COMEDI_LOOPBACK="$BIN_DIR/comedi-loopback"

DEVICE="${COMEDI_DEVICE:-/dev/comedi0}"
DURATION_SECONDS="${1:-30}"
PERIOD_NS="${2:-${RTSYN_PERIOD_NS:-100000}}"
MODE="${3:-both}"
rtsyn_validate_period "$PERIOD_NS" || exit 1
case "$MODE" in excitatory|inhibitory|control|both) ;; *) echo 'error: mode must be excitatory, inhibitory, control, or both' >&2; exit 1 ;; esac
[[ "$DURATION_SECONDS" =~ ^[0-9]+$ ]] && ((DURATION_SECONDS > 0)) || { echo 'error: duration must be positive' >&2; exit 1; }

RT_PRIORITY="${RTSYN_RT_PRIORITY:-90}"
DEADLINE_TOLERANCE_NS="${RTSYN_DEADLINE_TOLERANCE_NS:-5000}"
PREFLIGHT_TOLERANCE_V="${COMEDI_PREFLIGHT_TOLERANCE_V:-0.15}"
# The previous 1000 V/nA setting paired with 0.001 uS limited the current
# delivered to the neuron to a few pA. Use 0.1 uS with 10 V/nA instead: the
# AO waveform remains at a similar voltage (g*gain is unchanged), while the
# postsynaptic model receives 100x more current. AI0 uses reciprocal gain so
# the measured current is still in nA. This is a numerical loopback mapping,
# not a biological amplifier calibration.
CURRENT_TO_AO_GAIN="${COMEDI_CURRENT_TO_AO_GAIN:-10.0}"
WARMUP_SECONDS="${SYNAPSE_WARMUP_SECONDS:-6}"
TRACKING_TOLERANCE_V="${COMEDI_TRACKING_TOLERANCE_V:-0.1}"
CHECKER="$ROOT_DIR/tests/synapse-performance/check_synapse.py"
command -v python3 >/dev/null || { echo 'error: python3 required' >&2; exit 1; }
INPUT_GAIN="$(python3 - "$CURRENT_TO_AO_GAIN" "$WARMUP_SECONDS" "$TRACKING_TOLERANCE_V" <<'PYCONFIG'
import math, sys
gain, warmup, tolerance = map(float, sys.argv[1:])
if not all(map(math.isfinite, (gain,warmup,tolerance))) or gain <= 0 or warmup < 6 or tolerance <= 0:
    raise SystemExit('error: gain/tolerance must be positive and warm-up at least 6 seconds')
print(format(1/gain, '.17g'))
PYCONFIG
)"
EXCITATORY_G_US="${EXCITATORY_G_US:-0.1}"
INHIBITORY_G_US="${INHIBITORY_G_US:--0.1}"
PRE_E="${SYNAPSE_PRE_E:-3.2}"
POST_E="${SYNAPSE_POST_E:-2.8}"
python3 - "$EXCITATORY_G_US" "$INHIBITORY_G_US" "$PRE_E" "$POST_E" <<'PYCONFIG'
import math, sys
positive, negative, pre, post = map(float, sys.argv[1:])
if not all(map(math.isfinite, (positive,negative,pre,post))) or positive <= 0 or negative >= 0:
    raise SystemExit('error: use finite neuron parameters, positive excitatory g and negative inhibitory g')
PYCONFIG
PERIOD_TAG="$(rtsyn_period_tag "$PERIOD_NS")"
DATA_DIR="$ROOT_DIR/data/synapse-performance/$PERIOD_TAG"
mkdir -p "$DATA_DIR"

declare -A MODULE=(
    [hr]="$BIN_DIR/librthybrid-hindmarsh-rose-1984-neuron-v2.so"
    [synapse]="$BIN_DIR/librthybrid-electrical-synapse.so"
    [burst]="$BIN_DIR/librthybrid-burst-analysis.so"
    [scale]="$BIN_DIR/librthybrid-amplitude-scale-offset.so"
    [comedi]="$BIN_DIR/librtsyn-comedi.so"
)
for artifact in "$RTSYN" "$COMEDI_LOOPBACK" "${MODULE[@]}"; do
    [[ -f "$artifact" ]] || { printf 'error: missing %s; run setup.bash first\n' "$artifact" >&2; exit 1; }
done
((EUID != 0)) || { echo 'error: run as normal user, not root' >&2; exit 1; }
command -v comedi_calibrate >/dev/null || { echo 'error: comedi_calibrate is required' >&2; exit 1; }

average_ai0_voltage() {
    awk '/^AI sample [0-9]+:/ { for (i=1;i<=NF;i++) if ($i ~ /^voltage=/) { v=$i; sub(/^voltage=/,"",v); sum+=v; n+=1 } } END { if (!n) exit 1; printf "%.9f", sum/n }'
}
wait_for_telemetry_drain() {
    # The engine can leave warm-up events queued while it is paused. The API
    # continues draining them into the warm-up CSV; do not switch sinks until
    # both SPSC queues are empty, or those old rows can contaminate the main
    # capture as measurement-only cycles.
    python3 - "$RTSYN" <<'PYDRAIN'
import json
import subprocess
import sys
import time

binary = sys.argv[1]
deadline = time.monotonic() + 10.0
while time.monotonic() < deadline:
    result = subprocess.run(
        [binary, "--no-gui", "health"], check=True, capture_output=True, text=True
    )
    status = json.loads(result.stdout)
    if status.get("telemetry_queue_size") == 0 and status.get("telemetry_values_size") == 0:
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit("error: telemetry queues did not drain before experiment capture")
PYDRAIN
}
AI0_ZERO_V=""
WARMUP_CSV_PATH=""
preflight() {
    local commanded="$1" measured output
    output="$("$COMEDI_LOOPBACK" "$DEVICE" "$commanded" 0 0 ground)"
    measured="$(printf '%s\n' "$output" | average_ai0_voltage)"
    if [[ "$commanded" == 0 ]]; then AI0_ZERO_V="$measured"; fi
    printf 'Loopback preflight: commanded %+g V, AI0 measured %+.6f V\n' "$commanded" "$measured"
    awk -v c="$commanded" -v m="$measured" -v t="$PREFLIGHT_TOLERANCE_V" 'BEGIN { e=m-c; if(e<0)e=-e; exit e<=t ? 0:1 }' || {
        echo 'error: AO0-to-AI0 preflight failed; use CB-68LP 22->68 and 55->67' >&2; exit 1; }
}
node_id() {
    local response="$1" id
    id="$(printf '%s\n' "$response" | sed -n 's/.*"node_id":\([0-9][0-9]*\).*/\1/p' | head -n1)"
    [[ -n "$id" && "$id" != 4294967295 ]] || { printf 'error: node creation failed: %s\n' "$response" >&2; exit 1; }
    printf '%s' "$id"
}
cleanup() {
    set +e
    "$RTSYN" --no-gui engine pause >/dev/null 2>&1
    "$RTSYN" --no-gui daemon stop >/dev/null 2>&1
    "$COMEDI_LOOPBACK" "$DEVICE" 0 0 0 ground >/dev/null 2>&1
    if [[ -n "$WARMUP_CSV_PATH" ]]; then rm -f -- "$WARMUP_CSV_PATH"; fi
}
trap cleanup EXIT INT TERM

run_mode() {
    local label="$1" conductance="$2" timestamp csv
    timestamp="$(date +%Y%m%d-%H%M%S)"
    csv="${RTSYN_CSV_PATH:-$DATA_DIR/monodirectional-$label-$timestamp-$PERIOD_TAG.csv}"
    WARMUP_CSV_PATH="$(mktemp "$DATA_DIR/.synapse-warmup.XXXXXX")"
    [[ "$MODE" == both ]] && unset RTSYN_CSV_PATH

    "$RTSYN" --no-gui daemon stop >/dev/null 2>&1 || true
    # The API writes every subscribed value twice during CSV capture: to the
    # requested CSV and to its live JSONL spool (normally /tmp/rtsyn-values).
    # At 10 kHz the extra JSON serialization and filesystem traffic can make
    # the bounded engine telemetry queue drop events. This runner consumes the
    # explicit CSV only, so discard the redundant live spool for this daemon.
    RTSYN_VALUES_FILE=/dev/null
    export RTSYN_VALUES_FILE
    "$RTSYN" --no-gui daemon start
    "$RTSYN" --no-gui runtime period "$PERIOD_NS"
    "$RTSYN" --no-gui runtime priority "$RT_PRIORITY"
    "$RTSYN" --no-gui runtime deadline-tolerance "$DEADLINE_TOLERANCE_NS"

    local pre post pre_burst post_burst scale synapse comedi response
    "$RTSYN" --no-gui plugin load "${MODULE[hr]}"
    response="$("$RTSYN" --no-gui plugin add rthybrid_hindmarsh_rose_1984_neuron_v2)"; pre="$(node_id "$response")"
    response="$("$RTSYN" --no-gui plugin add rthybrid_hindmarsh_rose_1984_neuron_v2)"; post="$(node_id "$response")"
    "$RTSYN" --no-gui plugin load "${MODULE[burst]}"
    response="$("$RTSYN" --no-gui plugin add rthybrid_burst_analysis)"; pre_burst="$(node_id "$response")"
    response="$("$RTSYN" --no-gui plugin add rthybrid_burst_analysis)"; post_burst="$(node_id "$response")"
    "$RTSYN" --no-gui plugin load "${MODULE[scale]}"
    response="$("$RTSYN" --no-gui plugin add rthybrid_amplitude_scale_offset)"; scale="$(node_id "$response")"
    "$RTSYN" --no-gui plugin load "${MODULE[synapse]}"
    response="$("$RTSYN" --no-gui plugin add rthybrid_electrical_synapse)"; synapse="$(node_id "$response")"
    "$RTSYN" --no-gui device load "${MODULE[comedi]}"
    response="$("$RTSYN" --no-gui device add comedi)"; comedi="$(node_id "$response")"

    # HR parameter 3 is E; synapse parameter 0 is conductance in micro-siemens.
    "$RTSYN" --no-gui param set "$pre" 3 f64 -- "$PRE_E"
    "$RTSYN" --no-gui param set "$post" 3 f64 -- "$POST_E"
    "$RTSYN" --no-gui param set "$synapse" 0 f64 -- 0.0
    # COMEDI instances default to /dev/comedi0. Skip the redundant string
    # update on the standard path; only configure an explicit alternate path.
    if [[ "$DEVICE" != "/dev/comedi0" ]]; then
        "$RTSYN" --no-gui param set "$comedi" 0 string "$DEVICE"
    fi

    # The first add argument is a unique connection ID, not a timing flag.
    # plugin-to-plugin: pre/post -> analyzers -> range scaler -> synapse.
    # Device input is read first; its AI0 output reaches post:isyn_na before
    # the plugin phase. Synapse current reaches AO0 in the terminal device phase.
    "$RTSYN" --no-gui connection add 0 "$pre" 2 "$pre_burst" 0
    "$RTSYN" --no-gui connection add 1 "$post" 2 "$post_burst" 0
    "$RTSYN" --no-gui connection add 2 "$pre_burst" 1 "$scale" 0
    "$RTSYN" --no-gui connection add 3 "$pre_burst" 2 "$scale" 1
    "$RTSYN" --no-gui connection add 4 "$post_burst" 1 "$scale" 2
    "$RTSYN" --no-gui connection add 5 "$post_burst" 2 "$scale" 3
    "$RTSYN" --no-gui connection add 6 "$post" 2 "$synapse" 0
    "$RTSYN" --no-gui connection add 7 "$pre" 2 "$synapse" 1
    "$RTSYN" --no-gui connection add 8 "$scale" 4 "$synapse" 2
    "$RTSYN" --no-gui connection add 9 "$scale" 5 "$synapse" 3
    "$RTSYN" --no-gui connection add 10 "$synapse" 4 "$comedi" 0
    "$RTSYN" --no-gui connection add 11 "$comedi" 10 "$post" 0

    # Pre uses vm_mv (port 3) and post uses vm_v (port 2), so both signals
    # have distinct CSV selectors and can later be analysed for phase shift.
    "$RTSYN" --no-gui subscribe ports "$pre" on 0x8
    "$RTSYN" --no-gui subscribe ports "$post" on 0x4
    "$RTSYN" --no-gui subscribe ports "$synapse" on 0x10
    "$RTSYN" --no-gui subscribe ports "$comedi" on 0x400
    # The current CLI selector is keyed by value id, not node id. Using pre
    # vm_mv (3) and post vm_v (2) keeps the source/post columns unambiguous.
    "$RTSYN" --no-gui device start "$comedi"
    # Apply channel transforms after device startup. The values are consumed
    # by the module process callback, so the measured CSV output below also
    # verifies they took effect rather than trusting the API's requested-value
    # snapshot.
    "$RTSYN" --no-gui param set "$comedi" 1 f64 -- "$CURRENT_TO_AO_GAIN"
    "$RTSYN" --no-gui param set "$comedi" 3 f64 -- "$INPUT_GAIN"
    "$RTSYN" --no-gui param set "$comedi" 19 f64 -- 0.0
    "$RTSYN" --no-gui param set "$comedi" 21 f64 -- "$AI0_INPUT_OFFSET"
    for id in "$pre" "$post" "$pre_burst" "$post_burst" "$scale" "$synapse"; do "$RTSYN" --no-gui plugin start "$id"; done
    # Verify the graph is processing and the acknowledged parameter requests
    # match this run's configuration.
    "$RTSYN" --no-gui nodes > "${csv%.csv}.warmup-nodes.json"
    python3 "$CHECKER" graph "${csv%.csv}.warmup-nodes.json" \
        --ids "$pre" "$post" "$pre_burst" "$post_burst" "$scale" "$synapse" "$comedi" \
        --gain "$CURRENT_TO_AO_GAIN" --conductance 0 --pre-e "$PRE_E" --post-e "$POST_E" \
        --ai-offset "$AI0_INPUT_OFFSET"
    # Start draining telemetry before warm-up. Previously events accumulated
    # while the engine ran without a CSV consumer, so the subsequent capture
    # began with an already non-zero dropped-event counter.
    # Keep the zero-conductance observer warm-up in a temporary file. The
    # engine continues emitting cycle telemetry while paused for configuration,
    # but plugin values are held; including that interval makes flat segments
    # appear in the experiment plots.
    "$RTSYN" --no-gui telemetry csv "$WARMUP_CSV_PATH" pre_vm_mv:3 post_vm_v:2 synaptic_current_na:4 returned_current_na:10 \
        --measurement-fields period_ns,actual_period_ns,latency_ns,wake_lateness_ns,skipped_cycle_count,deadline_missed,devices_read_ns,plugins_time_ns,devices_write_ns,telemetry_dropped_events
    "$RTSYN" --no-gui engine resume
    printf 'Observing neuron ranges for %ss with zero conductance...\n' "$WARMUP_SECONDS"
    sleep "$WARMUP_SECONDS"
    "$RTSYN" --no-gui engine pause
    "$RTSYN" --no-gui measurements > "${csv%.csv}.warmup-measurement.json"
    python3 "$CHECKER" warmup "${csv%.csv}.warmup-measurement.json" \
        --gain "$CURRENT_TO_AO_GAIN" --conductance 0 --period-ns "$PERIOD_NS" \
        --telemetry-csv "$WARMUP_CSV_PATH" --deadline-tolerance-ns "$DEADLINE_TOLERANCE_NS"
    python3 "$CHECKER" ai-zero "$WARMUP_CSV_PATH" --gain "$CURRENT_TO_AO_GAIN" --conductance 0 \
        --zero-tolerance-na "$AI0_ZERO_TOLERANCE_NA"
    "$RTSYN" --no-gui param set "$synapse" 0 f64 -- "$conductance"
    "$RTSYN" --no-gui nodes > "${csv%.csv}.nodes.json"
    python3 "$CHECKER" graph "${csv%.csv}.nodes.json" \
        --ids "$pre" "$post" "$pre_burst" "$post_burst" "$scale" "$synapse" "$comedi" \
        --gain "$CURRENT_TO_AO_GAIN" --conductance="$conductance" --pre-e "$PRE_E" --post-e "$POST_E" \
        --ai-offset "$AI0_INPUT_OFFSET"
    # AI0 now represents reconstructed nA, not physical volts.
    printf 'Running %s monodirectional synapse: g=%s uS, %ss, CSV=%s\n' "$label" "$conductance" "$DURATION_SECONDS" "$csv"
    wait_for_telemetry_drain
    # Attach the experiment sink while paused and only after the warm-up queue
    # is empty. Resuming first lets queued warm-up measurements leak into this
    # CSV without corresponding plugin values.
    "$RTSYN" --no-gui telemetry csv "$csv" pre_vm_mv:3 post_vm_v:2 synaptic_current_na:4 returned_current_na:10 \
        --measurement-fields period_ns,actual_period_ns,latency_ns,wake_lateness_ns,skipped_cycle_count,deadline_missed,devices_read_ns,plugins_time_ns,devices_write_ns,telemetry_dropped_events
    "$RTSYN" --no-gui engine resume
    rm -f -- "$WARMUP_CSV_PATH"
    WARMUP_CSV_PATH=""
    sleep "$DURATION_SECONDS"
    "$RTSYN" --no-gui engine pause
    "$RTSYN" --no-gui measurements
    "$RTSYN" --no-gui daemon stop
    "$COMEDI_LOOPBACK" "$DEVICE" 0 0 0 ground >/dev/null
    python3 "$CHECKER" capture "$csv" --gain "$CURRENT_TO_AO_GAIN" \
        --conductance="$conductance" --period-ns "$PERIOD_NS" \
        --tolerance-v "$TRACKING_TOLERANCE_V"
}

soft_memlock="$(ulimit -Sl)"; soft_rtprio="$(ulimit -Sr)"
[[ "$soft_memlock" == unlimited && "$soft_rtprio" =~ ^[0-9]+$ && "$soft_rtprio" -ge "$RT_PRIORITY" ]] || { echo 'error: insufficient realtime limits' >&2; exit 1; }
comedi_calibrate -v -f "$DEVICE"
preflight 0; preflight 1; preflight -1; preflight 0
AI0_INPUT_OFFSET="$(python3 - "$AI0_ZERO_V" "$INPUT_GAIN" <<'PYCONFIG'
import math, sys
zero_v, gain = map(float, sys.argv[1:])
if not all(map(math.isfinite, (zero_v, gain))) or gain <= 0:
    raise SystemExit('error: invalid AO0-zero calibration for AI0')
print(format(-zero_v * gain, '.17g'))
PYCONFIG
)"
AI0_ZERO_TOLERANCE_NA="$(python3 - "$PREFLIGHT_TOLERANCE_V" "$INPUT_GAIN" <<'PYCONFIG'
import math, sys
tolerance_v, gain = map(float, sys.argv[1:])
print(format(tolerance_v * gain, '.17g'))
PYCONFIG
)"
# Dispatch directly: Bash suppresses errexit inside functions used as an if
# condition, which can otherwise let a failed mode/check continue silently.
case "$MODE" in
    control) run_mode control 0 ;;
    excitatory) run_mode excitatory "$EXCITATORY_G_US" ;;
    inhibitory) run_mode inhibitory "$INHIBITORY_G_US" ;;
    both)
        run_mode control 0
        run_mode excitatory "$EXCITATORY_G_US"
        run_mode inhibitory "$INHIBITORY_G_US"
        ;;
esac
trap - EXIT INT TERM
printf 'Synapse signal-path checks passed: %s\n' "$DATA_DIR"
