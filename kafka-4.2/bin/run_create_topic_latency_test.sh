#!/bin/bash

set -euo pipefail

KAFKA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
LOG_DIR="/tmp/kraft-combined-logs"
BOOTSTRAP_SERVER="localhost:9092"
NUM_TOPICS=1000
TOPIC_PREFIX="cp_topic"
PARTITIONS=1
REPLICATION_FACTOR=1
INTERVAL_MS=10
REPEAT=1
REPEAT_INTERVAL_MS=5000
OUTPUT_DIR="$KAFKA_HOME/output/topic_create_latency"
RESET_BROKER=true
KEEP_BROKER_RUNNING=false
CONTROLLER_LOG_PATH="$KAFKA_HOME/logs/controller.log"
CONTROLLER_LOG_START_LINE=0
CONTROLLER_RUN_LOG=""
HAS_RG=false
if command -v rg >/dev/null 2>&1; then
  HAS_RG=true
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

extract_metric_values() {
  local file=$1
  local metric_pattern=$2
  local field_name=$3
  local out_file=$4

  if [[ "$HAS_RG" == true ]]; then
    rg "$metric_pattern" "$file" \
      | rg -o "${field_name}=[0-9]+" \
      | cut -d= -f2 > "$out_file" || true
  else
    grep -F "$metric_pattern" "$file" \
      | grep -Eo "${field_name}=[0-9]+" \
      | cut -d= -f2 > "$out_file" || true
  fi
}

count_metric_lines() {
  local file=$1
  local metric_pattern=$2

  if [[ "$HAS_RG" == true ]]; then
    rg -c "$metric_pattern" "$file" || true
  else
    grep -F -c "$metric_pattern" "$file" || true
  fi
}

has_metric_line() {
  local file=$1
  local metric_pattern=$2

  if [[ "$HAS_RG" == true ]]; then
    rg -q "$metric_pattern" "$file"
  else
    grep -F -q "$metric_pattern" "$file"
  fi
}

percentile_from_sorted_file() {
  local file=$1
  local count=$2
  local percentile=$3

  local idx=$(( (count * percentile + 99) / 100 ))
  if [[ $idx -lt 1 ]]; then
    idx=1
  fi
  if [[ $idx -gt $count ]]; then
    idx=$count
  fi

  sed -n "${idx}p" "$file"
}

metric_stats_csv() {
  local value_file=$1

  if [[ ! -s "$value_file" ]]; then
    echo "0,0,0,0,0,0,0"
    return
  fi

  local sorted_file
  sorted_file="$(mktemp)"
  sort -n "$value_file" > "$sorted_file"

  local count min max sum avg p50 p95 p99
  count=$(wc -l < "$sorted_file" | tr -d ' ')
  min=$(head -n 1 "$sorted_file")
  max=$(tail -n 1 "$sorted_file")
  sum=$(awk '{s += $1} END {printf "%.0f", s}' "$sorted_file")
  avg=$((sum / count))
  p50=$(percentile_from_sorted_file "$sorted_file" "$count" 50)
  p95=$(percentile_from_sorted_file "$sorted_file" "$count" 95)
  p99=$(percentile_from_sorted_file "$sorted_file" "$count" 99)

  rm -f "$sorted_file"
  echo "$count,$min,$max,$avg,$p50,$p95,$p99"
}

convert_ns_file_to_us_file() {
  local ns_file=$1
  local us_file=$2

  if [[ -s "$ns_file" ]]; then
    awk '{printf "%.0f\n", $1 / 1000}' "$ns_file" > "$us_file"
  else
    : > "$us_file"
  fi
}

capture_controller_run_log() {
  local run_ts=$1
  local controller_log_dir="$OUTPUT_DIR/logs/controller"
  mkdir -p "$controller_log_dir"
  CONTROLLER_RUN_LOG="$controller_log_dir/${run_ts}.log"

  if [[ -f "$CONTROLLER_LOG_PATH" ]]; then
    if [[ "$CONTROLLER_LOG_START_LINE" -gt 0 ]]; then
      tail -n +"$((CONTROLLER_LOG_START_LINE + 1))" "$CONTROLLER_LOG_PATH" > "$CONTROLLER_RUN_LOG" || true
    else
      cp "$CONTROLLER_LOG_PATH" "$CONTROLLER_RUN_LOG" || true
    fi
  else
    : > "$CONTROLLER_RUN_LOG"
  fi
}

