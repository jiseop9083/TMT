#!/usr/bin/env bash
set -euo pipefail

MODE="all"
OUT_DIR=""
ZSCORE_FILTER=0
ZSCORE_THRESHOLD=""
REGRESSION=0
E2E_MAX_MS="200"
E2E_MIN_MS="0"
BREAKDOWN_MAX_MS="200"
BREAKDOWN_MIN_MS="0"
INTERVAL_MS=""

usage() {
  cat <<'EOF'
Usage: run_latency_pipeline.sh [--out-dir <dir> | <dir>] [options]

Options:
  --latency-only          Generate CSV only, skip plots
  --plot-only             Generate plots only, skip CSV
  --zscore <number>       Apply z-score filter (omit to use all data)
  --regression            Draw regression line on plots
  --e2e-max-ms <number>       Hide E2E values above max (default: 200)
  --e2e-min-ms <number>       Hide E2E values below min (default: 0)
  --breakdown-max-ms <number> Hide breakdown values above max (default: 200)
  --breakdown-min-ms <number> Hide breakdown values below min (default: 0)
  --interval-ms <number>  Y-axis tick interval
  --out-dir <dir>         Output directory
  --help                  Show this help
EOF
}

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
    --zscore)
      if [[ -z "${2:-}" ]]; then
        echo "--zscore requires a value" >&2
        exit 1
      fi
      ZSCORE_FILTER=1
      ZSCORE_THRESHOLD="$2"
      shift 2
      ;;
    --e2e-max-ms)
      if [[ -z "${2:-}" ]]; then
        echo "--e2e-max-ms requires a value" >&2
        exit 1
      fi
      E2E_MAX_MS="$2"
      shift 2
      ;;
    --e2e-min-ms)
      if [[ -z "${2:-}" ]]; then
        echo "--e2e-min-ms requires a value" >&2
        exit 1
      fi
      E2E_MIN_MS="$2"
      shift 2
      ;;
    --breakdown-max-ms)
      if [[ -z "${2:-}" ]]; then
        echo "--breakdown-max-ms requires a value" >&2
        exit 1
      fi
      BREAKDOWN_MAX_MS="$2"
      shift 2
      ;;
    --breakdown-min-ms)
      if [[ -z "${2:-}" ]]; then
        echo "--breakdown-min-ms requires a value" >&2
        exit 1
      fi
      BREAKDOWN_MIN_MS="$2"
      shift 2
      ;;
    --interval-ms)
      if [[ -z "${2:-}" ]]; then
        echo "--interval-ms requires a value" >&2
        exit 1
      fi
      INTERVAL_MS="$2"
      shift 2
      ;;
    --regression)
      REGRESSION=1
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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="$1"
        shift
      else
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

OUT_DIR="${OUT_DIR:-client_profile_job/out}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FIGURES_OUT_DIR="${OUT_DIR/experiments\/output/experiments\/figures}"
if [[ "$FIGURES_OUT_DIR" == "$OUT_DIR" ]]; then
  FIGURES_OUT_DIR="${OUT_DIR%/}/../figures/$(basename "$OUT_DIR")"
fi

resolve_latest_run_dir() {
  local base_dir="$1"
  local latest=""
  if [[ -d "$base_dir" ]]; then
    local base_name
    base_name="$(basename "$base_dir")"
    if [[ "$base_name" == run_* || "$base_name" == 202* ]]; then
      echo "$base_dir"
      return
    fi
    for d in "$base_dir"/run_* "$base_dir"/202*; do
      if [[ -d "$d" ]]; then
        latest="$d"
      fi
    done
  fi
  echo "$latest"
}

