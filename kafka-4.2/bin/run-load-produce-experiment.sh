#!/bin/bash
#
# Run Producer Latency Experiment WITH Background Load
#
# This script:
#   1. Stops any existing broker
#   2. Cleans previous Kafka data
#   3. Builds Kafka
#   4. Formats and starts the broker (logs saved)
#   5. Starts N background producers sending every 100ms to a temp topic
#   6. Runs the latency experiment (3000 topics, 15 sends each)
#   7. Stops background producers
#   8. Shuts down the broker
#

set -e

KAFKA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
LOG_DIR="/tmp/kraft-combined-logs"
BOOTSTRAP_SERVER="localhost:9092"
OUTPUT_BASE="$KAFKA_HOME/output/multi-produce-to-same-topics"
RESOURCE_SAMPLE_INTERVAL_SEC="${RESOURCE_SAMPLE_INTERVAL_SEC:-2}"

# Experiment defaults
NUM_TOPICS="${NUM_TOPICS:-3000}"
NUM_SENDS="${NUM_SENDS:-15}"
RECORD_SIZE="${RECORD_SIZE:-1048576}"
PARTITIONS="${PARTITIONS:-1}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-1}"
ACKS="${ACKS:-1}"

# Background load defaults
LOAD_NUM_PRODUCERS="${LOAD_NUM_PRODUCERS:-5}"
LOAD_INTERVAL_MS="${LOAD_INTERVAL_MS:-100}"
LOAD_RECORD_SIZE="${LOAD_RECORD_SIZE:-1024}"
LOAD_TOPIC="${LOAD_TOPIC:-background_load_topic}"
RESOURCE_SAMPLER_PID=""
LOAD_PID=""

# Determine size name from RECORD_SIZE
case $RECORD_SIZE in
    1024)     SIZE_NAME="1KB" ;;
    10240)    SIZE_NAME="10KB" ;;
    1048576)  SIZE_NAME="1MB" ;;
    10485760) SIZE_NAME="10MB" ;;
    *)        SIZE_NAME="${RECORD_SIZE}B" ;;
esac

cd "$KAFKA_HOME"

# Log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

now_epoch_ms() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time()*1000))'
    else
        echo "$(date '+%s')000"
    fi
}

count_topic_dirs() {
    local base_dir="$1"
    if [[ ! -d "$base_dir" ]]; then
        echo "0"
        return 0
    fi
    find "$base_dir" -maxdepth 1 -type d -name 'test_topic_*' 2>/dev/null | wc -l | tr -d ' '
}

