# RTSyn validation plots

`rtsyn-validation-plots` is a small Python package and CLI for turning RTSyn validation CSV files into reusable PNG, SVG, or PDF figures. It detects available timing metrics and, for loopback runs, plots the signal sent to the output against the physically measured input.

## Requirements and setup

Install [uv](https://docs.astral.sh/uv/) and Python 3.13 or newer. From this directory:

```bash
uv sync
```

This installs the package, runtime plotting dependencies, and the development tools. Run the CLI without installing it globally using `uv run`:

```bash
uv run plot-tests --help
```

You can also use the Python module entry point: `uv run python -m plot_tests`.

## Generate plots

```bash
uv run plot-tests generate ../data/loopback-performance/100us/ni-pci-6024e-hindmarsh-rose-20260925-210614-100us.csv
```

By default the figures are placed in a sibling directory named `<csv-name>_<period>_plots`. The period is inferred from the CSV's `period_ns` data; use `--period-ns` to set it for data without that column. Choose another destination and/or multiple formats like this:

```bash
uv run plot-tests generate capture.csv --output-dir results/run-01 \
  --format png --format svg
```

For a legacy or external capture without `period_ns`, specify the period explicitly:

```bash
uv run plot-tests generate capture.csv --period-ns 100000
```

For a loopback CSV, the sent/output series is computed from its source-signal column multiplied by the configured AO gain; the measured series comes from the input column. The standard Hindmarsh–Rose test now uses `vm_mv` with `COMEDI_AO0_GAIN=1`, so the tool applies gain 1 by default for `hindmarsh_rose_vm_mv`. Older captures using `vm_v` retain the 1000 default. Override when a run used a different gain:

```bash
uv run plot-tests generate capture.csv --ao-gain 250
```

For other recognized source/measurement pairs, the default gain is 1. This is only an estimate of the commanded voltage from the logged source and gain—not a hardware AO readback. The AO subdevice does not expose readback in the current Comedi driver.

Inspect the input columns and detected test shape before plotting:

```bash
uv run plot-tests inspect capture.csv
```

## Summarize independent executions

Do not treat the hundreds of thousands of 10 kHz cycles in one CSV as
independent repetitions.  Generate one row per capture and use that table for
between-run variability and paired A/B analysis:

```bash
uv run plot-tests summarize ../data/repeated-comparison/20261115-120000-100us/run-*.csv \
  --output ../data/repeated-comparison/20261115-120000-100us/run-summary.csv
```

The output records coverage (`cycle_id` gaps), the maximum reported telemetry
event-drop counter, deadline and skipped-cycle counts, wake-lateness
percentiles plus maximum, and (when present) loopback pairing coverage, bias,
MAE and RMSE.  A nonzero gap or drop counter is a data-integrity finding: do
not silently omit that capture from the analysis.  The source-to-AO gain is
inferred as 1000 for the standard Hindmarsh--Rose test and may be made
explicit with `--ao-gain`.

For a `repeated-comparison.bash` campaign, compare alternating pairs directly:

```bash
uv run plot-tests compare ../data/repeated-comparison/<lote>/manifest.tsv
```

It validates that every pair has one `no-device` and one `loopback` capture,
then writes raw pair effects, an effect summary with a fixed-seed bootstrap
confidence interval for the mean, and `paired-effects.png`. The chart connects
the two executions in each pair; it does not average their time series.
It also writes `test-integrity.csv`: for each timing/signal metric and each
condition, `test_integrity_percent` is the mean absolute difference from the
median execution as a percentage of that median. Zero means identical runs;
lower is better. For a nonzero series with a zero median the percentage is
undefined, so use `absolute_range` instead.

For any other repeated test (such as the synapse conditions), request the same
table while summarizing only captures of that one test and condition:

```bash
uv run plot-tests summarize data/synapse-performance/100us/monodirectional-excitatory-*.csv \
  --test-name synapse-excitatory --output run-summary.csv
```

## Generated figures

The exact set depends on columns in the CSV. Timing figures are emitted when their source metrics are present:

- `period-jitter`: target and actual cycle period plus actual-minus-target deviation.
- `wake-lateness`: wake lateness over elapsed time/cycle; falls back to `latency_ns` if needed.
- `wake-lateness-distribution`: histogram with p50, p95, p99, and p99.9 markers.
- `cycle-work`: device-read, plugin, and device-write processing times when logged.
- `deadline-events`: deadline-missed flags when logged.

Recognized source/read signal pairs add:

- `loopback-tracking`: sent/commanded and measured voltage, with the tracking error below.
- `loopback-transfer`: measured voltage against sent voltage and the ideal 1:1 line.

Long time-series are decimated for line plots to keep output manageable; distribution summaries use all available samples. Empty sparse cells in merged telemetry are left missing rather than treated as zero.

Every generated figure filename is suffixed with the input CSV basename and configured period so files remain identifiable when copied out of their capture folder. The output directory also includes the period, for example `run-03-loopback_100us_plots`; images include the period and frequency in their title. If the CSV lacks a `period_ns` column, pass `--period-ns` explicitly.

## CSV expectations

The tool accepts RTSyn validation CSVs with a `timestamp_ns` or `cycle_id` x-axis. It recognizes timing columns including `period_ns`, `actual_period_ns`, `wake_lateness_ns`, `latency_ns`, `devices_read_ns`, `plugins_time_ns`, `devices_write_ns`, and `deadline_missed`. Loopback columns currently recognized include `hindmarsh_rose_vm_mv` or `hindmarsh_rose_vm_v` with `comedi_ai0_v`, `analog_output_0` with `analog_input_0`, `comedi_ao0_v` with `comedi_ai0_v`, and `synaptic_current_na` with `comedi_ai0_v`; generic `analog_output_*`/`analog_input_*` pairs are also supported.

## Development

```bash
uv run pytest
uv run ruff check .
uv build
```

The package uses a `src/` layout. CSV loading and test-shape detection live in `plot_tests.data`, the Typer CLI in `plot_tests.cli`, and plot families in `plot_tests.plots`.

### Overlay and zoom

`loopback-tracking` overlays commanded AO0 and measured AI0 on one shared
voltage axis, with identical time direction and no baseline subtraction.
`loopback-tracking-zoom` shows a centered 20-second window by default.
`loopback-error` now contains the residual separately. Override the zoom with:

```bash
uv run plot-tests generate capture.csv --zoom-start 10 --zoom-duration 0.1
```

Zoom coordinates are elapsed seconds, or cycle IDs when timestamps are absent.
Real offsets remain visible; plotting does not force mismatched signals to overlap.

Synapse captures additionally produce `neuron-voltages` and
`neuron-voltages-zoom`: pre/post neuron outputs overlaid in mV, converting
`post_vm_v` to mV. These are distinct from the AO0 synaptic-current loopback.
