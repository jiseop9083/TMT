#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Iterable, List

COMBINED_PREFIX = "combined_metrics_"
YAMMER_PREFIX = "yammer_"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plot first-produce-with-message-load metrics from combined_metrics/yammer CSV files."
        )
    )
    parser.add_argument(
        "--out-dir",
        default="kafka-4.2/output/first-produce-with-message-load",
        help="Directory that contains combined_metrics_*.csv and yammer_*.csv",
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help="Specific timestamp suffix (e.g. 20260226_020448). Default: latest",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Plot all timestamps that have both combined_metrics and yammer CSV",
    )
    parser.add_argument(
        "--fig-dir",
        default="",
        help="Output figure directory (default: <out-dir>/plots)",
    )
    return parser.parse_args()


def csv_timestamps(base: Path, prefix: str) -> set[str]:
    values: set[str] = set()
    for p in sorted(base.glob(f"{prefix}*.csv")):
        name = p.name
        if not name.startswith(prefix) or not name.endswith(".csv"):
            continue
        values.add(name[len(prefix) : -4])
    return values


def pick_timestamps(base: Path, requested_ts: str, all_runs: bool) -> List[str]:
    combined_ts = csv_timestamps(base, COMBINED_PREFIX)
    yammer_ts = csv_timestamps(base, YAMMER_PREFIX)
    common = sorted(combined_ts & yammer_ts)

    if not common:
        raise SystemExit(
            f"No matching timestamp pairs found under {base} for combined_metrics/yammer CSVs"
        )

    if requested_ts:
        if requested_ts not in common:
            raise SystemExit(
                f"Timestamp {requested_ts} not found in matching pairs. Available: {', '.join(common)}"
            )
        return [requested_ts]

    if all_runs:
        return common

    return [common[-1]]


def load_numeric_rows(path: Path) -> List[dict[str, float]]:
    rows: List[dict[str, float]] = []
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for raw in reader:
            row: dict[str, float] = {}
            for k, v in raw.items():
                if v is None:
                    continue
                text = v.strip()
                if text == "":
                    continue
                try:
                    row[k] = float(text)
                except ValueError:
                    continue
            rows.append(row)
    return rows


def col(rows: Iterable[dict[str, float]], key: str) -> List[float]:
    result: List[float] = []
    for r in rows:
        if key in r:
            result.append(r[key])
    return result


