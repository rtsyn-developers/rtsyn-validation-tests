"""Plots for source/send signals and physical loopback measurements."""

from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from plot_tests.data import Dataset, x_axis
from plot_tests.plots.common import COLORS, add_empty_note, apply_style, save_figure


def generate_loopback_plots(
    dataset: Dataset,
    output_dir: Path,
    formats: Iterable[str],
    ao_gain: float | None,
    suffix: str | None = None,
    period_ns: int | None = None,
    zoom_start: float | None = None,
    zoom_duration: float = 20.0,
) -> list[Path]:
    signals = dataset.loopback
    if signals is None:
        return []

    current_units = signals.measured_column == "returned_current_na"
    unit = "nA" if current_units else "V"
    source_label = "Synaptic current sent" if current_units else "AO0 commanded / sent"
    measured_label = "AI0 reconstructed current" if current_units else "AI0 measured"
    gain = ao_gain
    if gain is None:
        gain = 1000.0 if signals.source_column == "hindmarsh_rose_vm_v" else 1.0

    frame = dataset.frame
    x_values, x_label = x_axis(frame)
    # Keep the full-rate samples. Uniform stride decimation hid short spikes and
    # made telemetry loss look like clean, continuous data. NaNs are retained in
    # the time-series traces so matplotlib renders real gaps as breaks.
    valid = frame[[signals.source_column, signals.measured_column]].copy()
    valid["_plot_x"] = x_values
    valid = valid.sort_values("_plot_x", kind="stable")
    valid["sent_v"] = valid[signals.source_column] * gain
    valid["measured_v"] = valid[signals.measured_column]
    valid["error_v"] = valid["measured_v"] - valid["sent_v"]
    paired = valid.dropna(subset=["sent_v", "measured_v"])
    source_missing = int(valid["sent_v"].isna().sum())
    measured_missing = int(valid["measured_v"].isna().sum())
    coverage_note = ""
    if "period_ns" in frame and frame["period_ns"].notna().any():
        period = float(frame["period_ns"].dropna().median())
        elapsed_ns = float((valid["_plot_x"].max() - valid["_plot_x"].min()) * 1_000_000_000)
        expected_cycles = max(1, round(elapsed_ns / period) + 1) if period > 0 else 0
        observed_cycles = int(frame["cycle_id"].nunique()) if "cycle_id" in frame else len(frame)
        if expected_cycles:
            coverage_note = f"  cycles≈{observed_cycles:,}/{expected_cycles:,} ({observed_cycles / expected_cycles:.1%})"
    dropped_note = ""
    if "telemetry_dropped_events" in frame:
        drops = frame["telemetry_dropped_events"].dropna()
        if not drops.empty:
            dropped_note = f"  event drops={int(drops.max()):,}"

    if not np.isfinite(zoom_duration) or zoom_duration <= 0:
        raise ValueError("zoom_duration must be finite and positive")
    formats = tuple(formats)
    apply_style()
    generated = []
    note = (f"Paired: {len(paired):,}   Missing send: {source_missing:,}   Missing AI: {measured_missing:,}"
            f"{coverage_note}{dropped_note}")
    low_x, high_x = float(valid["_plot_x"].min()), float(valid["_plot_x"].max())
    start = max(low_x, (low_x + high_x - zoom_duration) / 2) if zoom_start is None else zoom_start
    end = min(high_x, start + zoom_duration)
    if not np.isfinite(start) or start > high_x or start + zoom_duration < low_x:
        raise ValueError("Zoom window does not intersect the capture")
    zoom = valid[valid["_plot_x"].between(start, end)]
    for stem, samples, title in (
        ("loopback-tracking", valid, "Loopback · sent and measured"),
        ("loopback-tracking-zoom", zoom, f"Loopback · zoom {start:g}–{end:g}"),
    ):
        figure, axis = plt.subplots(figsize=(12, 5))
        if samples.empty:
            add_empty_note(axis, "No samples in this window")
        else:
            # One shared voltage axis, same polarity and time origin. No offset
            # removal or independent autoscaling that could conceal a mismatch.
            axis.plot(samples["_plot_x"], samples["sent_v"], color=COLORS["blue"],
                      linewidth=1.6, label=source_label, zorder=3)
            axis.plot(samples["_plot_x"], samples["measured_v"], color=COLORS["orange"],
                      linewidth=1.0, alpha=0.85, linestyle="--", label=measured_label, zorder=4)
            axis.legend(loc="upper center", bbox_to_anchor=(0.5, 1.02), ncol=2)
        axis.set_title(title, pad=32)
        axis.set_ylabel(f"Current ({unit})" if current_units else "Voltage (V)")
        axis.set_xlabel(x_label)
        axis.margins(x=0.01, y=0.15)
        figure.text(0.5, 0.01, note, ha="center", fontsize=8, color=COLORS["slate"])
        generated += save_figure(figure, output_dir, stem, formats, suffix, period_ns)

    figure, axis = plt.subplots(figsize=(12, 4))
    axis.plot(valid["_plot_x"], valid["error_v"], color=COLORS["red"], alpha=0.85)
    axis.axhline(0, color=COLORS["slate"], linewidth=0.8)
    axis.set_title("Loopback error · measured minus sent")
    axis.set_xlabel(x_label)
    axis.set_ylabel(f"AI0 − sent ({unit})")
    generated += save_figure(figure, output_dir, "loopback-error", formats, suffix, period_ns)

    # Synapse captures also contain the actual neuron voltage outputs. They
    # are distinct from the synaptic-current signal transported through AO0.
    if {"pre_vm_mv", "post_vm_v"}.issubset(frame.columns):
        neurons = frame[["pre_vm_mv", "post_vm_v"]].copy()
        neurons["_plot_x"] = x_values
        neurons = neurons.sort_values("_plot_x", kind="stable")
        for stem, samples, title in (
            ("neuron-voltages", neurons, "Neuron voltage outputs · pre and post"),
            ("neuron-voltages-zoom", neurons[neurons["_plot_x"].between(start, end)],
             f"Neuron voltage outputs · zoom {start:g}–{end:g}"),
        ):
            figure, axis = plt.subplots(figsize=(12, 5))
            axis.plot(samples["_plot_x"], samples["pre_vm_mv"],
                      color=COLORS["blue"], label="Pre neuron", linewidth=1.3)
            axis.plot(samples["_plot_x"], samples["post_vm_v"] * 1000.0,
                      color=COLORS["orange"], label="Post neuron", linewidth=1.0, alpha=0.8)
            axis.set_title(title, pad=32)
            axis.set_ylabel("Membrane voltage (mV)")
            axis.set_xlabel(x_label)
            axis.legend(loc="upper center", bbox_to_anchor=(0.5, 1.02), ncol=2)
            axis.margins(x=0.01, y=0.15)
            generated += save_figure(figure, output_dir, stem, formats, suffix, period_ns)

    if not paired.empty:
        figure, axis = plt.subplots(figsize=(6.5, 6))
        axis.scatter(
            paired["sent_v"],
            paired["measured_v"],
            s=5,
            alpha=0.22,
            color=COLORS["blue"],
            rasterized=True,
        )
        low = float(min(paired["sent_v"].min(), paired["measured_v"].min()))
        high = float(max(paired["sent_v"].max(), paired["measured_v"].max()))
        if np.isclose(low, high):
            low -= 0.01
            high += 0.01
        axis.plot([low, high], [low, high], color=COLORS["red"], linestyle="--", label="Ideal 1:1")
        axis.set_xlim(low, high)
        axis.set_ylim(low, high)
        axis.set_aspect("equal", adjustable="box")
        axis.set_title("Loopback transfer")
        axis.set_xlabel(f"{source_label} ({unit})")
        axis.set_ylabel(f"{measured_label} ({unit})")
        axis.legend()
        generated += save_figure(
            figure, output_dir, "loopback-transfer", formats, suffix, period_ns
        )

    return generated
