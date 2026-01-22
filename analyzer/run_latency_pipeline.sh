#!/usr/bin/env bash
set -euo pipefail

MODE="all"
if [[ "${1:-}" == "--latency-only" ]]; then
  MODE="latency"
  shift
fi

OUT_DIR="${1:-client_profile_job/out}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${RUN_IN_DOCKER:-}" ]]; then
  IMAGE_NAME="dynamic-analysis-analyzer"
  echo "Building docker image: ${IMAGE_NAME}"
  docker build -f "$ROOT_DIR/analyzer/Dockerfile" -t "$IMAGE_NAME" "$ROOT_DIR"
  echo "Running pipeline inside docker..."
  docker run --rm \
    -e RUN_IN_DOCKER=1 \
    -e RUN_MODE="$MODE" \
    -v "$ROOT_DIR":/workspace \
    -w /workspace \
    "$IMAGE_NAME" \
    /workspace/analyzer/run_latency_pipeline.sh "$OUT_DIR"
  exit 0
fi

if ! command -v javac >/dev/null 2>&1; then
  echo "javac not found in PATH" >&2
  exit 1
fi

if ! command -v java >/dev/null 2>&1; then
  echo "java not found in PATH" >&2
  exit 1
fi

RUN_MODE="${RUN_MODE:-all}"

TMP_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_BUILD_DIR"' EXIT

echo "Compiling analysis tools (container-local)..."
javac -d "$TMP_BUILD_DIR" \
  "$ROOT_DIR/analyzer/JfrLatencyBreakdown.java" \
  "$ROOT_DIR/analyzer/JfrLatencyPlot.java"

echo "Generating latency_breakdown.csv (JSON parse + CSV export)..."
java -cp "$TMP_BUILD_DIR" JfrLatencyBreakdown --out-dir "$OUT_DIR"

if [[ "$RUN_MODE" == "latency" ]]; then
  exit 0
fi

ZSCORE_THRESHOLD=2.33 # 99%
echo "Generating plots from latency_breakdown.csv..."
java -cp "$TMP_BUILD_DIR" JfrLatencyPlot --out-dir "$OUT_DIR" --zscore-filter --zscore-threshold "$ZSCORE_THRESHOLD"