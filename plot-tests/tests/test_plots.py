from pathlib import Path

import numpy as np
import pandas as pd

from plot_tests.data import load_dataset
from plot_tests.plots import loopback as loopback_module
from plot_tests.plots.loopback import generate_loopback_plots
from plot_tests.plots.performance import generate_performance_plots


def test_timing_and_loopback_figures_are_created(tmp_path: Path) -> None:
    csv_path = tmp_path / "run.csv"
    pd.DataFrame(
        {
            "cycle_id": [1, 2, 3, 4],
            "timestamp_ns": [1_000_000_000, 1_001_000_000, 1_002_000_000, 1_003_000_000],
            "period_ns": [1_000_000] * 4,
            "actual_period_ns": [999_000, 1_001_000, 1_000_000, 1_005_000],
            "wake_lateness_ns": [100, 300, 200, 500],
            "devices_read_ns": [10, 11, 10, 12],
            "plugins_time_ns": [100, 105, 95, 110],
            "devices_write_ns": [20, 18, 22, 21],
            "deadline_missed": [0, 0, 1, 0],
            "hindmarsh_rose_vm_v": [0.0, 0.001, 0.002, 0.003],
            "comedi_ai0_v": [0.0, 1.0, 2.0, 3.0],
        }
    ).to_csv(csv_path, index=False)
    dataset = load_dataset(csv_path)

    performance = generate_performance_plots(
        dataset, tmp_path, ["png"], suffix="run-03-loopback", period_ns=100_000
    )
    loopback = generate_loopback_plots(
        dataset, tmp_path, ["png"], ao_gain=1000, suffix="run-03-loopback", period_ns=100_000
    )

    assert {path.stem for path in performance} == {
        "period-jitter__run-03-loopback__100us",
        "wake-lateness__run-03-loopback__100us",
        "wake-lateness-distribution__run-03-loopback__100us",
        "cycle-work__run-03-loopback__100us",
        "deadline-events__run-03-loopback__100us",
    }
    assert {path.stem for path in loopback} == {
        "loopback-tracking__run-03-loopback__100us",
        "loopback-transfer__run-03-loopback__100us",
        "loopback-tracking-zoom__run-03-loopback__100us",
        "loopback-error__run-03-loopback__100us",
    }
    assert all(path.is_file() and path.stat().st_size > 0 for path in performance + loopback)


def test_generic_performance_csv_does_not_create_loopback_plots(tmp_path: Path) -> None:
    csv_path = tmp_path / "timing.csv"
    pd.DataFrame({"cycle_id": [1, 2], "latency_ns": [5, 9]}).to_csv(csv_path, index=False)
    dataset = load_dataset(csv_path)

    generated = generate_loopback_plots(dataset, tmp_path, ["png"], ao_gain=None)

    assert generated == []


def test_loopback_time_series_preserve_gaps_and_all_samples(tmp_path: Path, monkeypatch) -> None:
    csv_path = tmp_path / "sparse.csv"
    pd.DataFrame(
        {
            "cycle_id": [1, 2, 3, 4],
            "timestamp_ns": [1_000, 2_000, 3_000, 4_000],
            "hindmarsh_rose_vm_v": [0.0, np.nan, 0.002, 0.003],
            "comedi_ai0_v": [0.0, 1.0, np.nan, 3.0],
        }
    ).to_csv(csv_path, index=False)
    dataset = load_dataset(csv_path)
    plotted_lines: list[list[float]] = []

    def capture(figure, output_dir, stem, formats, suffix=None, period_ns=None):
        if stem == "loopback-tracking":
            plotted_lines.extend([line.get_ydata().tolist() for line in figure.axes[0].lines[:2]])
        return []

    monkeypatch.setattr(loopback_module, "save_figure", capture)
    generate_loopback_plots(dataset, tmp_path, ["png"], ao_gain=1.0)

    assert len(plotted_lines) == 2
    assert len(plotted_lines[0]) == 4
    assert np.isnan(plotted_lines[0][1])
    assert np.isnan(plotted_lines[1][2])


def test_zoom_uses_same_axis_and_preserves_measured_offset(tmp_path, monkeypatch):
    path = tmp_path / "offset.csv"
    pd.DataFrame({"timestamp_ns": np.arange(5) * 1_000_000_000,
                  "sent_v": [0, 1, 2, 3, 4], "measured_v": [0.05, 1.05, 2.05, 3.05, 4.05]}).to_csv(path, index=False)
    captured = {}
    def capture(figure, output_dir, stem, *args):
        if stem == "loopback-tracking-zoom":
            assert len(figure.axes) == 1
            captured["lines"] = [(line.get_xdata(), line.get_ydata()) for line in figure.axes[0].lines]
        plt.close(figure)
        return []
    import matplotlib.pyplot as plt
    monkeypatch.setattr(loopback_module, "save_figure", capture)
    generate_loopback_plots(load_dataset(path), tmp_path, ["png"], None, zoom_start=1, zoom_duration=2)
    lines = captured["lines"]
    np.testing.assert_array_equal(lines[0][0], [1, 2, 3])
    np.testing.assert_allclose(lines[1][1] - lines[0][1], 0.05)


def test_neuron_overlay_preserves_polarity_and_defaults_to_twenty_seconds(tmp_path, monkeypatch):
    import matplotlib.pyplot as plt
    path = tmp_path / "synapse.csv"
    pd.DataFrame({"timestamp_ns": np.arange(61) * 1_000_000_000,
                  "pre_vm_mv": [-1.0] * 30 + [2.0] + [-1.0] * 30,
                  "post_vm_v": [-0.001] * 30 + [0.002] + [-0.001] * 30,
                  "synaptic_current_na": [0.0] * 61,
                  "comedi_ai0_v": [0.05] * 61}).to_csv(path, index=False)
    captured = {}
    def capture(figure, output_dir, stem, *args):
        if stem == "neuron-voltages-zoom":
            assert len(figure.axes) == 1
            captured["lines"] = [(line.get_xdata(), line.get_ydata()) for line in figure.axes[0].lines]
        plt.close(figure)
        return []
    monkeypatch.setattr(loopback_module, "save_figure", capture)
    generate_loopback_plots(load_dataset(path), tmp_path, ["png"], None)
    lines = captured["lines"]
    assert lines[0][0][0] == 20
    assert lines[0][0][-1] == 40
    np.testing.assert_allclose(lines[0][1], lines[1][1])
    assert lines[0][1][10] == 2.0
    assert lines[0][1][9] == -1.0


def test_returned_current_plot_is_labelled_na(tmp_path, monkeypatch):
    import matplotlib.pyplot as plt
    path = tmp_path / 'current.csv'
    pd.DataFrame({'cycle_id':[1,2], 'synaptic_current_na':[.001,.002],
                  'returned_current_na':[.0011,.0021]}).to_csv(path,index=False)
    checked = []
    def capture(figure, output_dir, stem, *args):
        if stem == 'loopback-tracking':
            assert figure.axes[0].get_ylabel() == 'Current (nA)'
            np.testing.assert_allclose(figure.axes[0].lines[0].get_ydata(), [.001,.002])
            checked.append(True)
        plt.close(figure)
        return []
    monkeypatch.setattr(loopback_module, 'save_figure', capture)
    generate_loopback_plots(load_dataset(path),tmp_path,['png'],None)
    assert checked
