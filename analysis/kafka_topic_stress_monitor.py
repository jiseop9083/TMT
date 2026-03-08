#!/usr/bin/env python3
import argparse
import csv
import glob
import os
import signal
import socket
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List, Optional

import matplotlib.pyplot as plt
import psutil


@dataclass
class Sample:
    elapsed_sec: float
    cpu_percent: float
    memory_mb: float
    disk_percent: float
    phase: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Grow topic count and monitor broker resource usage."
    )
    parser.add_argument("--count", type=int, default=1000, help="Number of topics to create (default: 4000)")
    parser.add_argument("--bootstrap-server", default="localhost:9092", help="Kafka bootstrap server")
    parser.add_argument("--topic-prefix", default="load-topic", help="Prefix for generated topic names")
    parser.add_argument("--partitions", type=int, default=1, help="Partitions per topic")
    parser.add_argument("--replication-factor", type=int, default=1, help="Replication factor per topic")
    parser.add_argument(
        "--kafka-bin",
        default="./kafka/bin",
        help="Kafka bin directory containing kafka-topics.sh (default: ./kafka/bin)",
    )
    parser.add_argument(
        "--broker-pid",
        type=int,
        default=None,
        help="Kafka broker PID. If not set, script auto-detects process containing 'kafka.Kafka'.",
    )
    parser.add_argument(
        "--disk-path",
        default=".",
        help="Path used for disk usage percent (default: current directory)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=0.5,
        help="Monitoring interval in seconds (default: 0.5)",
    )
    parser.add_argument(
        "--post-seconds",
        type=float,
        default=1800.0,
        help="Extra monitor time after all phases complete (default: 1800s)",
    )
    parser.add_argument(
        "--output-prefix",
        default=None,
        help="Output prefix for csv/png. Default: kafka_monitor_<timestamp>",
    )
    parser.add_argument(
        "--server-config",
        default="./kafka-4.2/config/server.properties",
        help="Kafka server.properties path used for format/start (default: ./kafka-4.2/config/server.properties)",
    )
    parser.add_argument(
        "--skip-broker-reset",
        action="store_true",
        help="Skip broker stop/log-clean/format/start sequence before topic creation.",
    )
    parser.add_argument(
        "--startup-timeout",
        type=float,
        default=60.0,
        help="Broker startup timeout in seconds (default: 60)",
    )
    parser.add_argument(
        "--topic-init-method",
        choices=["produce-auto", "admin", "cli"],
        default="produce-auto",
        help="How to create/grow topics. produce-auto sends to new topics and relies on auto-topic-create (default).",
    )
    parser.add_argument(
        "--admin-timeout-sec",
        type=float,
        default=30.0,
        help="AdminClient request timeout in seconds (default: 30)",
    )
    parser.add_argument(
        "--message-bytes",
        type=int,
        default=1,
        help="Message size in bytes for produce-auto mode (default: 1)",
    )
    parser.add_argument(
        "--retention-ms",
        type=int,
        default=1000,
        help="Per-topic retention.ms to apply after all topics are created (default: 1000)",
    )
    parser.add_argument(
        "--skip-retention-phase",
        action="store_true",
        help="Skip per-topic retention.ms update phase.",
    )
    parser.add_argument(
        "--retention-segment-ms",
        type=int,
        default=1000,
        help="Per-topic segment.ms set together with retention.ms to accelerate retention (default: 1000)",
    )
    parser.add_argument(
        "--retention-wait-timeout-sec",
        type=float,
        default=600.0,
        help="Max seconds to wait for retention cleanup completion (default: 600)",
    )
    parser.add_argument(
        "--retention-check-interval-sec",
        type=float,
        default=1.0,
        help="Polling interval while waiting for retention cleanup completion (default: 1.0)",
    )
    parser.add_argument(
        "--skip-retention-wait",
        action="store_true",
        help="Do not wait for actual retention cleanup completion after configs are applied.",
    )
    parser.add_argument(
        "--wait-retention-complete-on-skip",
        action="store_true",
        help="Even when --skip-retention-phase is set, wait until topic log cleanup completes.",
    )
    parser.add_argument(
        "--broker-default-retention-ms",
        type=int,
        default=None,
        help="Override broker default log.retention.ms during this run only (e.g. 1000).",
    )
    parser.add_argument(
        "--broker-default-segment-ms",
        type=int,
        default=None,
        help="Override broker default log.roll.ms during this run only (e.g. 1000).",
    )
    parser.add_argument(
        "--broker-default-retention-check-interval-ms",
        type=int,
        default=None,
        help="Override broker default log.retention.check.interval.ms during this run only (e.g. 1000).",
    )
    return parser.parse_args()