enrich_request_results_with_metrics() {
  local broker_log_path="${BROKER_LOG:-}"
  local controller_log_source="${CONTROLLER_RUN_LOG:-$CONTROLLER_LOG_PATH}"
  local temp_dir
  temp_dir="$(mktemp -d)"

  local e2e_pairs_ns_file="$temp_dir/e2e_pairs_ns.csv"
  local e2e_pairs_file="$temp_dir/e2e_pairs_us.csv"
  local on_metadata_values_ns_file="$temp_dir/on_metadata_values_ns.txt"
  local on_metadata_values_file="$temp_dir/on_metadata_values_us.txt"
  local create_topics_values_ns_file="$temp_dir/create_topics_values_ns.txt"
  local create_topics_values_file="$temp_dir/create_topics_values_us.txt"
  local enriched_csv="$temp_dir/topic_create_requests_enriched.csv"

  : > "$e2e_pairs_ns_file"
  : > "$e2e_pairs_file"
  : > "$on_metadata_values_ns_file"
  : > "$on_metadata_values_file"
  : > "$create_topics_values_ns_file"
  : > "$create_topics_values_file"

  if [[ -n "$broker_log_path" && -f "$broker_log_path" ]]; then
    awk '
      /TOPIC_CREATE_METRIC metric=e2e / {
        topic=""
        latency=""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^topic=/) topic = substr($i, 7)
          if ($i ~ /^latency_ns=/) latency = substr($i, 12)
        }
        if (topic != "" && latency != "") {
          print topic "," latency
        }
      }
    ' "$broker_log_path" > "$e2e_pairs_ns_file"

    extract_metric_values "$broker_log_path" "TOPIC_CREATE_METRIC metric=onMetadataUpdate " "duration_ns" "$on_metadata_values_ns_file"

    :
  fi

  if [[ -f "$controller_log_source" ]]; then
    extract_metric_values "$controller_log_source" "TOPIC_CREATE_METRIC metric=createTopics " "duration_ns" "$create_topics_values_ns_file"
  fi

  if [[ -s "$e2e_pairs_ns_file" ]]; then
    awk -F, '{printf "%s,%.0f\n", $1, $2 / 1000}' "$e2e_pairs_ns_file" > "$e2e_pairs_file"
  fi
  convert_ns_file_to_us_file "$on_metadata_values_ns_file" "$on_metadata_values_file"
  convert_ns_file_to_us_file "$create_topics_values_ns_file" "$create_topics_values_file"

  local e2e_count on_metadata_count create_topics_count
  e2e_count=$(wc -l < "$e2e_pairs_file" | tr -d ' ')
  on_metadata_count=$(wc -l < "$on_metadata_values_file" | tr -d ' ')
  create_topics_count=$(wc -l < "$create_topics_values_file" | tr -d ' ')
  if [[ "$e2e_count" -gt 0 && "$on_metadata_count" -eq 0 ]]; then
    log "WARNING: e2e metric은 있는데 onMetadataUpdate metric 파싱 결과가 0건입니다. broker log를 확인하세요: $broker_log_path"
  fi
  if [[ "$e2e_count" -gt 0 && "$create_topics_count" -eq 0 ]]; then
    log "WARNING: e2e metric은 있는데 createTopics metric 파싱 결과가 0건입니다. controller log를 확인하세요: $controller_log_source"
  fi

  printf "%s\n" \
    "seq,topic_name,request_latency_us,e2e_latency_us,on_metadata_duration_us,create_topics_duration_us,status,error" \
    > "$enriched_csv"

  local line_no=0
  while IFS=',' read -r seq topic_name request_latency_us status error; do
    if [[ "$seq" == "seq" ]]; then
      continue
    fi
    line_no=$((line_no + 1))

    local e2e_latency_us on_metadata_duration_us create_topics_duration_us
    e2e_latency_us=$(awk -F, -v topic="$topic_name" '$1 == topic { print $2; exit }' "$e2e_pairs_file")
    on_metadata_duration_us=$(sed -n "${line_no}p" "$on_metadata_values_file")
    create_topics_duration_us=$(sed -n "${line_no}p" "$create_topics_values_file")

    printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$seq" "$topic_name" "$request_latency_us" "${e2e_latency_us:-}" "${on_metadata_duration_us:-}" "${create_topics_duration_us:-}" "$status" "$error" \
      >> "$enriched_csv"
  done < "$RESULT_CSV"

  mv "$enriched_csv" "$RESULT_CSV"
  rm -rf "$temp_dir"
}

