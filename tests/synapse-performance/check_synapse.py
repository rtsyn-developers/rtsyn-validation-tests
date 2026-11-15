"""Fail-fast checks for the physical synapse runner; no hardware access."""
import argparse
import csv
import json
import math
import statistics
from pathlib import Path


def check_graph(snapshot, ids, gain, conductance, pre_e, post_e, ai_offset=0.):
    pre, post, pre_burst, post_burst, scale, synapse, comedi = ids
    edges = [(pre,2,pre_burst,0), (post,2,post_burst,0),
             (pre_burst,1,scale,0), (pre_burst,2,scale,1),
             (post_burst,1,scale,2), (post_burst,2,scale,3),
             (post,2,synapse,0), (pre,2,synapse,1),
             (scale,4,synapse,2), (scale,5,synapse,3),
             (synapse,4,comedi,0), (comedi,10,post,0)]
    actual = {c['connection_id']: tuple(c[k] for k in (
        'source_node_id','source_port_id','destination_node_id','destination_port_id'))
        for c in snapshot['connections']}
    if actual != dict(enumerate(edges)):
        raise ValueError('Runtime graph does not match all 12 expected connections')
    nodes = {n['node_id']: n for n in snapshot['nodes']}
    if any(nodes.get(n, {}).get('runtime_state') != 'process' for n in ids):
        raise ValueError('Not all seven nodes are processing')
    # API param_values is requested configuration, not independent module readback.
    params = {(p['node_id'],p['param_id']):p['value'] for p in snapshot['param_values']}
    expected = {(pre,3):pre_e, (post,3):post_e, (synapse,0):conductance,
                (comedi,1):gain, (comedi,3):1/gain, (comedi,19):0.,
                (comedi,21):ai_offset}
    for key, value in expected.items():
        # The nodes snapshot serializes f64 values with about six significant
        # digits. Allow that rounding for the small calibrated AI0 offset.
        rel_tol = 2e-6 if key == (comedi, 21) else 1e-8
        if key not in params or not math.isclose(float(params[key]), value, rel_tol=rel_tol, abs_tol=1e-12):
            raise ValueError(f'Parameter {key}: expected {value}, got {params.get(key)}')
    return {'graph_verified': True, 'ao_volts_per_na': gain, 'ai_na_per_volt': 1/gain,
            'conductance_us': conductance, 'node_ids': ids}


