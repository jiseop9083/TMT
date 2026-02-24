#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INPUT_DIR="$ROOT_DIR/kafka-4.2/output/topic_create_latency"
INPUT_CSV=""
OUTPUT_DIR="$ROOT_DIR/kafka-4.2/figures/create-topic-latency-test"
E2E_MIN_MS=""
E2E_MAX_MS=""
ON_METADATA_MIN_MS=""
ON_METADATA_MAX_MS=""
CREATE_TOPICS_MIN_US=""
CREATE_TOPICS_MAX_US=""

usage() {
  cat <<'EOF'
Usage: run_create_topic_latency_plot_pipeline.sh [options]

Options:
  --input-dir <path>    Directory containing topic_create_requests_*.csv
  --input-csv <path>    Input topic_create_requests_*.csv
  --output-dir <path>   Output directory (default: kafka-4.2/figures/create-topic-latency-test)
  --e2e-min-ms <v>      Y-axis min for e2e_latency.png
  --e2e-max-ms <v>      Y-axis max for e2e_latency.png
  --on-metadata-min-ms <v>  Y-axis min for on_metadata_duration.png
  --on-metadata-max-ms <v>  Y-axis max for on_metadata_duration.png
  --create-topics-min-us <v> Y-axis min for create_topics_duration.png
  --create-topics-max-us <v> Y-axis max for create_topics_duration.png
  --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-dir)
      if [[ -z "${2:-}" ]]; then
        echo "--input-dir requires a value" >&2
        exit 1
      fi
      INPUT_DIR="$2"
      shift 2
      ;;
    --input-csv)
      if [[ -z "${2:-}" ]]; then
        echo "--input-csv requires a value" >&2
        exit 1
      fi
      INPUT_CSV="$2"
      shift 2
      ;;
    --output-dir)
      if [[ -z "${2:-}" ]]; then
        echo "--output-dir requires a value" >&2
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --e2e-min-ms)
      E2E_MIN_MS="$2"
      shift 2
      ;;
    --e2e-max-ms)
      E2E_MAX_MS="$2"
      shift 2
      ;;
    --on-metadata-min-ms)
      ON_METADATA_MIN_MS="$2"
      shift 2
      ;;
    --on-metadata-max-ms)
      ON_METADATA_MAX_MS="$2"
      shift 2
      ;;
    --create-topics-min-us)
      CREATE_TOPICS_MIN_US="$2"
      shift 2
      ;;
    --create-topics-max-us)
      CREATE_TOPICS_MAX_US="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
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
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi

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

mkdir -p "$OUTPUT_DIR"

TMP_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_BUILD_DIR"' EXIT

echo "Compiling TopicCreateLatencyPlot.java..."
javac -d "$TMP_BUILD_DIR" "$SCRIPT_DIR/TopicCreateLatencyPlot.java"

echo "Generating scatter plots..."
JAVA_ARGS=(--output-dir "$OUTPUT_DIR")
if [[ -n "$E2E_MIN_MS" ]]; then
  JAVA_ARGS+=(--e2e-min-ms "$E2E_MIN_MS")
fi
if [[ -n "$E2E_MAX_MS" ]]; then
  JAVA_ARGS+=(--e2e-max-ms "$E2E_MAX_MS")
fi
if [[ -n "$ON_METADATA_MIN_MS" ]]; then
  JAVA_ARGS+=(--on-metadata-min-ms "$ON_METADATA_MIN_MS")
fi
if [[ -n "$ON_METADATA_MAX_MS" ]]; then
  JAVA_ARGS+=(--on-metadata-max-ms "$ON_METADATA_MAX_MS")
fi
if [[ -n "$CREATE_TOPICS_MIN_US" ]]; then
  JAVA_ARGS+=(--create-topics-min-us "$CREATE_TOPICS_MIN_US")
fi
if [[ -n "$CREATE_TOPICS_MAX_US" ]]; then
  JAVA_ARGS+=(--create-topics-max-us "$CREATE_TOPICS_MAX_US")
fi

if [[ -n "$INPUT_CSV" ]]; then
  JAVA_ARGS+=(--input-csv "$INPUT_CSV")
  java -cp "$TMP_BUILD_DIR" TopicCreateLatencyPlot "${JAVA_ARGS[@]}"
  echo "Input CSV: $INPUT_CSV"
else
  JAVA_ARGS+=(--input-dir "$INPUT_DIR")
  java -cp "$TMP_BUILD_DIR" TopicCreateLatencyPlot "${JAVA_ARGS[@]}"
  echo "Input dir: $INPUT_DIR"
fi
echo "Output dir: $OUTPUT_DIR"
