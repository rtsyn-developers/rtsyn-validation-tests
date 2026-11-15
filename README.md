# RTSyn validation tests

This repository contains reproducible hardware validation tests for RTSyn. Each test stages its dependencies locally, validates the physical device wiring before execution when possible, runs RTSyn through its command-line API, and writes captured data under `data/`.

## Repository structure

```text
rtsyn-validation-tests/
├── README.md
├── setup.bash
├── scripts/
│   └── run-and-plot-all.bash    runs all measurement suites and plots new CSVs
├── bin/                         generated binaries and shared modules
├── repos/                       cloned source repositories
├── devices/                     device pinouts and validation notes
│   └── ni-pci-6024e.md
├── tests/
│   ├── loopback-performance/
│       ├── ni-pci-6024e.bash
│       ├── no-device-runtime.bash
│       └── repeated-comparison.bash
│   └── synapse-performance/
│       └── monodirectional-electrical-synapse.bash
└── data/
    └── loopback-performance/    generated CSV results
```

The `bin/`, `repos/`, and `data/` directories are generated locally and excluded from Git.

## Requirements

- Linux with a supported realtime backend
- Git
- Xmake
- Rust/Cargo
- A C/C++ toolchain
- Comedi development/runtime packages for Comedi tests
- Permission to access the selected device, normally `/dev/comedi0`

For the NI PCI-6024E test, the kernel must load the `ni_pcimio` driver and this command must identify the card:

```bash
comedi_board_info /dev/comedi0
```

## Setup

Run setup from anywhere:

```bash
bash ./setup.bash
```

Run the script as your normal user—do **not** run the complete script through `sudo`. This keeps cloned repositories, Xmake caches, and build artifacts owned by your account and allows setup to find tools installed in your user environment. Setup invokes `sudo` itself only when it must stage the final RTSyn executable outside a `nosuid` filesystem and apply capabilities to it.

The setup script:

1. Clones the required repositories into `repos/`.
2. Builds RTSyn with the PREEMPT_RT thread backend by default.
3. Builds the Comedi device module and standalone diagnostics.
4. Builds the Hindmarsh–Rose neuron plugin.
5. Copies all runtime artifacts into `bin/`.

Setup supports both target layouts used by the projects: RTSyn's project-local `repos/rtsyn/build/` directory and the shared validation `build/` directory currently used by the standalone module targets. Final artifacts are always staged uniformly in `bin/`.

The resulting artifacts are:

```text
bin/rtsyn
bin/librtsyn-comedi.so
bin/librthybrid-hindmarsh-rose-1984-neuron-v2.so
bin/librthybrid-electrical-synapse.so
bin/librthybrid-burst-analysis.so
bin/librthybrid-amplitude-scale-offset.so
bin/comedi-loopback
bin/comedi-digital-loopback
```

Existing Git repositories under `repos/` are reused and never overwritten. Remove or update them explicitly when a fresh revision is required.

Only the top-level projects used directly by this validation are always cloned: RTSyn, the Comedi device module, and the Hindmarsh–Rose plugin. Xmake resolves RTSyn libraries, the ABI, the module loader, and other transitive dependencies through `rtsyn-xmake-repo`. Setup reuses that repository when it is already registered; if it is missing, setup clones it into `repos/` and registers the local checkout with Xmake.

The Comedi module declares `rtsyn-abi` and `rtsyn-module-loader`; both are provided by `rtsyn-xmake-repo`, and `rtsyn-module-loader` in turn declares `rtsyn-abi` and `libuv`. The native Comedi library remains a Linux system dependency (`libcomedi-dev` on Debian) because it is linked directly as `libcomedi`, not supplied by the RTSyn package repository.

### Build configuration

The build backend and mode can be overridden:

```bash
RTSYN_THREAD_CORE=posix RTSYN_BUILD_MODE=debug ./setup.bash
```

Defaults:

| Variable | Default | Meaning |
|---|---|---|
| `RTSYN_THREAD_CORE` | `preempt_rt` | RTSyn realtime thread backend |
| `RTSYN_BUILD_MODE` | `release` | Xmake/Cargo build mode |

For PREEMPT_RT builds, setup grants the staged RTSyn executable these Linux capabilities:

```bash
sudo setcap cap_sys_nice,cap_ipc_lock=eip "$(readlink -f ./bin/rtsyn)"
```

- `CAP_SYS_NICE` permits the daemon to create its realtime thread with the requested scheduling policy and priority.
- `CAP_IPC_LOCK` permits the PREEMPT_RT backend to lock current and future memory with `mlockall()`.

