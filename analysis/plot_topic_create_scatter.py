#!/usr/bin/env python3

import argparse
import csv
from pathlib import Path

import matplotlib.pyplot as plt


def load_rows(csv_path: Path):
    seq = []
    e2e_ms = []
    on_meta_ms = []
    create_us = []

    with csv_path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("status") != "OK":
                continue
            seq_val = row.get("seq", "").strip()
            if not seq_val:
                continue
            x = int(seq_val)

            seq.append(x)

            e2e_us = row.get("e2e_latency_us", "").strip()
            on_meta_us = row.get("on_metadata_duration_us", "").strip()
            create_topic_us = row.get("create_topics_duration_us", "").strip()

            e2e_ms.append(float(e2e_us) / 1000.0 if e2e_us else None)
            on_meta_ms.append(float(on_meta_us) / 1000.0 if on_meta_us else None)
            create_us.append(float(create_topic_us) if create_topic_us else None)

    return seq, e2e_ms, on_meta_ms, create_us


def scatter_plot(x, y, title, ylabel, output_path: Path, color):
    xs = []
    ys = []
    for xi, yi in zip(x, y):
        if yi is None:
            continue
        xs.append(xi)
        ys.append(yi)

    plt.figure(figsize=(11, 4.5))
    plt.scatter(xs, ys, s=8, alpha=0.65, color=color, edgecolors="none")
    plt.title(title)
    plt.xlabel("Topic Sequence (seq)")
    plt.ylabel(ylabel)
    plt.grid(alpha=0.25)
    plt.tight_layout()
    plt.savefig(output_path, dpi=180)
    plt.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input-csv",
        default="kafka-4.2/output/topic_create_latency/topic_create_requests_20260223_215534.csv",
    )
    parser.add_argument("--output-dir", default="figures/create-topic-latency-test")
    args = parser.parse_args()

    input_csv = Path(args.input_csv)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    seq, e2e_ms, on_meta_ms, create_us = load_rows(input_csv)
    stem = input_csv.stem

    scatter_plot(
        seq,
        e2e_ms,
        "Topic Create E2E Latency Scatter",
        "e2e_latency (ms)",
        output_dir / f"{stem}_e2e_latency_ms_scatter.png",
        color="#2f6fdf",
    )
    scatter_plot(
        seq,
        on_meta_ms,
        "Broker onMetadataUpdate Duration Scatter",
        "on_metadata_duration (ms)",
        output_dir / f"{stem}_on_metadata_duration_ms_scatter.png",
        color="#0f9d58",
    )
    scatter_plot(
        seq,
        create_us,
        "Controller createTopics Duration Scatter",
        "create_topics_duration (us)",
        output_dir / f"{stem}_create_topics_duration_us_scatter.png",
        color="#d17a00",
    )


if __name__ == "__main__":
    main()
