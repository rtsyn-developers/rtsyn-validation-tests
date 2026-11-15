"""Run-level, auditable summaries for RTSyn validation captures.

The unit of replication is a CSV capture, never the individual 10 kHz
cycles within it.  This module therefore emits one row per capture so the
thesis can report variability between independent executions.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from plot_tests.data import Dataset

SUMMARY_COLUMNS = (
    "capture",
    "rows",
    "unique_cycle_ids",
    "cycle_id_gaps",
    "telemetry_dropped_events_max",
    "deadline_missed_count",
    "deadline_missed_rate",
    "skipped_cycle_count_total",
    "wake_lateness_p50_ns",
    "wake_lateness_p95_ns",
    "wake_lateness_p99_ns",
    "wake_lateness_p999_ns",
    "wake_lateness_max_ns",
    "loopback_paired_samples",
    "loopback_missing_source",
    "loopback_missing_measured",
    "loopback_bias_v",
    "loopback_mae_v",
    "loopback_rmse_v",
    "loopback_bias_na",
    "loopback_mae_na",
    "loopback_rmse_na",
)


def _quantile(frame: pd.DataFrame, column: str, quantile: float) -> float:
    if column not in frame:
        return float("nan")
    values = frame[column].dropna().to_numpy(dtype=float)
    return float(np.quantile(values, quantile)) if values.size else float("nan")


def summarize_dataset(dataset: Dataset, ao_gain: float | None = None) -> dict[str, object]:
    """Return one reproducible statistics row for a single CSV capture."""

    frame = dataset.frame
    result: dict[str, object] = {column: float("nan") for column in SUMMARY_COLUMNS}
    result["capture"] = dataset.path.name
    result["rows"] = len(frame)

    if "cycle_id" in frame:
        cycles = frame["cycle_id"].dropna().astype("int64")
        unique = cycles.nunique()
        result["unique_cycle_ids"] = unique
        result["cycle_id_gaps"] = int(cycles.max() - cycles.min() + 1 - unique) if unique else 0
    if "telemetry_dropped_events" in frame:
        result["telemetry_dropped_events_max"] = int(frame["telemetry_dropped_events"].max())
    if "deadline_missed" in frame:
        flags = frame["deadline_missed"].dropna().astype(bool)
        result["deadline_missed_count"] = int(flags.sum())
        result["deadline_missed_rate"] = float(flags.mean()) if len(flags) else float("nan")
    if "skipped_cycle_count" in frame:
        result["skipped_cycle_count_total"] = int(frame["skipped_cycle_count"].fillna(0).sum())

    for quantile, name in ((0.5, "p50"), (0.95, "p95"), (0.99, "p99"), (0.999, "p999")):
        result[f"wake_lateness_{name}_ns"] = _quantile(frame, "wake_lateness_ns", quantile)
    result["wake_lateness_max_ns"] = _quantile(frame, "wake_lateness_ns", 1.0)

    if dataset.loopback is not None:
        source = frame[dataset.loopback.source_column]
        measured = frame[dataset.loopback.measured_column]
        gain = ao_gain if ao_gain is not None else (
            1000.0 if dataset.loopback.source_column == "hindmarsh_rose_vm_v" else 1.0
        )
        sent = source * gain
        error = (measured - sent).dropna()
        result["loopback_paired_samples"] = len(error)
        result["loopback_missing_source"] = int(sent.isna().sum())
        result["loopback_missing_measured"] = int(measured.isna().sum())
        unit = "na" if dataset.loopback.measured_column == "returned_current_na" else "v"
        if len(error):
            result[f"loopback_bias_{unit}"] = float(error.mean())
            result[f"loopback_mae_{unit}"] = float(error.abs().mean())
            result[f"loopback_rmse_{unit}"] = float(np.sqrt(np.mean(np.square(error))))
    return result


def summarize_datasets(datasets: list[Dataset], ao_gain: float | None = None) -> pd.DataFrame:
    """Create a table whose rows remain the independent experimental runs."""

    return pd.DataFrame([summarize_dataset(dataset, ao_gain) for dataset in datasets], columns=SUMMARY_COLUMNS)