Setup requests `sudo` for the narrowly scoped final executable installation (when required) and `setcap`, then verifies both capabilities with `getcap`. Capabilities are applied after copying the binary because replacing a file removes its capability extended attribute.

On Debian, `setcap` and `getcap` are provided by `libcap2-bin` and may live in `/usr/sbin` even when that directory is absent from the normal-user `PATH`. Setup checks both `PATH` and the standard system administration directories automatically.

No capabilities are added to the shared modules or standalone Comedi diagnostics. Access to `/dev/comedi0` must instead be provided through its owner/group and udev permissions.

File capabilities are ineffective on filesystems mounted with `nosuid`. For PREEMPT_RT, setup therefore always installs only the RTSyn executable at `/usr/local/libexec/rtsyn-validation-tests/rtsyn`, applies capabilities there, and makes `bin/rtsyn` a symlink to it. This avoids unreliable mount-policy detection across mount namespaces. Override that location with `RTSYN_CAPABILITY_DIR` when necessary. Run both setup and validation as your normal user; do not run the complete test with `sudo`. A POSIX-backend build avoids realtime privileges but does not validate PREEMPT_RT behavior.

## Device documentation

Device-specific reference material is stored in `devices/`.

### NI PCI-6024E

[devices/ni-pci-6024e.md](devices/ni-pci-6024e.md) contains:

- Official NI manual references
- PCI-6024E to CB-68LP pin mapping
- Analog and digital loopback wiring
- Direct multimeter tests
- Comedi calibration commands
- Expected raw and physical values
- Cable and floating-input troubleshooting

## Tests

### Run and plot all measurement suites

After `setup.bash`, run the complete measurement suite and generate plots for
every CSV created during that invocation:

```bash
bash ./scripts/run-and-plot-all.bash
```

The arguments are the duration in seconds for individual runs and the repeat
pair count (defaults: 60 seconds and three pairs). The validation runtime
period is fixed at 100,000 ns = 100 µs = 10 kHz.
It runs the standalone NI physical-loopback and no-device baselines, the
repeated no-device/loopback comparison (including separate `cyclictest` and
`rtla` references), the CPU idle-latency QoS A/B suite, and the
monodirectional electrical-synapse test in both excitatory and inhibitory
conditions. For the QoS A/B
suite it explicitly disables RTSyn's built-in default request in both
profiles, so the no-QoS control is genuine; the QoS-enabled profile is supplied
by the test runner's held-open `/dev/cpu_dma_latency` request. Each new CSV is
plotted with `plot-tests` into a sibling capture-and-period-specific plots directory. Run as
your normal user; individual scripts invoke `sudo` only where needed.

The orchestrator saves a timestamped console log for each top-level suite in
`data/run-logs/`. If a suite exits nonzero before producing a CSV, inspect its
matching log there; the repeated-comparison runner also keeps per-run logs in
its own timestamped data directory.

If `/dev/cpu_dma_latency` is not writable by the current user, the orchestrator
explicitly disables RTSyn's built-in request for the standalone and repeated
baseline suites so they can still run; it prints a warning that those suites
do not validate the default-on behavior. The dedicated QoS A/B suite continues
to test both profiles using its separate sudo-held request. Granting the user
write access to `/dev/cpu_dma_latency` is necessary to test RTSyn's default-on
request directly.

This command takes several minutes with default settings and requires the
physical AO0-to-AI0 wiring and RTSyn realtime/device permissions. The DIO
jumper diagnostic is not run automatically because it requires a separate
physical DIO0-to-DIO1 jumper; invoke `./bin/comedi-digital-loopback /dev/comedi0 0 1`
only when that wiring is in place.

Tests are grouped by their validation purpose under `tests/`. Every test resolves `bin/`, `data/`, and other repository paths relative to its own location, so it does not depend on the current working directory.

### NI PCI-6024E loopback performance

Script:

```text
tests/loopback-performance/ni-pci-6024e.bash
```

This test runs a Hindmarsh–Rose neuron model in RTSyn, sends its membrane-voltage signal through Comedi AO0, reads the physical signal back through AI0, and records the subscribed model and AI0 telemetry values to CSV. The supported `telemetry csv` CLI exports selected value columns only; the separate `measurements` command reports the latest runtime timing metrics.

Required ground-referenced CB-68LP wiring:

