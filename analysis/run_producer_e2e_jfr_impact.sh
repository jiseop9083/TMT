#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KAFKA_HOME="${ROOT_DIR}/kafka-4.2"
CONFIG="${KAFKA_HOME}/config/server.properties"
LOG_DIR="/tmp/kraft-combined-logs"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-localhost:9092}"
NUM_TOPICS="${NUM_TOPICS:-3000}"
RECORD_SIZE="${RECORD_SIZE:-1}"
ITERATIONS="${ITERATIONS:-5}"
ACKS="${ACKS:-1}"
MAX_WAIT_SECS="${MAX_WAIT_SECS:-60}"
JFR_CONFIG="${JFR_CONFIG:-${SCRIPT_DIR}/producer-e2e-custom-profiling.jfc}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${KAFKA_HOME}/output/jfr-producer-e2e-impact}"
CONDITIONS=("off" "default" "profile" "custom")
READY_ENDPOINT="${BOOTSTRAP_SERVER%%,*}"
READY_HOST="${READY_ENDPOINT%:*}"
READY_PORT="${READY_ENDPOINT##*:}"
if [[ "${READY_HOST}" == "${READY_ENDPOINT}" ]]; then
  READY_HOST="localhost"
fi
if [[ -z "${READY_PORT}" || "${READY_PORT}" == "${READY_ENDPOINT}" ]]; then
  READY_PORT="9092"
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --iterations <n>          Number of repeats per condition (default: ${ITERATIONS})
  --num-topics <n>          Number of topics (default: ${NUM_TOPICS})
  --record-size <bytes>     Record size in bytes (default: ${RECORD_SIZE})
  --bootstrap-server <addr> Bootstrap server (default: ${BOOTSTRAP_SERVER})
  --acks <value>            Producer acks value (default: ${ACKS})
  --output-root <dir>       Output root directory
  --jfr-config <file>       Custom JFR .jfc file path
  --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --num-topics) NUM_TOPICS="$2"; shift 2 ;;
    --record-size) RECORD_SIZE="$2"; shift 2 ;;
    --bootstrap-server) BOOTSTRAP_SERVER="$2"; shift 2 ;;
    --acks) ACKS="$2"; shift 2 ;;
    --output-root) OUTPUT_ROOT="$2"; shift 2 ;;
    --jfr-config) JFR_CONFIG="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

stop_kafka() {
  log "Stopping Kafka broker..."
  "${KAFKA_HOME}/bin/kafka-server-stop.sh" 2>/dev/null || true
  sleep 5
  if pgrep -f "kafka.Kafka" >/dev/null 2>&1; then
    log "Force killing remaining Kafka broker processes..."
    pkill -f "kafka.Kafka" 2>/dev/null || true
    sleep 3
  fi
  log "Kafka broker stopped."
}

clean_logs() {
  log "Cleaning broker logs in ${LOG_DIR}"
  rm -rf "${LOG_DIR}"
}

format_storage() {
  local cluster_id
  log "Formatting KRaft storage..."
  cluster_id="$("${KAFKA_HOME}/bin/kafka-storage.sh" random-uuid)"
  "${KAFKA_HOME}/bin/kafka-storage.sh" format --standalone -t "${cluster_id}" -c "${CONFIG}"
  log "Formatted storage with cluster id ${cluster_id}"
}

start_kafka() {
  local broker_log="$1"
  local waited=0
  log "Starting Kafka broker..."
  KAFKA_OPTS="" "${KAFKA_HOME}/bin/kafka-server-start.sh" "${CONFIG}" >"${broker_log}" 2>&1 &
  BROKER_PID=$!
  log "Broker PID: ${BROKER_PID}"
  log "Waiting for broker readiness on ${READY_HOST}:${READY_PORT}"
  while ! nc -z "${READY_HOST}" "${READY_PORT}" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [[ "${waited}" -ge "${MAX_WAIT_SECS}" ]]; then
      echo "Broker did not become ready within ${MAX_WAIT_SECS}s" >&2
      exit 1
    fi
  done
  sleep 5
  log "Kafka broker is ready."
}