generate_experiment_summary() {
  local run_ts=$1
  local summary_csv="$OUTPUT_DIR/experiment_summary_${run_ts}.csv"
  local broker_log_path="${BROKER_LOG:-}"
  local controller_log_source="${CONTROLLER_RUN_LOG:-$CONTROLLER_LOG_PATH}"
  local temp_dir
  temp_dir="$(mktemp -d)"

  local e2e_values_ns_file="$temp_dir/e2e_values_ns.txt"
  local e2e_values_file="$temp_dir/e2e_values_us.txt"
  local on_metadata_values_ns_file="$temp_dir/on_metadata_values_ns.txt"
  local on_metadata_values_file="$temp_dir/on_metadata_values_us.txt"
  local create_topics_values_ns_file="$temp_dir/create_topics_values_ns.txt"
  local create_topics_values_file="$temp_dir/create_topics_values_us.txt"
  local request_values_file="$temp_dir/request_values_us.txt"

  if [[ -n "$broker_log_path" && -f "$broker_log_path" ]]; then
    extract_metric_values "$broker_log_path" "TOPIC_CREATE_METRIC metric=e2e " "latency_ns" "$e2e_values_ns_file"
    extract_metric_values "$broker_log_path" "TOPIC_CREATE_METRIC metric=onMetadataUpdate " "duration_ns" "$on_metadata_values_ns_file"

    :
  else
    : > "$e2e_values_ns_file"
    : > "$on_metadata_values_ns_file"
    : > "$create_topics_values_ns_file"
  fi

  if [[ -f "$controller_log_source" ]]; then
    extract_metric_values "$controller_log_source" "TOPIC_CREATE_METRIC metric=createTopics " "duration_ns" "$create_topics_values_ns_file"
  fi

  convert_ns_file_to_us_file "$e2e_values_ns_file" "$e2e_values_file"
  convert_ns_file_to_us_file "$on_metadata_values_ns_file" "$on_metadata_values_file"
  convert_ns_file_to_us_file "$create_topics_values_ns_file" "$create_topics_values_file"

  tail -n +2 "$RESULT_CSV" | cut -d, -f3 > "$request_values_file"

  local forward_count
  if [[ -n "$broker_log_path" && -f "$broker_log_path" ]]; then
    forward_count=$(count_metric_lines "$broker_log_path" "TOPIC_CREATE_METRIC metric=forwardToController ")
    if [[ -z "$forward_count" ]]; then
      forward_count=0
    fi
  else
    forward_count=0
  fi

  local e2e_stats on_metadata_stats create_topics_stats request_stats
  e2e_stats=$(metric_stats_csv "$e2e_values_file")
  on_metadata_stats=$(metric_stats_csv "$on_metadata_values_file")
  create_topics_stats=$(metric_stats_csv "$create_topics_values_file")
  request_stats=$(metric_stats_csv "$request_values_file")

  printf "%s\n" \
    "timestamp,num_topics,interval_ms,partitions,replication_factor,forward_count,e2e_count,e2e_min_us,e2e_max_us,e2e_avg_us,e2e_p50_us,e2e_p95_us,e2e_p99_us,on_metadata_count,on_metadata_min_us,on_metadata_max_us,on_metadata_avg_us,on_metadata_p50_us,on_metadata_p95_us,on_metadata_p99_us,create_topics_count,create_topics_min_us,create_topics_max_us,create_topics_avg_us,create_topics_p50_us,create_topics_p95_us,create_topics_p99_us,request_count,request_min_us,request_max_us,request_avg_us,request_p50_us,request_p95_us,request_p99_us" \
    > "$summary_csv"

  printf "%s\n" \
    "$run_ts,$NUM_TOPICS,$INTERVAL_MS,$PARTITIONS,$REPLICATION_FACTOR,$forward_count,$e2e_stats,$on_metadata_stats,$create_topics_stats,$request_stats" \
    >> "$summary_csv"

  rm -rf "$temp_dir"
  SUMMARY_CSV="$summary_csv"
}

now_ns() {
  perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000000000)'
}

parse_bootstrap_endpoint() {
  local endpoint host port
  endpoint="${BOOTSTRAP_SERVER%%,*}"
  host="${endpoint%%:*}"
  port="${endpoint##*:}"

  if [[ "$host" == "$port" ]]; then
    port="9092"
  fi

  BOOTSTRAP_HOST="$host"
  BOOTSTRAP_PORT="$port"
}

