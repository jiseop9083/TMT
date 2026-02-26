#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIGURES_ROOT="${ROOT_DIR}/kafka-4.2/figures"

OUT_DIR="${ROOT_DIR}/kafka-4.2/output/first-produce-with-message-load"
FIG_DIR=""
TIMESTAMP=""
ALL=0

usage() {
  cat <<'EOF'
Usage: run_first_produce_with_message_load_pipeline.sh [options]

Options:
  --out-dir <dir>        Directory containing combined_metrics_*.csv and yammer_*.csv
  --fig-dir <dir>        Output directory for generated plots
  --timestamp <ts>       Specific timestamp suffix (e.g. 20260226_020448)
  --all                  Plot all matching timestamp pairs
  --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      if [[ -z "${2:-}" ]]; then
        echo "--out-dir requires a value" >&2
        exit 1
      fi
      OUT_DIR="$2"
      shift 2
      ;;
    --fig-dir)
      if [[ -z "${2:-}" ]]; then
        echo "--fig-dir requires a value" >&2
        exit 1
      fi
      FIG_DIR="$2"
      shift 2
      ;;
    --timestamp)
      if [[ -z "${2:-}" ]]; then
        echo "--timestamp requires a value" >&2
        exit 1
      fi
      TIMESTAMP="$2"
      shift 2
      ;;
    --all)
      ALL=1
      shift
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

if [[ "$OUT_DIR" != /* ]]; then
  OUT_DIR="$ROOT_DIR/$OUT_DIR"
fi

if [[ -n "$FIG_DIR" && "$FIG_DIR" != /* ]]; then
  FIG_DIR="$ROOT_DIR/$FIG_DIR"
fi

map_to_figures() {
  local path="$1"
  if [[ "$path" == "$ROOT_DIR/kafka-4.2/output/"* ]]; then
    echo "${FIGURES_ROOT}/${path#$ROOT_DIR/kafka-4.2/output/}"
    return
  fi
  if [[ "$path" == "$ROOT_DIR/experiments/output/"* ]]; then
    echo "${FIGURES_ROOT}/${path#$ROOT_DIR/experiments/output/}"
    return
  fi
  if [[ "$path" == "$ROOT_DIR/output/"* ]]; then
    echo "${FIGURES_ROOT}/${path#$ROOT_DIR/output/}"
    return
  fi
  echo "$path"
}

if [[ -z "$FIG_DIR" ]]; then
  FIG_DIR="$(map_to_figures "$OUT_DIR")"
fi

map_to_docker_path() {
  local host_path="$1"
  if [[ "$host_path" == "$ROOT_DIR"* ]]; then
    echo "/workspace${host_path#$ROOT_DIR}"
    return
  fi
  echo "$host_path"
}

if [[ -z "${RUN_IN_DOCKER:-}" ]]; then
  IMAGE_NAME="dynamic-analyses-analyzer"
  echo "Building docker image: ${IMAGE_NAME}"
  docker build -f "$SCRIPT_DIR/Dockerfile" -t "$IMAGE_NAME" "$ROOT_DIR"
  echo "Running first-produce plot pipeline inside docker..."

  export MSYS2_ARG_CONV_EXCL="/workspace"
  ROOT_DIR_DOCKER="$ROOT_DIR"
  if command -v cygpath >/dev/null 2>&1; then
    ROOT_DIR_DOCKER="$(cygpath -m "$ROOT_DIR")"
  fi

  DOCKER_ARGS=(--out-dir "$(map_to_docker_path "$OUT_DIR")")
  if [[ -n "$FIG_DIR" ]]; then
    DOCKER_ARGS+=(--fig-dir "$(map_to_docker_path "$FIG_DIR")")
  fi
  if [[ -n "$TIMESTAMP" ]]; then
    DOCKER_ARGS+=(--timestamp "$TIMESTAMP")
  fi
  if [[ "$ALL" -eq 1 ]]; then
    DOCKER_ARGS+=(--all)
  fi

  docker run --rm \
    -e RUN_IN_DOCKER=1 \
    --mount type=bind,source="$ROOT_DIR_DOCKER",target=/workspace \
    -w /workspace \
    "$IMAGE_NAME" \
    /workspace/analysis/run_first_produce_with_message_load_pipeline.sh \
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

javac -d "$TMP_BUILD_DIR" "$SCRIPT_DIR/FirstProduceWithMessageLoadPlot.java"

JAVA_ARGS=(--out-dir "$OUT_DIR")
if [[ -n "$FIG_DIR" ]]; then
  JAVA_ARGS+=(--fig-dir "$FIG_DIR")
fi
if [[ -n "$TIMESTAMP" ]]; then
  JAVA_ARGS+=(--timestamp "$TIMESTAMP")
fi
if [[ "$ALL" -eq 1 ]]; then
  JAVA_ARGS+=(--all)
fi

java -cp "$TMP_BUILD_DIR" FirstProduceWithMessageLoadPlot "${JAVA_ARGS[@]}"
