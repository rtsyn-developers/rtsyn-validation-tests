"""CSV loading, validation, and test-shape detection."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import pandas as pd

PERFORMANCE_COLUMNS = (
    "period_ns",
    "actual_period_ns",
    "latency_ns",
    "wake_lateness_ns",
    "skipped_cycle_count",
    "deadline_missed",
    "devices_read_ns",
    "plugins_time_ns",
    "devices_write_ns",
    "telemetry_dropped_events",
)


@dataclass(frozen=True)
class LoopbackSignals:
    """Names of a sent/source signal and its measured loopback input."""

    source_column: str
    measured_column: str


@dataclass(frozen=True)
class Dataset:
    """Validated input CSV and detected columns used by the plotters."""

    path: Path
    frame: pd.DataFrame
    loopback: LoopbackSignals | None

    @property
    def available_performance_columns(self) -> tuple[str, ...]:
        return tuple(column for column in PERFORMANCE_COLUMNS if column in self.frame.columns)


def load_dataset(path: Path) -> Dataset:
    """Read a validation CSV and normalize known numeric columns."""

    try:
        frame = pd.read_csv(path, low_memory=False)
    except (OSError, pd.errors.ParserError, UnicodeDecodeError) as error:
        raise ValueError(f"could not read CSV {path}: {error}") from error

    if frame.empty:
        raise ValueError(f"CSV has a header but no data rows: {path}")
    frame.columns = [str(column).strip() for column in frame.columns]
    if "cycle_id" not in frame.columns and "timestamp_ns" not in frame.columns:
        raise ValueError("expected at least one x-axis column: cycle_id or timestamp_ns")

    numeric_columns = set(PERFORMANCE_COLUMNS)
    numeric_columns.update({"cycle_id", "timestamp_ns"})
    numeric_columns.update(
        column
        for column in frame.columns
        if column.endswith(("_v", "_na", "_mv")) or column.startswith(("analog_output_", "analog_input_"))
    )
    for column in numeric_columns.intersection(frame.columns):
        frame[column] = pd.to_numeric(frame[column], errors="coerce")

    frame = frame.dropna(how="all", subset=[column for column in ("cycle_id", "timestamp_ns") if column in frame])
    if frame.empty:
        raise ValueError("CSV contains no rows with a cycle_id or timestamp_ns")

    # RTSyn emits separate telemetry rows for port values and cycle
    # measurements. Coalesce partial rows for the same cycle before plotting
    # or summarizing, so signals with different event types share one sample
    # row and do not appear as sparse, truncated traces.
    if "cycle_id" in frame.columns:
        has_cycle = frame["cycle_id"].notna()
        if has_cycle.any():
            cycle_rows = frame.loc[has_cycle].groupby(
                "cycle_id", as_index=False, sort=False
            ).first()
            no_cycle_rows = frame.loc[~has_cycle]
            if no_cycle_rows.empty:
                frame = cycle_rows
            else:
                frame = pd.concat([cycle_rows, no_cycle_rows], ignore_index=True)
                if "timestamp_ns" in frame.columns:
                    frame = frame.sort_values("timestamp_ns", kind="stable")
                frame = frame.reset_index(drop=True)

    loopback = _detect_loopback(frame.columns)
    return Dataset(path=path, frame=frame, loopback=loopback)


def _detect_loopback(columns: pd.Index) -> LoopbackSignals | None:
    names = set(columns)
    known_pairs = (
        ("hindmarsh_rose_vm_mv", "comedi_ai0_v"),
        ("hindmarsh_rose_vm_v", "comedi_ai0_v"),
        ("synaptic_current_na", "returned_current_na"),
        ("synaptic_current_na", "comedi_ai0_v"),
        ("analog_output_0", "analog_input_0"),
        ("comedi_ao0_v", "comedi_ai0_v"),
        ("sent_v", "measured_v"),
        ("write_v", "read_v"),
    )
    for source, measured in known_pairs:
        if source in names and measured in names:
            return LoopbackSignals(source, measured)

    output_columns = sorted(column for column in names if column.startswith("analog_output_"))
    input_columns = sorted(column for column in names if column.startswith("analog_input_"))
    if output_columns and input_columns:
        return LoopbackSignals(output_columns[0], input_columns[0])
    return None


def x_axis(frame: pd.DataFrame) -> tuple[pd.Series, str]:
    """Use elapsed seconds when timestamps exist; otherwise use cycle IDs."""

    if "timestamp_ns" in frame.columns and frame["timestamp_ns"].notna().any():
        timestamps = frame["timestamp_ns"]
        origin = timestamps.dropna().iloc[0]
        return (timestamps - origin) / 1_000_000_000.0, "Elapsed time (s)"
    return frame["cycle_id"], "Cycle"