stop_kafka() {
  log "Stopping Kafka broker..."
  "$KAFKA_HOME/bin/kafka-server-stop.sh" 2>/dev/null || true
  sleep 5

  if pgrep -f "kafka.Kafka" > /dev/null 2>&1; then
    log "Force killing remaining Kafka processes..."
    pkill -f "kafka.Kafka" 2>/dev/null || true
    sleep 3
  fi

  log "Kafka broker stopped."
}

clean_logs() {
  log "Cleaning log directory: $LOG_DIR"
  local max_attempts=8
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    rm -rf "$LOG_DIR" 2>/dev/null || true
    if [[ ! -e "$LOG_DIR" ]]; then
      log "Log directory cleaned."
      return
    fi
    log "Log directory cleanup retry (${attempt}/${max_attempts})..."
    sleep 2
    attempt=$((attempt + 1))
  done

  if [[ -d "$LOG_DIR" ]]; then
    find "$LOG_DIR" -mindepth 1 -depth -exec rm -rf {} + 2>/dev/null || true
    rmdir "$LOG_DIR" 2>/dev/null || true
  fi

  if [[ -e "$LOG_DIR" ]]; then
    log "ERROR: Failed to clean log directory after retries: $LOG_DIR"
    exit 1
  fi

  log "Log directory cleaned."
}

format_storage() {
  log "Formatting KRaft storage..."
  local cluster_id
  cluster_id=$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)
  log "Generated new Cluster ID: $cluster_id"
  "$KAFKA_HOME/bin/kafka-storage.sh" format --standalone -t "$cluster_id" -c "$CONFIG"
  log "Storage formatted."
}

start_kafka() {
  local run_ts=$1
  local broker_log_dir="$OUTPUT_DIR/logs/broker"
  mkdir -p "$broker_log_dir"
  BROKER_LOG="$broker_log_dir/${run_ts}.log"

  log "Starting Kafka broker..."
  "$KAFKA_HOME/bin/kafka-server-start.sh" "$CONFIG" > "$BROKER_LOG" 2>&1 &
  KAFKA_PID=$!
  log "Kafka broker starting (PID: $KAFKA_PID)"
  log "Broker log: $BROKER_LOG"

  parse_bootstrap_endpoint
  log "Waiting for broker to be ready on ${BOOTSTRAP_HOST}:${BOOTSTRAP_PORT}..."

  local max_wait=60
  local waited=0
  while ! nc -z "$BOOTSTRAP_HOST" "$BOOTSTRAP_PORT" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge $max_wait ]]; then
      log "ERROR: Broker did not start within ${max_wait}s"
      exit 1
    fi
  done

  sleep 5
  log "Kafka broker is ready."
}

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --bootstrap-server <host:port>    (default: localhost:9092)
  --num-topics <n>                  (default: 1000)
  --topic-prefix <prefix>           (default: cp_topic)
  --partitions <n>                  (default: 1)
  --replication-factor <n>          (default: 1)
  --interval-ms <ms>                (default: 10)
  --repeat <n>                      Repeat whole experiment n times (default: 1)
  --repeat-interval-ms <ms>         Wait between repeated experiments (default: 5000)
  --output-dir <path>               (default: kafka-4.2/output/topic_create_latency)
  --skip-broker-reset               Skip stop/clean/format/start sequence
  --keep-broker-running             Do not stop broker after test (only when this script started it)
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap-server)
      BOOTSTRAP_SERVER="$2"; shift 2 ;;
    --num-topics)
      NUM_TOPICS="$2"; shift 2 ;;
    --topic-prefix)
      TOPIC_PREFIX="$2"; shift 2 ;;
    --partitions)
      PARTITIONS="$2"; shift 2 ;;
    --replication-factor)
      REPLICATION_FACTOR="$2"; shift 2 ;;
    --interval-ms)
      INTERVAL_MS="$2"; shift 2 ;;
    --repeat)
      REPEAT="$2"; shift 2 ;;
    --repeat-interval-ms)
      REPEAT_INTERVAL_MS="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --skip-broker-reset)
      RESET_BROKER=false; shift ;;
    --keep-broker-running)
      KEEP_BROKER_RUNNING=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1 ;;
  esac
done

mkdir -p "$OUTPUT_DIR"
SLEEP_SEC=$(awk "BEGIN { printf \"%.6f\", $INTERVAL_MS / 1000 }")
REPEAT_SLEEP_SEC=$(awk "BEGIN { printf \"%.6f\", $REPEAT_INTERVAL_MS / 1000 }")