measure_ps_stats() {
    local pid="$1"
    if ! command -v ps >/dev/null 2>&1; then
        echo ",,"
        return 0
    fi
    local row
    row="$(ps -p "$pid" -o %cpu=,rss=,vsz= 2>/dev/null | awk 'NR==1{print $1","$2","$3}')"
    if [[ -z "$row" ]]; then
        echo ",,"
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

measure_storage_kb() {
    local base_dir="$1"
    if [[ ! -d "$base_dir" ]]; then
        echo "0"
        return 0
    fi
    du -sk "$base_dir" 2>/dev/null | awk '{print $1}'
}

start_resource_sampler() {
    local pid="$1"
    local out_csv="$2"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        log "WARN: Broker PID is not alive; skipping resource sampling."
        return 0
    fi

    printf '%s\n' "timestamp,epoch_ms,broker_pid,topic_dir_count,cpu_pct,rss_kb,vsz_kb,heap_used_kb,heap_committed_kb,log_dir_storage_kb" >"$out_csv"
    (
        while kill -0 "$pid" 2>/dev/null; do
            local now epoch_ms topic_dir_count ps_stats cpu_pct rss_kb vsz_kb heap_stats heap_used_kb heap_committed_kb
            local log_dir_storage_kb
            now="$(date '+%Y-%m-%d %H:%M:%S')"
            epoch_ms="$(now_epoch_ms)"
            topic_dir_count="$(count_topic_dirs "$LOG_DIR")"
            ps_stats="$(measure_ps_stats "$pid")"
            IFS=',' read -r cpu_pct rss_kb vsz_kb <<<"$ps_stats"
            heap_stats="$(measure_heap_kb "$pid")"
            IFS=',' read -r heap_used_kb heap_committed_kb <<<"$heap_stats"
            log_dir_storage_kb="$(measure_storage_kb "$LOG_DIR")"
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$now" "$epoch_ms" "$pid" "${topic_dir_count:-0}" "${cpu_pct:-}" "${rss_kb:-}" "${vsz_kb:-}" \
                "${heap_used_kb:-}" "${heap_committed_kb:-}" "${log_dir_storage_kb:-0}" \
                >>"$out_csv"
            sleep "$RESOURCE_SAMPLE_INTERVAL_SEC"
        done
    ) &
    RESOURCE_SAMPLER_PID=$!
    log "Started resource sampler (PID: $RESOURCE_SAMPLER_PID), interval=${RESOURCE_SAMPLE_INTERVAL_SEC}s"
}

stop_resource_sampler() {
    if [[ -n "${RESOURCE_SAMPLER_PID:-}" ]] && kill -0 "$RESOURCE_SAMPLER_PID" 2>/dev/null; then
        kill "$RESOURCE_SAMPLER_PID" 2>/dev/null || true
        wait "$RESOURCE_SAMPLER_PID" 2>/dev/null || true
    fi
    RESOURCE_SAMPLER_PID=""
}

# Stop Kafka broker
stop_kafka() {
    stop_resource_sampler
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

# Clean log directory
clean_logs() {
    log "Cleaning log directory: $LOG_DIR"
    rm -rf "$LOG_DIR"
    log "Log directory cleaned."
}

# Format storage (KRaft mode)
format_storage() {
    log "Formatting KRaft storage..."
    CLUSTER_ID=$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)
    log "Generated new Cluster ID: $CLUSTER_ID"
    "$KAFKA_HOME/bin/kafka-storage.sh" format --standalone -t "$CLUSTER_ID" -c "$CONFIG"
    log "Storage formatted."
}

# Start Kafka broker
start_kafka() {
    local broker_log=$1

    log "Starting Kafka broker..."
    "$KAFKA_HOME/bin/kafka-server-start.sh" "$CONFIG" > "$broker_log" 2>&1 &
    KAFKA_PID=$!
    log "Broker log: $broker_log"
    log "Kafka broker starting (PID: $KAFKA_PID)..."

    log "Waiting for broker to be ready..."
    MAX_WAIT=60
    WAITED=0
    while ! nc -z localhost 9092 2>/dev/null; do
        sleep 2
        WAITED=$((WAITED + 2))
        if [ $WAITED -ge $MAX_WAIT ]; then
            log "ERROR: Broker did not start within ${MAX_WAIT}s"
            exit 1
        fi
    done
    sleep 5
    log "Kafka broker is ready."
}

# Stop background load producers
stop_load_producers() {
    if [ -n "$LOAD_PID" ] && kill -0 "$LOAD_PID" 2>/dev/null; then
        log "Stopping background load producers (PID: $LOAD_PID)..."
        kill "$LOAD_PID" 2>/dev/null || true
        wait "$LOAD_PID" 2>/dev/null || true
        log "Background load producers stopped."
    fi
}

# Cleanup on exit
cleanup() {
    stop_resource_sampler
    stop_load_producers
    stop_kafka
}
trap cleanup EXIT

# Generate shared timestamp
EXPERIMENT_TS=$(date '+%Y%m%d_%H%M%S')

# Setup output directories
OUTPUT_DIR="$OUTPUT_BASE/${SIZE_NAME}"
BROKER_LOG_DIR="$OUTPUT_DIR/logs/broker"
PRODUCER_LOG_DIR="$OUTPUT_DIR/logs/producer"
LOAD_LOG_DIR="$OUTPUT_DIR/logs/load"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$BROKER_LOG_DIR"
mkdir -p "$PRODUCER_LOG_DIR"
mkdir -p "$LOAD_LOG_DIR"

OUTPUT_FILE="$OUTPUT_DIR/producer_latency_load_${EXPERIMENT_TS}.csv"
BROKER_LOG="$BROKER_LOG_DIR/load_${EXPERIMENT_TS}.log"
PRODUCER_LOG="$PRODUCER_LOG_DIR/load_${EXPERIMENT_TS}.log"
LOAD_LOG="$LOAD_LOG_DIR/${EXPERIMENT_TS}.log"
RESOURCE_DIR="$OUTPUT_DIR/resource"
mkdir -p "$RESOURCE_DIR"
RESOURCE_CSV="$RESOURCE_DIR/broker_resource_usage_${EXPERIMENT_TS}.csv"

log "============================================"
log "Producer Latency Experiment WITH Background Load"
log "============================================"
log "Kafka home:        $KAFKA_HOME"
log "Size name:         $SIZE_NAME"
log "--- Main Experiment ---"
log "Num topics:        $NUM_TOPICS"
log "Sends per topic:   $NUM_SENDS"
log "Record size:       $RECORD_SIZE bytes"
log "Partitions:        $PARTITIONS"
log "Replication:       $REPLICATION_FACTOR"
log "--- Background Load ---"
log "Load producers:    $LOAD_NUM_PRODUCERS"
log "Load interval:     ${LOAD_INTERVAL_MS}ms"
log "Load record size:  $LOAD_RECORD_SIZE bytes"
log "Load topic:        $LOAD_TOPIC"
log "--- Output ---"
log "Output CSV:        $OUTPUT_FILE"
log "Broker log:        $BROKER_LOG"
log "Producer log:      $PRODUCER_LOG"
log "Load log:          $LOAD_LOG"
log "Resource CSV:      $RESOURCE_CSV"
log "============================================"

# Step 1: Stop broker (if running)
log ""
log "[Step 1/7] Stopping existing broker..."
stop_kafka

# Step 2: Clean logs & format
log ""
log "[Step 2/7] Cleaning and formatting..."
clean_logs
format_storage

# Step 3: Build Kafka
log ""
log "[Step 3/7] Building Kafka..."
./gradlew jar -PscalaVersion=2.13.17 2>&1 | tail -5

# Step 4: Start broker
log ""
log "[Step 4/7] Starting broker..."
start_kafka "$BROKER_LOG"
start_resource_sampler "$KAFKA_PID" "$RESOURCE_CSV"

# Step 5: Start background load producers
log ""
log "[Step 5/7] Starting background load producers..."
"$KAFKA_HOME/bin/kafka-background-producer-load.sh" \
    --bootstrap-server "$BOOTSTRAP_SERVER" \
    --topic "$LOAD_TOPIC" \
    --num-producers "$LOAD_NUM_PRODUCERS" \
    --interval-ms "$LOAD_INTERVAL_MS" \
    --record-size "$LOAD_RECORD_SIZE" \
    --acks "$ACKS" \
    > "$LOAD_LOG" 2>&1 &
LOAD_PID=$!
log "Background load started (PID: $LOAD_PID)"
log "Load log: $LOAD_LOG"

# Wait for load producers to warm up
sleep 3

# Step 6: Run main experiment
log ""
log "[Step 6/7] Running latency experiment with background load..."
log "Output CSV:   $OUTPUT_FILE"
log "Producer log: $PRODUCER_LOG"

"$KAFKA_HOME/bin/kafka-producer-latency-multi.sh" \
    --bootstrap-server "$BOOTSTRAP_SERVER" \
    --num-topics "$NUM_TOPICS" \
    --num-sends "$NUM_SENDS" \
    --record-size "$RECORD_SIZE" \
    --partitions "$PARTITIONS" \
    --replication-factor "$REPLICATION_FACTOR" \
    --acks "$ACKS" \
    --output "$OUTPUT_FILE" \
    > "$PRODUCER_LOG" 2>&1

EXPERIMENT_EXIT=$?

# Step 7: Shutdown
log ""
log "[Step 7/7] Shutting down..."
stop_load_producers
stop_kafka

# Disable trap since we already cleaned up
trap - EXIT

# Step 8: Parse broker log to CSV
BROKER_CSV="$OUTPUT_DIR/broker_processing_time_${EXPERIMENT_TS}.csv"
log ""
log "[Post] Parsing broker ProduceRequest logs to CSV..."
echo "topic_num,topic_name,e2e_ms" > "$BROKER_CSV"
grep '\[ProduceRequest\]' "$BROKER_LOG" | while IFS= read -r line; do
    # Extract topic name from partitions=[test_topic_83-0]
    topic_part=$(echo "$line" | sed -n 's/.*partitions=\[\([^]]*\)\].*/\1/p')
    # Extract topic name (remove -partition suffix)
    topic_name=$(echo "$topic_part" | sed 's/-[0-9]*$//')
    # Extract topic number from test_topic_N
    topic_num=$(echo "$topic_name" | sed -n 's/.*_\([0-9]*\)$/\1/p')
    # Extract e2e time
    e2e=$(echo "$line" | sed -n 's/.*e2e=\([0-9.]*\)ms.*/\1/p')

    if [ -n "$topic_num" ] && [ -n "$e2e" ]; then
        echo "${topic_num},${topic_name},${e2e}" >> "$BROKER_CSV"
    fi
done
log "Broker CSV:   $BROKER_CSV"

log ""
log "============================================"
log "Experiment complete! (exit code: $EXPERIMENT_EXIT)"
log "============================================"
log "Output CSV:      $OUTPUT_FILE"
log "Broker CSV:      $BROKER_CSV"
log "Broker log:      $BROKER_LOG"
log "Producer log:    $PRODUCER_LOG"
log "Load log:        $LOAD_LOG"
log "Resource CSV:    $RESOURCE_CSV"
log "============================================"

exit $EXPERIMENT_EXIT
