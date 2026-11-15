from pathlib import Path

import pandas as pd
import pytest

from plot_tests.data import load_dataset


def test_load_detects_loopback_and_preserves_sparse_values(tmp_path: Path) -> None:
    csv_path = tmp_path / "loopback.csv"
    csv_path.write_text(
        "cycle_id,timestamp_ns,hindmarsh_rose_vm_v,comedi_ai0_v,wake_lateness_ns\n"
        "1,1000000000,0.01,10,4\n"
        "2,1001000000,,10.5,8\n"
        "3,1002000000,0.02,,12\n",
        encoding="utf-8",
    )

    dataset = load_dataset(csv_path)

    assert dataset.loopback is not None
    assert dataset.loopback.source_column == "hindmarsh_rose_vm_v"
    assert dataset.loopback.measured_column == "comedi_ai0_v"
    assert pd.isna(dataset.frame.loc[1, "hindmarsh_rose_vm_v"])
    assert dataset.available_performance_columns == ("wake_lateness_ns",)


def test_load_rejects_csv_without_axis(tmp_path: Path) -> None:
    csv_path = tmp_path / "bad.csv"
    csv_path.write_text("voltage\n1\n", encoding="utf-8")

    with pytest.raises(ValueError, match="x-axis"):
        load_dataset(csv_path)


def test_load_detects_synaptic_current_transport(tmp_path: Path) -> None:
    csv_path = tmp_path / "synapse.csv"
    csv_path.write_text(
        "cycle_id,synaptic_current_na,comedi_ai0_v\n1,0.02,0.02\n",
        encoding="utf-8",
    )

    dataset = load_dataset(csv_path)

    assert dataset.loopback is not None
    assert dataset.loopback.source_column == "synaptic_current_na"
    assert dataset.loopback.measured_column == "comedi_ai0_v"

