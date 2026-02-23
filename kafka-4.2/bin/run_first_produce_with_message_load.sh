#!/usr/bin/env bash
#
# First Produce E2E under Message Load
# - 3 producers total:
#   1) First producer sends to a non-existing topic (auto topic creation path) and records e2e.
#   2) Two load producers continuously send periodic batches to pre-created topics.
#
# Workflow per iteration:
# 1. Stop broker
# 2. Clean logs
# 3. Reformat storage
# 4. Start broker
# 5. Create load topics
# 6. Start 2 background load producers
# 7. Measure first-produce e2e on a new topic
#

set -euo pipefail

KAFKA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
LOG_DIR="/tmp/kraft-combined-logs"
BOOTSTRAP_SERVER="localhost:9092"
ACKS="1"

ITERATIONS=5
FIRST_RECORD_SIZE=1048576
FIRST_NUM_TOPICS=3000

LOAD_PRODUCER_COUNT=2
LOAD_RECORD_SIZE=1048576
LOAD_BATCH_RECORDS=1
LOAD_THROUGHPUT=-1
LOAD_MAX_REQUEST_SIZE=2097152
LOAD_SLEEP_SEC=0.1
LOAD_WARMUP_SEC=10
LOAD_TOPIC_PARTITIONS=12
LOAD_TOPIC_REPLICATION_FACTOR=1
FD_SAMPLE_INTERVAL_SEC=2

OUTPUT_BASE="$KAFKA_HOME/output/first-produce-with-message-load"
BROKER_PID=""
FD_SAMPLER_PID=""
declare -a LOAD_PIDS=()

mkdir -p "$OUTPUT_BASE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

epoch_ms() {
  date '+%s%3N' 2>/dev/null || date '+%s000'
}

wait_for_port() {
  local host="$1"
  local port="$2"
  local max_wait="$3"
  local waited=0

  while ! nc -z "$host" "$port" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [[ "$waited" -ge "$max_wait" ]]; then
      return 1
    fi
  done

  return 0
}

count_open_fds() {
  local pid="$1"
  if ! command -v lsof >/dev/null 2>&1; then
    echo ""
    return 1
  fi
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo ""
    return 1
  fi
  lsof -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
}

count_topic_dirs() {
  local base_dir="$1"
  if [[ ! -d "$base_dir" ]]; then
    echo "0"
    return 0
  fi
  find "$base_dir" -maxdepth 1 -type d -name 'test_topic_*' 2>/dev/null | wc -l | tr -d ' '
}

count_segment_files() {
  local base_dir="$1"
  if [[ ! -d "$base_dir" ]]; then
    echo "0"
    return 0
  fi
  find "$base_dir" -type f \( -name '*.log' -o -name '*.index' -o -name '*.timeindex' \) 2>/dev/null | wc -l | tr -d ' '
}

measure_storage_kb() {
  local base_dir="$1"
  if [[ ! -d "$base_dir" ]]; then
    echo "0"
    return 0
  fi
  du -sk "$base_dir" 2>/dev/null | awk '{print $1}'
}

measure_ps_stats() {
  local pid="$1"
  if ! command -v ps >/dev/null 2>&1; then
    echo ",,,"
    return 0
  fi
  local row
  row="$(ps -p "$pid" -o %cpu=,rss=,vsz= 2>/dev/null | awk 'NR==1{print $1","$2","$3}')"
  if [[ -z "$row" ]]; then
    echo ",,,"
  else
    echo "$row"
  fi
}

measure_heap_kb() {
  local pid="$1"
  if ! command -v jstat >/dev/null 2>&1; then
    echo ","
    return 0
  fi
  local gc_row
  gc_row="$(jstat -gc "$pid" 2>/dev/null | awk 'NR==2{print $1","$2","$3","$4","$5","$6","$7","$8}')"
  if [[ -z "$gc_row" ]]; then
    echo ","
    return 0
  fi
  IFS=',' read -r s0c s1c s0u s1u ec eu oc ou <<<"$gc_row"
  awk -v s0c="${s0c:-0}" -v s1c="${s1c:-0}" -v ec="${ec:-0}" -v oc="${oc:-0}" \
      -v s0u="${s0u:-0}" -v s1u="${s1u:-0}" -v eu="${eu:-0}" -v ou="${ou:-0}" \
      'BEGIN{
        committed=s0c+s1c+ec+oc;
        used=s0u+s1u+eu+ou;
        printf "%.0f,%.0f", used, committed;
      }'
}