```text
22 (AO0 / DAC0OUT)  -> 68 (AI0 / ACH0)
55 (AOGND)          -> 67 (AIGND)
```

These terminal assignments come from Figure B-1 of the official NI 6023E/6024E/6025E manual. The CB-68LP maps its numbered terminals one-to-one to the DAQ connector pins.

Run a 30-second measurement at the required 100 µs period (10 kHz). The
optional second argument is accepted only when it is `100000`:

```bash
./tests/loopback-performance/ni-pci-6024e.bash 30
# Explicitly pass the required 100 µs period
./tests/loopback-performance/ni-pci-6024e.bash 30 100000
```

#### Repeated controlled comparison

For the no-device versus physical-I/O comparison, use the combined installer/runner:

```bash
bash ./tests/loopback-performance/repeated-comparison.bash 30 3
```

It installs Debian's `rt-tests` and `rtla` packages if `cyclictest` or `rtla` is missing, then runs separate scheduler references (`cyclictest` and `rtla timerlat hist`) and alternates three no-device and three AO0→AI0 runs. The first argument is seconds per run; the second is repeat pairs. Scheduler references run separately so they do not perturb the A/B measurements. `cyclictest` and `rtla` run through `sudo` (for RT scheduling/device access and kernel tracing respectively); RTSyn tests themselves run as the normal user. `cyclictest -p 90` sets its test thread to FIFO priority 90, matching RTSyn's default test priority, so an extra `chrt` wrapper is unnecessary.

The period is fixed at `100000` ns (100 µs / 10 kHz). Artifacts go into a timestamp-and-period directory under `data/repeated-comparison/`: per-run CSVs and logs, the independent scheduler outputs, an environment snapshot, and a TSV manifest with configuration and SHA-256 for every CSV. The no-device and loopback runs use the same period, priority, deadline tolerance, duration, and Hindmarsh–Rose model. The physical run necessarily adds Comedi nodes and AO0→AI0 wiring, so this remains a comparison of I/O-enabled versus no-device execution, not identical graph topology.

To test whether CPU idle-state exit latency explains high wake lateness, run the opt-in no-device PM QoS A/B test:

```bash
bash ./tests/loopback-performance/cpu-idle-qos-ab.bash 30 3
```

The period is fixed at `100000` ns (100 µs / 10 kHz). It alternates a run with no QoS request added by this runner and a run with `cpu_dma_latency=0`, keeping the workload and RTSyn settings the same. (Other system processes may independently hold QoS requests.) Only the QoS-enabled run uses `sudo`: it opens `/dev/cpu_dma_latency`, writes a zero-microsecond constraint, drops back to the invoking user, and holds the descriptor open until that test exits. The request is released automatically; no persistent CPU-idle settings are changed. Logs, CSVs, a manifest, a cpuidle-state snapshot, and sampled thread scheduling/CPU data are written to a timestamp-and-period directory under `data/cpu-idle-qos-ab/`. This runner does not pin the RTSyn engine thread; it records observed CPU placement so the result is not mislabeled as pinned.

The validation pipeline keeps its 100 µs period (10 kHz). Its key defaults are:

| Setting | Default | Meaning |
|---|---:|---|
| Runtime period | `100000 ns` (100 µs) | One engine cycle every 100 µs |
| Deadline tolerance | `5000 ns` (5 µs) | Wake lateness allowed before a deadline is marked missed |
| RTSyn realtime priority | `90` | FIFO priority requested for the engine |
| Run duration | `60 s` | Duration of each individual capture |
| Repeated comparison pairs | `3` | Three no-device and three physical-I/O runs |
| Loopback preflight tolerance | `0.15 V` | Maximum accepted AO0-to-AI0 discrepancy |
| Synapse conductance | `+0.1 / -0.1 µS` | Excitatory and inhibitory runs; control uses `0 µS` |
| Synapse transport gain | `10 V/nA` | AO conversion; AI conversion uses reciprocal `0.1 nA/V` |
| Synapse range warm-up | `6 s` | Minimum zero-conductance observation interval |
| Synapse tracking tolerance | `0.1 V` | Maximum accepted AO/AI transport RMSE |

