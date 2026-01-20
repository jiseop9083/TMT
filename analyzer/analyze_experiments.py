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
TRACKED_METHODS: Dict[str, str] = {
    "do_send": "org.apache.kafka.clients.producer.KafkaProducer.doSend",
    "wait_on_metadata": "org.apache.kafka.clients.producer.KafkaProducer.waitOnMetadata",
    "record_accumulator_append": "org.apache.kafka.clients.producer.internals.RecordAccumulator.append",
    "serializer_serialize": "org.apache.kafka.common.serialization.Serializer.serialize",
}

WALL_CLOCK_EVENT_TYPES = [
    "jdk.ThreadSleep",
    "jdk.JavaMonitorEnter",
    "jdk.JavaMonitorWait",
    "jdk.ThreadPark",
    "jdk.SocketRead",
    "jdk.SocketWrite",
    "jdk.FileRead",
    "jdk.FileWrite",
]


@dataclass
class ParsedRun:
    run_dir: Path
    experiment_id: int
    topic: str
    topic_count: int
    send_ack_total_ms: int
    num_messages: int
    app_elapsed_ms: int
    jfr_total_samples: int
    cpu_total_ms: float
    wall_clock_total_ms: float
    wall_clock_event_count: int
    tracked_method_samples: Dict[str, int]
    tracked_method_ms: Dict[str, float]
    method_samples: Dict[str, int]
    method_cpu_ms: Dict[str, float]
    method_wall_clock_ms: Dict[str, float]
    method_event_counts: Dict[str, int]
    method_total_ms: Dict[str, float]
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


def normalize_method_name(name: str) -> str:
    if not name:
        return ""
    name = name.strip()
    name = name.replace("/", ".")
    if name.startswith("L") and name.endswith(";"):
        name = name[1:-1]
    return name


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


def extract_frames(event: Dict[str, object]) -> List[Dict[str, object]]:
    stack = event.get("stackTrace")
    if not isinstance(stack, dict):
        values = event.get("values", {})
        if isinstance(values, dict):
            stack = values.get("stackTrace")
    if not isinstance(stack, dict):
        return []
    frames = stack.get("frames", [])
    if isinstance(frames, list):
        return [f for f in frames if isinstance(f, dict)]
    return []


def frame_method_name(frame: Dict[str, object]) -> str:
    method = frame.get("method")
    if isinstance(method, dict):
        method_name = str(method.get("name", "")).strip()
        method_type = method.get("type") or method.get("class")
        type_name = ""
        if isinstance(method_type, dict):
            type_name = str(method_type.get("name", "")).strip()
        elif isinstance(method_type, str):
            type_name = method_type.strip()
        full = f"{type_name}.{method_name}" if type_name and method_name else method_name
        return normalize_method_name(full)
    if isinstance(method, str):
        return normalize_method_name(method)
    return ""


def parse_method_samples(jfr_path: Path) -> Tuple[int, Dict[str, int]]:
    events = read_jfr_events(
        jfr_path,
        [
            "jdk.ExecutionSample",
            "jdk.NativeMethodSample",
        ],
    )
    if not events:
        return 0, {}
    samples = 0
    method_counts: Dict[str, int] = defaultdict(int)
    for event in events:
        if not isinstance(event, dict):
            continue
        samples += 1
        frames = extract_frames(event)
        if not frames:
            continue
        top_method = frame_method_name(frames[0])
        if not top_method:
            continue
        method_counts[top_method] += 1
    return samples, dict(method_counts)


def duration_to_ms(raw_duration: object) -> float:
    unit = "ns"
    value = raw_duration
    if isinstance(raw_duration, dict):
        unit = str(raw_duration.get("unit", "ns"))
        value = raw_duration.get("value", 0)
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return 0.0
    if unit == "ns":
        return numeric / 1_000_000.0
    if unit == "us":
        return numeric / 1_000.0
    if unit == "ms":
        return numeric
    if unit == "s":
        return numeric * 1_000.0
    return 0.0