start_fd_sampler() {
  local pid="$1"
  local out_csv="$2"
  if ! command -v lsof >/dev/null 2>&1; then
    log "WARN: lsof not found; skipping resource sampling."
    return 0
  fi
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    log "WARN: Broker PID is not alive; skipping resource sampling."
    return 0
  fi

  printf '%s\n' "timestamp,epoch_ms,broker_pid,open_fd_count,cpu_pct,rss_kb,vsz_kb,heap_used_kb,heap_committed_kb,storage_kb,topic_dir_count,segment_file_count" >"$out_csv"
  (
    while kill -0 "$pid" 2>/dev/null; do
      local now epoch_now fd_count ps_stats cpu_pct rss_kb vsz_kb heap_stats heap_used_kb heap_committed_kb
      local storage_kb topic_dir_count segment_file_count
      now="$(date '+%Y-%m-%d %H:%M:%S')"
      epoch_now="$(epoch_ms)"
      fd_count="$(count_open_fds "$pid")"
      ps_stats="$(measure_ps_stats "$pid")"
      IFS=',' read -r cpu_pct rss_kb vsz_kb <<<"$ps_stats"
      heap_stats="$(measure_heap_kb "$pid")"
      IFS=',' read -r heap_used_kb heap_committed_kb <<<"$heap_stats"
      storage_kb="$(measure_storage_kb "$LOG_DIR")"
      topic_dir_count="$(count_topic_dirs "$LOG_DIR")"
      segment_file_count="$(count_segment_files "$LOG_DIR")"
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$now" "$epoch_now" "$pid" "${fd_count:-}" "${cpu_pct:-}" "${rss_kb:-}" "${vsz_kb:-}" \
        "${heap_used_kb:-}" "${heap_committed_kb:-}" "${storage_kb:-0}" "${topic_dir_count:-0}" "${segment_file_count:-0}" \
        >>"$out_csv"
      sleep "$FD_SAMPLE_INTERVAL_SEC"
    done
  ) &
  FD_SAMPLER_PID=$!
  log "Started resource sampler (PID: $FD_SAMPLER_PID), interval=${FD_SAMPLE_INTERVAL_SEC}s"
}

stop_fd_sampler() {
  if [[ -n "${FD_SAMPLER_PID:-}" ]] && kill -0 "$FD_SAMPLER_PID" 2>/dev/null; then
    kill "$FD_SAMPLER_PID" 2>/dev/null || true
    wait "$FD_SAMPLER_PID" 2>/dev/null || true
  fi
  FD_SAMPLER_PID=""
}

stop_load_producers() {
  if [[ "${#LOAD_PIDS[@]}" -eq 0 ]]; then
    return 0
  fi

  log "Stopping load producers..."
  local pid
  for pid in "${LOAD_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done

  for pid in "${LOAD_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  LOAD_PIDS=()
  log "Load producers stopped."
}

stop_kafka() {
  stop_fd_sampler
  stop_load_producers
  log "Stopping Kafka broker..."
  "$KAFKA_HOME/bin/kafka-server-stop.sh" 2>/dev/null || true
  sleep 5

  if pgrep -f "kafka.Kafka" >/dev/null 2>&1; then
    log "Force killing remaining Kafka processes..."
    pkill -f "kafka.Kafka" 2>/dev/null || true
    sleep 3
  fi

  BROKER_PID=""
  log "Kafka broker stopped."
}

clean_logs() {
  log "Cleaning log directory: $LOG_DIR"
  local max_attempts=8
  local attempt=1

  while [[ "$attempt" -le "$max_attempts" ]]; do
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
  cluster_id="$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)"
  log "Generated new Cluster ID: $cluster_id"
  "$KAFKA_HOME/bin/kafka-storage.sh" format --standalone -t "$cluster_id" -c "$CONFIG"
  log "Storage formatted."
}

start_kafka() {
  local iteration="$1"
  local timestamp="$2"
  local broker_log_dir="$OUTPUT_BASE/iter_${iteration}/logs/broker"
  mkdir -p "$broker_log_dir"
  local broker_log="$broker_log_dir/${timestamp}.log"

  log "Starting Kafka broker..."
  "$KAFKA_HOME/bin/kafka-server-start.sh" "$CONFIG" >"$broker_log" 2>&1 &
  BROKER_PID=$!
  log "Broker log: $broker_log"
  log "Kafka broker starting (PID: $BROKER_PID)..."

  log "Waiting for broker listener ${BOOTSTRAP_SERVER}..."
  if ! wait_for_port "127.0.0.1" 9092 60; then
    log "ERROR: Broker did not start within 60s"
    exit 1
  fi

  sleep 5
  log "Kafka broker is ready."
}

