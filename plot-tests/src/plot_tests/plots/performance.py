"""Runtime timing plots shared across validation test types."""

from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from plot_tests.data import Dataset, x_axis
from plot_tests.plots.common import COLORS, add_empty_note, apply_style, plot_frame, save_figure


def generate_performance_plots(
    dataset: Dataset,
    output_dir: Path,
    formats: Iterable[str],
    suffix: str | None = None,
    period_ns: int | None = None,
) -> list[Path]:
    frame = dataset.frame
    x_values, x_label = x_axis(frame)
    plotted = plot_frame(frame, x_values)
    generated: list[Path] = []
    apply_style()

    if {"period_ns", "actual_period_ns"}.issubset(frame.columns):
        figure, (period_axis, error_axis) = plt.subplots(
            2, 1, figsize=(12, 7), sharex=True, gridspec_kw={"height_ratios": [2, 1]}
        )
        valid = plotted[["_plot_x", "period_ns", "actual_period_ns"]].dropna()
        if valid.empty:
            add_empty_note(period_axis)
            add_empty_note(error_axis)
        else:
            period_axis.plot(valid["_plot_x"], valid["period_ns"], color=COLORS["slate"], label="Target period")
            period_axis.plot(valid["_plot_x"], valid["actual_period_ns"], color=COLORS["blue"], label="Actual period")
            error_axis.plot(
                valid["_plot_x"],
                valid["actual_period_ns"] - valid["period_ns"],
                color=COLORS["orange"],
                label="Actual − target",
            )
            error_axis.axhline(0, color=COLORS["slate"], linewidth=0.8)
        period_axis.set_ylabel("Period (ns)")
        period_axis.set_title("Runtime period and cycle-to-cycle deviation")
        period_axis.legend(loc="upper right")
        error_axis.set_ylabel("Deviation (ns)")
        error_axis.set_xlabel(x_label)
        error_axis.legend(loc="upper right")
        generated += save_figure(figure, output_dir, "period-jitter", formats, suffix, period_ns)

    lateness_column = "wake_lateness_ns" if "wake_lateness_ns" in frame else (
        "latency_ns" if "latency_ns" in frame else None
    )
    if lateness_column:
        figure, axis = plt.subplots(figsize=(12, 4.5))
        valid = plotted[["_plot_x", lateness_column]].dropna()
        if valid.empty:
            add_empty_note(axis)
        else:
            axis.plot(valid["_plot_x"], valid[lateness_column], color=COLORS["purple"], alpha=0.9)
        axis.set_title(f"Wake lateness ({lateness_column})")
        axis.set_xlabel(x_label)
        axis.set_ylabel("Lateness (ns)")
        generated += save_figure(figure, output_dir, "wake-lateness", formats, suffix, period_ns)

        values = frame[lateness_column].dropna().to_numpy(dtype=float)
        if values.size:
            figure, axis = plt.subplots(figsize=(9, 5))
            axis.hist(values, bins="fd", color=COLORS["blue"], alpha=0.85, edgecolor="white")
            quantiles = np.quantile(values, [0.5, 0.95, 0.99, 0.999])
            labels = ("p50", "p95", "p99", "p99.9")
            for quantile, label, color in zip(quantiles, labels, (COLORS["green"], COLORS["orange"], COLORS["red"], COLORS["purple"]), strict=True):
                axis.axvline(quantile, color=color, linestyle="--", label=f"{label}: {quantile:,.0f} ns")
            axis.set_title("Wake-lateness distribution")
            axis.set_xlabel("Lateness (ns)")
            axis.set_ylabel("Cycles")
            axis.legend()
            generated += save_figure(figure, output_dir, "wake-lateness-distribution", formats, suffix, period_ns)

    work_columns = [
        ("devices_read_ns", "Device reads", COLORS["cyan"]),
        ("plugins_time_ns", "Plugin processing", COLORS["blue"]),
        ("devices_write_ns", "Device writes", COLORS["orange"]),
    ]
    available_work = [(column, label, color) for column, label, color in work_columns if column in frame]
    if available_work:
        figure, axis = plt.subplots(figsize=(12, 5))
        for column, label, color in available_work:
            valid = plotted[["_plot_x", column]].dropna()
            if not valid.empty:
                axis.plot(valid["_plot_x"], valid[column], label=label, color=color)
        axis.set_title("Runtime work by subsystem")
        axis.set_xlabel(x_label)
        axis.set_ylabel("Time (ns)")
        axis.legend(loc="upper right")
        generated += save_figure(figure, output_dir, "cycle-work", formats, suffix, period_ns)

    event_columns = [column for column in ("deadline_missed",) if column in frame]
    if event_columns:
        figure, axis = plt.subplots(figsize=(12, 3.8))
        tick_positions: list[float] = []
        tick_labels: list[str] = []
        for index, (column, color) in enumerate(
            zip(event_columns, (COLORS["red"], COLORS["orange"]), strict=False)
        ):
            valid = plotted[["_plot_x", column]].dropna()
            if not valid.empty:
                positions = valid[column].astype(float).clip(0, 1) + index * 1.3
                axis.scatter(valid["_plot_x"], positions, s=5, alpha=0.7, label=column, color=color)
                tick_positions.extend([index * 1.3, index * 1.3 + 1])
                tick_labels.extend([f"{column}: false", f"{column}: true"])
        axis.set_yticks(tick_positions, tick_labels)
        axis.set_title("Missed-cycle and deadline flags")
        axis.set_xlabel(x_label)
        axis.set_ylabel("Flag")
        axis.legend(loc="upper right")
        generated += save_figure(figure, output_dir, "deadline-events", formats, suffix, period_ns)

    return generated