def check_capture(path, gain, conductance, tolerance_v=0.1, expected_period_ns=None):
    # RTSyn writes one CSV row per telemetry event. Port values and measurement
    # metrics therefore arrive as separate, often partial rows for one cycle.
    # Join those rows by cycle_id before assessing completeness or transport.
    cycles = {}
    errors = [0., 0.]; counts = [0, 0]
    command_error_sq = 0.; command_count = 0
    source_command_error_sq = 0.
    lo, hi, rlo, rhi = math.inf, -math.inf, math.inf, -math.inf
    previous = None
    drops = 0
    missing_cycles = 0
    observed_periods = set()
    with Path(path).open() as stream:
        reader = csv.DictReader(stream)
        fields = set(reader.fieldnames or [])
        source = ('synaptic_current_na' if 'synaptic_current_na' in fields else
                  'hindmarsh_rose_vm_mv' if 'hindmarsh_rose_vm_mv' in fields else
                  'hindmarsh_rose_vm_v')
        measured = 'returned_current_na' if 'returned_current_na' in (reader.fieldnames or []) else 'comedi_ai0_v'
        command = 'comedi_ao0_input' if 'comedi_ao0_input' in (reader.fieldnames or []) else None
        measured_gain = 1. if measured == 'returned_current_na' else 1/gain
        required = {'cycle_id', source, measured, 'telemetry_dropped_events'}
        if expected_period_ns is not None:
            required.add('period_ns')
        if not required.issubset(reader.fieldnames or []):
            raise ValueError('Capture lacks required current/telemetry columns')
        for row in reader:
            raw_period = row.get('period_ns', '')
            if raw_period:
                period_value = float(raw_period)
                if not math.isfinite(period_value):
                    raise ValueError('Capture contains a non-finite runtime period')
                observed_periods.add(period_value)
            if row['telemetry_dropped_events']:
                drops = max(drops, int(row['telemetry_dropped_events']))
            if not row['cycle_id']:
                continue
            cycle = int(row['cycle_id'])
            bucket = cycles.setdefault(cycle, {})
            for field in (source, measured, command):
                if field is None:
                    continue
                if row[field]:
                    bucket[field] = float(row[field])

    count = len(cycles)
    paired = 0
    ordered_cycles = sorted(cycles)
    for previous_cycle, cycle in zip(ordered_cycles, ordered_cycles[1:]):
        if cycle > previous_cycle + 1:
            missing_cycles += cycle - previous_cycle - 1
    for cycle in ordered_cycles:
        row = cycles[cycle]
        if source not in row or measured not in row:
            previous = None
            continue
        current, returned = row[source], row[measured]*measured_gain
        if not math.isfinite(current) or not math.isfinite(returned):
            raise ValueError('Non-finite current in capture')
        paired += 1
        lo, hi = min(lo,current), max(hi,current)
        rlo, rhi = min(rlo,returned), max(rhi,returned)
        measured_voltage = returned * gain
        source_voltage = current * gain
        target_voltage = source_voltage
        if command is not None and command in row:
            target_voltage = row[command] * gain
            source_command_error_sq += (target_voltage - source_voltage) ** 2
            command_error_sq += (measured_voltage - target_voltage) ** 2
            command_count += 1
        errors[0] += (measured_voltage-target_voltage)**2; counts[0] += 1
        if command is None and previous and previous[0]+1 == cycle:
            errors[1] += ((returned-previous[1])*gain)**2; counts[1] += 1
        previous = (cycle,current)
    failures = []
    if expected_period_ns is not None and observed_periods != {float(expected_period_ns)}:
        failures.append(
            f'Capture period must be exactly {expected_period_ns} ns; '
            f'observed {sorted(observed_periods)}'
        )
    if paired < 100 or paired < count * .99: failures.append('Insufficient paired telemetry (requires 99%)')
    if drops: failures.append('Telemetry events dropped')
    if missing_cycles: failures.append('Runtime telemetry has gaps between cycle IDs')
    if command is not None and command_count < paired * .99:
        failures.append('Insufficient AO0 command samples (requires 99%)')
    if command_count:
        command_rmse = math.sqrt(command_error_sq / command_count)
        source_command_rmse = math.sqrt(source_command_error_sq / command_count)
        if command_rmse > tolerance_v:
            failures.append('AI0 does not track the commanded AO0 signal')
        if source_command_rmse > tolerance_v:
            failures.append('AO0 command does not track the source through the runtime graph')
    if paired:
        if max(abs(lo),abs(hi))*gain >= 9.: failures.append('Command approaches DAC rails (9 V safety margin)')
        if conductance != 0 and (hi-lo)*gain < .1: failures.append('Synaptic current absent or spans less than 0.1 V at DAC')
        if conductance != 0 and (rhi-rlo)*gain < .05: failures.append('Returned current is flat or under-resolved')
        if conductance == 0 and max(abs(lo),abs(hi)) > 1e-12: failures.append('Zero-conductance control produced current')
    rmses = [math.sqrt(e/n) if n else None for e,n in zip(errors,counts)]
    valid = [(v,i) for i,v in enumerate(rmses) if v is not None]
    rmse, lag = min(valid) if valid else (None,None)
    if rmse is None or rmse > tolerance_v: failures.append('AO/AI tracking error exceeds tolerance')
    return {'passed':not failures, 'failures':failures, 'rows':count, 'paired':paired,
            'missing_cycles':missing_cycles,
            'observed_period_ns':sorted(observed_periods),
            'transport_rmse_v':rmse, 'lag_cycles':lag, 'telemetry_drops':drops,
            'ao_command_samples':command_count,
            'ao_command_tracking_rmse_v':math.sqrt(command_error_sq/command_count) if command_count else None,
            'source_to_ao_command_rmse_v':math.sqrt(source_command_error_sq/command_count) if command_count else None,
            'scope':'Signal-path sanity only; not proof of synchronization or biological validity'}