jfr_opts_for_condition() {
  local condition="$1"
  local jfr_file="$2"
  case "${condition}" in
    off) printf '' ;;
    default) printf '%s' "-XX:StartFlightRecording=settings=default,filename=${jfr_file},dumponexit=true" ;;
    profile) printf '%s' "-XX:StartFlightRecording=settings=profile,filename=${jfr_file},dumponexit=true" ;;
    custom) printf '%s' "-XX:StartFlightRecording=settings=${JFR_CONFIG},filename=${jfr_file},dumponexit=true" ;;
    *) echo "Unknown condition: ${condition}" >&2; exit 1 ;;
  esac
}

summarize_csv() {
  local csv_path="$1"
  local condition="$2"
  local iteration="$3"
  awk -F',' 'NR > 1 && $3 != "ERROR" { print $3 }' "${csv_path}" \
    | sort -g \
    | awk -v condition="${condition}" -v iteration="${iteration}" '
      function percentile(p, idx) {
        if (n == 0) return "nan"
        if (p <= 0) return values[1]
        if (p >= 100) return values[n]
        idx = int(((n - 1) * p) / 100) + 1
        if (idx < 1) idx = 1
        if (idx > n) idx = n
        return values[idx]
      }
      { n++; values[n] = $1 + 0.0; sum += values[n] }
      END {
        if (n == 0) {
          printf "%s,%s,0,nan,nan,nan,nan,nan,nan,nan,nan\n", condition, iteration
          exit
        }
        printf "%s,%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
          condition, iteration, n, sum / n,
          percentile(100), percentile(99), percentile(95), percentile(75),
          percentile(50), percentile(25), percentile(0)
      }'
}

summarize_csvs() {
  local condition="$1"
  shift
  local iteration_count="$#"
  if [[ "${iteration_count}" -eq 0 ]]; then
    printf "%s,0,0,nan,nan,nan,nan,nan,nan,nan,nan\n" "${condition}"
    return
  fi
  awk -F',' 'NR > 1 && $3 != "ERROR" { print $3 }' "$@" \
    | sort -g \
    | awk -v condition="${condition}" -v iteration_count="${iteration_count}" '
      function percentile(p, idx) {
        if (n == 0) return "nan"
        if (p <= 0) return values[1]
        if (p >= 100) return values[n]
        idx = int(((n - 1) * p) / 100) + 1
        if (idx < 1) idx = 1
        if (idx > n) idx = n
        return values[idx]
      }
      { n++; values[n] = $1 + 0.0; sum += values[n] }
      END {
        if (n == 0) {
          printf "%s,%s,0,nan,nan,nan,nan,nan,nan,nan,nan\n", condition, iteration_count
          exit
        }
        printf "%s,%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
          condition, iteration_count, n, sum / n,
          percentile(100), percentile(99), percentile(95), percentile(75),
          percentile(50), percentile(25), percentile(0)
      }'
}

write_comparison_csv() {
  local aggregate_csv="$1"
  local comparison_csv="$2"
  awk -F',' '
    NR == 1 { next }
    {
      cond = $1
      avg[cond] = $4; p100[cond] = $5; p99[cond] = $6; p95[cond] = $7
      p75[cond] = $8; p50[cond] = $9; p25[cond] = $10; p0[cond] = $11
      seen[cond] = 1
    }
    END {
      print "condition,metric,off_ms,condition_ms,delta_ms,delta_pct"
      for (cond in seen) {
        if (cond == "off") continue
        emit(cond, "avg", avg["off"], avg[cond])
        emit(cond, "p100", p100["off"], p100[cond])
        emit(cond, "p99", p99["off"], p99[cond])
        emit(cond, "p95", p95["off"], p95[cond])
        emit(cond, "p75", p75["off"], p75[cond])
        emit(cond, "p50", p50["off"], p50[cond])
        emit(cond, "p25", p25["off"], p25[cond])
        emit(cond, "p0", p0["off"], p0[cond])
      }
    }
    function emit(cond, metric, base, value, delta, pct) {
      delta = value - base
      if (base == 0) pct = "nan"; else pct = sprintf("%.6f", (delta / base) * 100.0)
      printf "%s,%s,%.6f,%.6f,%.6f,%s\n", cond, metric, base, value, delta, pct
    }' "${aggregate_csv}" >"${comparison_csv}"
}

