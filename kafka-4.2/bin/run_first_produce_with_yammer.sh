#!/usr/bin/env bash
#
# 20 Producer Latency Experiments with Yammer/JMX snapshots
# 4 message sizes (1KB, 10KB, 1MB, 10MB) x 5 iterations each
# Between each experiment: stop broker, delete logs, reformat, restart broker
#

set -euo pipefail

KAFKA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
LOG_DIR="/tmp/kraft-combined-logs"
BOOTSTRAP_SERVER="localhost:9092"
NUM_TOPICS=3000
ACKS="1"
SNAPSHOT_EVERY_TOPICS=300
JMX_PORT=9999
JMX_URL="service:jmx:rmi:///jndi/rmi://127.0.0.1:${JMX_PORT}/jmxrmi"
OUTPUT_BASE="$KAFKA_HOME/output/first-produce-with-yammer"

declare -a SIZE_NAMES=("10KB")
declare -a SIZE_BYTES=(10240)
ITERATIONS=5

JMX_ATTRIBUTES="Count,Mean,Min,Max,95thPercentile,99thPercentile"
declare -a JMX_OBJECTS=(
  "kafka.network:type=RequestMetrics,name=TotalTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=RequestQueueTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=LocalTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=RemoteTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=ResponseQueueTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=ResponseSendTimeMs,request=Produce"
)

mkdir -p "$OUTPUT_BASE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

stop_kafka() {
  log "Stopping Kafka broker..."
  "$KAFKA_HOME/bin/kafka-server-stop.sh" 2>/dev/null || true
  sleep 5
  if pgrep -f "kafka.Kafka" >/dev/null 2>&1; then
    log "Force killing remaining Kafka processes..."
    pkill -f "kafka.Kafka" 2>/dev/null || true
    sleep 3
  fi
  log "Kafka broker stopped."
}