run_single_experiment() {
  local run_idx=$1
  local run_ts=$2
  local script_started_broker=false
  RESULT_CSV="$OUTPUT_DIR/topic_create_requests_${run_ts}.csv"
  SUMMARY_CSV=""
  BROKER_LOG=""
  CONTROLLER_RUN_LOG=""
  CONTROLLER_LOG_START_LINE=0

  log "Starting create-topic latency test (${run_idx}/${REPEAT})"
  log "bootstrap-server: $BOOTSTRAP_SERVER"
  log "num-topics: $NUM_TOPICS"
  log "topic-prefix: $TOPIC_PREFIX"
  log "partitions: $PARTITIONS"
  log "replication-factor: $REPLICATION_FACTOR"
  log "interval-ms: $INTERVAL_MS"
  log "request result csv: $RESULT_CSV"

  if [[ "$RESET_BROKER" == true ]]; then
    log "Preparing broker before test (stop -> clean logs -> format -> start)"
    stop_kafka
    clean_logs
    format_storage
    start_kafka "$run_ts"
    script_started_broker=true
  fi

  if [[ -f "$CONTROLLER_LOG_PATH" ]]; then
    CONTROLLER_LOG_START_LINE=$(wc -l < "$CONTROLLER_LOG_PATH" | tr -d ' ')
  fi

  printf "seq,topic_name,request_latency_us,status,error\n" > "$RESULT_CSV"

  for i in $(seq 1 "$NUM_TOPICS"); do
    topic_name="${TOPIC_PREFIX}_${run_ts}_${i}"
    start_ns=$(now_ns)

    if output=$("$KAFKA_HOME/bin/kafka-topics.sh" \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --create \
      --topic "$topic_name" \
      --partitions "$PARTITIONS" \
      --replication-factor "$REPLICATION_FACTOR" 2>&1); then
      status="OK"
      error=""
    else
      status="ERROR"
      error=$(echo "$output" | tr '\n' ' ' | tr ',' ';' | cut -c1-300)
    fi

    end_ns=$(now_ns)
    latency_ns=$((end_ns - start_ns))
    latency_us=$((latency_ns / 1000))
    printf "%s,%s,%s,%s,%s\n" "$i" "$topic_name" "$latency_us" "$status" "$error" >> "$RESULT_CSV"

    if [[ "$i" == "1" || $((i % 100)) == 0 || "$i" == "$NUM_TOPICS" ]]; then
      log "[$i/$NUM_TOPICS] topic=$topic_name request_latency_us=$latency_us status=$status"
    fi

    if [[ "$INTERVAL_MS" -gt 0 ]]; then
      sleep "$SLEEP_SEC"
    fi
  done

  if [[ "$script_started_broker" == true && "$KEEP_BROKER_RUNNING" == false ]]; then
    stop_kafka
  fi

  capture_controller_run_log "$run_ts"
  enrich_request_results_with_metrics
  generate_experiment_summary "$run_ts"

  log "Test completed (${run_idx}/${REPEAT})"
  log "CSV: $RESULT_CSV"
  log "Summary CSV: $SUMMARY_CSV"
  if [[ -n "${BROKER_LOG:-}" ]]; then
    log "Broker log: $BROKER_LOG"
  fi
  if [[ -n "${CONTROLLER_RUN_LOG:-}" ]]; then
    log "Controller log: $CONTROLLER_RUN_LOG"
  fi
  log "Broker log에서 아래 문자열로 계측 결과를 확인하세요:"
  log "TOPIC_CREATE_METRIC"
  if [[ -n "${BROKER_LOG:-}" ]] && ! has_metric_line "$BROKER_LOG" "TOPIC_CREATE_METRIC"; then
    log "WARNING: broker log에 TOPIC_CREATE_METRIC가 없습니다. 코드 수정 후에는 './gradlew :core:jar :metadata:jar :server:jar :tools:jar -x test'를 먼저 실행하세요."
  fi
}

for run_idx in $(seq 1 "$REPEAT"); do
  RUN_TS=$(date '+%Y%m%d_%H%M%S')
  run_single_experiment "$run_idx" "$RUN_TS"
  if [[ "$run_idx" -lt "$REPEAT" && "$REPEAT_INTERVAL_MS" -gt 0 ]]; then
    log "Waiting ${REPEAT_INTERVAL_MS}ms before next experiment..."
    sleep "$REPEAT_SLEEP_SEC"
  fi
done