The validation period is fixed at `100000` ns (100 µs / 10 kHz); the orchestrator rejects another period argument or a conflicting `RTSYN_PERIOD_NS` override, and individual runners reject non-100-µs values. Period-aware output directories and PNG metadata use the `100us` tag. Override the priority and deadline tolerance with `RTSYN_RT_PRIORITY` and `RTSYN_DEADLINE_TOLERANCE_NS`. `RTSYN_RT_CPU` (or its compatibility alias `RTSYN_TEST_CPU`) currently pins only the `cyclictest` and `rtla` reference tools; it is recorded in the environment snapshot but is **not applied to the RTSyn engine thread**. Do not describe these RTSyn results as CPU-pinned. Ensure the physical loopback is wired and RTSyn realtime limits/device permissions are configured before starting.

During synapse warm-up, individual wakes beyond the configured deadline tolerance
are reported with their count, rate, and maximum lateness and shown in the
`deadline-events` plot; they do not by themselves fail the run. Warm-up still
fails if work reaches the period, a complete cycle is skipped, or telemetry is
dropped. The period remains fixed at 100 µs.

Before starting RTSyn, the script performs a physical preflight:

1. Applies the device calibration with `comedi_calibrate -v -f /dev/comedi0`.
2. Commands AO0 to 0 V and checks AI0.
3. Commands AO0 to +1 V and checks AI0.
4. Commands AO0 back to 0 V and checks AI0 again.
5. Aborts if the absolute loopback error exceeds the configured tolerance.

Only after this preflight succeeds does the test:

1. Start a clean RTSyn daemon.
2. Configure the runtime period, realtime priority, and explicit deadline tolerance.
3. Load the Hindmarsh–Rose plugin and Comedi device module from `bin/`.
4. Add both runtime nodes and obtain their actual node IDs.
5. Set `/dev/comedi0`, AO0 gain (default 1), and AI0 gain 1.
6. Connect Hindmarsh–Rose `vm_mv` to Comedi `analog_output_0`.
7. Activate AI0 acquisition through its telemetry subscription, without feeding it back into the neuron.
8. Subscribe the relevant ports and record them to CSV.
9. Run for the requested duration.
10. Stop the nodes and daemon and explicitly return AO0 to 0 V.

Cleanup is also registered for interruption or failure, so `Ctrl+C` stops the daemon and attempts to return AO0 to 0 V.

The source is `vm_mv` (port 3), sent with AO0 gain 1. Its numeric millivolt
waveform gives a volt-scale physical signal, avoiding the PCI-6024E ±10 V
range's roughly 4.88 mV quantization step overwhelming it. AI0 gain stays at 1,
so `comedi_ai0_v` records physical volts; the plotter compares it with
`hindmarsh_rose_vm_mv × 1`. The capture also records `comedi_ao0_input`, the
pre-gain value received at the AO0 port, to separate graph transfer from the
physical AO0-to-AI0 path. This applies to the repeated comparison and all-tests
runner, which call this script.

### Test configuration

The NI loopback test accepts its duration as the first positional argument and supports these environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `COMEDI_DEVICE` | `/dev/comedi0` | Comedi device path |
| `COMEDI_PREFLIGHT_TOLERANCE_V` | `0.15` | Maximum preflight AO-to-AI voltage error |
| `COMEDI_AO0_GAIN` | `1.0` | Gain applied to Hindmarsh–Rose `vm_mv` before AO0 |
| `RTSYN_PERIOD_NS` | `100000` | Required validation period in nanoseconds (fixed at 100 µs, 10 kHz) |
| `RTSYN_RT_PRIORITY` | `90` | Realtime thread priority |

Example:

```bash
COMEDI_DEVICE=/dev/comedi0 \
COMEDI_PREFLIGHT_TOLERANCE_V=0.05 \
RTSYN_PERIOD_NS=100000 \
RTSYN_RT_PRIORITY=90 \
./tests/loopback-performance/ni-pci-6024e.bash 60
```

### Output data

Successful NI loopback runs create captures in a period-tagged directory and include the period in the CSV basename, for example:

```text
data/loopback-performance/100us/ni-pci-6024e-hindmarsh-rose-YYYYMMDD-HHMMSS-100us.csv
```

The CSV contains the selected signal values plus per-cycle runtime measurements:

