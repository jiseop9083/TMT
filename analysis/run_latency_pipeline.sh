#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

MODE="all"
OUT_DIR=""
ZSCORE_FILTER=0
ZSCORE_THRESHOLD=""
REGRESSION=0
E2E_MAX_MS="300"
E2E_MIN_MS="100"
BREAKDOWN_MAX_MS="200"
BREAKDOWN_MIN_MS="0"
INTERVAL_MS=""
ALL_RUNS=1
ALL_RUNS_EXPLICIT=0

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
  --all-runs              Process all run_* dirs under out-dir
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
    --all-runs)
      ALL_RUNS=1
      ALL_RUNS_EXPLICIT=1
      shift
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIGURES_ROOT="${ROOT_DIR}/kafka-4.2/figures"

# Normalize OUT_DIR to a real path inside the repo when possible.
ORIG_OUT_DIR="$OUT_DIR"
if [[ "$OUT_DIR" != /* ]]; then
  OUT_DIR="$ROOT_DIR/$OUT_DIR"
fi
if [[ ! -d "$OUT_DIR" ]]; then
  if [[ -d "$ROOT_DIR/experiments/$ORIG_OUT_DIR" ]]; then
    OUT_DIR="$ROOT_DIR/experiments/$ORIG_OUT_DIR"
  elif [[ -d "$ROOT_DIR/$ORIG_OUT_DIR" ]]; then
    OUT_DIR="$ROOT_DIR/$ORIG_OUT_DIR"
  elif [[ -d "$ROOT_DIR/kafka-4.2/$ORIG_OUT_DIR" ]]; then
    OUT_DIR="$ROOT_DIR/kafka-4.2/$ORIG_OUT_DIR"
  elif [[ "$ORIG_OUT_DIR" == kafka-4.2/* && -d "$ROOT_DIR/${ORIG_OUT_DIR#kafka-4.2/}" ]]; then
    OUT_DIR="$ROOT_DIR/${ORIG_OUT_DIR#kafka-4.2/}"
  elif [[ "$ORIG_OUT_DIR" == output/* && -d "$ROOT_DIR/experiments/$ORIG_OUT_DIR" ]]; then
    OUT_DIR="$ROOT_DIR/experiments/$ORIG_OUT_DIR"
  elif [[ "$ORIG_OUT_DIR" == output/* && -d "$ROOT_DIR/experiments/output/${ORIG_OUT_DIR#output/}" ]]; then
    OUT_DIR="$ROOT_DIR/experiments/output/${ORIG_OUT_DIR#output/}"
  elif [[ "$ORIG_OUT_DIR" == output/* && -d "$ROOT_DIR/kafka-4.2/output/${ORIG_OUT_DIR#output/}" ]]; then
    OUT_DIR="$ROOT_DIR/kafka-4.2/output/${ORIG_OUT_DIR#output/}"
  elif [[ "$ORIG_OUT_DIR" == output/* && -d "$ROOT_DIR/output/${ORIG_OUT_DIR#output/}" ]]; then
    OUT_DIR="$ROOT_DIR/output/${ORIG_OUT_DIR#output/}"
  elif [[ "$OUT_DIR" == *"/output/"* && -d "${OUT_DIR/\/output\//\/experiments\/output\/}" ]]; then
    OUT_DIR="${OUT_DIR/\/output\//\/experiments\/output\/}"
  elif [[ "$OUT_DIR" == *"/experiments/output/"* && -d "${OUT_DIR/\/experiments\/output\//\/output\/}" ]]; then
    OUT_DIR="${OUT_DIR/\/experiments\/output\//\/output\/}"
  fi
fi

# If a specific run_* or dated directory is provided, default to single-run
# unless the user explicitly requested --all-runs.
if [[ "$ALL_RUNS_EXPLICIT" -eq 0 ]]; then
  base_name="$(basename "$OUT_DIR")"
  if [[ "$base_name" == run_* || "$base_name" == 202* ]]; then
    ALL_RUNS=0
  fi
fi

map_to_figures() {
  local path="$1"
  if [[ "$path" == "$ROOT_DIR/experiments/output/"* ]]; then
    echo "${FIGURES_ROOT}/${path#$ROOT_DIR/experiments/output/}"
    return
  fi
  if [[ "$path" == "$ROOT_DIR/kafka-4.2/output/"* ]]; then
    echo "${FIGURES_ROOT}/${path#$ROOT_DIR/kafka-4.2/output/}"
    return
  fi
  if [[ "$path" == "$ROOT_DIR/output/"* ]]; then
    echo "${FIGURES_ROOT}/${path#$ROOT_DIR/output/}"
    return
  fi
  echo "$path"
}

FIGURES_OUT_DIR="$(map_to_figures "$OUT_DIR")"
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

list_run_dirs() {
  local base_dir="$1"
  local found=0
  if [[ -d "$base_dir" ]]; then
    for d in "$base_dir"/run_* "$base_dir"/202*; do
      if [[ -d "$d" ]]; then
        echo "$d"
        found=1
      fi
    done
  fi
  return 0
}

copy_analyses_assets() {
  local run_dir="$1"
  if [[ -z "$run_dir" ]]; then
    return
  fi
  local analyses_dir="$run_dir/analyses"
  if [[ ! -d "$analyses_dir" ]]; then
    return
  fi
  local figures_run_dir
  figures_run_dir="$(map_to_figures "$run_dir")"
  if [[ "$figures_run_dir" == "$run_dir" ]]; then
    figures_run_dir="$FIGURES_OUT_DIR/$(basename "$run_dir")"
  fi
  mkdir -p "$figures_run_dir"
  # Copy full analysis artifacts under figures/..../analysis
  mkdir -p "$figures_run_dir/analysis"
  cp -rf "$analyses_dir/"* "$figures_run_dir/analysis/" 2>/dev/null || true
  if compgen -G "$analyses_dir/*.csv" >/dev/null; then
    cp -f "$analyses_dir"/*.csv "$figures_run_dir"/
  fi
  if [[ -d "$analyses_dir/json" ]]; then
    mkdir -p "$figures_run_dir/json"
    cp -rf "$analyses_dir/json/"* "$figures_run_dir/json/" 2>/dev/null || true
  fi
  if [[ -d "$analyses_dir/plots" ]]; then
    mkdir -p "$figures_run_dir/plots"
    cp -f "$analyses_dir/plots/"* "$figures_run_dir/plots/" 2>/dev/null || true
  fi
}

copy_base_plots() {
  local base_dir="$1"
  if [[ -z "$base_dir" ]]; then
    return
  fi
  local plots_dir="$base_dir/plots"
  if [[ ! -d "$plots_dir" ]]; then
    return
  fi
  local figures_base_dir
  figures_base_dir="$(map_to_figures "$base_dir")"
  if [[ "$figures_base_dir" == "$base_dir" ]]; then
    figures_base_dir="$FIGURES_OUT_DIR"
  fi
  mkdir -p "$figures_base_dir/plots"
  cp -f "$plots_dir/"* "$figures_base_dir/plots/" 2>/dev/null || true
}

write_e2e_csv() {
  local figures_base_dir="$1"
  if [[ -z "$figures_base_dir" ]]; then
    return
  fi
  local out_csv="$figures_base_dir/e2e_by_run.csv"
  local tmp_csv
  tmp_csv="$(mktemp)"
  local runs_list
  runs_list="$(mktemp)"
  local -a csvs
  local run_count=0
  for d in "$figures_base_dir"/run_* "$figures_base_dir"/202*; do
    if [[ -d "$d" ]]; then
      echo "$d"
    fi
  done | sort >"$runs_list"
  if [[ ! -s "$runs_list" ]]; then
    rm -f "$runs_list" "$tmp_csv"
    return
  fi
  while IFS= read -r run_dir; do
    local csv="$run_dir/latency_breakdown.csv"
    if [[ -f "$csv" ]]; then
      csvs+=("$csv")
      run_count=$((run_count + 1))
    fi
  done <"$runs_list"
  if [[ "$run_count" -eq 0 ]]; then
    rm -f "$runs_list" "$tmp_csv"
    return
  fi
  {
    printf "topic_count"
    for i in $(seq 1 "$run_count"); do
      printf ",experiment_%d" "$i"
    done
    printf "\n"
  } >"$tmp_csv"
  awk -F',' -v OFS=',' -v runs="$run_count" '
    FNR==1 {
      fileIndex++
      delete idx
      for (i=1; i<=NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        idx[$i]=i
      }
      next
    }
    {
      tc=$(idx["topic_count"])
      e2e=$(idx["producer_e2e_ms"])
      if (tc == "" || e2e == "") next
      sub(/^[[:space:]]+|[[:space:]]+$/, "", tc)
      sub(/^[[:space:]]+|[[:space:]]+$/, "", e2e)
      if (tc == "" || e2e == "") next
      runIdx=fileIndex
      key=tc SUBSEP runIdx
      vals[key]=e2e
      topics[tc]=1
    }
    END {
      for (tc in topics) {
        printf "%s", tc
        for (r=1; r<=runs; r++) {
          v=vals[tc SUBSEP r]
          if (v == "") v="null"
          printf ",%s", v
        }
        printf "\n"
      }
    }
  ' "${csvs[@]}" | sort -t',' -k1,1n >>"$tmp_csv"
  mv "$tmp_csv" "$out_csv"
  rm -f "$runs_list"
}

list_producer_csvs() {
  local base_dir="$1"
  if [[ ! -d "$base_dir" ]]; then
    return
  fi
  local -a files=()
  for f in "$base_dir"/producer_latency_results_*.csv; do
    if [[ -f "$f" ]]; then
      files+=("$f")
    fi
  done
  if ((${#files[@]})); then
    printf '%s\n' "${files[@]}" | sort
  fi
}

append_producer_csv_as_latency_rows() {
  local in_csv="$1"
  local out_csv="$2"
  local run_label="$3"
  awk -F',' -v OFS=',' -v run_dir="$run_label" '
    NR==1 {
      for (i=1; i<=NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        idx[$i]=i
      }
      next
    }
    {
      topicNumIdx=idx["topic_num"]
      topicNameIdx=idx["topic_name"]
      latencyIdx=idx["latency_ms"]
      if (topicNumIdx == "" || latencyIdx == "") next
      topicCount=$topicNumIdx
      latency=$latencyIdx
      topic=(topicNameIdx != "" && $topicNameIdx != "") ? $topicNameIdx : ("test_topic_" topicCount)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", topic)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", topicCount)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", latency)
      if (topicCount == "" || latency == "") next
      print topic, topicCount, latency, "null", "null", "null", run_dir
    }
  ' "$in_csv" >>"$out_csv"
}

convert_producer_csvs_to_latency_csv() {
  local out_csv="$1"
  shift
  if [[ $# -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "topic,topic_count,producer_e2e_ms,produce_completion_ms,e2e_completion_remainder_ms,wait_on_metadata_ms,run_dir" >"$out_csv"
  local csv=""
  for csv in "$@"; do
    append_producer_csv_as_latency_rows "$csv" "$out_csv" "$csv"
  done
}

write_producer_summary_csv() {
  local in_latency_csv="$1"
  local out_csv="$2"
  local tmp_csv
  tmp_csv="$(mktemp)"
  awk -F',' -v OFS=',' '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function is_number(s) {
      return (s ~ /^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/)
    }
    NR==1 {
      for (i=1; i<=NF; i++) {
        h=trim($i)
        idx[h]=i
      }
      topicCountIdx=idx["topic_count"]
      e2eIdx=idx["producer_e2e_ms"]
      next
    }
    {
      if (topicCountIdx == "" || e2eIdx == "") next
      tc=trim($(topicCountIdx))
      e2e=trim($(e2eIdx))
      if (tc == "" || e2e == "" || e2e == "null") next
      if (!is_number(tc) || !is_number(e2e)) next
      v=e2e+0.0
      n[tc]++
      sum[tc]+=v
      sumsq[tc]+=(v*v)
      if (!(tc in minv) || v < minv[tc]) minv[tc]=v
      if (!(tc in maxv) || v > maxv[tc]) maxv[tc]=v
    }
    END {
      for (tc in n) {
        mean=sum[tc]/n[tc]
        variance=(sumsq[tc]/n[tc])-(mean*mean)
        if (variance < 0) variance=0
        stddev=sqrt(variance)
        printf "%s,%d,%.6f,%.6f,%.6f,%.6f\n", tc, n[tc], mean, stddev, minv[tc], maxv[tc]
      }
    }
  ' "$in_latency_csv" | sort -t',' -k1,1n >"$tmp_csv"
  {
    printf '%s\n' "topic_count,sample_count,mean_e2e_ms,stddev_e2e_ms,min_e2e_ms,max_e2e_ms"
    cat "$tmp_csv"
  } >"$out_csv"
  rm -f "$tmp_csv"
}

if [[ -z "${RUN_IN_DOCKER:-}" ]]; then
  IMAGE_NAME="dynamic-analyses-analyzer"
  echo "Building docker image: ${IMAGE_NAME}"
  docker build -f "$SCRIPT_DIR/Dockerfile" -t "$IMAGE_NAME" "$ROOT_DIR"
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
  OUT_DIR_DOCKER="$OUT_DIR"
  if [[ "$OUT_DIR_DOCKER" == "$ROOT_DIR"* ]]; then
    OUT_DIR_DOCKER="/workspace${OUT_DIR_DOCKER#$ROOT_DIR}"
  fi
  DOCKER_ARGS+=("$OUT_DIR_DOCKER")
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
    /workspace/analysis/run_latency_pipeline.sh \
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

echo "Compiling analyses tools (container-local)..."
javac -d "$TMP_BUILD_DIR" \
  "$SCRIPT_DIR/JfrLatencyBreakdown.java" \
  "$SCRIPT_DIR/JfrLatencyPlot.java"

if [[ "$RUN_MODE" == "plot" ]]; then
  echo "Skipping latency_breakdown.csv generation (plot-only mode)."
else
  echo "Generating latency_breakdown.csv (JSON parse + CSV export)..."
  if [[ "$ALL_RUNS" -eq 1 ]]; then
    base_dir="$OUT_DIR"
    base_name="$(basename "$base_dir")"
    if [[ "$base_name" == run_* || "$base_name" == 202* ]]; then
      base_dir="${base_dir%/*}"
    fi
    while IFS= read -r run_dir; do
      if [[ -z "$run_dir" ]]; then
        continue
      fi
      figures_run_dir="$(map_to_figures "$run_dir")"
      analysis_dir="${figures_run_dir}"
      java -cp "$TMP_BUILD_DIR" JfrLatencyBreakdown --out-dir "$run_dir" --analysis-dir "$analysis_dir"
    done < <(list_run_dirs "$base_dir")
  else
    run_dir="$(resolve_latest_run_dir "$OUT_DIR")"
    figures_run_dir="$(map_to_figures "$run_dir")"
    analysis_dir="${figures_run_dir}"
    java -cp "$TMP_BUILD_DIR" JfrLatencyBreakdown --out-dir "$OUT_DIR" --analysis-dir "$analysis_dir"
  fi

  if [[ "$RUN_MODE" == "latency" ]]; then
    exit 0
  fi
fi

echo "Generating plots from latency_breakdown.csv..."
PLOT_ARGS=(--out-dir "$OUT_DIR")
figures_base_dir="$(map_to_figures "$OUT_DIR")"
base_name="$(basename "$OUT_DIR")"
if [[ "$base_name" == run_* || "$base_name" == 202* ]]; then
  figures_base_dir="$(map_to_figures "${OUT_DIR%/*}")"
fi
producer_csv_count=0
latest_producer_csv=""
producer_csv_first=""
if [[ -d "$OUT_DIR" ]]; then
  has_runs=0
  for d in "$OUT_DIR"/run_* "$OUT_DIR"/202*; do
    if [[ -d "$d" ]]; then
      has_runs=1
      break
    fi
  done
  if [[ "$has_runs" -eq 0 ]]; then
    while IFS= read -r csv_path; do
      if [[ -z "$csv_path" ]]; then
        continue
      fi
      if [[ "$producer_csv_count" -eq 0 ]]; then
        producer_csv_first="$csv_path"
      fi
      latest_producer_csv="$csv_path"
      producer_csv_count=$((producer_csv_count + 1))
    done < <(list_producer_csvs "$OUT_DIR")
  fi
fi
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
if [[ "$producer_csv_count" -gt 0 ]]; then
  csv_plot_dir="${figures_base_dir%/}/csv_plot"
  mkdir -p "$csv_plot_dir"
  converted_latency_csv="$csv_plot_dir/latency_breakdown.csv"
  producer_summary_csv="$csv_plot_dir/producer_e2e_summary.csv"
  producer_csvs=()
  while IFS= read -r csv_path; do
    if [[ -n "$csv_path" ]]; then
      producer_csvs+=("$csv_path")
    fi
  done < <(list_producer_csvs "$OUT_DIR")
  convert_producer_csvs_to_latency_csv "$converted_latency_csv" "${producer_csvs[@]}"
  write_producer_summary_csv "$converted_latency_csv" "$producer_summary_csv"
  PLOT_ARGS+=(--analysis-dir "$csv_plot_dir")
  PLOT_ARGS+=(--plot-dir "$csv_plot_dir/plots")
  echo "Using source CSV files: $producer_csv_count"
  echo "CSV range: $producer_csv_first -> $latest_producer_csv"
  echo "Converted latency CSV: $converted_latency_csv"
  echo "Producer summary CSV: $producer_summary_csv"
elif [[ "$ALL_RUNS" -eq 1 ]]; then
  PLOT_ARGS+=(--aggregate-only)
  PLOT_ARGS+=(--analysis-base-dir "$figures_base_dir")
  PLOT_ARGS+=(--combined-plot-dir "$figures_base_dir/plots")
else
  run_dir="$(resolve_latest_run_dir "$OUT_DIR")"
  figures_run_dir="$(map_to_figures "$run_dir")"
  analysis_dir="${figures_run_dir}"
  PLOT_ARGS+=(--analysis-dir "$analysis_dir")
  PLOT_ARGS+=(--plot-dir "$analysis_dir/plots")
fi
java -cp "$TMP_BUILD_DIR" JfrLatencyPlot "${PLOT_ARGS[@]}"

if [[ -z "$latest_producer_csv" ]]; then
  write_e2e_csv "$figures_base_dir"
fi