def resolve_topics_script(kafka_bin: str) -> Path:
    path = Path(kafka_bin).expanduser().resolve() / "kafka-topics.sh"
    if path.exists() and os.access(path, os.X_OK):
        return path

    fallback = Path("./kafka-4.2/bin/kafka-topics.sh").resolve()
    if fallback.exists() and os.access(fallback, os.X_OK):
        return fallback

    raise FileNotFoundError(
        f"kafka-topics.sh not found. checked: {path} and {fallback}. "
        "Use --kafka-bin to point to your Kafka bin directory."
    )


def resolve_kafka_home(kafka_bin: str) -> Path:
    p = Path(kafka_bin).expanduser().resolve()
    if p.name == "bin":
        return p.parent
    return p


def parse_log_dirs_from_config(config_path: Path) -> List[Path]:
    log_dirs: List[Path] = []
    with config_path.open("r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            key = k.strip()
            value = v.strip()
            if key not in {"log.dirs", "metadata.log.dir"} or not value:
                continue
            for item in value.split(","):
                d = item.strip()
                if d:
                    log_dirs.append(Path(d).expanduser())
    uniq = []
    seen = set()
    for p in log_dirs:
        rp = str(p.resolve()) if p.exists() else str(p)
        if rp not in seen:
            seen.add(rp)
            uniq.append(p)
    return uniq


def stop_kafka(kafka_home: Path) -> None:
    subprocess.run([str(kafka_home / "bin" / "kafka-server-stop.sh")], check=False, capture_output=True, text=True)
    time.sleep(5)
    subprocess.run(["pkill", "-f", "kafka.Kafka"], check=False, capture_output=True, text=True)
    time.sleep(2)


def clean_log_dirs(log_dirs: List[Path]) -> None:
    for d in log_dirs:
        subprocess.run(["rm", "-rf", str(d)], check=False)


def format_storage(kafka_home: Path, server_config: Path) -> str:
    random_uuid = subprocess.run(
        [str(kafka_home / "bin" / "kafka-storage.sh"), "random-uuid"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    subprocess.run(
        [
            str(kafka_home / "bin" / "kafka-storage.sh"),
            "format",
            "--standalone",
            "-t",
            random_uuid,
            "-c",
            str(server_config),
        ],
        check=True,
    )
    return random_uuid


def parse_bootstrap_host_port(bootstrap_server: str) -> tuple[str, int]:
    first = bootstrap_server.split(",")[0].strip()
    host, _, port_s = first.rpartition(":")
    if not host or not port_s:
        raise ValueError(f"invalid --bootstrap-server format: {bootstrap_server}")
    return host, int(port_s)


def wait_for_port(host: str, port: int, timeout_sec: float) -> None:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=2):
                return
        except OSError:
            time.sleep(2)
    raise TimeoutError(f"broker not ready on {host}:{port} within {timeout_sec}s")


def start_kafka(kafka_home: Path, server_config: Path, broker_log: Path) -> subprocess.Popen:
    broker_log.parent.mkdir(parents=True, exist_ok=True)
    out = broker_log.open("w", encoding="utf-8")
    try:
        proc = subprocess.Popen(
            [str(kafka_home / "bin" / "kafka-server-start.sh"), str(server_config)],
            stdout=out,
            stderr=subprocess.STDOUT,
            text=True,
        )
    finally:
        out.close()
    return proc


def build_server_config_with_overrides(
    base_config: Path,
    retention_ms: Optional[int],
    segment_ms: Optional[int],
    retention_check_interval_ms: Optional[int],
) -> Path:
    overrides = []
    if retention_ms is not None:
        overrides.append(("log.retention.ms", retention_ms))
    if segment_ms is not None:
        overrides.append(("log.roll.ms", segment_ms))
    if retention_check_interval_ms is not None:
        overrides.append(("log.retention.check.interval.ms", retention_check_interval_ms))

    if not overrides:
        return base_config

    with base_config.open("r", encoding="utf-8") as src:
        content = src.read()

    fd, tmp_path = tempfile.mkstemp(prefix="server_overrides_", suffix=".properties")
    os.close(fd)

    with open(tmp_path, "w", encoding="utf-8") as dst:
        dst.write(content)
        if not content.endswith("\n"):
            dst.write("\n")
        dst.write("\n# temporary overrides from kafka_topic_stress_monitor.py\n")
        for key, value in overrides:
            dst.write(f"{key}={value}\n")

    return Path(tmp_path)


def find_broker_process(user_pid: Optional[int]) -> psutil.Process:
    if user_pid is not None:
        proc = psutil.Process(user_pid)
        if not proc.is_running():
            raise RuntimeError(f"PID {user_pid} is not running")
        return proc

    candidates = []
    for proc in psutil.process_iter(attrs=["pid", "cmdline", "name"]):
        try:
            cmdline = " ".join(proc.info.get("cmdline") or [])
        except (psutil.AccessDenied, psutil.ZombieProcess):
            continue

        if "kafka.Kafka" in cmdline or "kafka-server-start" in cmdline:
            candidates.append(proc)

    if not candidates:
        raise RuntimeError(
            "Kafka broker process not found. Start broker first or provide --broker-pid."
        )

    return sorted(candidates, key=lambda p: p.pid)[0]


def create_topic(topics_script: Path, bootstrap: str, topic: str, partitions: int, replication: int) -> bool:
    cmd = [
        str(topics_script),
        "--create",
        "--if-not-exists",
        "--bootstrap-server",
        bootstrap,
        "--topic",
        topic,
        "--partitions",
        str(partitions),
        "--replication-factor",
        str(replication),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        return True

    err = (result.stderr or "") + (result.stdout or "")
    if "already exists" in err.lower():
        return False

    raise RuntimeError(f"Failed creating topic '{topic}': {err.strip()}")


def apply_retention_with_cli(
    kafka_home: Path,
    bootstrap: str,
    topic_prefix: str,
    count: int,
    retention_ms: int,
    segment_ms: int,
) -> tuple[int, int]:
    configs_script = kafka_home / "bin" / "kafka-configs.sh"
    if not configs_script.exists():
        raise FileNotFoundError(f"kafka-configs.sh not found: {configs_script}")

    updated = 0
    skipped = 0
    for i in range(1, count + 1):
        topic_name = f"{topic_prefix}-{i:04d}"
        cmd = [
            str(configs_script),
            "--bootstrap-server",
            bootstrap,
            "--alter",
            "--entity-type",
            "topics",
            "--entity-name",
            topic_name,
            "--add-config",
            f"retention.ms={retention_ms},segment.ms={segment_ms}",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            updated += 1
        else:
            err = (result.stderr or "") + (result.stdout or "")
            msg = err.lower()
            if "unknown topic or partition" in msg or "does not exist" in msg:
                skipped += 1
            else:
                raise RuntimeError(f"Failed retention update for '{topic_name}': {err.strip()}")

        if i % 100 == 0 or i == count:
            print(f"[INFO] retention progress: {i}/{count} (updated={updated}, skipped={skipped})")

    return updated, skipped


def produce_to_new_topics_with_auto_create(
    bootstrap: str,
    topic_prefix: str,
    count: int,
    message_bytes: int,
    request_timeout_sec: float,
) -> tuple[int, int]:
    try:
        from kafka import KafkaProducer
        from kafka.errors import KafkaError
    except ImportError as e:
        raise RuntimeError(
            "kafka-python is required for produce-auto mode. install with: pip3 install kafka-python"
        ) from e

    payload = b"x" * max(1, message_bytes)
    producer = KafkaProducer(
        bootstrap_servers=bootstrap,
        acks=1,
        retries=3,
        request_timeout_ms=int(request_timeout_sec * 1000),
    )

    produced = 0
    failed = 0
    try:
        for i in range(1, count + 1):
            topic_name = f"{topic_prefix}-{i:04d}"
            try:
                fut = producer.send(topic_name, value=payload)
                fut.get(timeout=request_timeout_sec)
                produced += 1
            except KafkaError as err:
                failed += 1
                raise RuntimeError(f"Failed produce for topic '{topic_name}': {err}") from err

            if i % 100 == 0 or i == count:
                print(f"[INFO] produce progress: {i}/{count} (ok={produced}, failed={failed})")
    finally:
        producer.flush(timeout=request_timeout_sec)
        producer.close(timeout=request_timeout_sec)

    return produced, failed


def create_topics_with_admin(
    admin,
    topic_prefix: str,
    count: int,
    partitions: int,
    replication: int,
) -> tuple[int, int]:
    from kafka.admin import NewTopic
    from kafka.errors import KafkaError, TopicAlreadyExistsError

    created = 0
    skipped = 0
    for i in range(1, count + 1):
        topic_name = f"{topic_prefix}-{i:04d}"
        try:
            admin.create_topics(
                new_topics=[NewTopic(name=topic_name, num_partitions=partitions, replication_factor=replication)],
                validate_only=False,
            )
            created += 1
        except TopicAlreadyExistsError:
            skipped += 1
        except KafkaError as err:
            message = str(err).lower()
            if "already exists" in message:
                skipped += 1
            else:
                raise RuntimeError(f"Failed creating topic '{topic_name}': {err}") from err

        if i % 100 == 0 or i == count:
            print(f"[INFO] create progress: {i}/{count} (created={created}, skipped={skipped})")

    return created, skipped


def apply_retention_with_admin(
    admin,
    topic_prefix: str,
    count: int,
    retention_ms: int,
    segment_ms: int,
) -> tuple[int, int]:
    from kafka.admin import ConfigResource, ConfigResourceType
    from kafka.errors import KafkaError, UnknownTopicOrPartitionError

    updated = 0
    skipped = 0

    for i in range(1, count + 1):
        topic_name = f"{topic_prefix}-{i:04d}"
        try:
            resource = ConfigResource(
                resource_type=ConfigResourceType.TOPIC,
                name=topic_name,
                configs={
                    "retention.ms": str(retention_ms),
                    "segment.ms": str(segment_ms),
                },
            )
            admin.alter_configs([resource])
            updated += 1
        except UnknownTopicOrPartitionError:
            skipped += 1
        except KafkaError as err:
            message = str(err).lower()
            if "unknown_topic_or_partition" in message or "unknown topic" in message:
                skipped += 1
            else:
                raise RuntimeError(f"Failed retention update for '{topic_name}': {err}") from err

        if i % 100 == 0 or i == count:
            print(f"[INFO] retention progress: {i}/{count} (updated={updated}, skipped={skipped})")

    return updated, skipped


def create_admin_client(bootstrap: str, request_timeout_sec: float):
    try:
        from kafka import KafkaAdminClient
    except ImportError as e:
        raise RuntimeError(
            "kafka-python is required for --topic-init-method admin/produce-auto. install with: pip3 install kafka-python"
        ) from e

    return KafkaAdminClient(
        bootstrap_servers=bootstrap,
        client_id="topic-stress-monitor",
        request_timeout_ms=int(request_timeout_sec * 1000),
    )


def wait_for_retention_cleanup(
    log_dirs: List[Path],
    topic_prefix: str,
    count: int,
    timeout_sec: float,
    check_interval_sec: float,
) -> tuple[bool, int]:
    topic_dirs = [f"{topic_prefix}-{i:04d}-0" for i in range(1, count + 1)]
    deadline = time.time() + timeout_sec

    while time.time() < deadline:
        pending = 0
        for td in topic_dirs:
            has_data = False
            for base in log_dirs:
                d = base / td
                if not d.exists():
                    continue
                for logfile in glob.glob(str(d / "*.log")):
                    try:
                        if os.path.getsize(logfile) > 0:
                            has_data = True
                            break
                    except OSError:
                        continue
                if has_data:
                    break
            if has_data:
                pending += 1

        if pending == 0:
            return True, 0

        print(f"[INFO] retention wait: pending topics with data={pending}/{count}")
        time.sleep(check_interval_sec)

    return False, pending


def monitor_loop(
    broker_proc: psutil.Process,
    disk_path: Path,
    interval: float,
    stop_event: threading.Event,
    samples: List[Sample],
    phase_getter,
) -> None:
    start = time.time()
    broker_proc.cpu_percent(None)

    while not stop_event.is_set():
        now = time.time()
        try:
            cpu = broker_proc.cpu_percent(None)
            mem_mb = broker_proc.memory_info().rss / (1024 * 1024)
            disk_pct = psutil.disk_usage(str(disk_path)).percent
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            break

        samples.append(Sample(now - start, cpu, mem_mb, disk_pct, phase_getter()))
        stop_event.wait(interval)


def save_csv(samples: List[Sample], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["elapsed_sec", "cpu_percent", "memory_mb", "disk_percent", "phase"])
        for s in samples:
            writer.writerow([
                f"{s.elapsed_sec:.3f}",
                f"{s.cpu_percent:.3f}",
                f"{s.memory_mb:.3f}",
                f"{s.disk_percent:.3f}",
                s.phase,
            ])


def save_plot(samples: List[Sample], path: Path) -> None:
    x = [s.elapsed_sec for s in samples]
    cpu = [s.cpu_percent for s in samples]
    mem = [s.memory_mb for s in samples]
    disk = [s.disk_percent for s in samples]

    fig, axes = plt.subplots(3, 1, figsize=(12, 10), sharex=True)

    retention_start = None
    for s in samples:
        if s.phase.startswith("retention"):
            retention_start = s.elapsed_sec
            break
    if retention_start is not None:
        for ax in axes:
            ax.axvspan(retention_start, x[-1], color="#ffcccb", alpha=0.22, label="Retention Phase")

    axes[0].plot(x, cpu, color="#d62728")
    axes[0].set_ylabel("CPU (%)")
    axes[0].set_title("Kafka Broker Resource Usage")
    axes[0].grid(alpha=0.25)
    if retention_start is not None:
        axes[0].legend(loc="upper right")

    axes[1].plot(x, mem, color="#1f77b4")
    axes[1].set_ylabel("Memory (MB)")
    axes[1].grid(alpha=0.25)

    axes[2].plot(x, disk, color="#2ca02c")
    axes[2].set_ylabel("Disk (%)")
    axes[2].set_xlabel("Elapsed Time (sec)")
    axes[2].grid(alpha=0.25)

    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def main() -> None:
    args = parse_args()

    topics_script = resolve_topics_script(args.kafka_bin)
    kafka_home = resolve_kafka_home(args.kafka_bin)
    disk_path = Path(args.disk_path).expanduser().resolve()
    server_config = Path(args.server_config).expanduser().resolve()
    temp_server_config: Optional[Path] = None
    if not disk_path.exists():
        raise FileNotFoundError(f"disk path does not exist: {disk_path}")
    if not server_config.exists():
        raise FileNotFoundError(f"server config not found: {server_config}")

    runtime_server_config = build_server_config_with_overrides(
        base_config=server_config,
        retention_ms=args.broker_default_retention_ms,
        segment_ms=args.broker_default_segment_ms,
        retention_check_interval_ms=args.broker_default_retention_check_interval_ms,
    )
    if runtime_server_config != server_config:
        temp_server_config = runtime_server_config
        print(f"[INFO] using temporary server config overrides: {runtime_server_config}")
    log_dirs = parse_log_dirs_from_config(runtime_server_config)
    if not log_dirs:
        raise RuntimeError(f"no log dirs found in {runtime_server_config}")

    host, port = parse_bootstrap_host_port(args.bootstrap_server)

    if not args.skip_broker_reset:
        print("[INFO] stopping kafka broker")
        stop_kafka(kafka_home)

        print(f"[INFO] cleaning log dirs: {', '.join(str(p) for p in log_dirs)}")
        clean_log_dirs(log_dirs)

        cluster_id = format_storage(kafka_home, runtime_server_config)
        print(f"[INFO] storage formatted. cluster id: {cluster_id}")

        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        broker_log = Path(f"broker_start_{ts}.log").resolve()
        started = start_kafka(kafka_home, runtime_server_config, broker_log)
        print(f"[INFO] broker start requested (pid={started.pid}), log: {broker_log}")
        wait_for_port(host, port, args.startup_timeout)
        time.sleep(5)
        print(f"[INFO] broker is ready on {host}:{port}")

    broker_proc = find_broker_process(args.broker_pid)
    print(f"[INFO] broker PID for monitoring: {broker_proc.pid}")
    print(f"[INFO] kafka-topics script: {topics_script}")

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    prefix = args.output_prefix or f"kafka_monitor_{ts}"
    csv_path = Path(f"{prefix}.csv").resolve()
    png_path = Path(f"{prefix}.png").resolve()

    samples: List[Sample] = []
    stop_event = threading.Event()
    phase_state = {"name": "init"}

    def set_phase(name: str) -> None:
        phase_state["name"] = name

    def get_phase() -> str:
        return phase_state["name"]

    def handle_sigint(_signum, _frame):
        stop_event.set()

    signal.signal(signal.SIGINT, handle_sigint)

    monitor_thread = threading.Thread(
        target=monitor_loop,
        args=(broker_proc, disk_path, args.interval, stop_event, samples, get_phase),
        daemon=True,
    )
    monitor_thread.start()

    init_success = 0
    init_failed = 0
    retention_updated = 0
    retention_skipped = 0

    try:
        if args.topic_init_method == "produce-auto":
            set_phase("produce")
            print(
                f"[INFO] produce-auto: sending {args.message_bytes} byte message to each new topic "
                f"up to {args.count} topics"
            )
            init_success, init_failed = produce_to_new_topics_with_auto_create(
                bootstrap=args.bootstrap_server,
                topic_prefix=args.topic_prefix,
                count=args.count,
                message_bytes=args.message_bytes,
                request_timeout_sec=args.admin_timeout_sec,
            )
            if not args.skip_retention_phase:
                set_phase("retention_apply")
                print(f"[INFO] applying retention.ms={args.retention_ms} to {args.count} topics (after produce phase)")
                admin = create_admin_client(args.bootstrap_server, args.admin_timeout_sec)
                try:
                    retention_updated, retention_skipped = apply_retention_with_admin(
                        admin=admin,
                        topic_prefix=args.topic_prefix,
                        count=args.count,
                        retention_ms=args.retention_ms,
                        segment_ms=args.retention_segment_ms,
                    )
                finally:
                    admin.close()
                if not args.skip_retention_wait:
                    set_phase("retention_wait")
                    done, pending = wait_for_retention_cleanup(
                        log_dirs=log_dirs,
                        topic_prefix=args.topic_prefix,
                        count=args.count,
                        timeout_sec=args.retention_wait_timeout_sec,
                        check_interval_sec=args.retention_check_interval_sec,
                    )
                    if done:
                        print("[INFO] retention wait done: all topic log segments cleaned.")
                    else:
                        print(f"[WARN] retention wait timeout: pending topics with data={pending}")
            elif args.wait_retention_complete_on_skip:
                set_phase("retention_wait")
                print("[INFO] waiting for retention cleanup completion with broker default retention settings")
                done, pending = wait_for_retention_cleanup(
                    log_dirs=log_dirs,
                    topic_prefix=args.topic_prefix,
                    count=args.count,
                    timeout_sec=args.retention_wait_timeout_sec,
                    check_interval_sec=args.retention_check_interval_sec,
                )
                if done:
                    print("[INFO] retention wait done: all topic log segments cleaned.")
                else:
                    print(f"[WARN] retention wait timeout: pending topics with data={pending}")
        elif args.topic_init_method == "admin":
            set_phase("create")
            admin = create_admin_client(args.bootstrap_server, args.admin_timeout_sec)
            try:
                init_success, init_failed = create_topics_with_admin(
                    admin=admin,
                    topic_prefix=args.topic_prefix,
                    count=args.count,
                    partitions=args.partitions,
                    replication=args.replication_factor,
                )
                if not args.skip_retention_phase:
                    set_phase("retention_apply")
                    print(f"[INFO] applying retention.ms={args.retention_ms} to {args.count} topics (after create phase)")
                    retention_updated, retention_skipped = apply_retention_with_admin(
                        admin=admin,
                        topic_prefix=args.topic_prefix,
                        count=args.count,
                        retention_ms=args.retention_ms,
                        segment_ms=args.retention_segment_ms,
                    )
            finally:
                admin.close()
            if (not args.skip_retention_phase) and (not args.skip_retention_wait):
                set_phase("retention_wait")
                done, pending = wait_for_retention_cleanup(
                    log_dirs=log_dirs,
                    topic_prefix=args.topic_prefix,
                    count=args.count,
                    timeout_sec=args.retention_wait_timeout_sec,
                    check_interval_sec=args.retention_check_interval_sec,
                )
                if done:
                    print("[INFO] retention wait done: all topic log segments cleaned.")
                else:
                    print(f"[WARN] retention wait timeout: pending topics with data={pending}")
            elif args.skip_retention_phase and args.wait_retention_complete_on_skip:
                set_phase("retention_wait")
                print("[INFO] waiting for retention cleanup completion with broker default retention settings")
                done, pending = wait_for_retention_cleanup(
                    log_dirs=log_dirs,
                    topic_prefix=args.topic_prefix,
                    count=args.count,
                    timeout_sec=args.retention_wait_timeout_sec,
                    check_interval_sec=args.retention_check_interval_sec,
                )
                if done:
                    print("[INFO] retention wait done: all topic log segments cleaned.")
                else:
                    print(f"[WARN] retention wait timeout: pending topics with data={pending}")
        else:
            set_phase("create")
            for i in range(1, args.count + 1):
                topic_name = f"{args.topic_prefix}-{i:04d}"
                made = create_topic(
                    topics_script,
                    args.bootstrap_server,
                    topic_name,
                    args.partitions,
                    args.replication_factor,
                )
                if made:
                    init_success += 1
                else:
                    init_failed += 1

                if i % 100 == 0 or i == args.count:
                    print(f"[INFO] create progress: {i}/{args.count} (created={init_success}, skipped={init_failed})")

            if not args.skip_retention_phase:
                set_phase("retention_apply")
                print(f"[INFO] applying retention.ms={args.retention_ms} to {args.count} topics (after creation)")
                retention_updated, retention_skipped = apply_retention_with_cli(
                    kafka_home=kafka_home,
                    bootstrap=args.bootstrap_server,
                    topic_prefix=args.topic_prefix,
                    count=args.count,
                    retention_ms=args.retention_ms,
                    segment_ms=args.retention_segment_ms,
                )
                if not args.skip_retention_wait:
                    set_phase("retention_wait")
                    done, pending = wait_for_retention_cleanup(
                        log_dirs=log_dirs,
                        topic_prefix=args.topic_prefix,
                        count=args.count,
                        timeout_sec=args.retention_wait_timeout_sec,
                        check_interval_sec=args.retention_check_interval_sec,
                    )
                    if done:
                        print("[INFO] retention wait done: all topic log segments cleaned.")
                    else:
                        print(f"[WARN] retention wait timeout: pending topics with data={pending}")
            elif args.wait_retention_complete_on_skip:
                set_phase("retention_wait")
                print("[INFO] waiting for retention cleanup completion with broker default retention settings")
                done, pending = wait_for_retention_cleanup(
                    log_dirs=log_dirs,
                    topic_prefix=args.topic_prefix,
                    count=args.count,
                    timeout_sec=args.retention_wait_timeout_sec,
                    check_interval_sec=args.retention_check_interval_sec,
                )
                if done:
                    print("[INFO] retention wait done: all topic log segments cleaned.")
                else:
                    print(f"[WARN] retention wait timeout: pending topics with data={pending}")

        if args.post_seconds > 0:
            set_phase("post")
            print(f"[INFO] all phases done. keep monitoring for {args.post_seconds}s")
            stop_event.wait(args.post_seconds)

    finally:
        stop_event.set()
        monitor_thread.join(timeout=5)

    if not samples:
        raise RuntimeError("No monitoring samples collected.")

    save_csv(samples, csv_path)
    save_plot(samples, png_path)

    print(
        f"[DONE] init_success={init_success}, init_failed={init_failed}, retention_updated={retention_updated}, "
        f"retention_skipped={retention_skipped}, samples={len(samples)}"
    )
    print(f"[DONE] csv: {csv_path}")
    print(f"[DONE] plot: {png_path}")

    if temp_server_config is not None:
        try:
            temp_server_config.unlink(missing_ok=True)
        except OSError as e:
            print(f"[WARN] failed to remove temporary server config {temp_server_config}: {e}")


if __name__ == "__main__":
    main()
