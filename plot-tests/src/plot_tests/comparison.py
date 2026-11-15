"""Paired run comparisons for alternating RTSyn validation campaigns."""

from __future__ import annotations

from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from plot_tests.data import load_dataset
from plot_tests.plots.common import COLORS, apply_style
from plot_tests.summary import summarize_datasets

METRICS = (
    "wake_lateness_p99_ns",
    "wake_lateness_p999_ns",
    "wake_lateness_max_ns",
    "deadline_missed_rate",
    "skipped_cycle_count_total",
    "loopback_rmse_v",
)


def calculate_test_integrity(summary: pd.DataFrame, test_name: str) -> pd.DataFrame:
    """Quantify execution-to-execution difference for one repeated test.

    ``test_integrity_percent`` is the mean absolute deviation from the
    metric's median, divided by its absolute median.  It is a difference
    measure: 0% means identical executions, so lower is better.  A percentage
    is deliberately not fabricated for a nonzero series with a zero median;
    its absolute range remains available instead.
    """

    rows: list[dict[str, object]] = []
    for metric in METRICS:
        if metric not in summary:
            continue
        values = summary[metric].dropna().to_numpy(dtype=float)
        if not len(values):
            continue
        median = float(np.median(values))
        absolute_range = float(values.max() - values.min())
        if median == 0.0:
            difference = 0.0 if absolute_range == 0.0 else float("nan")
        else:
            difference = float(np.mean(np.abs(values - median)) / abs(median) * 100.0)
        rows.append({
            "test": test_name, "metric": metric, "executions": len(values),
            "median": median, "absolute_range": absolute_range,
            "test_integrity_percent": difference,
        })
    return pd.DataFrame(rows)


def _resolve_capture(manifest: Path, capture: str) -> Path:
    path = Path(capture)
    if path.is_absolute() and path.is_file():
        return path
    for parent in (manifest.parent, *manifest.parents):
        candidate = parent / path
        if candidate.is_file():
            return candidate
    raise ValueError(f"capture listed in manifest does not exist: {capture}")


def load_manifest_runs(manifest: Path) -> pd.DataFrame:
    """Load and validate the alternating-run manifest produced by the runner."""

    try:
        runs = pd.read_csv(manifest, sep="\t")
    except (OSError, pd.errors.ParserError) as error:
        raise ValueError(f"could not read manifest {manifest}: {error}") from error
    required = {"run", "mode", "csv"}
    if missing := required.difference(runs.columns):
        raise ValueError(f"manifest is missing columns: {', '.join(sorted(missing))}")
    if len(runs) < 2 or len(runs) % 2:
        raise ValueError("manifest must contain an even number of runs")
    runs = runs.sort_values("run", kind="stable").reset_index(drop=True)
    runs["csv_path"] = [_resolve_capture(manifest, capture) for capture in runs["csv"]]
    runs["pair"] = np.arange(len(runs)) // 2 + 1
    for pair, group in runs.groupby("pair", sort=True):
        if set(group["mode"]) != {"no-device", "loopback"} or len(group) != 2:
            raise ValueError(f"pair {pair} must contain exactly one no-device and one loopback run")
    return runs


def paired_effects(manifest: Path, ao_gain: float | None = None) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Return one paired effect per metric and its between-pair summary."""

    runs = load_manifest_runs(manifest)
    summaries = summarize_datasets([load_dataset(path) for path in runs["csv_path"]], ao_gain)
    summaries["run"] = runs["run"].to_numpy()
    summaries["mode"] = runs["mode"].to_numpy()
    summaries["pair"] = runs["pair"].to_numpy()

    rows: list[dict[str, object]] = []
    for pair, group in summaries.groupby("pair", sort=True):
        baseline = group.loc[group["mode"] == "no-device"].iloc[0]
        loopback = group.loc[group["mode"] == "loopback"].iloc[0]
        for metric in METRICS:
            left, right = baseline[metric], loopback[metric]
            if pd.notna(left) and pd.notna(right):
                rows.append({"pair": pair, "metric": metric, "no_device": left,
                             "loopback": right, "effect_loopback_minus_no_device": right - left})
    effects = pd.DataFrame(rows)
    summaries_rows: list[dict[str, object]] = []
    rng = np.random.default_rng(20261115)
    for metric, group in effects.groupby("metric", sort=False):
        values = group["effect_loopback_minus_no_device"].to_numpy(dtype=float)
        samples = rng.choice(values, size=(10_000, len(values)), replace=True).mean(axis=1)
        summaries_rows.append({
            "metric": metric, "pairs": len(values), "effect_mean": values.mean(),
            "effect_median": np.median(values), "effect_std": values.std(ddof=1) if len(values) > 1 else np.nan,
            "effect_min": values.min(), "effect_max": values.max(),
            "mean_bootstrap_ci95_low": np.quantile(samples, 0.025),
            "mean_bootstrap_ci95_high": np.quantile(samples, 0.975),
        })
    return effects, pd.DataFrame(summaries_rows)


def paired_test_integrity(effects: pd.DataFrame) -> pd.DataFrame:
    """Calculate the integrity table independently for both paired modes."""

    rows: list[pd.DataFrame] = []
    for label, column in (("no-device", "no_device"), ("loopback", "loopback")):
        frame = effects.pivot(index="pair", columns="metric", values=column).reset_index(drop=True)
        rows.append(calculate_test_integrity(frame, label))
    return pd.concat(rows, ignore_index=True) if rows else pd.DataFrame()


def plot_paired_effects(effects: pd.DataFrame, output: Path) -> None:
    """Plot raw paired values; connected points preserve execution-level evidence."""

    metrics = list(effects["metric"].unique())
    if not metrics:
        raise ValueError("no metrics are available in both modes")
    apply_style()
    figure, axes = plt.subplots(len(metrics), 1, figsize=(9, 3.2 * len(metrics)), squeeze=False)
    for axis, metric in zip(axes[:, 0], metrics, strict=True):
        group = effects.loc[effects["metric"] == metric]
        for _, row in group.iterrows():
            axis.plot([0, 1], [row["no_device"], row["loopback"]], color=COLORS["slate"], alpha=0.65)
            axis.scatter([0, 1], [row["no_device"], row["loopback"]], color=[COLORS["blue"], COLORS["orange"]], zorder=2)
        axis.set_xticks([0, 1], ["No device", "Loopback"])
        axis.set_ylabel(metric)
        axis.set_title(f"Paired executions: {metric}")
    figure.tight_layout()
    figure.savefig(output, dpi=170, bbox_inches="tight")
    plt.close(figure)