| Column | Source |
|---|---|
| `hindmarsh_rose_vm_mv` | Hindmarsh–Rose membrane output in millivolts, sent to AO0 |
| `comedi_ao0_input` | Value received at AO0 before Comedi gain and physical output |
| `comedi_ai0_v` | Voltage measured on Comedi AI0 after physical loopback |
| `period_ns` | Configured runtime period |
| `actual_period_ns` | Time from this cycle's start to completion of its scheduled sleep/wakeup |
| `latency_ns` | Compatibility alias of `wake_lateness_ns` in runtime telemetry (currently duplicates it) |
| `wake_lateness_ns` | Lateness relative to the scheduled wake deadline |
| `skipped_cycle_count` | Number of complete periods skipped due to lateness |
| `deadline_missed` | Whether wake lateness exceeded the configured deadline tolerance |
| `devices_read_ns` | Time spent reading devices in the cycle |
| `plugins_time_ns` | Time spent processing plugins in the cycle |
| `devices_write_ns` | Time spent writing devices in the cycle |
| `telemetry_dropped_events` | Cumulative telemetry event drops reported by the realtime producer (should remain 0) |

The supported CLI syntax for including timing fields is:

```text
rtsyn --no-gui telemetry csv <PATH> <COLUMNS>... --measurement-fields <FIELD>[,<FIELD>...]
```

The loopback plotter keeps all samples and breaks traces at missing values; its
tracking plot also reports approximate cycle coverage and the producer drop
counter when available. A flat AI0 trace is not treated as a plotting gap: it
means the captured input values are present but not following the commanded
output. RTSyn now propagates Comedi read/write failures as node errors instead
of silently exporting the previous cached sample.

For example, the NI test uses `--measurement-fields` to place the per-cycle
timing series in the same CSV as the signal columns. The separate
`rtsyn --no-gui measurements` command still returns only the latest timing
snapshot and is printed at the end as a convenient summary.

The engine advances an absolute deadline by one configured period each cycle.
Consequently, `actual_period_ns` is the interval from a cycle's start to the
completion of its sleep-until-deadline operation; it is not the current wake's
lateness and may differ from `period_ns` as wake lateness changes between
cycles. `wake_lateness_ns` is the non-negative offset from the scheduled
deadline. The measurement library initially computes `latency_ns` as the
absolute difference between configured and actual cycle period, but runtime
telemetry overwrites it with `wake_lateness_ns` for compatibility. Use
`wake_lateness_ns` for deadline timing and `skipped_cycle_count` to identify
whole periods of lateness.

### Monodirectional electrical-synapse performance

`tests/synapse-performance/monodirectional-electrical-synapse.bash` runs two
Hindmarsh--Rose neurons with a one-way electrical synapse. It uses all four
RTHybrid modules staged by `setup.bash`: burst analysis measures each voltage
range, amplitude-scale-offset maps the presynaptic range to the postsynaptic
range, and electrical-synapse produces `current_na`.

The computed current is sent through the same physical wiring as the ordinary
loopback test:

```text
CB-68LP 22 (AO0) -> 68 (AI0 / ACH0)
CB-68LP 55 (AOGND) -> 67 (AIGND)
```

AI0 is read in the device-first phase and connected only to the postsynaptic
neuron's `isyn_na`; no connection returns to the presynaptic neuron. AO0 is
written from the synapse current in the terminal device phase. The physical
device consequently forms the transport path, with one cycle of acquisition
delay, rather than a software-only synapse.

Run both signs of conductance (the default) or one mode:

```bash
bash ./tests/synapse-performance/monodirectional-electrical-synapse.bash 30 100000
bash ./tests/synapse-performance/monodirectional-electrical-synapse.bash 30 100000 excitatory
bash ./tests/synapse-performance/monodirectional-electrical-synapse.bash 30 100000 inhibitory
```

For the Hindmarsh--Rose equation used here, positive `g_us` contributes an
excitatory term while the scaled presynaptic voltage exceeds the postsynaptic
voltage; negative `g_us` reverses that instantaneous contribution. This is a
sign-of-coupling configuration, not a guarantee of globally excitatory or
inhibitory dynamics: verify phase/antiphase from each capture. The default
conductances are `+0.1` and `-0.1` micro-siemens. The earlier `±0.001 µS`
setting produced only a few pA in these captures and barely affected the
postsynaptic trace. The higher default is chosen to make coupling visible
while staying within the DAQ voltage range; it is a validation setting, not a
conductance value specified by the thesis. The CSV records presynaptic and
postsynaptic voltages, calculated synaptic current, acquired AI0 value and
per-cycle timing metrics.

The numerical transport convention defaults to `COMEDI_CURRENT_TO_AO_GAIN=10`
V/nA. AI0 automatically uses the reciprocal gain (0.1 nA/V), preserving the
current supplied to the neuron. The product of conductance and AO gain keeps
the expected AO amplitude similar to the earlier weak-coupling setup, while
the returned current delivered to the model is 100 times larger. This is not
a biological amplifier calibration.
The CSV column `returned_current_na` contains reconstructed current; old captures
with `comedi_ai0_v` remain physical volts. Plotting and summaries distinguish them.