run_case() {
  local condition="$1"
  local iteration="$2"
  local run_dir="$3"
  local case_dir="${run_dir}/${condition}/iteration_${iteration}"
  local broker_log="${case_dir}/broker.log"
  local producer_log="${case_dir}/producer.log"
  local producer_csv="${case_dir}/producer_latency_results.csv"
  local jfr_file="${case_dir}/producer.jfr"
  local opts

  mkdir -p "${case_dir}"
  stop_kafka
  clean_logs
  format_storage
  start_kafka "${broker_log}"

  log "Running condition=${condition}, iteration=${iteration}"
  opts="$(jfr_opts_for_condition "${condition}" "${jfr_file}")"
  KAFKA_OPTS="${opts}" \
    "${KAFKA_HOME}/bin/kafka-producer-latency.sh" \
    --bootstrap-server "${BOOTSTRAP_SERVER}" \
    --num-topics "${NUM_TOPICS}" \
    --record-size "${RECORD_SIZE}" \
    --acks "${ACKS}" \
    --output "${producer_csv}" \
    >"${producer_log}" 2>&1

  summarize_csv "${producer_csv}" "${condition}" "${iteration}" >>"${RUN_SUMMARY_CSV}"
  log "Finished condition=${condition}, iteration=${iteration}"
}

rotated_conditions() {
  local start_index="$1"
  local total="${#CONDITIONS[@]}"
  local i idx
  for ((i = 0; i < total; i++)); do
    idx=$(((start_index + i) % total))
    printf '%s\n' "${CONDITIONS[$idx]}"
  done
}

require_command bash
require_command java
require_command nc
require_command pgrep
require_command pkill

if [[ ! -f "${CONFIG}" ]]; then
  echo "Kafka config not found: ${CONFIG}" >&2
  exit 1
fi
if [[ ! -f "${JFR_CONFIG}" ]]; then
  echo "JFR config not found: ${JFR_CONFIG}" >&2
  exit 1
fi

RUN_ID="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="${OUTPUT_ROOT}/${RUN_ID}"
mkdir -p "${RUN_DIR}"
RUN_SUMMARY_CSV="${RUN_DIR}/iteration_summary.csv"
AGGREGATE_CSV="${RUN_DIR}/condition_summary.csv"
COMPARISON_CSV="${RUN_DIR}/comparison.csv"
METADATA_TXT="${RUN_DIR}/metadata.txt"

cat >"${METADATA_TXT}" <<EOF
run_id=${RUN_ID}
bootstrap_server=${BOOTSTRAP_SERVER}
num_topics=${NUM_TOPICS}
record_size=${RECORD_SIZE}
acks=${ACKS}
iterations=${ITERATIONS}
jfr_config=${JFR_CONFIG}
conditions=${CONDITIONS[*]}
log_dir=${LOG_DIR}
EOF

printf '%s\n' "condition,iteration,sample_count,avg_ms,p100_ms,p99_ms,p95_ms,p75_ms,p50_ms,p25_ms,p0_ms" >"${RUN_SUMMARY_CSV}"

log "Starting producer E2E JFR impact experiment"
log "Output directory: ${RUN_DIR}"
log "Topics=${NUM_TOPICS}, record_size=${RECORD_SIZE}, iterations=${ITERATIONS}"
log "Conditions=${CONDITIONS[*]}"

trap 'stop_kafka >/dev/null 2>&1 || true' EXIT

for iteration in $(seq 1 "${ITERATIONS}"); do
  mapfile -t ORDER < <(rotated_conditions $(((iteration - 1) % ${#CONDITIONS[@]})))
  for condition in "${ORDER[@]}"; do
    run_case "${condition}" "${iteration}" "${RUN_DIR}"
  done
done

stop_kafka

printf '%s\n' "condition,iteration_count,sample_count,avg_ms,p100_ms,p99_ms,p95_ms,p75_ms,p50_ms,p25_ms,p0_ms" >"${AGGREGATE_CSV}"
shopt -s nullglob
for condition in "${CONDITIONS[@]}"; do
  CSVS=("${RUN_DIR}/${condition}"/iteration_*/producer_latency_results.csv)
  summarize_csvs "${condition}" "${CSVS[@]}" >>"${AGGREGATE_CSV}"
done
shopt -u nullglob

write_comparison_csv "${AGGREGATE_CSV}" "${COMPARISON_CSV}"

log "Experiment completed"
log "Per-iteration summary: ${RUN_SUMMARY_CSV}"
log "Condition summary: ${AGGREGATE_CSV}"
log "Comparison: ${COMPARISON_CSV}"