def plot_combined(ts: str, rows: List[dict[str, float]], fig_dir: Path) -> Path:
    import matplotlib.pyplot as plt

    x = col(rows, "topic_num")
    if not x:
        raise SystemExit(f"combined_metrics_{ts}.csv has no topic_num values")

    fig, axes = plt.subplots(2, 2, figsize=(13, 9), constrained_layout=True)

    axes[0, 0].scatter(x, col(rows, "e2e_ms"), s=24, alpha=0.85, color="#1f77b4")
    axes[0, 0].set_title("E2E Latency")
    axes[0, 0].set_xlabel("Topic Count")
    axes[0, 0].set_ylabel("e2e_ms")
    axes[0, 0].grid(alpha=0.25)

    axes[0, 1].scatter(
        x,
        col(rows, "metadata_req_queue_wait_ms"),
        s=20,
        alpha=0.85,
        label="metadata_req_queue_wait_ms",
        color="#ff7f0e",
    )
    axes[0, 1].scatter(
        x,
        col(rows, "produce_queue_wait_ms"),
        s=20,
        alpha=0.85,
        label="produce_queue_wait_ms",
        color="#2ca02c",
    )
    axes[0, 1].set_title("Queue Wait Time")
    axes[0, 1].set_xlabel("Topic Count")
    axes[0, 1].set_ylabel("ms")
    axes[0, 1].grid(alpha=0.25)
    axes[0, 1].legend()

    axes[1, 0].scatter(
        x,
        col(rows, "broker_proc_time_ms_last"),
        s=24,
        alpha=0.85,
        color="#d62728",
    )
    axes[1, 0].set_title("Broker Process Time (Last)")
    axes[1, 0].set_xlabel("Topic Count")
    axes[1, 0].set_ylabel("broker_proc_time_ms_last")
    axes[1, 0].grid(alpha=0.25)

    axes[1, 1].scatter(
        x,
        col(rows, "broker_meta_update_ms"),
        s=20,
        alpha=0.85,
        label="broker_meta_update_ms",
        color="#9467bd",
    )
    axes[1, 1].scatter(
        x,
        col(rows, "broker_topic_create_proc_ms"),
        s=20,
        alpha=0.85,
        label="broker_topic_create_proc_ms",
        color="#8c564b",
    )
    axes[1, 1].set_title("Broker-side")
    axes[1, 1].set_xlabel("Topic Count")
    axes[1, 1].set_ylabel("ms")
    axes[1, 1].grid(alpha=0.25)
    axes[1, 1].legend()

    out = fig_dir / f"combined_scatter_{ts}.png"
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def plot_yammer(ts: str, rows: List[dict[str, float]], fig_dir: Path) -> Path:
    import matplotlib.pyplot as plt

    x = col(rows, "topic_dir_count")
    if not x:
        raise SystemExit(f"yammer_{ts}.csv has no topic_dir_count values")

    fig, axes = plt.subplots(2, 2, figsize=(13, 9), constrained_layout=True)

    axes[0, 0].plot(x, col(rows, "cpu_pct"), marker="o", linewidth=1.8, color="#1f77b4")
    axes[0, 0].set_title("CPU Usage")
    axes[0, 0].set_xlabel("Topic Count (topic_dir_count)")
    axes[0, 0].set_ylabel("cpu_pct")
    axes[0, 0].grid(alpha=0.25)

    axes[0, 1].plot(
        x,
        col(rows, "rss_kb"),
        marker="o",
        linewidth=1.8,
        label="rss_kb",
        color="#ff7f0e",
    )
    axes[0, 1].plot(
        x,
        col(rows, "heap_used_kb"),
        marker="o",
        linewidth=1.8,
        label="heap_used_kb",
        color="#2ca02c",
    )
    axes[0, 1].set_title("Memory")
    axes[0, 1].set_xlabel("Topic Count (topic_dir_count)")
    axes[0, 1].set_ylabel("KB")
    axes[0, 1].grid(alpha=0.25)
    axes[0, 1].legend()

    axes[1, 0].plot(x, col(rows, "storage_kb"), marker="o", linewidth=1.8, color="#d62728")
    axes[1, 0].set_title("Disk Usage")
    axes[1, 0].set_xlabel("Topic Count (topic_dir_count)")
    axes[1, 0].set_ylabel("storage_kb")
    axes[1, 0].grid(alpha=0.25)

    axes[1, 1].axis("off")

    out = fig_dir / f"yammer_lines_{ts}.png"
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def main() -> None:
    args = parse_args()
    try:
        import matplotlib  # noqa: F401
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "matplotlib is required. Install it with: pip3 install matplotlib"
        ) from exc

    base = Path(args.out_dir).resolve()
    if not base.exists():
        raise SystemExit(f"Output directory not found: {base}")

    fig_dir = Path(args.fig_dir).resolve() if args.fig_dir else (base / "plots")
    fig_dir.mkdir(parents=True, exist_ok=True)

    timestamps = pick_timestamps(base, args.timestamp, args.all)

    for ts in timestamps:
        combined_path = base / f"{COMBINED_PREFIX}{ts}.csv"
        yammer_path = base / f"{YAMMER_PREFIX}{ts}.csv"

        combined_rows = load_numeric_rows(combined_path)
        yammer_rows = load_numeric_rows(yammer_path)

        combined_png = plot_combined(ts, combined_rows, fig_dir)
        yammer_png = plot_yammer(ts, yammer_rows, fig_dir)

        print(f"[{ts}] combined scatter: {combined_png}")
        print(f"[{ts}] yammer lines   : {yammer_png}")


if __name__ == "__main__":
    main()