The runner verifies all 12 connections, node processing states and requested
parameter values through a runtime snapshot. The API parameter table records
requests, so it is not independent hardware readback; the capture checks are
needed to verify actual signal behavior. It records a separate temporary
telemetry file while warming up the observers for six seconds with zero
conductance, then checks the latest runtime measurement against the requested
100 µs period before entering the long capture. This avoids running a full
capture if measured device/plugin work already exceeds the cycle budget. The
temporary warm-up file is removed after its timing and AI0-zero checks, so the
experiment CSV and its plots contain only live samples from the selected
conductance condition, without the held-value interval during configuration.
Before switching to that CSV, the runner waits for both API telemetry queues to
drain while the engine is paused, preventing queued warm-up measurements from
being written as unpaired rows at the start of the experiment capture.
`both` runs a zero-conductance control,
then positive and negative conductance, each from a clean daemon. `control` can
also be run separately. Snapshots and check reports are saved beside each CSV.

After recording, checks reject missing telemetry, dropped events, zero/under-resolved
current in coupled runs, flat returned current, commands approaching ±9 V, and
tracking RMSE above `COMEDI_TRACKING_TOLERANCE_V` (default 0.1 physical V). Tracking
allows the expected one-cycle AI-before-AO delay. These are signal-path sanity
checks, not proof of synchronization. Neither phase locking nor antiphase is
guaranteed; assess the voltage traces and current direction in the captures.
The known flat-input captures should fail these checks. No DC bias is silently
subtracted.

`COMEDI_CURRENT_TO_AO_GAIN`, `EXCITATORY_G_US`, `INHIBITORY_G_US`,
`SYNAPSE_PRE_E`, `SYNAPSE_POST_E`, and `SYNAPSE_WARMUP_SECONDS` (minimum 6) are
configurable. Increasing conductance may require reducing transport gain to
avoid clipping. Rebuild/stage with `setup.bash` when the installed modules lack
AI gain and offset parameters.

With the sibling source workspace available, run the hardware-free module check:

```bash
python3 tests/synapse-performance/run_software_check.py
```

It uses the staged neuron, observer, scaler and synapse modules with the native
runtime, testing zero and both conductance signs through a direct software
feedback path. It does not exercise Comedi or validate physical hardware.
The ordinary NI waveform runner also rejects flat or inaccurate AI captures
using the same post-capture tracking check.

## Local development build

To build and stage the sibling development repositories instead of cloning
remote sources, run from this validation repository:

```bash
bash setup-local.bash
```

The workspace defaults to the parent directory; override `RTSYN_WORKSPACE` if
needed. This builds the launcher with its local native dependencies and local
`rtsyn-ui`, Comedi, and the four RT hybrid modules used by the tests. It stages
the modules in `bin/`, installs the launcher under
`/usr/local/libexec/rtsyn-validation-tests/rtsyn`, restores its realtime
capabilities, and creates `bin/rtsyn` for the validation runners. Launcher
staging is implemented directly in `setup-local.bash`; there is no separate
staging script. Sudo is requested only to install the launcher and set its
capabilities. Setup does not run a hardware experiment or restart an existing
daemon. `bin/local-build-sha256.txt` records the prepared artifact hashes.

## Standalone diagnostics

The setup script also installs diagnostics that can be run without the RTSyn graph.

Analog AO0-to-AI0 loopback:

```bash
./bin/comedi-loopback /dev/comedi0 1 0 0 ground
./bin/comedi-loopback /dev/comedi0 0 0 0 ground
```

Digital DIO0-to-DIO1 loopback, using terminal 52 connected to terminal 17:

```bash
./bin/comedi-digital-loopback /dev/comedi0 0 1
```

Refer to the device document before changing wiring or selecting other channels.

## Adding tests

When adding a new validation test:

1. Add authoritative hardware references and pinouts under `devices/`.
2. Put the executable test under a descriptive `tests/<category>/` directory.
3. Add every required source repository and build artifact to `setup.bash`.
4. Resolve all paths relative to the repository, not the caller's working directory.
5. Validate hardware state before collecting data whenever practical.
6. Use traps to stop RTSyn and leave physical outputs in a safe state.
7. Store generated results under the matching `data/<category>/` directory.
8. Document the test and its configuration in this README.