copy_analysis_assets() {
  local run_dir="$1"
  if [[ -z "$run_dir" ]]; then
    return
  fi
  local analysis_dir="$run_dir/analysis"
  if [[ ! -d "$analysis_dir" ]]; then
    return
  fi
  local figures_run_dir
  figures_run_dir="${run_dir/experiments\/output/experiments\/figures}"
  if [[ "$figures_run_dir" == "$run_dir" ]]; then
    figures_run_dir="$FIGURES_OUT_DIR/$(basename "$run_dir")"
  fi
  mkdir -p "$figures_run_dir"
  if compgen -G "$analysis_dir/*.csv" >/dev/null; then
    cp -f "$analysis_dir"/*.csv "$figures_run_dir"/
  fi
  if [[ -d "$analysis_dir/json" ]]; then
    mkdir -p "$figures_run_dir/json"
    cp -rf "$analysis_dir/json/"* "$figures_run_dir/json/" 2>/dev/null || true
  fi
  if [[ -d "$analysis_dir/plots" ]]; then
    mkdir -p "$figures_run_dir/plots"
    cp -f "$analysis_dir/plots/"* "$figures_run_dir/plots/" 2>/dev/null || true
  fi
}

if [[ -z "${RUN_IN_DOCKER:-}" ]]; then
  IMAGE_NAME="dynamic-analysis-analyzer"
  echo "Building docker image: ${IMAGE_NAME}"
  docker build -f "$ROOT_DIR/experiments/analysis/Dockerfile" -t "$IMAGE_NAME" "$ROOT_DIR"
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
    DOCKER_ZSCORE_ARG+=(--zscore "$ZSCORE_THRESHOLD")
  fi
  DOCKER_REGRESSION_ARG=()
  if [[ "$REGRESSION" -eq 1 ]]; then
    DOCKER_REGRESSION_ARG+=(--regression)
  fi
  DOCKER_ARGS=()
  if [[ -n "$DOCKER_MODE_ARG" ]]; then
    DOCKER_ARGS+=("$DOCKER_MODE_ARG")
  fi
  DOCKER_ARGS+=("$OUT_DIR")
  if ((${#DOCKER_ZSCORE_ARG[@]})); then
    DOCKER_ARGS+=("${DOCKER_ZSCORE_ARG[@]}")
  fi
  if ((${#DOCKER_REGRESSION_ARG[@]})); then
    DOCKER_ARGS+=("${DOCKER_REGRESSION_ARG[@]}")
  fi
  DOCKER_ARGS+=(--e2e-max-ms "$E2E_MAX_MS")
  DOCKER_ARGS+=(--e2e-min-ms "$E2E_MIN_MS")
  DOCKER_ARGS+=(--breakdown-max-ms "$BREAKDOWN_MAX_MS")
  DOCKER_ARGS+=(--breakdown-min-ms "$BREAKDOWN_MIN_MS")
  if [[ -n "$INTERVAL_MS" ]]; then
    DOCKER_ARGS+=(--interval-ms "$INTERVAL_MS")
  fi

  docker run --rm \
    -e RUN_IN_DOCKER=1 \
    -e RUN_MODE="$MODE" \
    --mount type=bind,source="$ROOT_DIR_DOCKER",target=/workspace \
    -w /workspace \
    "$IMAGE_NAME" \
    /workspace/experiments/analysis/run_latency_pipeline.sh \
    "${DOCKER_ARGS[@]}"
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
  "$ROOT_DIR/experiments/analysis/JfrLatencyBreakdown.java" \
  "$ROOT_DIR/experiments/analysis/JfrLatencyPlot.java"

if [[ "$RUN_MODE" == "plot" ]]; then
  echo "Skipping latency_breakdown.csv generation (plot-only mode)."
else
  echo "Generating latency_breakdown.csv (JSON parse + CSV export)..."
  java -cp "$TMP_BUILD_DIR" JfrLatencyBreakdown --out-dir "$OUT_DIR"

  if [[ "$RUN_MODE" == "latency" ]]; then
    exit 0
  fi
fi

echo "Generating plots from latency_breakdown.csv..."
PLOT_ARGS=(--out-dir "$OUT_DIR")
if [[ "$ZSCORE_FILTER" -eq 1 ]]; then
  PLOT_ARGS+=(--zscore "$ZSCORE_THRESHOLD")
fi
if [[ "$REGRESSION" -eq 1 ]]; then
  PLOT_ARGS+=(--regression)
fi
PLOT_ARGS+=(--e2e-max-ms "$E2E_MAX_MS")
PLOT_ARGS+=(--e2e-min-ms "$E2E_MIN_MS")
PLOT_ARGS+=(--breakdown-max-ms "$BREAKDOWN_MAX_MS")
PLOT_ARGS+=(--breakdown-min-ms "$BREAKDOWN_MIN_MS")
if [[ -n "$INTERVAL_MS" ]]; then
  PLOT_ARGS+=(--interval-ms "$INTERVAL_MS")
fi
java -cp "$TMP_BUILD_DIR" JfrLatencyPlot "${PLOT_ARGS[@]}"

latest_run_dir="$(resolve_latest_run_dir "$OUT_DIR")"
copy_analysis_assets "$latest_run_dir"
