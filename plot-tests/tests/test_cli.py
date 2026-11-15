from pathlib import Path

import pandas as pd
from typer.testing import CliRunner

from plot_tests.cli import app


def test_generate_infers_period_for_plot_names_folder_and_metadata(tmp_path: Path) -> None:
    csv_path = tmp_path / "capture-run-01.csv"
    pd.DataFrame(
        {
            "cycle_id": [1, 2, 3],
            "period_ns": [100_000, 100_000, 100_000],
            "wake_lateness_ns": [100, 200, 150],
        }
    ).to_csv(csv_path, index=False)

    result = CliRunner().invoke(app, ["generate", str(csv_path)])

    output_dir = tmp_path / "capture-run-01_100us_plots"
    assert result.exit_code == 0, result.output
    assert (output_dir / "wake-lateness__capture-run-01__100us.png").is_file()
    assert "100us" in result.output
    assert "10 kHz" in result.output
