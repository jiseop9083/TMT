#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import subprocess
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

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
    resource_stats: "ResourceStats | None"


@dataclass
class ResourceStats:
    cpu_samples: int
    cpu_jvm_user_avg: float
    cpu_jvm_user_max: float
    cpu_jvm_system_avg: float
    cpu_jvm_system_max: float
    cpu_machine_total_avg: float
    cpu_machine_total_max: float
    cpu_jvm_total_avg: float
    cpu_jvm_total_max: float
    phys_mem_samples: int
    phys_mem_total_bytes: int
    phys_mem_used_avg: float
    phys_mem_used_max: float
    heap_before_gc_samples: int
    heap_before_gc_used_avg: float
    heap_before_gc_used_max: float
    heap_after_gc_samples: int
    heap_after_gc_used_avg: float
    heap_after_gc_used_max: float
    heap_committed_avg: float


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


def safe_mean(values: List[float]) -> float:
    if not values:
        return 0.0
    return sum(values) / len(values)


def safe_max(values: List[float]) -> float:
    if not values:
        return 0.0
    return max(values)


def read_jfr_events(path: Path, event_names: Iterable[str]) -> List[Dict[str, object]]:
    if not path.exists():
        return []
    if shutil.which("jfr") is None:
        return []
    cmd = [
        "jfr",
        "print",
        "--json",
        "--events",
        ",".join(event_names),
        str(path),
    ]
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return []
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []
    return list(data.get("recording", {}).get("events", []))


def parse_resource_stats(jfr_path: Path) -> ResourceStats | None:
    events = read_jfr_events(jfr_path, ["CPULoad", "PhysicalMemory", "GCHeapSummary"])
    if not events:
        return None

    cpu_user: List[float] = []
    cpu_system: List[float] = []
    cpu_machine: List[float] = []
    phys_total: List[int] = []
    phys_used: List[int] = []
    heap_before: List[int] = []
    heap_after: List[int] = []
    heap_committed: List[int] = []

    for event in events:
        if not isinstance(event, dict):
            continue
        event_type = event.get("type")
        values = event.get("values", {})
        if not isinstance(values, dict):
            continue
        if event_type == "jdk.CPULoad":
            cpu_user.append(float(values.get("jvmUser", 0.0)))
            cpu_system.append(float(values.get("jvmSystem", 0.0)))
            cpu_machine.append(float(values.get("machineTotal", 0.0)))
        elif event_type == "jdk.PhysicalMemory":
            phys_total.append(int(values.get("totalSize", 0)))
            phys_used.append(int(values.get("usedSize", 0)))
        elif event_type == "jdk.GCHeapSummary":
            when = values.get("when")
            heap_used = int(values.get("heapUsed", 0))
            heap_space = values.get("heapSpace", {})
            if isinstance(heap_space, dict):
                heap_committed.append(int(heap_space.get("committedSize", 0)))
            if when == "Before GC":
                heap_before.append(heap_used)
            elif when == "After GC":
                heap_after.append(heap_used)

    cpu_jvm_total = [u + s for u, s in zip(cpu_user, cpu_system)]

    return ResourceStats(
        cpu_samples=len(cpu_user),
        cpu_jvm_user_avg=safe_mean(cpu_user),
        cpu_jvm_user_max=safe_max(cpu_user),
        cpu_jvm_system_avg=safe_mean(cpu_system),
        cpu_jvm_system_max=safe_max(cpu_system),
        cpu_machine_total_avg=safe_mean(cpu_machine),
        cpu_machine_total_max=safe_max(cpu_machine),
        cpu_jvm_total_avg=safe_mean(cpu_jvm_total),
        cpu_jvm_total_max=safe_max(cpu_jvm_total),
        phys_mem_samples=len(phys_used),
        phys_mem_total_bytes=int(safe_mean([float(v) for v in phys_total])),
        phys_mem_used_avg=safe_mean([float(v) for v in phys_used]),
        phys_mem_used_max=float(safe_max([float(v) for v in phys_used])),
        heap_before_gc_samples=len(heap_before),
        heap_before_gc_used_avg=safe_mean([float(v) for v in heap_before]),
        heap_before_gc_used_max=float(safe_max([float(v) for v in heap_before])),
        heap_after_gc_samples=len(heap_after),
        heap_after_gc_used_avg=safe_mean([float(v) for v in heap_after]),
        heap_after_gc_used_max=float(safe_max([float(v) for v in heap_after])),
        heap_committed_avg=safe_mean([float(v) for v in heap_committed]),
    )


