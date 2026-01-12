#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import re
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import matplotlib.pyplot as plt

APP_LOG_ELAPSED_RE = re.compile(r"elapsed_ms=(\d+)")
DO_SEND_FRAME = "org/apache/kafka/clients/producer/KafkaProducer.doSend"
WAIT_ON_METADATA_FRAME = (
    "org/apache/kafka/clients/producer/KafkaProducer.waitOnMetadata"
)
RECORD_ACCUMULATOR_APPEND_FRAME = (
    "org/apache/kafka/clients/producer/internals/RecordAccumulator.append"
)
SERIALIZER_SERIALIZE_FRAME = (
    "org/apache/kafka/common/serialization/Serializer.serialize"
)

# Adjust these patterns if you want a stricter or broader definition of metadata lookup.
METADATA_FRAME_PATTERNS: List[Tuple[str, re.Pattern[str]]] = [
    ("default_metadata_updater", re.compile(r"NetworkClient\\$DefaultMetadataUpdater")),
    ("metadata_request", re.compile(r"MetadataRequest")),
    ("metadata_response", re.compile(r"MetadataResponse")),
    ("cluster", re.compile(r"KafkaProducer\\$ClusterAndWaitTime")),
    ("topic_ids_for_batches", re.compile(r"Sender\\.topicIdsForBatches")),
]


@dataclass
class ParsedRun:
    run_dir: Path
    experiment_id: int
    topic: str
    topic_count: int
    send_ack_total_ms: int
    num_messages: int
    profiler_elapsed_ms: int
    total_samples: int
    metadata_samples: int
    do_send_samples: int
    wait_on_metadata_samples: int
    record_accumulator_append_samples: int
    serializer_serialize_samples: int
    do_send_ms: float
    wait_on_metadata_ms: float
    record_accumulator_append_ms: float
    serializer_serialize_ms: float
    metadata_by_frame: Dict[str, int]
    do_send_children: Dict[str, int]
    do_send_full_paths: Dict[str, int]


