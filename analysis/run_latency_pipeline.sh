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
E2E_MAX_MS="200"
E2E_MIN_MS="0"
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
  local f=""
  local key=""
  local best=""
  declare -A chosen=()

  # Support both naming schemes:
  # - producer_latency_results_<ts>.csv
  # - producer_latency_load_<ts>.csv
  # If both exist for the same <ts>, prefer the "results" file.
  for f in "$base_dir"/producer_latency_results_*.csv "$base_dir"/producer_latency_load_*.csv; do
    if [[ ! -f "$f" ]]; then
      continue
    fi
    key="$(basename "$f")"
    key="${key#producer_latency_results_}"
    key="${key#producer_latency_load_}"

    best="${chosen[$key]:-}"
    if [[ -z "$best" || "$f" == *"/producer_latency_results_"* ]]; then
      chosen["$key"]="$f"
    fi
  done

  for key in "${!chosen[@]}"; do
    files+=("${chosen[$key]}")
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

list_resource_csvs() {
  local base_dir="$1"
  if [[ ! -d "$base_dir" ]]; then
    return
  fi

  local base_name
  base_name="$(basename "$base_dir")"
  if [[ "$base_name" == run_* || "$base_name" == 202* ]]; then
    find "$base_dir/resource" -maxdepth 1 -type f -name 'broker_resource_usage_*.csv' 2>/dev/null | sort
  else
    find "$base_dir" -maxdepth 3 -type f -path '*/resource/broker_resource_usage_*.csv' 2>/dev/null | sort
  fi
}

write_resource_summary_csv() {
  local out_csv="$1"
  shift
  if [[ $# -eq 0 ]]; then
    return 1
  fi
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
    function pctl_from_sorted(n, p,  rank) {
      if (n <= 0) return ""
      rank = int((p/100.0) * n + 0.999999)
      if (rank < 1) rank = 1
      if (rank > n) rank = n
      return rank
    }
    function sort_numeric(arr, n,   i, j, t) {
      for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
          if (arr[i] > arr[j]) {
            t = arr[i]
            arr[i] = arr[j]
            arr[j] = t
          }
        }
      }
    }
    FNR==1 {
      file_idx++
      src=file_idx
      source[src]=FILENAME
      delete idx
      for (i=1; i<=NF; i++) {
        idx[trim($i)] = i
      }
      first_epoch[src] = ""
      last_epoch[src] = ""
      next
    }
    {
      epoch = trim($(idx["epoch_ms"]))
      topic_dir_count = trim($(idx["topic_dir_count"]))
      cpu = trim($(idx["cpu_pct"]))
      rss = trim($(idx["rss_kb"]))
      vsz = trim($(idx["vsz_kb"]))
      heap_used = trim($(idx["heap_used_kb"]))
      heap_committed = trim($(idx["heap_committed_kb"]))
      storage = trim($(idx["log_dir_storage_kb"]))

      if (is_number(epoch)) {
        e = epoch + 0
        if (first_epoch[src] == "" || e < first_epoch[src]) first_epoch[src] = e
        if (last_epoch[src] == "" || e > last_epoch[src]) last_epoch[src] = e
      }
      if (is_number(topic_dir_count)) {
        t = topic_dir_count + 0
        if (!(src in max_topic_dirs) || t > max_topic_dirs[src]) max_topic_dirs[src] = t
      }
      if (is_number(cpu)) {
        v = cpu + 0.0
        cpu_count[src]++
        cpu_sum[src] += v
        cpu_vals[src SUBSEP cpu_count[src]] = v
        if (!(src in cpu_max) || v > cpu_max[src]) cpu_max[src] = v
      }
      if (is_number(rss)) {
        v = rss + 0.0
        rss_count[src]++
        rss_sum[src] += v
        if (!(src in rss_max) || v > rss_max[src]) rss_max[src] = v
      }
      if (is_number(vsz)) {
        v = vsz + 0.0
        vsz_count[src]++
        vsz_sum[src] += v
        if (!(src in vsz_max) || v > vsz_max[src]) vsz_max[src] = v
      }
      if (is_number(heap_used)) {
        v = heap_used + 0.0
        heap_used_count[src]++
        heap_used_sum[src] += v
        if (!(src in heap_used_max) || v > heap_used_max[src]) heap_used_max[src] = v
      }
      if (is_number(heap_committed)) {
        v = heap_committed + 0.0
        heap_committed_count[src]++
        heap_committed_sum[src] += v
        if (!(src in heap_committed_max) || v > heap_committed_max[src]) heap_committed_max[src] = v
      }
      if (is_number(storage)) {
        v = storage + 0.0
        storage_count[src]++
        storage_sum[src] += v
        if (!(src in storage_max) || v > storage_max[src]) storage_max[src] = v
      }
    }
    END {
      for (src=1; src<=file_idx; src++) {
        cpu_avg = cpu_count[src] ? (cpu_sum[src]/cpu_count[src]) : ""
        rss_avg = rss_count[src] ? (rss_sum[src]/rss_count[src]) : ""
        vsz_avg = vsz_count[src] ? (vsz_sum[src]/vsz_count[src]) : ""
        heap_used_avg = heap_used_count[src] ? (heap_used_sum[src]/heap_used_count[src]) : ""
        heap_committed_avg = heap_committed_count[src] ? (heap_committed_sum[src]/heap_committed_count[src]) : ""
        storage_avg = storage_count[src] ? (storage_sum[src]/storage_count[src]) : ""

        cpu_p95 = ""
        if (cpu_count[src] > 0) {
          n = cpu_count[src]
          delete tmp
          for (i=1; i<=n; i++) tmp[i] = cpu_vals[src SUBSEP i]
          sort_numeric(tmp, n)
          rank = pctl_from_sorted(n, 95)
          cpu_p95 = tmp[rank]
        }

        duration_sec = ""
        if (first_epoch[src] != "" && last_epoch[src] != "" && last_epoch[src] >= first_epoch[src]) {
          duration_sec = (last_epoch[src] - first_epoch[src]) / 1000.0
        }

        printf "%s,%d,%.3f,%s,%.6f,%.6f,%.6f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
          source[src],
          cpu_count[src] + 0,
          duration_sec,
          ((src in max_topic_dirs) ? max_topic_dirs[src] : ""),
          cpu_avg, cpu_p95, ((src in cpu_max) ? cpu_max[src] : 0),
          rss_avg, ((src in rss_max) ? rss_max[src] : 0),
          vsz_avg, ((src in vsz_max) ? vsz_max[src] : 0),
          heap_used_avg, ((src in heap_used_max) ? heap_used_max[src] : 0),
          heap_committed_avg, ((src in heap_committed_max) ? heap_committed_max[src] : 0),
          storage_avg, ((src in storage_max) ? storage_max[src] : 0)
      }
    }
  ' "$@" >"$tmp_csv"
  {
    printf '%s\n' "resource_csv,sample_count,duration_sec,max_topic_dir_count,cpu_pct_avg,cpu_pct_p95,cpu_pct_max,rss_kb_avg,rss_kb_max,vsz_kb_avg,vsz_kb_max,heap_used_kb_avg,heap_used_kb_max,heap_committed_kb_avg,heap_committed_kb_max,log_dir_storage_kb_avg,log_dir_storage_kb_max"
    cat "$tmp_csv"
  } >"$out_csv"
  rm -f "$tmp_csv"
}