create_load_topics() {
  local topic1="$1"
  local topic2="$2"

  log "Creating load topics: $topic1, $topic2"
  "$KAFKA_HOME/bin/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP_SERVER" \
    --create --if-not-exists --topic "$topic1" \
    --partitions "$LOAD_TOPIC_PARTITIONS" --replication-factor "$LOAD_TOPIC_REPLICATION_FACTOR" >/dev/null

  "$KAFKA_HOME/bin/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP_SERVER" \
    --create --if-not-exists --topic "$topic2" \
    --partitions "$LOAD_TOPIC_PARTITIONS" --replication-factor "$LOAD_TOPIC_REPLICATION_FACTOR" >/dev/null
}

start_one_load_producer() {
  local topic="$1"
  local log_file="$2"

  (
    while true; do
      "$KAFKA_HOME/bin/kafka-producer-perf-test.sh" \
        --topic "$topic" \
        --num-records "$LOAD_BATCH_RECORDS" \
        --record-size "$LOAD_RECORD_SIZE" \
        --throughput "$LOAD_THROUGHPUT" \
        --command-property "bootstrap.servers=$BOOTSTRAP_SERVER" \
        --command-property "acks=$ACKS" \
        --command-property "max.request.size=$LOAD_MAX_REQUEST_SIZE" \
        >>"$log_file" 2>&1 || true

      sleep "$LOAD_SLEEP_SEC"
    done
  ) &

  local pid=$!
  LOAD_PIDS+=("$pid")
  log "Started load producer for topic=$topic (PID: $pid)"
}

start_load_producers() {
  local topic1="$1"
  local topic2="$2"
  local iter_dir="$3"

  local load_log_dir="$iter_dir/logs/load"
  mkdir -p "$load_log_dir"

  LOAD_PIDS=()
  start_one_load_producer "$topic1" "$load_log_dir/${topic1}.log"
  start_one_load_producer "$topic2" "$load_log_dir/${topic2}.log"

  log "Warming up load for ${LOAD_WARMUP_SEC}s..."
  sleep "$LOAD_WARMUP_SEC"
}

extract_metric() {
  local output="$1"
  local key="$2"
  echo "$output" | awk -v k="$key" '$0 ~ k {print $3; exit}'
}

extract_percentile_metric() {
  local output="$1"
  local idx="$2"
  echo "$output" | awk -v i="$idx" '/Percentiles:/ {gsub(/Percentiles: /, ""); n=split($0, a, ", "); if (n>=i) {split(a[i], b, " = "); print b[2]}; exit}'
}

extract_min_max() {
  local output="$1"
  local mode="$2"
  if [[ "$mode" == "min" ]]; then
    echo "$output" | awk '/Min:/ {print $2; exit}'
  else
    echo "$output" | awk '/Min:/ {print $5; exit}'
  fi
}

