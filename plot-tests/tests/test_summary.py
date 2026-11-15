from pathlib import Path

import pandas as pd
import pytest

from plot_tests.data import load_dataset
from plot_tests.summary import summarize_dataset


def test_summary_reports_integrity_timing_and_loopback_error(tmp_path: Path) -> None:
    path = tmp_path / "capture.csv"
    pd.DataFrame(
        {
            "cycle_id": [10, 11, 13],
            "hindmarsh_rose_vm_v": [0.001, 0.002, 0.003],
            "comedi_ai0_v": [1.1, 1.8, None],
            "wake_lateness_ns": [10, 20, 30],
            "deadline_missed": [0, 1, 0],
            "skipped_cycle_count": [0, 2, 0],
            "telemetry_dropped_events": [0, 0, 4],
        }
    ).to_csv(path, index=False)

    summary = summarize_dataset(load_dataset(path))

    assert summary["unique_cycle_ids"] == 3
    assert summary["cycle_id_gaps"] == 1
    assert summary["telemetry_dropped_events_max"] == 4
    assert summary["deadline_missed_count"] == 1
    assert summary["skipped_cycle_count_total"] == 2
    assert summary["wake_lateness_max_ns"] == 30
    assert summary["loopback_paired_samples"] == 2
    assert summary["loopback_bias_v"] == pytest.approx(-0.05)
    assert summary["loopback_mae_v"] == pytest.approx(0.15)


def test_returned_current_metrics_use_na_not_volts(tmp_path):
    path = tmp_path / 'current.csv'
    pd.DataFrame({'cycle_id':[1,2], 'synaptic_current_na':[.001,.002],
                  'returned_current_na':[.0011,.0021]}).to_csv(path,index=False)
    result = summarize_dataset(load_dataset(path))
    assert result['loopback_bias_na'] == pytest.approx(.0001)
    assert pd.isna(result['loopback_bias_v'])