def check_warmup(path, period_ns, telemetry_csv=None, deadline_tolerance_ns=5000):
    # measurements can include a CLI envelope before the final JSON object.
    lines = Path(path).read_text().splitlines()
    measurement = None
    for line in reversed(lines):
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if all(key in candidate for key in ('devices_read_ns', 'plugins_time_ns', 'devices_write_ns')):
            measurement = candidate
            break
    if measurement is None:
        raise ValueError('Warm-up did not return a runtime measurement object')
    read_ns = int(measurement['devices_read_ns'])
    plugin_ns = int(measurement['plugins_time_ns'])
    write_ns = int(measurement['devices_write_ns'])
    work_ns = read_ns + plugin_ns + write_ns
    sample_count = 1
    missed_count = int(measurement.get('deadline_missed', False))
    skipped = int(measurement.get('skipped_cycle_count', 0))
    dropped = int(measurement.get('dropped_event_count', 0))
    max_wake_lateness_ns = int(measurement.get('wake_lateness_ns', 0))
    max_work_ns = work_ns
    work_sample_count = 1
    if telemetry_csv is not None:
        sample_count = 0
        work_sample_count = 0
        missed_count = skipped = dropped = max_wake_lateness_ns = max_work_ns = 0
        seen_cycles = {}
        with Path(telemetry_csv).open() as stream:
            for row in csv.DictReader(stream):
                if not row.get('wake_lateness_ns'):
                    continue
                cycle_id = row.get('cycle_id') or str(sample_count)
                sample = seen_cycles.setdefault(cycle_id, {
                    'missed': False, 'skipped': 0, 'dropped': 0,
                    'lateness': 0, 'work': 0, 'has_work': False,
                })
                sample['lateness'] = max(sample['lateness'], int(row['wake_lateness_ns']))
                if row.get('deadline_missed'):
                    sample['missed'] |= row['deadline_missed'].strip().lower() in ('1', 'true', 'yes')
                if row.get('skipped_cycle_count'):
                    sample['skipped'] = max(sample['skipped'], int(row['skipped_cycle_count']))
                if row.get('telemetry_dropped_events'):
                    sample['dropped'] = max(sample['dropped'], int(row['telemetry_dropped_events']))
                work_fields = ('devices_read_ns', 'plugins_time_ns', 'devices_write_ns')
                if all(row.get(field) for field in work_fields):
                    sample['work'] = sum(int(row[field]) for field in work_fields)
                    sample['has_work'] = True
        sample_count = len(seen_cycles)
        if sample_count:
            work_sample_count = sum(sample['has_work'] for sample in seen_cycles.values())
            missed_count = sum(sample['missed'] for sample in seen_cycles.values())
            skipped = max(sample['skipped'] for sample in seen_cycles.values())
            dropped = max(sample['dropped'] for sample in seen_cycles.values())
            max_wake_lateness_ns = max(sample['lateness'] for sample in seen_cycles.values())
            max_work_ns = max(sample['work'] for sample in seen_cycles.values())
    failures = []
    warnings = []
    if telemetry_csv is not None and not sample_count:
        failures.append('Warm-up CSV contains no timing samples')
    if telemetry_csv is not None and work_sample_count != sample_count:
        failures.append('Warm-up CSV is missing per-cycle work measurements')
    if max_work_ns >= period_ns:
        failures.append('Measured device/plugin work meets or exceeds the runtime period')
    if skipped:
        failures.append('Runtime skipped one or more complete cycles during warm-up')
    if dropped:
        failures.append('Telemetry events were dropped during warm-up')
    if missed_count:
        rate = 100.0 * missed_count / sample_count if sample_count else 0.0
        warnings.append(
            f'{missed_count}/{sample_count} samples exceeded the {deadline_tolerance_ns} ns '
            f'deadline tolerance ({rate:.3f}%); see the deadline-events plot'
        )
    return {'passed': not failures, 'failures': failures, 'period_ns': period_ns,
            'devices_read_ns': read_ns, 'plugins_time_ns': plugin_ns,
            'devices_write_ns': write_ns, 'last_sample_work_ns': work_ns,
            'max_sample_work_ns': max_work_ns, 'timing_samples': sample_count,
            'deadline_tolerance_ns': deadline_tolerance_ns,
            'deadline_missed_count': missed_count,
            'max_wake_lateness_ns': max_wake_lateness_ns,
            'warnings': warnings, 'skipped_cycle_count': skipped,
            'dropped_event_count': dropped}


