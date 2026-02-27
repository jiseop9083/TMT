#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INPUT_DIR="$ROOT_DIR/kafka-4.2/output/topic-create-with-message-load"
INPUT_CSV=""
OUTPUT_DIR=""
OUTPUT_DIR_SET=false
RESOURCE_INPUT_DIR=""

E2E_MIN_MS="0"
E2E_MAX_MS="100"
ON_METADATA_MIN_MS="0"
ON_METADATA_MAX_MS="100"
CREATE_TOPIC_MIN_US="0"
CREATE_TOPIC_MAX_US="800"
TOPIC_MIN=""
TOPIC_MAX=""

usage() {
  cat <<'EOF'
Usage: run_topic_create_with_message_load_plot_pipeline.sh [options]

Options:
  --input-dir <path>    Directory containing topic_create_requests_*.csv and system/*.csv
  --input-csv <path>    Single topic_create_requests_*.csv
  --resource-input-dir <path>
                        Directory containing *_broker_resource.csv (default: <input-dir>/system)
  --output-dir <path>   Output directory (default: kafka-4.2/figures/<input-dir-name>)
  --e2e-min-ms <v>
  --e2e-max-ms <v>
  --broker-metadata-update-min-ms <v>
  --broker-metadata-update-max-ms <v>
  --controller-topic-creation-min-us <v>
  --controller-topic-creation-max-us <v>
  --topic-min <n>      Minimum topic index (x-axis lower bound)
  --topic-max <n>      Maximum topic index (x-axis upper bound)
  --help                Show this help
EOF
}

generate_resource_plots() {
  local input_dir="$1"
  local out_dir="$2"
  if [[ ! -d "$input_dir" ]]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found; skipping resource plots."
    return 0
  fi

  mkdir -p "$out_dir"
  local csv_path
  local found=0
  for csv_path in "$input_dir"/*_broker_resource.csv; do
    if [[ ! -f "$csv_path" ]]; then
      continue
    fi
    found=1
    local base_name run_ts
    base_name="$(basename "$csv_path")"
    run_ts="${base_name%_broker_resource.csv}"
    python3 - "$csv_path" "$out_dir" "$run_ts" <<'PY'
import csv
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
run_ts = sys.argv[3] or "unknown"

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except Exception as e:
    print(f"matplotlib unavailable; skipping plots for {csv_path}: {e}")
    sys.exit(0)

rows = []
with csv_path.open(newline="") as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

if not rows:
    print(f"No rows in {csv_path}; skipping plots.")
    sys.exit(0)

def num(v):
    if v is None:
        return None
    v = str(v).strip()
    if not v:
        return None
    try:
        return float(v)
    except ValueError:
        return None

times = []
for i, r in enumerate(rows):
    epoch = num(r.get("epoch_ms"))
    times.append((epoch / 1000.0) if epoch is not None else float(i))
t0 = times[0]
times = [t - t0 for t in times]

cpu = [num(r.get("cpu_pct")) for r in rows]
rss_mb = [((num(r.get("rss_kb")) or 0.0) / 1024.0) if num(r.get("rss_kb")) is not None else None for r in rows]
heap_used_mb = [((num(r.get("heap_used_kb")) or 0.0) / 1024.0) if num(r.get("heap_used_kb")) is not None else None for r in rows]

# topic-create load script uses storage_kb (not log_dir_storage_kb)
storage_kb_values = [num(r.get("storage_kb")) for r in rows]
storage_mb = [((v or 0.0) / 1024.0) if v is not None else None for v in storage_kb_values]

def has_values(series):
    return any(v is not None for v in series)

def save_plot(path, title, y_label, series):
    fig, ax = plt.subplots(figsize=(10, 4))
    for label, vals, color in series:
        if not has_values(vals):
            continue
        ax.plot(times, vals, label=label, linewidth=1.7, color=color)
    ax.set_title(title)
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel(y_label)
    ax.grid(alpha=0.25, linestyle="--")
    if len(ax.lines) > 1:
        ax.legend()
    fig.tight_layout()
    fig.savefig(path, dpi=140)
    plt.close(fig)

cpu_png = out_dir / f"cpu_{run_ts}.png"
mem_png = out_dir / f"memory_{run_ts}.png"
disk_png = out_dir / f"disk_{run_ts}.png"

if has_values(cpu):
    save_plot(cpu_png, f"Broker CPU Usage ({run_ts})", "CPU (%)", [("cpu_pct", cpu, "#d7263d")])
if has_values(rss_mb) or has_values(heap_used_mb):
    save_plot(
        mem_png,
        f"Broker Memory Usage ({run_ts})",
        "Memory (MB)",
        [
            ("memory usage", rss_mb, "#1f77b4"),
            ("heap usage", heap_used_mb, "#2ca02c"),
        ],
    )
if has_values(storage_mb):
    save_plot(disk_png, f"Broker Log Storage ({run_ts})", "Storage (MB)", [("storage_mb", storage_mb, "#6a4c93")])

print(f"Wrote resource plots for {csv_path}")
PY
  done

  if [[ "$found" -eq 0 ]]; then
    echo "No *_broker_resource.csv files found under $input_dir; skipping extra resource plots."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-dir)
      INPUT_DIR="$2"; shift 2 ;;
    --input-csv)
      INPUT_CSV="$2"; shift 2 ;;
    --resource-input-dir)
      RESOURCE_INPUT_DIR="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; OUTPUT_DIR_SET=true; shift 2 ;;
    --e2e-min-ms)
      E2E_MIN_MS="$2"; shift 2 ;;
    --e2e-max-ms)
      E2E_MAX_MS="$2"; shift 2 ;;
    --broker-metadata-update-min-ms)
      ON_METADATA_MIN_MS="$2"; shift 2 ;;
    --broker-metadata-update-max-ms)
      ON_METADATA_MAX_MS="$2"; shift 2 ;;
    --controller-topic-creation-min-us)
      CREATE_TOPIC_MIN_US="$2"; shift 2 ;;
    --controller-topic-creation-max-us)
      CREATE_TOPIC_MAX_US="$2"; shift 2 ;;
    --topic-min)
      TOPIC_MIN="$2"; shift 2 ;;
    --topic-max)
      TOPIC_MAX="$2"; shift 2 ;;
    --help|-h)
      usage
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if ! command -v javac >/dev/null 2>&1; then
  echo "javac not found in PATH" >&2
  exit 1
fi
if ! command -v java >/dev/null 2>&1; then
  echo "java not found in PATH" >&2
  exit 1
fi
if [[ -n "$INPUT_CSV" && "$INPUT_CSV" != /* ]]; then
  INPUT_CSV="$ROOT_DIR/$INPUT_CSV"
fi
if [[ "$INPUT_DIR" != /* ]]; then
  INPUT_DIR="$ROOT_DIR/$INPUT_DIR"
fi
if [[ -n "$RESOURCE_INPUT_DIR" && "$RESOURCE_INPUT_DIR" != /* ]]; then
  RESOURCE_INPUT_DIR="$ROOT_DIR/$RESOURCE_INPUT_DIR"
fi
if [[ "$OUTPUT_DIR_SET" == true ]]; then
  if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
  fi
else
  input_base=""
  if [[ -n "$INPUT_CSV" ]]; then
    input_base="$(basename "$(dirname "$INPUT_CSV")")"
  else
    input_base="$(basename "$INPUT_DIR")"
  fi
  OUTPUT_DIR="$ROOT_DIR/kafka-4.2/figures/$input_base"
fi
if [[ -z "$RESOURCE_INPUT_DIR" ]]; then
  RESOURCE_INPUT_DIR="$INPUT_DIR/system"
fi

mkdir -p "$OUTPUT_DIR"

if [[ -n "$INPUT_CSV" ]]; then
  if [[ ! -f "$INPUT_CSV" ]]; then
    echo "Input CSV not found: $INPUT_CSV" >&2
    exit 1
  fi
else
  if [[ ! -d "$INPUT_DIR" ]]; then
    echo "Input dir not found: $INPUT_DIR" >&2
    exit 1
  fi
fi

if [[ ! -d "$RESOURCE_INPUT_DIR" ]]; then
  echo "Resource input dir not found: $RESOURCE_INPUT_DIR" >&2
  exit 1
fi

TMP_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_BUILD_DIR"' EXIT

echo "Compiling TopicCreateLatencyPlot.java..."
javac -d "$TMP_BUILD_DIR" "$SCRIPT_DIR/TopicCreateLatencyPlot.java"
echo "Compiling BrokerResourceTrendPlot.java..."
javac -d "$TMP_BUILD_DIR" "$SCRIPT_DIR/BrokerResourceTrendPlot.java"

echo "Generating latency scatter plots..."
LATENCY_OUTPUT_DIR="$OUTPUT_DIR/latency"
mkdir -p "$LATENCY_OUTPUT_DIR"

JAVA_ARGS=(--output-dir "$LATENCY_OUTPUT_DIR")
JAVA_ARGS+=(--e2e-min-ms "$E2E_MIN_MS")
JAVA_ARGS+=(--e2e-max-ms "$E2E_MAX_MS")
JAVA_ARGS+=(--broker-metadata-update-min-ms "$ON_METADATA_MIN_MS")
JAVA_ARGS+=(--broker-metadata-update-max-ms "$ON_METADATA_MAX_MS")
JAVA_ARGS+=(--controller-topic-creation-min-us "$CREATE_TOPIC_MIN_US")
JAVA_ARGS+=(--controller-topic-creation-max-us "$CREATE_TOPIC_MAX_US")
if [[ -n "$TOPIC_MIN" ]]; then
  JAVA_ARGS+=(--topic-min "$TOPIC_MIN")
fi
if [[ -n "$TOPIC_MAX" ]]; then
  JAVA_ARGS+=(--topic-max "$TOPIC_MAX")
fi

if [[ -n "$INPUT_CSV" ]]; then
  JAVA_ARGS+=(--input-csv "$INPUT_CSV")
else
  JAVA_ARGS+=(--input-dir "$INPUT_DIR")
fi
java -cp "$TMP_BUILD_DIR" TopicCreateLatencyPlot "${JAVA_ARGS[@]}"

echo "Generating broker resource trend line plots..."
RESOURCE_OUTPUT_DIR="$OUTPUT_DIR/resource_trends"
RESOURCE_SUMMARY_CSV="$OUTPUT_DIR/resource_summary.csv"
java -cp "$TMP_BUILD_DIR" BrokerResourceTrendPlot \
  --input-dir "$RESOURCE_INPUT_DIR" \
  --output-dir "$RESOURCE_OUTPUT_DIR" \
  --summary-csv "$RESOURCE_SUMMARY_CSV"

echo "Generating broker resource plots (cpu/memory/disk)..."
RESOURCE_SIMPLE_OUTPUT_DIR="$OUTPUT_DIR/resource"
generate_resource_plots "$RESOURCE_INPUT_DIR" "$RESOURCE_SIMPLE_OUTPUT_DIR"

echo "Input dir: $INPUT_DIR"
echo "Resource input dir: $RESOURCE_INPUT_DIR"
echo "Output dir: $OUTPUT_DIR"
echo "Latency plots: $LATENCY_OUTPUT_DIR"
echo "Resource plots: $RESOURCE_OUTPUT_DIR"
echo "Resource simple plots: $RESOURCE_SIMPLE_OUTPUT_DIR"
echo "Resource summary: $RESOURCE_SUMMARY_CSV"