generate_resource_plots() {
  local figures_resource_dir="$1"
  shift
  if [[ $# -eq 0 ]]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found; skipping resource plots."
    return 0
  fi

  mkdir -p "$figures_resource_dir"
  local csv_path
  for csv_path in "$@"; do
    if [[ ! -f "$csv_path" ]]; then
      continue
    fi
    local base_name ts
    base_name="$(basename "$csv_path")"
    ts="${base_name#broker_resource_usage_}"
    ts="${ts%.csv}"
    python3 - "$csv_path" "$figures_resource_dir" "$ts" <<'PY'
import csv
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
ts = sys.argv[3] or "unknown"

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
storage_mb = [((num(r.get("log_dir_storage_kb")) or 0.0) / 1024.0) if num(r.get("log_dir_storage_kb")) is not None else None for r in rows]

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

cpu_png = out_dir / f"cpu_{ts}.png"
mem_png = out_dir / f"memory_{ts}.png"
disk_png = out_dir / f"disk_{ts}.png"

if has_values(cpu):
    save_plot(cpu_png, f"Broker CPU Usage ({ts})", "CPU (%)", [("cpu_pct", cpu, "#d7263d")])
if has_values(rss_mb) or has_values(heap_used_mb):
    save_plot(
        mem_png,
        f"Broker Memory Usage ({ts})",
        "Memory (MB)",
        [
            ("memory usage", rss_mb, "#1f77b4"),
            ("heap usage", heap_used_mb, "#2ca02c"),
        ],
    )
if has_values(storage_mb):
    save_plot(disk_png, f"Broker Log Storage ({ts})", "Storage (MB)", [("log_dir_storage_mb", storage_mb, "#6a4c93")])

print(f"Wrote resource plots for {csv_path}")
PY
  done
}

emit_resource_summary() {
  local out_dir="$1"
  local figures_base_dir_local
  figures_base_dir_local="$(map_to_figures "$out_dir")"
  local out_base_name
  out_base_name="$(basename "$out_dir")"
  if [[ "$out_base_name" == run_* || "$out_base_name" == 202* ]]; then
    figures_base_dir_local="$(map_to_figures "${out_dir%/*}")"
  fi

  local resource_csv_count=0
  local resource_csv_first=""
  local latest_resource_csv=""
  local resource_csvs=()
  local csv_path
  while IFS= read -r csv_path; do
    if [[ -z "$csv_path" ]]; then
      continue
    fi
    if [[ "$resource_csv_count" -eq 0 ]]; then
      resource_csv_first="$csv_path"
    fi
    latest_resource_csv="$csv_path"
    resource_csv_count=$((resource_csv_count + 1))
    resource_csvs+=("$csv_path")
  done < <(list_resource_csvs "$out_dir")

  if [[ "$resource_csv_count" -gt 0 ]]; then
    local resource_out_dir="${figures_base_dir_local%/}/resource"
    local resource_summary_csv
    mkdir -p "$resource_out_dir"
    resource_summary_csv="$resource_out_dir/resource_summary.csv"
    write_resource_summary_csv "$resource_summary_csv" "${resource_csvs[@]}"
    generate_resource_plots "$resource_out_dir" "${resource_csvs[@]}"
    echo "Resource CSV files: $resource_csv_count"
    echo "Resource range: $resource_csv_first -> $latest_resource_csv"
    echo "Resource summary CSV: $resource_summary_csv"
  fi
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
    emit_resource_summary "$OUT_DIR"
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

emit_resource_summary "$OUT_DIR"