def check_ai_zero(path, tolerance_na):
    values = []
    with Path(path).open() as stream:
        reader = csv.DictReader(stream)
        if 'returned_current_na' not in (reader.fieldnames or []):
            raise ValueError('Capture lacks the returned AI0 current column')
        for row in reader:
            raw = row.get('returned_current_na', '')
            if raw:
                value = float(raw)
                if not math.isfinite(value):
                    raise ValueError('AI0 zero-input capture contains a non-finite value')
                values.append(value)
    if len(values) < 1000:
        raise ValueError(f'AI0 zero-input check has too few samples ({len(values)}; requires 1000)')
    median = statistics.median(values)
    failures = []
    if abs(median) > tolerance_na:
        failures.append('AI0 gain/offset calibration did not scale the zero-input baseline')
    return {'passed': not failures, 'failures': failures, 'samples': len(values),
            'median_returned_current_na': median,
            'zero_tolerance_na': tolerance_na}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action', choices=['graph','capture','warmup','ai-zero'])
    parser.add_argument('path', type=Path)
    parser.add_argument('--gain',type=float,required=True)
    parser.add_argument('--conductance',type=float,required=True)
    parser.add_argument('--ids',type=int,nargs=7)
    parser.add_argument('--pre-e',type=float,default=3.2)
    parser.add_argument('--post-e',type=float,default=2.8)
    parser.add_argument('--tolerance-v',type=float,default=.1)
    parser.add_argument('--period-ns',type=int,default=100000,
                        help='Expected validation period for capture checks (fixed at 100000 ns)')
    parser.add_argument('--zero-tolerance-na',type=float)
    parser.add_argument('--ai-offset',type=float,default=0.)
    parser.add_argument('--telemetry-csv',type=Path)
    parser.add_argument('--deadline-tolerance-ns',type=int,default=5000)
    args=parser.parse_args()
    if not all(map(math.isfinite, (args.gain,args.conductance,args.tolerance_v))) or args.gain <= 0 or args.tolerance_v <= 0:
        parser.error('Use finite conductance and positive finite gain/tolerance')
    try:
        if args.action == 'graph':
            report=check_graph(json.loads(args.path.read_text()),args.ids,args.gain,args.conductance,args.pre_e,args.post_e,args.ai_offset)
        elif args.action == 'capture':
            if args.period_ns != 100000:
                parser.error('Capture validation period is fixed at 100000 ns (100 us)')
            report=check_capture(args.path,args.gain,args.conductance,args.tolerance_v,
                                 expected_period_ns=args.period_ns)
        elif args.action == 'ai-zero':
            if args.zero_tolerance_na is None or not math.isfinite(args.zero_tolerance_na) or args.zero_tolerance_na <= 0:
                parser.error('ai-zero action requires a positive finite --zero-tolerance-na')
            report=check_ai_zero(args.path,args.zero_tolerance_na)
        else:
            if args.period_ns is None or args.period_ns <= 0:
                parser.error('warmup action requires a positive --period-ns')
            report=check_warmup(args.path,args.period_ns,args.telemetry_csv,args.deadline_tolerance_ns)
        args.path.with_suffix('.'+args.action+'-check.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report))
        if report.get('passed') is False: raise SystemExit(1)
    except (ValueError,KeyError,TypeError) as error:
        parser.exit(1,f'error: {error}\n')

if __name__ == '__main__': main()