run_experiment() {
  local iteration="$1"
  local timestamp="$2"
  local iter_dir="$OUTPUT_BASE/iter_${iteration}"
  local first_topic_prefix="test_topic_"
  local first_topic="${first_topic_prefix}1"
  local load_topic1="load_existing_topic_1"
  local load_topic2="load_existing_topic_2"

  mkdir -p "$iter_dir"

  local first_log="$iter_dir/logs/first_producer/${timestamp}.log"
  local latency_csv="$iter_dir/producer_latency_results_${timestamp}.csv"
  local result_csv="$iter_dir/first_produce_result_${timestamp}.csv"
  local resource_csv="$iter_dir/fd/${timestamp}_broker_resource.csv"
  mkdir -p "$(dirname "$first_log")"
  mkdir -p "$(dirname "$resource_csv")"

  create_load_topics "$load_topic1" "$load_topic2"
  start_fd_sampler "$BROKER_PID" "$resource_csv"
  start_load_producers "$load_topic1" "$load_topic2" "$iter_dir"

  log "=========================================="
  log "Experiment iteration=${iteration}/${ITERATIONS}"
  log "First topic (must not exist): ${first_topic}"
  log "First producer topic count: ${FIRST_NUM_TOPICS}"
  log "First producer record size: ${FIRST_RECORD_SIZE}"
  log "Load producer topics: ${load_topic1}, ${load_topic2}"
  log "Result CSV: ${result_csv}"
  log "=========================================="

  local started_ms ended_ms e2e_ms status first_output
  started_ms="$(epoch_ms)"

  set +e
  first_output="$("$KAFKA_HOME/bin/kafka-producer-latency.sh" \
    --bootstrap-server "$BOOTSTRAP_SERVER" \
    --num-topics "$FIRST_NUM_TOPICS" \
    --topic-prefix "$first_topic_prefix" \
    --record-size "$FIRST_RECORD_SIZE" \
    --acks "$ACKS" \
    --output "$latency_csv" 2>&1)"
  status=$?
  set -e

  ended_ms="$(epoch_ms)"
  e2e_ms=$((ended_ms - started_ms))

  printf '%s\n' "$first_output" >"$first_log"

  if [[ "$status" -ne 0 ]]; then
    log "ERROR: First producer failed with exit code ${status}"
    stop_fd_sampler
    stop_load_producers
    exit "$status"
  fi

  local avg_latency p50 p99 p999 min_ms max_ms
  avg_latency="$(extract_metric "$first_output" "Avg latency:")"
  p50="$(extract_percentile_metric "$first_output" 1)"
  p99="$(extract_percentile_metric "$first_output" 2)"
  p999="$(extract_percentile_metric "$first_output" 3)"
  min_ms="$(extract_min_max "$first_output" "min")"
  max_ms="$(extract_min_max "$first_output" "max")"

  printf '%s\n' "timestamp,iteration,first_topic,acks,first_num_topics,first_record_size_bytes,e2e_wall_ms,avg_latency_ms,p50_ms,p99_ms,p999_ms,min_ms,max_ms,first_log,latency_csv,broker_resource_csv,load_topic_1,load_topic_2,load_record_size_bytes,load_batch_records,load_throughput_msgs_per_sec,load_sleep_sec" >"$result_csv"
  printf '%s\n' "${timestamp},${iteration},${first_topic},${ACKS},${FIRST_NUM_TOPICS},${FIRST_RECORD_SIZE},${e2e_ms},${avg_latency:-},${p50:-},${p99:-},${p999:-},${min_ms:-},${max_ms:-},${first_log},${latency_csv},${resource_csv},${load_topic1},${load_topic2},${LOAD_RECORD_SIZE},${LOAD_BATCH_RECORDS},${LOAD_THROUGHPUT},${LOAD_SLEEP_SEC}" >>"$result_csv"

  printf '%s\n' "${timestamp},${iteration},${first_topic},${e2e_ms},${avg_latency:-},${p99:-},${result_csv}" >>"$SUMMARY_CSV"

  log "First producer completed. e2e wall time=${e2e_ms}ms, avg=${avg_latency:-NA}ms, p99=${p99:-NA}ms"

  stop_fd_sampler
  stop_load_producers
}

cleanup_on_exit() {
  stop_load_producers
  stop_kafka
}

trap cleanup_on_exit EXIT

SUMMARY_CSV="$OUTPUT_BASE/experiment_summary_$(date '+%Y%m%d_%H%M%S').csv"
printf '%s\n' "timestamp,iteration,first_topic,e2e_wall_ms,avg_latency_ms,p99_ms,result_csv" >"$SUMMARY_CSV"

log "============================================"
log "Starting First Produce E2E with Message Load"
log "Iterations: ${ITERATIONS}"
log "First producer: new topic auto-creation path"
log "Load producers: ${LOAD_PRODUCER_COUNT} (existing topics)"
log "============================================"

for iter in $(seq 1 "$ITERATIONS"); do
  log ""
  log ">>>>>>>>>> Iteration ${iter} / ${ITERATIONS} <<<<<<<<<<"
  log ""

  stop_kafka
  clean_logs
  format_storage

  experiment_ts="$(date '+%Y%m%d_%H%M%S')"
  start_kafka "$iter" "$experiment_ts"
  run_experiment "$iter" "$experiment_ts"
done

stop_kafka
trap - EXIT

log ""
log "============================================"
log "All iterations completed!"
log "Results saved in: $OUTPUT_BASE"
log "Summary: $SUMMARY_CSV"
log "============================================"