def parse_wall_clock_durations(
    jfr_path: Path,
) -> Tuple[float, int, Dict[str, float], Dict[str, int]]:
    events = read_jfr_events(jfr_path, WALL_CLOCK_EVENT_TYPES)
    if not events:
        return 0.0, 0, {}, {}
    total_ms = 0.0
    total_events = 0
    method_totals: Dict[str, float] = defaultdict(float)
    method_event_counts: Dict[str, int] = defaultdict(int)
    for event in events:
        if not isinstance(event, dict):
            continue
        values = event.get("values", {})
        if not isinstance(values, dict):
            continue
        duration_ms = duration_to_ms(values.get("duration"))
        if duration_ms <= 0:
            continue
        frames = extract_frames(event)
        if not frames:
            continue
        total_ms += duration_ms
        total_events += 1
        seen_methods = set()
        for frame in frames:
            method = frame_method_name(frame)
            if not method:
                continue
            method_totals[method] += duration_ms
            if method not in seen_methods:
                method_event_counts[method] += 1
                seen_methods.add(method)
    return total_ms, total_events, dict(method_totals), dict(method_event_counts)


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
    metrics_candidates = sorted(exp_dir.glob("metrics-*.txt"))
    if not metrics_candidates:
        metrics_candidates = sorted(exp_dir.glob("metrics*.txt"))
    metrics_path = metrics_candidates[0] if metrics_candidates else None
    app_log_path = exp_dir / "app.log"
    jfr_candidates = sorted(exp_dir.glob("producer-*.jfr"))
    if not jfr_candidates:
        jfr_candidates = sorted(exp_dir.glob("*.jfr"))
    jfr_path = jfr_candidates[0] if jfr_candidates else None

    if metrics_path is None or jfr_path is None:
        return None

    metrics = parse_metrics(metrics_path)
    experiment_id = int(exp_dir.name.rsplit("-", 1)[-1])
    topic = metrics.get("topic", f"test_topic_{experiment_id}")
    topic_count = infer_topic_count(topic, experiment_id)
    app_elapsed_ms = 0
    if app_log_path.exists():
        app_elapsed_ms = parse_app_log(app_log_path)
    if jfr_progress:
        if jfr_path.exists():
            print(f"[jfr] {exp_dir.name} start")
        else:
            print(f"[jfr] {exp_dir.name} missing")
    jfr_total_samples, method_samples = parse_method_samples(jfr_path)
    wall_clock_total_ms, wall_clock_event_count, method_wall_clock_ms, method_event_counts = (
        parse_wall_clock_durations(jfr_path)
    )
    method_cpu_ms: Dict[str, float] = {}
    for method, samples in method_samples.items():
        method_cpu_ms[method] = samples_to_ms(samples, jfr_total_samples, app_elapsed_ms)
    cpu_total_ms = sum(method_cpu_ms.values())
    method_total_ms: Dict[str, float] = {}
    for method in set(method_cpu_ms) | set(method_wall_clock_ms):
        method_total_ms[method] = method_cpu_ms.get(method, 0.0) + method_wall_clock_ms.get(
            method, 0.0
        )
    tracked_method_samples: Dict[str, int] = {}
    tracked_method_ms: Dict[str, float] = {}
    for key, method in TRACKED_METHODS.items():
        normalized = normalize_method_name(method)
        count = method_samples.get(normalized, 0)
        tracked_method_samples[key] = count
        tracked_method_ms[key] = method_total_ms.get(normalized, 0.0)

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
        app_elapsed_ms=app_elapsed_ms,
        jfr_total_samples=jfr_total_samples,
        cpu_total_ms=cpu_total_ms,
        wall_clock_total_ms=wall_clock_total_ms,
        wall_clock_event_count=wall_clock_event_count,
        tracked_method_samples=tracked_method_samples,
        tracked_method_ms=tracked_method_ms,
        method_samples=method_samples,
        method_cpu_ms=method_cpu_ms,
        method_wall_clock_ms=method_wall_clock_ms,
        method_event_counts=method_event_counts,
        method_total_ms=method_total_ms,
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
                "app_elapsed_ms",
                "jfr_total_samples",
                "cpu_total_ms",
                "wall_clock_total_ms",
                "wall_clock_event_count",
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
                    run.app_elapsed_ms,
                    run.jfr_total_samples,
                    f"{run.cpu_total_ms:.3f}",
                    f"{run.wall_clock_total_ms:.3f}",
                    run.wall_clock_event_count,
                    run.tracked_method_samples.get("do_send", 0),
                    run.tracked_method_samples.get("wait_on_metadata", 0),
                    run.tracked_method_samples.get("record_accumulator_append", 0),
                    run.tracked_method_samples.get("serializer_serialize", 0),
                    f"{run.tracked_method_ms.get('do_send', 0.0):.3f}",
                    f"{run.tracked_method_ms.get('wait_on_metadata', 0.0):.3f}",
                    f"{run.tracked_method_ms.get('record_accumulator_append', 0.0):.3f}",
                    f"{run.tracked_method_ms.get('serializer_serialize', 0.0):.3f}",
                    run.run_dir,
                ]
            )


def write_method_times_csv(
    out_dir: Path, runs: List[ParsedRun], top_n: int
) -> None:
    path = out_dir / "method_times.csv"
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "experiment_id",
                "topic",
                "topic_count",
                "method",
                "event_count",
                "cpu_ms",
                "wall_clock_ms",
                "total_ms",
                "run_dir",
            ]
        )
        for run in sorted(runs, key=lambda r: (r.topic_count, r.experiment_id)):
            sorted_methods = sorted(
                run.method_total_ms.items(), key=lambda x: (-x[1], x[0])
            )
            if top_n > 0:
                sorted_methods = sorted_methods[:top_n]
            for method, total_ms in sorted_methods:
                writer.writerow(
                    [
                        run.experiment_id,
                        run.topic,
                        run.topic_count,
                        method,
                        run.method_event_counts.get(method, 0),
                        f"{run.method_cpu_ms.get(method, 0.0):.3f}",
                        f"{run.method_wall_clock_ms.get(method, 0.0):.3f}",
                        f"{total_ms:.3f}",
                        run.run_dir,
                    ]
                )


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
        "--jfr-progress",
        action="store_true",
        help="Print progress while parsing jfr.jfr files.",
    )
    parser.add_argument(
        "--top-n",
        type=int,
        default=50,
        help="Top N methods by wall-clock time (0 = all).",
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
    write_method_times_csv(analysis_dir, runs, args.top_n)
    write_resource_csv(analysis_dir, runs)

    print(f"Wrote analysis CSVs to {analysis_dir}")


if __name__ == "__main__":
    main()