def parse_run(exp_dir: Path, jfr_progress: bool = False) -> ParsedRun | None:
    metrics_path = exp_dir / "metrics.txt"
    collapsed_path = exp_dir / "async.collapsed"
    app_log_path = exp_dir / "app.log"
    jfr_path = exp_dir / "jfr.jfr"

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
    if jfr_progress:
        if jfr_path.exists():
            print(f"[jfr] {exp_dir.name} start")
        else:
            print(f"[jfr] {exp_dir.name} missing")
    resource_stats = parse_resource_stats(jfr_path)
    if jfr_progress and jfr_path.exists():
        print(f"[jfr] {exp_dir.name} done")

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
        resource_stats=resource_stats,
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


def write_resource_csv(out_dir: Path, runs: List[ParsedRun]) -> None:
    path = out_dir / "resources.csv"
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "experiment_id",
                "topic",
                "topic_count",
                "cpu_samples",
                "cpu_jvm_user_avg",
                "cpu_jvm_user_max",
                "cpu_jvm_system_avg",
                "cpu_jvm_system_max",
                "cpu_machine_total_avg",
                "cpu_machine_total_max",
                "cpu_jvm_total_avg",
                "cpu_jvm_total_max",
                "phys_mem_samples",
                "phys_mem_total_bytes",
                "phys_mem_used_avg",
                "phys_mem_used_max",
                "heap_before_gc_samples",
                "heap_before_gc_used_avg",
                "heap_before_gc_used_max",
                "heap_after_gc_samples",
                "heap_after_gc_used_avg",
                "heap_after_gc_used_max",
                "heap_committed_avg",
                "run_dir",
            ]
        )
        for run in sorted(runs, key=lambda r: (r.topic_count, r.experiment_id)):
            stats = run.resource_stats or ResourceStats(
                cpu_samples=0,
                cpu_jvm_user_avg=0.0,
                cpu_jvm_user_max=0.0,
                cpu_jvm_system_avg=0.0,
                cpu_jvm_system_max=0.0,
                cpu_machine_total_avg=0.0,
                cpu_machine_total_max=0.0,
                cpu_jvm_total_avg=0.0,
                cpu_jvm_total_max=0.0,
                phys_mem_samples=0,
                phys_mem_total_bytes=0,
                phys_mem_used_avg=0.0,
                phys_mem_used_max=0.0,
                heap_before_gc_samples=0,
                heap_before_gc_used_avg=0.0,
                heap_before_gc_used_max=0.0,
                heap_after_gc_samples=0,
                heap_after_gc_used_avg=0.0,
                heap_after_gc_used_max=0.0,
                heap_committed_avg=0.0,
            )
            writer.writerow(
                [
                    run.experiment_id,
                    run.topic,
                    run.topic_count,
                    stats.cpu_samples,
                    f"{stats.cpu_jvm_user_avg:.6f}",
                    f"{stats.cpu_jvm_user_max:.6f}",
                    f"{stats.cpu_jvm_system_avg:.6f}",
                    f"{stats.cpu_jvm_system_max:.6f}",
                    f"{stats.cpu_machine_total_avg:.6f}",
                    f"{stats.cpu_machine_total_max:.6f}",
                    f"{stats.cpu_jvm_total_avg:.6f}",
                    f"{stats.cpu_jvm_total_max:.6f}",
                    stats.phys_mem_samples,
                    stats.phys_mem_total_bytes,
                    f"{stats.phys_mem_used_avg:.2f}",
                    f"{stats.phys_mem_used_max:.2f}",
                    stats.heap_before_gc_samples,
                    f"{stats.heap_before_gc_used_avg:.2f}",
                    f"{stats.heap_before_gc_used_max:.2f}",
                    stats.heap_after_gc_samples,
                    f"{stats.heap_after_gc_used_avg:.2f}",
                    f"{stats.heap_after_gc_used_max:.2f}",
                    f"{stats.heap_committed_avg:.2f}",
                    run.run_dir,
                ]
            )


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
        "--jfr-progress",
        action="store_true",
        help="Print progress while parsing jfr.jfr files.",
    )
    args = parser.parse_args()

    run_dir = find_run_dir(Path(args.out_dir))
    exp_dirs = iter_experiment_dirs(run_dir)

    runs: List[ParsedRun] = []
    for exp_dir in exp_dirs:
        parsed = parse_run(exp_dir, jfr_progress=args.jfr_progress)
        if parsed:
            runs.append(parsed)

    if not runs:
        raise SystemExit("No valid experiment outputs found.")

    analysis_dir = run_dir / "analysis"
    analysis_dir.mkdir(exist_ok=True)

    write_summary_csv(analysis_dir, runs)
    write_kv_csv(analysis_dir / "metadata_by_frame.csv", runs, "metadata_by_frame")
    write_kv_csv(analysis_dir / "do_send_children.csv", runs, "do_send_children")
    write_resource_csv(analysis_dir, runs)

    if args.full_paths:
        write_kv_csv(
            analysis_dir / "do_send_full_paths.csv", runs, "do_send_full_paths"
        )

    print(f"Wrote analysis CSVs to {analysis_dir}")


if __name__ == "__main__":
    main()