def parse_metrics(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def infer_topic_count(topic: str, fallback: int) -> int:
    match = re.search(r"(\d+)$", topic)
    if match:
        return int(match.group(1))
    return fallback


def parse_collapsed(
    path: Path,
    do_send_frame: str,
    metadata_patterns: Iterable[Tuple[str, re.Pattern[str]]],
    extra_frames: Dict[str, str],
) -> Tuple[
    int,
    int,
    Dict[str, int],
    int,
    Dict[str, int],
    Dict[str, int],
    Dict[str, int],
]:
    total_samples = 0
    metadata_total = 0
    metadata_by_frame: Dict[str, int] = defaultdict(int)
    do_send_total = 0
    do_send_children: Dict[str, int] = defaultdict(int)
    do_send_full_paths: Dict[str, int] = defaultdict(int)
    extra_frame_counts: Dict[str, int] = defaultdict(int)

    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            stack_str, count_str = line.rsplit(" ", 1)
            count = int(count_str)
        except ValueError:
            continue
        total_samples += count
        stack = stack_str.split(";")

        matched_metadata = False
        for frame in stack:
            for label, pattern in metadata_patterns:
                if pattern.search(frame):
                    metadata_by_frame[label] += count
                    matched_metadata = True
            if matched_metadata:
                metadata_total += count
                break

        if do_send_frame in stack:
            do_send_total += count
            idx = stack.index(do_send_frame)
            if idx + 1 < len(stack):
                child = stack[idx + 1]
                do_send_children[child] += count
                subpath = ";".join(stack[idx + 1 :])
                do_send_full_paths[subpath] += count

        for label, frame in extra_frames.items():
            if frame in stack:
                extra_frame_counts[label] += count

    return (
        total_samples,
        metadata_total,
        dict(metadata_by_frame),
        do_send_total,
        dict(do_send_children),
        dict(do_send_full_paths),
        dict(extra_frame_counts),
    )


def find_run_dir(base: Path) -> Path:
    if base.name.startswith("202") and base.is_dir():
        return base
    candidates = sorted([p for p in base.iterdir() if p.is_dir()])
    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        return candidates[-1]
    raise FileNotFoundError(f"No run directories found under {base}")


def iter_experiment_dirs(run_dir: Path) -> List[Path]:
    return sorted(
        [
            p
            for p in run_dir.iterdir()
            if p.is_dir() and p.name.startswith("kafka-producer-experiment-")
        ]
    )


def parse_app_log(path: Path) -> int:
    elapsed_ms = 0
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not elapsed_ms:
            match = APP_LOG_ELAPSED_RE.search(line)
            if match:
                elapsed_ms = int(match.group(1))
        if elapsed_ms:
            break
    return elapsed_ms


def samples_to_ms(samples: int, total_samples: int, elapsed_ms: int) -> float:
    if total_samples <= 0 or elapsed_ms <= 0:
        return 0.0
    return (samples / total_samples) * elapsed_ms


def parse_run(exp_dir: Path) -> ParsedRun | None:
    metrics_path = exp_dir / "metrics.txt"
    collapsed_path = exp_dir / "async.collapsed"
    app_log_path = exp_dir / "app.log"

    if not metrics_path.exists() or not collapsed_path.exists():
        return None

    metrics = parse_metrics(metrics_path)
    experiment_id = int(exp_dir.name.rsplit("-", 1)[-1])
    topic = f"test_topic_{experiment_id}"
    topic_count = experiment_id
    profiler_elapsed_ms = 0
    if app_log_path.exists():
        profiler_elapsed_ms = parse_app_log(app_log_path)

    extra_frames = {
        "wait_on_metadata": WAIT_ON_METADATA_FRAME,
        "record_accumulator_append": RECORD_ACCUMULATOR_APPEND_FRAME,
        "serializer_serialize": SERIALIZER_SERIALIZE_FRAME,
    }

    (
        total_samples,
        metadata_total,
        metadata_by_frame,
        do_send_total,
        do_send_children,
        do_send_full_paths,
        extra_frame_counts,
    ) = parse_collapsed(
        collapsed_path, DO_SEND_FRAME, METADATA_FRAME_PATTERNS, extra_frames
    )

    wait_on_metadata_samples = extra_frame_counts.get("wait_on_metadata", 0)
    record_accumulator_append_samples = extra_frame_counts.get(
        "record_accumulator_append", 0
    )
    serializer_serialize_samples = extra_frame_counts.get("serializer_serialize", 0)
    time_base_ms = profiler_elapsed_ms
    do_send_ms = samples_to_ms(do_send_total, total_samples, time_base_ms)
    wait_on_metadata_ms = samples_to_ms(
        wait_on_metadata_samples, total_samples, time_base_ms
    )
    record_accumulator_append_ms = samples_to_ms(
        record_accumulator_append_samples, total_samples, time_base_ms
    )
    serializer_serialize_ms = samples_to_ms(
        serializer_serialize_samples, total_samples, time_base_ms
    )

    return ParsedRun(
        run_dir=exp_dir,
        experiment_id=experiment_id,
        topic=topic,
        topic_count=topic_count,
        send_ack_total_ms=int(metrics.get("send_ack_total_ms", "0")),
        num_messages=int(metrics.get("num_messages", "0")),
        profiler_elapsed_ms=profiler_elapsed_ms,
        total_samples=total_samples,
        metadata_samples=metadata_total,
        do_send_samples=do_send_total,
        wait_on_metadata_samples=wait_on_metadata_samples,
        record_accumulator_append_samples=record_accumulator_append_samples,
        serializer_serialize_samples=serializer_serialize_samples,
        do_send_ms=do_send_ms,
        wait_on_metadata_ms=wait_on_metadata_ms,
        record_accumulator_append_ms=record_accumulator_append_ms,
        serializer_serialize_ms=serializer_serialize_ms,
        metadata_by_frame=metadata_by_frame,
        do_send_children=do_send_children,
        do_send_full_paths=do_send_full_paths,
    )


def write_summary_csv(out_dir: Path, runs: List[ParsedRun]) -> None:
    path = out_dir / "summary.csv"
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "experiment_id",
                "topic",
                "topic_count",
                "send_ack_total_ms",
                "num_messages",
                "profiler_elapsed_ms",
                "total_samples",
                "metadata_samples",
                "do_send_samples",
                "wait_on_metadata_samples",
                "record_accumulator_append_samples",
                "serializer_serialize_samples",
                "do_send_ms",
                "wait_on_metadata_ms",
                "record_accumulator_append_ms",
                "serializer_serialize_ms",
                "run_dir",
            ]
        )
        for run in sorted(runs, key=lambda r: (r.topic_count, r.experiment_id)):
            writer.writerow(
                [
                    run.experiment_id,
                    run.topic,
                    run.topic_count,
                    run.send_ack_total_ms,
                    run.num_messages,
                    run.profiler_elapsed_ms,
                    run.total_samples,
                    run.metadata_samples,
                    run.do_send_samples,
                    run.wait_on_metadata_samples,
                    run.record_accumulator_append_samples,
                    run.serializer_serialize_samples,
                    f"{run.do_send_ms:.3f}",
                    f"{run.wait_on_metadata_ms:.3f}",
                    f"{run.record_accumulator_append_ms:.3f}",
                    f"{run.serializer_serialize_ms:.3f}",
                    run.run_dir,
                ]
            )


