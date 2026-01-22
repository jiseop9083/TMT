#!/usr/bin/env bash
set -euo pipefail

MODE="all"
OUT_DIR=""
ZSCORE_FILTER=1
ZSCORE_THRESHOLD="2.33"
AGGREGATE_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --latency-only)
      MODE="latency"
      shift
      ;;
    --plot-only)
      MODE="plot"
      shift
      ;;
    --zscore-filter)
      ZSCORE_FILTER=1
      shift
      ;;
    --zscore-threshold)
      if [[ -z "${2:-}" ]]; then
        echo "--zscore-threshold requires a value" >&2
        exit 1
      fi
      ZSCORE_THRESHOLD="$2"
      shift 2
      ;;
    --aggregate-only)
      AGGREGATE_ONLY=1
      shift
      ;;
    --out-dir)
      if [[ -z "${2:-}" ]]; then
        echo "--out-dir requires a value" >&2
        exit 1
      fi
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      if [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="$1"
        shift
      else
        echo "Unknown argument: $1" >&2
        exit 1
      fi
      ;;
  esac
done

OUT_DIR="${OUT_DIR:-client_profile_job/out}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${RUN_IN_DOCKER:-}" ]]; then
  IMAGE_NAME="dynamic-analysis-analyzer"
  echo "Building docker image: ${IMAGE_NAME}"
  docker build -f "$ROOT_DIR/analyzer_single_container/Dockerfile" -t "$IMAGE_NAME" "$ROOT_DIR"
  echo "Running pipeline inside docker..."
  # Avoid Git Bash path conversion for the container path.
  export MSYS2_ARG_CONV_EXCL="/workspace"
  ROOT_DIR_DOCKER="$ROOT_DIR"
  if command -v cygpath >/dev/null 2>&1; then
    ROOT_DIR_DOCKER="$(cygpath -m "$ROOT_DIR")"
  fi
  DOCKER_MODE_ARG=""
  if [[ "$MODE" == "latency" ]]; then
    DOCKER_MODE_ARG="--latency-only"
  elif [[ "$MODE" == "plot" ]]; then
    DOCKER_MODE_ARG="--plot-only"
  fi
  DOCKER_ZSCORE_ARG=()
  if [[ "$ZSCORE_FILTER" -eq 1 ]]; then
    DOCKER_ZSCORE_ARG+=(--zscore-filter)
  fi
  DOCKER_AGG_ARG=()
  if [[ "$AGGREGATE_ONLY" -eq 1 ]]; then
    DOCKER_AGG_ARG+=(--aggregate-only)
  fi
  docker run --rm \
    -e RUN_IN_DOCKER=1 \
    -e RUN_MODE="$MODE" \
    --mount type=bind,source="$ROOT_DIR_DOCKER",target=/workspace \
    -w /workspace \
    "$IMAGE_NAME" \
    /workspace/analyzer_single_container/run_latency_pipeline.sh \
    ${DOCKER_MODE_ARG} \
    "$OUT_DIR" \
    "${DOCKER_ZSCORE_ARG[@]}" \
    "${DOCKER_AGG_ARG[@]}" \
    --zscore-threshold "$ZSCORE_THRESHOLD"
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
  "$ROOT_DIR/analyzer_single_container/JfrLatencyBreakdown.java" \
  "$ROOT_DIR/analyzer_single_container/JfrLatencyPlot.java"

if [[ "$RUN_MODE" == "plot" ]]; then
  echo "Skipping latency_breakdown.csv generation (plot-only mode)."
elif [[ "$RUN_MODE" == "latency" ]]; then
  echo "Generating latency_breakdown.csv (JSON parse + CSV export)..."
  java -cp "$TMP_BUILD_DIR" JfrLatencyBreakdown --out-dir "$OUT_DIR"
  exit 0
else
  echo "Generating latency_breakdown.csv (JSON parse + CSV export)..."
  java -cp "$TMP_BUILD_DIR" JfrLatencyBreakdown --out-dir "$OUT_DIR"
fi

echo "Generating plots from latency_breakdown.csv..."
PLOT_ARGS=(--out-dir "$OUT_DIR" --zscore-threshold "$ZSCORE_THRESHOLD")
if [[ "$ZSCORE_FILTER" -eq 1 ]]; then
  PLOT_ARGS+=(--zscore-filter)
fi
if [[ "$AGGREGATE_ONLY" -eq 1 ]]; then
  PLOT_ARGS+=(--aggregate-only)
fi
java -cp "$TMP_BUILD_DIR" JfrLatencyPlot "${PLOT_ARGS[@]}"
