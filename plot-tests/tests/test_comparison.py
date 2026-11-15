from pathlib import Path

import pandas as pd

from plot_tests.comparison import calculate_test_integrity, paired_effects, paired_test_integrity


def _capture(path: Path, lateness: int) -> None:
    pd.DataFrame(
        {
            "cycle_id": [1, 2, 3], "wake_lateness_ns": [lateness, lateness, lateness],
            "deadline_missed": [0, 0, 0], "skipped_cycle_count": [0, 0, 0],
        }
    ).to_csv(path, index=False)


def test_paired_effects_uses_manifest_pairs(tmp_path: Path) -> None:
    _capture(tmp_path / "no-1.csv", 10)
    _capture(tmp_path / "loop-1.csv", 30)
    _capture(tmp_path / "loop-2.csv", 50)
    _capture(tmp_path / "no-2.csv", 20)
    manifest = tmp_path / "manifest.tsv"
    manifest.write_text(
        "run\tmode\tcsv\n1\tno-device\tno-1.csv\n2\tloopback\tloop-1.csv\n"
        "3\tloopback\tloop-2.csv\n4\tno-device\tno-2.csv\n",
        encoding="utf-8",
    )

    effects, summary = paired_effects(manifest)

    p99 = effects.loc[effects["metric"] == "wake_lateness_p99_ns"]
    assert p99["effect_loopback_minus_no_device"].tolist() == [20.0, 30.0]
    assert summary.loc[summary["metric"] == "wake_lateness_p99_ns", "pairs"].item() == 2
    integrity = paired_test_integrity(effects)
    assert set(integrity["test"]) == {"no-device", "loopback"}


def test_integrity_is_zero_for_identical_executions() -> None:
    integrity = calculate_test_integrity(
        pd.DataFrame({"wake_lateness_p99_ns": [20.0, 20.0]}), "timing"
    )

    assert integrity["test_integrity_percent"].item() == 0.0