def write_kv_csv(out_path: Path, runs: List[ParsedRun], attr: str) -> None:
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["topic_count", "label", "samples"])
        for run in sorted(runs, key=lambda r: (r.topic_count, r.experiment_id)):
            data: Dict[str, int] = getattr(run, attr)
            for label, samples in sorted(data.items(), key=lambda x: (-x[1], x[0])):
                writer.writerow([run.topic_count, label, samples])


def as_float(value: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


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


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Aggregate kafka producer experiment outputs."
    )
    parser.add_argument(
        "--out-dir",
        default="client_profile_job/out",
        help="Base output directory or a specific run directory.",
    )
    parser.add_argument(
        "--full-paths",
        action="store_true",
        help="Write doSend full subpaths CSV (can be large).",
    )
    parser.add_argument(
        "--plot",
        action="store_true",
        help="Write plots to analysis/plots.",
    )
    args = parser.parse_args()

    run_dir = find_run_dir(Path(args.out_dir))
    exp_dirs = iter_experiment_dirs(run_dir)

    runs: List[ParsedRun] = []
    for exp_dir in exp_dirs:
        parsed = parse_run(exp_dir)
        if parsed:
            runs.append(parsed)

    if not runs:
        raise SystemExit("No valid experiment outputs found.")

    analysis_dir = run_dir / "analysis"
    analysis_dir.mkdir(exist_ok=True)

    write_summary_csv(analysis_dir, runs)
    write_kv_csv(analysis_dir / "metadata_by_frame.csv", runs, "metadata_by_frame")
    write_kv_csv(analysis_dir / "do_send_children.csv", runs, "do_send_children")

    if args.full_paths:
        write_kv_csv(
            analysis_dir / "do_send_full_paths.csv", runs, "do_send_full_paths"
        )

    if args.plot:
        summary_path = analysis_dir / "summary.csv"
        with summary_path.open("r", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        rows.sort(
            key=lambda r: (
                as_float(r.get("topic_count", "0")),
                as_float(r.get("experiment_id", "0")),
            )
        )
        plot_dir = analysis_dir / "plots"
        plot_dir.mkdir(exist_ok=True)
        plot_latency(rows, plot_dir)
        plot_method_times(rows, plot_dir)

    print(f"Wrote analysis CSVs to {analysis_dir}")


if __name__ == "__main__":
    main()
