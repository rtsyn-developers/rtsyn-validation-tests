"""Shared plotting helpers and visual defaults."""

from __future__ import annotations

import re
from collections.abc import Iterable
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import pandas as pd

COLORS = {
    "blue": "#356ae6",
    "cyan": "#13a6a6",
    "orange": "#e58a26",
    "red": "#d84a4a",
    "purple": "#805ad5",
    "green": "#3a9d5d",
    "slate": "#64748b",
}


def period_tag(period_ns: int) -> str:
    if period_ns % 1_000_000 == 0:
        return f"{period_ns // 1_000_000}ms"
    if period_ns % 1_000 == 0:
        return f"{period_ns // 1_000}us"
    return f"{period_ns}ns"


def period_description(period_ns: int) -> str:
    if period_ns % 1_000_000 == 0:
        period = f"{period_ns / 1_000_000:g} ms"
    elif period_ns % 1_000 == 0:
        period = f"{period_ns / 1_000:g} µs"
    else:
        period = f"{period_ns:g} ns"
    frequency_hz = 1_000_000_000 / period_ns
    frequency = f"{frequency_hz / 1000:g} kHz" if frequency_hz >= 1000 else f"{frequency_hz:g} Hz"
    return f"{period} period / {frequency}"


def apply_style() -> None:
    plt.style.use("seaborn-v0_8-whitegrid")
    plt.rcParams.update(
        {
            "figure.facecolor": "white",
            "axes.facecolor": "#fbfcfe",
            "axes.edgecolor": "#d8dee9",
            "axes.titleweight": "semibold",
            "axes.labelcolor": "#334155",
            "grid.color": "#e5eaf1",
            "grid.linewidth": 0.8,
            "font.size": 10,
            "legend.frameon": False,
            "lines.linewidth": 1.15,
        }
    )


def save_figure(
    figure: plt.Figure,
    output_dir: Path,
    stem: str,
    formats: Iterable[str],
    suffix: str | None = None,
    period_ns: int | None = None,
) -> list[Path]:
    title_parts: list[str] = []
    if suffix:
        title_parts.append(suffix)
    if period_ns:
        title_parts.append(period_tag(period_ns))
    if title_parts:
        title = " • ".join(title_parts)
        if period_ns:
            title += f" — {period_description(period_ns)}"
        figure.suptitle(title, fontsize=10, color=COLORS["slate"])
        figure.tight_layout(rect=(0, 0, 1, 0.95))
    paths: list[Path] = []
    filename_suffix = suffix
    if period_ns:
        filename_suffix = f"{suffix}__{period_tag(period_ns)}" if suffix else period_tag(period_ns)
    for output_format in formats:
        safe_suffix = (
            re.sub(r"[^A-Za-z0-9._-]+", "-", filename_suffix).strip("-._")
            if filename_suffix
            else ""
        )
        filename_stem = f"{stem}__{safe_suffix}" if safe_suffix else stem
        path = output_dir / f"{filename_stem}.{output_format}"
        figure.savefig(path, dpi=170, bbox_inches="tight", format=output_format)
        paths.append(path)
    plt.close(figure)
    return paths


def plot_frame(frame: pd.DataFrame, x_values: pd.Series, max_points: int = 20_000) -> pd.DataFrame:
    plotted = frame.copy()
    plotted["_plot_x"] = x_values
    if len(plotted) > max_points:
        stride = max(1, len(plotted) // max_points)
        plotted = plotted.iloc[::stride]
    return plotted


def add_empty_note(axis: plt.Axes, message: str = "No samples available") -> None:
    axis.text(0.5, 0.5, message, transform=axis.transAxes, ha="center", va="center", color=COLORS["slate"])