clean_logs() {
  log "Cleaning log directory: $LOG_DIR"
  rm -rf "$LOG_DIR"
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

start_kafka() {
  local size_name="$1"
  local timestamp="$2"
  local broker_log_dir="$OUTPUT_BASE/${size_name}/logs/broker"
  mkdir -p "$broker_log_dir"
  local broker_log="$broker_log_dir/${timestamp}.log"

  log "Starting Kafka broker with JMX_PORT=${JMX_PORT}..."
  JMX_PORT="$JMX_PORT" "$KAFKA_HOME/bin/kafka-server-start.sh" "$CONFIG" >"$broker_log" 2>&1 &
  local kafka_pid=$!
  log "Broker log: $broker_log"
  log "Kafka broker starting (PID: $kafka_pid)..."

  log "Waiting for broker listener ${BOOTSTRAP_SERVER}..."
  if ! wait_for_port "127.0.0.1" 9092 60; then
    log "ERROR: Broker did not start within 60s"
    exit 1
  fi

  log "Waiting for JMX port ${JMX_PORT}..."
  if ! wait_for_port "127.0.0.1" "$JMX_PORT" 60; then
    log "ERROR: JMX port did not open within 60s"
    exit 1
  fi

  sleep 5
  log "Kafka broker is ready."
}

collect_jmx_snapshot() {
  local out_csv="$1"
  local out_log="$2"
  local cmd=(
    "$KAFKA_HOME/bin/kafka-jmx.sh"
    --jmx-url "$JMX_URL"
    --wait
    --one-time true
    --report-format csv
    --date-format "yyyy-MM-dd HH:mm:ss.SSS"
    --attributes "$JMX_ATTRIBUTES"
  )
  local obj
  for obj in "${JMX_OBJECTS[@]}"; do
    cmd+=(--object-name "$obj")
  done
  "${cmd[@]}" >"$out_csv" 2>"$out_log"
}

run_experiment() {
  local size_name="$1"
  local size_bytes="$2"
  local iteration="$3"
  local timestamp="$4"

  local output_dir="$OUTPUT_BASE/${size_name}"
  local producer_log_dir="$OUTPUT_BASE/${size_name}/logs/producer"
  local jmx_dir="$OUTPUT_BASE/${size_name}/jmx"
  mkdir -p "$output_dir" "$producer_log_dir" "$jmx_dir"

  local output_file="$output_dir/producer_latency_results_${timestamp}.csv"
  local producer_log="$producer_log_dir/${timestamp}.log"
  local jmx_post_csv="$jmx_dir/${timestamp}_post.csv"
  local jmx_post_log="$jmx_dir/${timestamp}_post.stderr.log"

  log "=========================================="
  log "Experiment: size=${size_name}, iteration=${iteration}/${ITERATIONS}"
  log "Record size: ${size_bytes} bytes"
  log "ACKS: ${ACKS}"
  log "Output CSV: ${output_file}"
  log "Producer log: ${producer_log}"
  log "JMX post snapshot: ${jmx_post_csv}"
  log "=========================================="

  "$KAFKA_HOME/bin/kafka-producer-latency.sh" \
    --bootstrap-server "$BOOTSTRAP_SERVER" \
    --num-topics "$NUM_TOPICS" \
    --record-size "$size_bytes" \
    --acks "$ACKS" \
    --output "$output_file" \
    2>&1 | tee "$producer_log" | while IFS= read -r line; do
      if [[ "$line" =~ ^\[([0-9]+)/([0-9]+)\] ]]; then
        local completed_topics="${BASH_REMATCH[1]}"
        if (( completed_topics > 0 && completed_topics % SNAPSHOT_EVERY_TOPICS == 0 )); then
          local jmx_step_csv="$jmx_dir/${timestamp}_${completed_topics}topics.csv"
          local jmx_step_log="$jmx_dir/${timestamp}_${completed_topics}topics.stderr.log"
          if [[ ! -f "$jmx_step_csv" ]]; then
            log "Collecting JMX snapshot at ${completed_topics} topics: ${jmx_step_csv}"
            collect_jmx_snapshot "$jmx_step_csv" "$jmx_step_log"
          fi
        fi
      fi
    done

  log "Collecting JMX post snapshot..."
  collect_jmx_snapshot "$jmx_post_csv" "$jmx_post_log"

  echo "${timestamp},${size_name},${iteration},${size_bytes},${output_file},${jmx_post_csv}" >>"$SUMMARY_CSV"
  log "Experiment completed: ${size_name} iteration ${iteration}"
}

log "============================================"
log "Starting 20 Producer Latency Experiments + Yammer JMX"
log "Sizes: ${SIZE_NAMES[*]}"
log "Iterations per size: $ITERATIONS"
log "Num topics per experiment: $NUM_TOPICS"
log "JMX metrics request: Produce"
log "============================================"

SUMMARY_CSV="$OUTPUT_BASE/experiment_summary_$(date '+%Y%m%d_%H%M%S').csv"
echo "timestamp,size_name,iteration,record_size_bytes,producer_csv,jmx_post_csv" >"$SUMMARY_CSV"

experiment_num=0
total_experiments=$((${#SIZE_NAMES[@]} * ITERATIONS))

for i in "${!SIZE_NAMES[@]}"; do
  size_name="${SIZE_NAMES[$i]}"
  size_bytes="${SIZE_BYTES[$i]}"

  for iter in $(seq 1 "$ITERATIONS"); do
    experiment_num=$((experiment_num + 1))
    log ""
    log ">>>>>>>>>> Experiment ${experiment_num} / ${total_experiments} <<<<<<<<<<<"
    log ""

    stop_kafka
    clean_logs
    format_storage

    experiment_ts="$(date '+%Y%m%d_%H%M%S')"
    start_kafka "$size_name" "$experiment_ts"
    run_experiment "$size_name" "$size_bytes" "$iter" "$experiment_ts"
  done
done

stop_kafka

log ""
log "============================================"
log "All ${total_experiments} experiments completed!"
log "Results saved in: $OUTPUT_BASE/"
log "Summary: $SUMMARY_CSV"
log "============================================"
