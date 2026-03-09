#!/usr/bin/env python3
import argparse
import csv
import multiprocessing as mp
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
class ResourceSample:
    elapsed_sec: float
    cpu_percent: float
    memory_mb: float
    disk_percent: float
    phase: str


@dataclass
class E2ESample:
    seq: int
    topic: str
    e2e_ms: float
    elapsed_sec: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Experiment 2: precreate topics, then run delete + auto-create&produce concurrently until both complete."
    )
    parser.add_argument("--bootstrap-server", default="localhost:9092")
    parser.add_argument("--kafka-bin", default="./kafka-4.2/bin")
    parser.add_argument("--server-config", default="./kafka-4.2/config/server.properties")
    parser.add_argument("--disk-path", default=".")
    parser.add_argument("--broker-pid", type=int, default=None)
    parser.add_argument("--startup-timeout", type=float, default=60.0)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--post-seconds", type=float, default=0.0)
    parser.add_argument("--precreate-count", type=int, default=3000)
    parser.add_argument("--delete-count", type=int, default=3000)
    parser.add_argument("--produce-count", type=int, default=1500)
    parser.add_argument("--precreate-prefix", default="exp2-base-topic")
    parser.add_argument("--produce-prefix", default="exp2-new-topic")
    parser.add_argument("--partitions", type=int, default=1)
    parser.add_argument("--replication-factor", type=int, default=1)
    parser.add_argument("--message-bytes", type=int, default=1)
    parser.add_argument("--producer-count", type=int, default=1)
    parser.add_argument("--request-timeout-sec", type=float, default=30.0)
    parser.add_argument("--skip-broker-reset", action="store_true")
    parser.add_argument("--broker-log-flush-interval-ms", type=int, default=None)
    parser.add_argument("--broker-log-segment-delete-delay-ms", type=int, default=1000)
    parser.add_argument("--broker-file-delete-delay-ms", type=int, default=1000)
    parser.add_argument("--broker-log-retention-check-interval-ms", type=int, default=5000)
    parser.add_argument("--physical-delete-wait-timeout-sec", type=float, default=600.0)
    parser.add_argument("--physical-delete-poll-interval-sec", type=float, default=1.0)
    parser.add_argument("--output-prefix", default=None)
    return parser.parse_args()


