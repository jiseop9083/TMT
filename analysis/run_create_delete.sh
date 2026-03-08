#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

RUN_DIR="kafka-4.2/output/create-delete"
PLOT_DIR=""
RUN_DIR_EXPLICIT=0

usage() {
  cat <<'USAGE'
Usage: run_create_delete.sh [--run-dir <dir>] [--plot-dir <dir>]

Options:
  --run-dir <dir>   Run directory or parent directory containing runs
                    (default: kafka-4.2/output/create-delete)
  --plot-dir <dir>  Output plot directory
                    (default: kafka-4.2/figures/create-delete 밑)
  --help            Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      if [[ -z "${2:-}" ]]; then
        echo "--run-dir requires a value" >&2
        exit 1
      fi
      RUN_DIR="$2"
      RUN_DIR_EXPLICIT=1
      shift 2
      ;;
    --plot-dir)
      if [[ -z "${2:-}" ]]; then
        echo "--plot-dir requires a value" >&2
        exit 1
      fi
      PLOT_DIR="$2"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIGURES_BASE_DIR="$ROOT_DIR/kafka-4.2/figures/create-delete"

if [[ "$RUN_DIR" != /* ]]; then
  RUN_DIR="$ROOT_DIR/$RUN_DIR"
fi
if [[ -n "$PLOT_DIR" && "$PLOT_DIR" != /* ]]; then
  PLOT_DIR="$ROOT_DIR/$PLOT_DIR"
fi

has_expected_csv() {
  local dir="$1"
  [[ -f "$dir/resource_usage.csv" && -f "$dir/e2e_latency.csv" && -f "$dir/broker_metadata_update.csv" ]]
}

list_run_dirs() {
  local base_dir="$1"
  if [[ ! -d "$base_dir" ]]; then
    return 0
  fi
  local d=""
  for d in "$base_dir"/run_* "$base_dir"/202*; do
    if [[ -d "$d" ]] && has_expected_csv "$d"; then
      echo "$d"
    fi
  done | sort
}

latest_run_under() {
  local base_dir="$1"
  if [[ ! -d "$base_dir" ]]; then
    return 0
  fi
  local latest=""
  local d=""
  for d in "$base_dir"/run_* "$base_dir"/202*; do
    if [[ -d "$d" ]] && has_expected_csv "$d"; then
      latest="$d"
    fi
  done
  if [[ -n "$latest" ]]; then
    echo "$latest"
  fi
}

if [[ "$RUN_DIR_EXPLICIT" -eq 1 && ! -d "$RUN_DIR" ]]; then
  parent_dir="$(dirname "$RUN_DIR")"
  latest="$(latest_run_under "$parent_dir")"
  if [[ -n "$latest" ]]; then
    RUN_DIR="$latest"
    echo "Requested run-dir not found. Auto-selected latest run: $RUN_DIR"
  fi
fi

if [[ -z "$PLOT_DIR" ]]; then
  if [[ -d "$RUN_DIR" ]] && has_expected_csv "$RUN_DIR"; then
    PLOT_DIR="$FIGURES_BASE_DIR/$(basename "$RUN_DIR")"
  else
    PLOT_DIR="$FIGURES_BASE_DIR"
  fi
fi

if [[ -z "${RUN_IN_DOCKER:-}" ]]; then
  IMAGE_NAME="dynamic-analyses-analyzer"
  echo "Building docker image: ${IMAGE_NAME}"
  docker build -f "$SCRIPT_DIR/Dockerfile" -t "$IMAGE_NAME" "$ROOT_DIR"

  ROOT_DIR_DOCKER="$ROOT_DIR"
  if command -v cygpath >/dev/null 2>&1; then
    ROOT_DIR_DOCKER="$(cygpath -m "$ROOT_DIR")"
  fi

  RUN_DIR_DOCKER="$RUN_DIR"
  if [[ "$RUN_DIR_DOCKER" == "$ROOT_DIR"* ]]; then
    RUN_DIR_DOCKER="/workspace${RUN_DIR_DOCKER#$ROOT_DIR}"
  fi

  DOCKER_ARGS=(--run-dir "$RUN_DIR_DOCKER")
  PLOT_DIR_DOCKER="$PLOT_DIR"
  if [[ "$PLOT_DIR_DOCKER" == "$ROOT_DIR"* ]]; then
    PLOT_DIR_DOCKER="/workspace${PLOT_DIR_DOCKER#$ROOT_DIR}"
  fi
  DOCKER_ARGS+=(--plot-dir "$PLOT_DIR_DOCKER")

  echo "Running create/delete plot pipeline inside docker..."
  export MSYS2_ARG_CONV_EXCL="/workspace"
  docker run --rm \
    -e RUN_IN_DOCKER=1 \
    --mount type=bind,source="$ROOT_DIR_DOCKER",target=/workspace \
    -w /workspace \
    "$IMAGE_NAME" \
    /workspace/analysis/run_create_delete.sh \
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

TMP_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_BUILD_DIR"' EXIT

echo "Compiling CreateDeleteMetricsPlot.java..."
javac -d "$TMP_BUILD_DIR" "$SCRIPT_DIR/CreateDeleteMetricsPlot.java"

run_count=0
if [[ -d "$RUN_DIR" ]] && ! has_expected_csv "$RUN_DIR"; then
  while IFS= read -r _; do
    if [[ -n "$_" ]]; then
      run_count=$((run_count + 1))
    fi
  done < <(list_run_dirs "$RUN_DIR")
fi

if [[ "$run_count" -gt 0 ]]; then
  echo "Generating per-run graphs..."
  while IFS= read -r run_path; do
    if [[ -z "$run_path" ]]; then
      continue
    fi
    run_name="$(basename "$run_path")"
    run_plot_dir="$FIGURES_BASE_DIR/$run_name"
    mkdir -p "$run_plot_dir"
    java -cp "$TMP_BUILD_DIR" CreateDeleteMetricsPlot \
      --run-dir "$run_path" \
      --plot-dir "$run_plot_dir"
  done < <(list_run_dirs "$RUN_DIR")
else
  JAVA_ARGS=(--run-dir "$RUN_DIR")
  mkdir -p "$PLOT_DIR"
  JAVA_ARGS+=(--plot-dir "$PLOT_DIR")
  echo "Generating graphs..."
  java -cp "$TMP_BUILD_DIR" CreateDeleteMetricsPlot "${JAVA_ARGS[@]}"
fi
