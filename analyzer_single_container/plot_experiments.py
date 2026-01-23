#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Dict, List

import matplotlib.pyplot as plt


def as_float(value: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def bytes_to_mb(value: str) -> float:
    return as_float(value) / (1024 * 1024)


def find_run_dir(base: Path) -> Path:
    if base.name.startswith("202") and base.is_dir():
        return base
    candidates = sorted([p for p in base.iterdir() if p.is_dir()])
    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        return candidates[-1]
    raise FileNotFoundError(f"No run directories found under {base}")


def plot_latency(rows: List[Dict[str, str]], out_dir: Path) -> None:
    topic_counts = [as_float(row.get("topic_count", "0")) for row in rows]
    send_ack_ms = [as_float(row.get("send_ack_total_ms", "0")) for row in rows]

    plt.figure(figsize=(9, 5))
    plt.scatter(topic_counts, send_ack_ms, label="E2E latency")
    plt.xlabel("topic_count")
    plt.ylabel("milliseconds")
    plt.title("E2E latency")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_dir / "e2e_latency.png", dpi=200)
    plt.close()


def plot_method_times(rows: List[Dict[str, str]], out_dir: Path) -> None:
    topic_counts = [as_float(row.get("topic_count", "0")) for row in rows]
    series = [
        ("doSend", "do_send_ms"),
        ("waitOnMetadata", "wait_on_metadata_ms"),
        ("RecordAccumulator.append", "record_accumulator_append_ms"),
        ("Serializer.serialize", "serializer_serialize_ms"),
    ]

    plt.figure(figsize=(9, 6))
    for label, key in series:
        values = [as_float(row.get(key, "0")) for row in rows]
        plt.scatter(topic_counts, values, label=label)
    plt.xlabel("topic_count")
    plt.ylabel("estimated ms")
    plt.title("Per-Method Latency")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_dir / "per_method_latency.png", dpi=200)
    plt.close()


def plot_cpu_load(rows: List[Dict[str, str]], out_dir: Path) -> None:
    topic_counts = [as_float(row.get("topic_count", "0")) for row in rows]
    jvm_total_avg = [
        as_float(row.get("cpu_jvm_total_avg", "0")) * 100.0 for row in rows
    ]
    machine_total_avg = [
        as_float(row.get("cpu_machine_total_avg", "0")) * 100.0 for row in rows
    ]

    plt.figure(figsize=(9, 5))
    plt.plot(topic_counts, jvm_total_avg, label="JVM total avg (%)")
    plt.plot(topic_counts, machine_total_avg, label="Machine total avg (%)")
    plt.xlabel("topic_count")
    plt.ylabel("CPU usage (%)")
    plt.title("CPU Usage")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_dir / "cpu_load.png", dpi=200)
    plt.close()


def plot_memory_usage(rows: List[Dict[str, str]], out_dir: Path) -> None:
    topic_counts = [as_float(row.get("topic_count", "0")) for row in rows]
    phys_used = [bytes_to_mb(row.get("phys_mem_used_avg", "0")) for row in rows]
    heap_before = [
        bytes_to_mb(row.get("heap_before_gc_used_avg", "0")) for row in rows
    ]
    heap_after = [
        bytes_to_mb(row.get("heap_after_gc_used_avg", "0")) for row in rows
    ]

    plt.figure(figsize=(9, 6))
    plt.plot(topic_counts, phys_used, label="Physical used avg")
    plt.plot(topic_counts, heap_before, label="Heap before GC avg")
    plt.plot(topic_counts, heap_after, label="Heap after GC avg")
    plt.xlabel("topic_count")
    plt.ylabel("MB")
    plt.title("Memory Usage")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_dir / "memory_usage.png", dpi=200)
    plt.close()


def read_csv(path: Path) -> List[Dict[str, str]]:
    with path.open("r", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    rows.sort(
        key=lambda r: (
            as_float(r.get("topic_count", "0")),
            as_float(r.get("experiment_id", "0")),
        )
    )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot analysis CSVs from kafka producer experiments."
    )
    parser.add_argument(
        "--out-dir",
        default="client_profile_job/out",
        help="Base output directory or a specific run directory.",
    )
    parser.add_argument(
        "--analysis-dir",
        default="",
        help="Explicit analysis directory (overrides --out-dir).",
    )
    parser.add_argument(
        "--plot-dir",
        default="",
        help="Explicit plot output directory (defaults to analysis/plots).",
    )
    args = parser.parse_args()

    if args.analysis_dir:
        analysis_dir = Path(args.analysis_dir)
    else:
        run_dir = find_run_dir(Path(args.out_dir))
        analysis_dir = run_dir / "analysis"

    if not analysis_dir.exists():
        raise SystemExit(f"analysis dir not found: {analysis_dir}")

    plot_dir = Path(args.plot_dir) if args.plot_dir else analysis_dir / "plots"
    plot_dir.mkdir(parents=True, exist_ok=True)

    summary_path = analysis_dir / "summary.csv"
    if not summary_path.exists():
        raise SystemExit(f"summary.csv not found: {summary_path}")
    summary_rows = read_csv(summary_path)
    plot_latency(summary_rows, plot_dir)
    plot_method_times(summary_rows, plot_dir)

    resources_path = analysis_dir / "resources.csv"
    if resources_path.exists():
        resource_rows = read_csv(resources_path)
        plot_cpu_load(resource_rows, plot_dir)
        plot_memory_usage(resource_rows, plot_dir)
    else:
        print(f"resources.csv not found: {resources_path}")

    print(f"Wrote plots to {plot_dir}")


if __name__ == "__main__":
    main()