def parse_log_dirs_from_config(config_path: Path) -> List[Path]:
    log_dirs: List[Path] = []
    with config_path.open("r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
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


def find_broker_process(user_pid: Optional[int]) -> psutil.Process:
    if user_pid is not None:
        proc = psutil.Process(user_pid)
        if not proc.is_running():
            raise RuntimeError(f"PID {user_pid} is not running")
        return proc

    candidates = []
    for proc in psutil.process_iter(attrs=["pid", "cmdline"]):
        try:
            cmdline = " ".join(proc.info.get("cmdline") or [])
        except (psutil.AccessDenied, psutil.ZombieProcess):
            continue
        if "kafka.Kafka" in cmdline or "kafka-server-start" in cmdline:
            candidates.append(proc)
    if not candidates:
        raise RuntimeError("Kafka broker process not found.")
    return sorted(candidates, key=lambda p: p.pid)[0]


def build_server_config_with_overrides(
    base_config: Path,
    flush_interval_ms: Optional[int],
    log_segment_delete_delay_ms: Optional[int],
    file_delete_delay_ms: Optional[int],
    log_retention_check_interval_ms: Optional[int],
) -> Path:
    if (
        flush_interval_ms is None
        and log_segment_delete_delay_ms is None
        and file_delete_delay_ms is None
        and log_retention_check_interval_ms is None
    ):
        return base_config

    with base_config.open("r", encoding="utf-8") as src:
        content = src.read()
    fd, tmp_path = tempfile.mkstemp(prefix="server_overrides_", suffix=".properties")
    os.close(fd)
    with open(tmp_path, "w", encoding="utf-8") as dst:
        dst.write(content)
        if not content.endswith("\n"):
            dst.write("\n")
        dst.write("\n# temporary overrides from experiment2 script\n")
        if flush_interval_ms is not None:
            dst.write(f"log.flush.interval.ms={flush_interval_ms}\n")
        if log_segment_delete_delay_ms is not None:
            dst.write(f"log.segment.delete.delay.ms={log_segment_delete_delay_ms}\n")
        if file_delete_delay_ms is not None:
            dst.write(f"file.delete.delay.ms={file_delete_delay_ms}\n")
        if log_retention_check_interval_ms is not None:
            dst.write(f"log.retention.check.interval.ms={log_retention_check_interval_ms}\n")
    return Path(tmp_path)


def create_topics_bulk(
    bootstrap: str,
    prefix: str,
    count: int,
    partitions: int,
    replication_factor: int,
    request_timeout_sec: float,
) -> int:
    from kafka import KafkaProducer

    _ = partitions
    _ = replication_factor
    producer = KafkaProducer(
        bootstrap_servers=bootstrap,
        client_id="exp2-precreate-producer",
        acks=1,
        retries=3,
        request_timeout_ms=int(request_timeout_sec * 1000),
    )
    created = 0
    payload = b"x"  # 1 byte payload for auto topic creation
    try:
        for i in range(1, count + 1):
            topic = f"{prefix}-{i:04d}"
            fut = producer.send(topic, value=payload)
            fut.get(timeout=request_timeout_sec)
            created += 1
            if i % 100 == 0 or i == count:
                print(f"[INFO] precreate(auto-create by produce) progress: {created}/{count}")
    finally:
        producer.flush(timeout=request_timeout_sec)
        producer.close(timeout=request_timeout_sec)
    return created


def producer_worker(
    bootstrap: str,
    produce_prefix: str,
    produce_count: int,
    producer_count: int,
    message_bytes: int,
    request_timeout_sec: float,
    elapsed_origin: float,
    stop_event: mp.Event,
    out_q: mp.Queue,
) -> None:
    try:
        from kafka import KafkaProducer

        if producer_count < 1:
            raise ValueError("--producer-count must be >= 1")

        payload = b"x" * max(1, message_bytes)
        producers = [
            KafkaProducer(
                bootstrap_servers=bootstrap,
                acks=1,
                retries=3,
                request_timeout_ms=int(request_timeout_sec * 1000),
                client_id=f"exp2-producer-{idx + 1}",
            )
            for idx in range(producer_count)
        ]
        records = []
        try:
            for i in range(1, produce_count + 1):
                if stop_event.is_set():
                    break
                topic = f"{produce_prefix}-{i:04d}"
                producer = producers[(i - 1) % producer_count]
                t0 = time.perf_counter()
                fut = producer.send(topic, value=payload)
                fut.get(timeout=request_timeout_sec)
                e2e_ms = (time.perf_counter() - t0) * 1000.0
                records.append((i, topic, e2e_ms, time.time() - elapsed_origin))
                if i % 100 == 0 or i == produce_count:
                    print(f"[PRODUCE] progress: {i}/{produce_count}")
        finally:
            for producer in producers:
                producer.flush(timeout=request_timeout_sec)
                producer.close(timeout=request_timeout_sec)
        out_q.put({"ok": True, "records": records, "produced": len(records), "target": produce_count})
    except Exception as e:
        out_q.put({"ok": False, "error": f"{type(e).__name__}: {e}"})


def delete_worker(
    bootstrap: str,
    delete_prefix: str,
    delete_count: int,
    request_timeout_sec: float,
    stop_event: mp.Event,
    out_q: mp.Queue,
) -> None:
    try:
        from kafka import KafkaAdminClient

        admin = KafkaAdminClient(
            bootstrap_servers=bootstrap,
            client_id="exp2-delete",
            request_timeout_ms=int(request_timeout_sec * 1000),
        )
        deleted = 0
        try:
            for i in range(1, delete_count + 1):
                if stop_event.is_set():
                    break
                topic = f"{delete_prefix}-{i:04d}"
                admin.delete_topics(topics=[topic], timeout_ms=int(request_timeout_sec * 1000))
                deleted += 1
                if i % 100 == 0 or i == delete_count:
                    print(f"[DELETE] progress: {i}/{delete_count}")
        finally:
            admin.close()
        out_q.put({"ok": True, "deleted": deleted, "target": delete_count})
    except Exception as e:
        out_q.put({"ok": False, "error": f"{type(e).__name__}: {e}"})


def count_existing_topics_in_log_dirs(log_dirs: List[Path], topic_prefix: str, topic_count: int) -> int:
    expected_topics = {f"{topic_prefix}-{i:04d}" for i in range(1, topic_count + 1)}
    found_topics = set()
    for log_dir in log_dirs:
        if not log_dir.exists():
            continue
        for entry in log_dir.iterdir():
            if not entry.is_dir():
                continue
            name = entry.name
            if not name.startswith(f"{topic_prefix}-"):
                continue
            base, sep, partition = name.rpartition("-")
            if sep and partition.isdigit() and base in expected_topics:
                found_topics.add(base)
    return len(found_topics)


def wait_for_physical_topic_deletion(
    log_dirs: List[Path],
    topic_prefix: str,
    topic_count: int,
    timeout_sec: float,
    poll_interval_sec: float,
) -> None:
    deadline = time.time() + timeout_sec
    last_reported = -1
    while True:
        remaining = count_existing_topics_in_log_dirs(log_dirs, topic_prefix, topic_count)
        if remaining == 0:
            print("[INFO] physical delete check complete: 0 topics remaining in log dirs")
            return

        if remaining != last_reported:
            print(f"[INFO] physical delete wait: remaining topics in log dirs = {remaining}")
            last_reported = remaining

        if time.time() >= deadline:
            raise TimeoutError(
                f"physical delete not completed within {timeout_sec}s (remaining topics: {remaining})"
            )
        time.sleep(max(0.1, poll_interval_sec))


def monitor_loop(
    broker_proc: psutil.Process,
    disk_path: Path,
    interval: float,
    stop_event: threading.Event,
    samples: List[ResourceSample],
    phase_getter,
    elapsed_origin: float,
) -> None:
    broker_proc.cpu_percent(None)
    while not stop_event.is_set():
        try:
            cpu = broker_proc.cpu_percent(None)
            mem_mb = broker_proc.memory_info().rss / (1024 * 1024)
            disk_pct = psutil.disk_usage(str(disk_path)).percent
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            break
        samples.append(
            ResourceSample(
                elapsed_sec=time.time() - elapsed_origin,
                cpu_percent=cpu,
                memory_mb=mem_mb,
                disk_percent=disk_pct,
                phase=phase_getter(),
            )
        )
        stop_event.wait(interval)


def save_resource_csv(path: Path, samples: List[ResourceSample]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["elapsed_sec", "cpu_percent", "memory_mb", "disk_percent", "phase"])
        for s in samples:
            w.writerow([f"{s.elapsed_sec:.3f}", f"{s.cpu_percent:.3f}", f"{s.memory_mb:.3f}", f"{s.disk_percent:.3f}", s.phase])


def save_e2e_csv(path: Path, records: List[E2ESample]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["seq", "topic", "e2e_ms", "elapsed_sec"])
        for r in records:
            w.writerow([r.seq, r.topic, f"{r.e2e_ms:.3f}", f"{r.elapsed_sec:.3f}"])


def save_resource_plot(path: Path, samples: List[ResourceSample]) -> None:
    x = [s.elapsed_sec for s in samples]
    cpu = [s.cpu_percent for s in samples]
    mem = [s.memory_mb for s in samples]
    disk = [s.disk_percent for s in samples]

    fig, axes = plt.subplots(3, 1, figsize=(12, 10), sharex=True)
    axes[0].plot(x, cpu, color="#d62728")
    axes[0].set_ylabel("CPU (%)")
    axes[0].set_title("Experiment 2 - Broker Resource Usage")
    axes[0].grid(alpha=0.25)

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


def save_e2e_plot(path: Path, records: List[E2ESample]) -> None:
    ordered = sorted(records, key=lambda r: r.seq)
    x = [r.seq for r in ordered]
    y = [r.e2e_ms for r in ordered]
    plt.figure(figsize=(12, 5))
    plt.scatter(x, y, s=8, color="#ff7f0e", alpha=0.8)
    plt.title("Experiment 2 - E2E per Produce (X: count, Y: E2E ms)")
    plt.xlabel("Produce Count")
    plt.ylabel("E2E (ms)")
    if x:
        plt.xlim(1, max(x))
    plt.ylim(0, 200)
    plt.grid(alpha=0.25)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def main() -> None:
    args = parse_args()
    kafka_home = Path(args.kafka_bin).expanduser().resolve().parent
    disk_path = Path(args.disk_path).expanduser().resolve()
    server_config = Path(args.server_config).expanduser().resolve()
    if not disk_path.exists():
        raise FileNotFoundError(f"disk path does not exist: {disk_path}")
    if not server_config.exists():
        raise FileNotFoundError(f"server config not found: {server_config}")

    runtime_server_config = build_server_config_with_overrides(
        server_config,
        args.broker_log_flush_interval_ms,
        args.broker_log_segment_delete_delay_ms,
        args.broker_file_delete_delay_ms,
        args.broker_log_retention_check_interval_ms,
    )
    temp_server_config: Optional[Path] = None
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

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    prefix = args.output_prefix or f"analysis/exp2_pre3000_delete1500_concurrent_autocreate1500_{ts}"
    e2e_csv = Path(f"{prefix}_e2e.csv").resolve()
    e2e_png = Path(f"{prefix}_e2e.png").resolve()
    res_csv = Path(f"{prefix}_resource.csv").resolve()
    res_png = Path(f"{prefix}_resource.png").resolve()

    phase_state = {"name": "init"}
    stop_event = threading.Event()
    resource_samples: List[ResourceSample] = []
    elapsed_origin = time.time()

    def set_phase(name: str) -> None:
        phase_state["name"] = name

    def get_phase() -> str:
        return phase_state["name"]

    def handle_sigint(_signum, _frame) -> None:
        stop_event.set()

    signal.signal(signal.SIGINT, handle_sigint)

    monitor_thread = threading.Thread(
        target=monitor_loop,
        args=(broker_proc, disk_path, args.interval, stop_event, resource_samples, get_phase, elapsed_origin),
        daemon=True,
    )
    monitor_thread.start()

    e2e_records: List[E2ESample] = []
    try:
        set_phase("precreate")
        created = create_topics_bulk(
            bootstrap=args.bootstrap_server,
            prefix=args.precreate_prefix,
            count=args.precreate_count,
            partitions=args.partitions,
            replication_factor=args.replication_factor,
            request_timeout_sec=args.request_timeout_sec,
        )
        print(f"[INFO] precreate done: {created}/{args.precreate_count}")

        set_phase("concurrent_delete_and_produce")
        produce_q: mp.Queue = mp.Queue()
        delete_q: mp.Queue = mp.Queue()
        race_stop = mp.Event()

        produce_proc = mp.Process(
            target=producer_worker,
            args=(
                args.bootstrap_server,
                args.produce_prefix,
                args.produce_count,
                args.producer_count,
                args.message_bytes,
                args.request_timeout_sec,
                elapsed_origin,
                race_stop,
                produce_q,
            ),
        )
        delete_proc = mp.Process(
            target=delete_worker,
            args=(
                args.bootstrap_server,
                args.precreate_prefix,
                args.delete_count,
                args.request_timeout_sec,
                race_stop,
                delete_q,
            ),
        )
        produce_proc.start()
        delete_proc.start()

        produce_result = None
        delete_result = None
        physical_delete_completed = False

        while produce_result is None or delete_result is None:
            if produce_result is None:
                try:
                    produce_result = produce_q.get_nowait()
                except Exception:
                    pass
            if delete_result is None:
                try:
                    delete_result = delete_q.get_nowait()
                except Exception:
                    pass

            remaining = count_existing_topics_in_log_dirs(log_dirs, args.precreate_prefix, args.delete_count)
            if remaining == 0 and not physical_delete_completed:
                physical_delete_completed = True
                set_phase("physical_delete_completed_stop_produce")
                print("[INFO] physical delete observed in log dirs (remaining=0), stopping produce/delete workers")
                race_stop.set()

            if (not produce_proc.is_alive()) and (not delete_proc.is_alive()):
                if produce_result is None:
                    try:
                        produce_result = produce_q.get_nowait()
                    except Exception:
                        pass
                if delete_result is None:
                    try:
                        delete_result = delete_q.get_nowait()
                    except Exception:
                        pass
                if produce_result is not None and delete_result is not None:
                    break
            time.sleep(max(0.1, args.physical_delete_poll_interval_sec))

        produce_proc.join(timeout=30)
        delete_proc.join(timeout=30)
        if produce_proc.is_alive():
            race_stop.set()
            produce_proc.terminate()
            produce_proc.join(timeout=5)
        if delete_proc.is_alive():
            race_stop.set()
            delete_proc.terminate()
            delete_proc.join(timeout=5)

        if produce_result is None:
            try:
                produce_result = produce_q.get_nowait()
            except Exception:
                pass
        if delete_result is None:
            try:
                delete_result = delete_q.get_nowait()
            except Exception:
                pass

        if produce_result is None:
            produce_result = {"ok": True, "records": [], "produced": 0, "target": args.produce_count}
        if delete_result is None:
            delete_result = {"ok": True, "deleted": 0, "target": args.delete_count}

        if not produce_result.get("ok"):
            raise RuntimeError(f"producer process failed: {produce_result.get('error')}")
        if not delete_result.get("ok"):
            raise RuntimeError(f"delete process failed: {delete_result.get('error')}")

        e2e_records = [
            E2ESample(seq=item[0], topic=item[1], e2e_ms=item[2], elapsed_sec=item[3])
            for item in produce_result["records"]
        ]
        print(f"[INFO] delete done: {delete_result.get('deleted')}/{delete_result.get('target')}")
        print(f"[INFO] produce done: {produce_result.get('produced')}/{produce_result.get('target')}")
        print(f"[INFO] physical delete completed while running: {physical_delete_completed}")

        if args.post_seconds > 0:
            set_phase("post")
            print(f"[INFO] post monitor wait: {args.post_seconds}s")
            stop_event.wait(args.post_seconds)
    finally:
        stop_event.set()
        monitor_thread.join(timeout=5)

    if not resource_samples:
        raise RuntimeError("No resource samples collected.")
    if not e2e_records:
        print("[WARN] No E2E samples collected.")

    save_e2e_csv(e2e_csv, e2e_records)
    save_e2e_plot(e2e_png, e2e_records)
    save_resource_csv(res_csv, resource_samples)
    save_resource_plot(res_png, resource_samples)

    print(f"[DONE] e2e csv: {e2e_csv}")
    print(f"[DONE] e2e plot: {e2e_png}")
    print(f"[DONE] resource csv: {res_csv}")
    print(f"[DONE] resource plot: {res_png}")

    if temp_server_config is not None:
        try:
            temp_server_config.unlink(missing_ok=True)
        except OSError as e:
            print(f"[WARN] failed to remove temporary server config {temp_server_config}: {e}")


if __name__ == "__main__":
    main()
