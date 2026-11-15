"""Command-line interface for RTSyn validation CSV plots."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

import typer

from plot_tests.comparison import (
    calculate_test_integrity,
    paired_effects,
    paired_test_integrity,
    plot_paired_effects,
)
from plot_tests.data import load_dataset
from plot_tests.plots.common import period_description, period_tag
from plot_tests.plots.loopback import generate_loopback_plots
from plot_tests.plots.performance import generate_performance_plots
from plot_tests.summary import summarize_datasets

app = typer.Typer(help="Plot performance and signal data from RTSyn validation CSV files.")


@app.command()
def generate(
    csv_path: Annotated[Path, typer.Argument(help="Input RTSyn validation CSV.", exists=True, dir_okay=False, readable=True)],
    output_dir: Annotated[
        Path | None,
        typer.Option("--output-dir", "-o", help="Directory for plots (default: <CSV name>_plots beside the CSV)."),
    ] = None,
    formats: Annotated[
        list[str] | None,
        typer.Option("--format", "-f", help="Output format; repeat for multiple formats (png, svg, pdf)."),
    ] = None,
    ao_gain: Annotated[
        float | None,
        typer.Option("--ao-gain", help="Multiply the loopback source signal by this AO gain before plotting."),
    ] = None,
    period_ns: Annotated[
        int | None,
        typer.Option("--period-ns", help="Override the run period in ns (otherwise inferred from period_ns in the CSV)."),
    ] = None,
    zoom_start: Annotated[float | None, typer.Option("--zoom-start", help="Zoom start in elapsed seconds (cycles without timestamps); default: centered window.")] = None,
    zoom_duration: Annotated[float, typer.Option("--zoom-duration", min=0.000000001, help="Zoom window width in seconds (cycles without timestamps).")] = 20.0,
) -> None:
    """Generate all applicable timing and loopback plots for CSV_PATH."""

    selected_formats = formats or ["png"]
    invalid = sorted(set(selected_formats) - {"png", "svg", "pdf"})
    if invalid:
        raise typer.BadParameter(f"unsupported format(s): {', '.join(invalid)}; choose png, svg, or pdf")
    if ao_gain is not None and ao_gain == 0:
        raise typer.BadParameter("--ao-gain must be non-zero")
    if period_ns is not None and period_ns < 1:
        raise typer.BadParameter("--period-ns must be positive")

    try:
        dataset = load_dataset(csv_path)
    except ValueError as error:
        raise typer.BadParameter(str(error), param_hint="CSV_PATH") from error
    if period_ns is None and "period_ns" in dataset.frame:
        observed_periods = dataset.frame["period_ns"].dropna()
        if not observed_periods.empty:
            period_ns = int(observed_periods.median())
    run_period_tag = period_tag(period_ns) if period_ns else "period-unknown"
    destination = output_dir or csv_path.with_name(f"{csv_path.stem}_{run_period_tag}_plots")
    destination.mkdir(parents=True, exist_ok=True)

    # Include the capture's basename in every figure filename. The basename is
    # the run/iteration label for comparison captures and the test name for
    # standalone captures.
    capture_label = csv_path.stem if period_ns else f"{csv_path.stem}__{run_period_tag}"
    generated = generate_performance_plots(dataset, destination, selected_formats, capture_label, period_ns)
    generated += generate_loopback_plots(dataset, destination, selected_formats, ao_gain, capture_label, period_ns, zoom_start, zoom_duration)
    if not generated:
        raise typer.BadParameter("CSV contains no supported performance or loopback columns", param_hint="CSV_PATH")

    typer.echo(f"Generated {len(generated)} plot file(s) in {destination.resolve()}")
    typer.echo(f"Period: {period_description(period_ns)}" if period_ns else "Period: unknown")
    if dataset.loopback:
        effective_gain = ao_gain
        if effective_gain is None:
            effective_gain = 1000.0 if dataset.loopback.source_column == "hindmarsh_rose_vm_v" else 1.0
        typer.echo(
            f"Loopback: {dataset.loopback.source_column} × {effective_gain:g} → "
            f"{dataset.loopback.measured_column}"
        )
        if ao_gain is None and effective_gain != 1.0:
            typer.echo("Gain inferred from the standard Hindmarsh–Rose validation test; override with --ao-gain.")
    for path in generated:
        typer.echo(f"  {path.name}")


@app.command()
def inspect(
    csv_path: Annotated[Path, typer.Argument(help="Input RTSyn validation CSV.", exists=True, dir_okay=False, readable=True)],
) -> None:
    """Show which plots can be produced from CSV_PATH."""

    try:
        dataset = load_dataset(csv_path)
    except ValueError as error:
        raise typer.BadParameter(str(error), param_hint="CSV_PATH") from error
    typer.echo(f"CSV: {dataset.path.resolve()}")
    typer.echo(f"Rows: {len(dataset.frame):,}")
    typer.echo("Performance columns: " + (", ".join(dataset.available_performance_columns) or "none"))
    if dataset.loopback:
        typer.echo(f"Loopback source: {dataset.loopback.source_column}")
        typer.echo(f"Loopback measurement: {dataset.loopback.measured_column}")
    else:
        typer.echo("Loopback source/measurement pair: not detected")


@app.command()
def summarize(
    csv_paths: Annotated[
        list[Path], typer.Argument(help="One or more RTSyn validation CSV captures.", exists=True, dir_okay=False, readable=True)
    ],
    output: Annotated[Path, typer.Option("--output", "-o", help="Output CSV path.")] = Path("run-summary.csv"),
    ao_gain: Annotated[
        float | None,
        typer.Option("--ao-gain", help="AO gain used to calculate loopback error metrics."),
    ] = None,
    test_name: Annotated[
        str | None,
        typer.Option("--test-name", help="Name of this repeated test; writes its integrity table."),
    ] = None,
) -> None:
    """Write one auditable statistics row per independent capture."""

    if ao_gain == 0:
        raise typer.BadParameter("--ao-gain must be non-zero")
    try:
        datasets = [load_dataset(path) for path in csv_paths]
    except ValueError as error:
        raise typer.BadParameter(str(error), param_hint="CSV_PATH") from error
    output.parent.mkdir(parents=True, exist_ok=True)
    summary = summarize_datasets(datasets, ao_gain)
    summary.to_csv(output, index=False)
    typer.echo(f"Wrote {len(summary)} independent-run summaries to {output.resolve()}")
    if test_name:
        integrity_path = output.with_name(f"{output.stem}-test-integrity.csv")
        integrity = calculate_test_integrity(summary, test_name)
        integrity.to_csv(integrity_path, index=False)
        typer.echo(f"Wrote test integrity metrics to {integrity_path.resolve()}")


@app.command()
def compare(
    manifest: Annotated[Path, typer.Argument(help="TSV manifest from repeated-comparison.bash.", exists=True, dir_okay=False, readable=True)],
    output_dir: Annotated[Path | None, typer.Option("--output-dir", "-o", help="Directory for paired tables and figure.")] = None,
    ao_gain: Annotated[float | None, typer.Option("--ao-gain", help="AO gain used for loopback error metrics.")] = None,
) -> None:
    """Compare alternating no-device/loopback captures as paired executions."""

    if ao_gain == 0:
        raise typer.BadParameter("--ao-gain must be non-zero")
    destination = output_dir or manifest.parent / "paired-comparison"
    destination.mkdir(parents=True, exist_ok=True)
    try:
        effects, summary = paired_effects(manifest, ao_gain)
        integrity = paired_test_integrity(effects)
        plot_paired_effects(effects, destination / "paired-effects.png")
    except ValueError as error:
        raise typer.BadParameter(str(error), param_hint="MANIFEST") from error
    effects.to_csv(destination / "paired-effects.csv", index=False)
    summary.to_csv(destination / "paired-effect-summary.csv", index=False)
    integrity.to_csv(destination / "test-integrity.csv", index=False)
    typer.echo(f"Wrote {len(effects)} paired effects and {len(summary)} metric summaries to {destination.resolve()}")


def main() -> None:
    """Run the Typer application."""

    app()
