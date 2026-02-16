#!/bin/bash
#
# Run Producer Latency vs Topic Count Experiment
#
# This script:
#   1. Stops any existing broker
#   2. Cleans previous Kafka data
#   3. Builds Kafka
#   4. Formats and starts the broker (logs saved)
#   5. Runs the latency experiment (logs saved)
#   6. Shuts down the broker
#

set -e

KAFKA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
LOG_DIR="/tmp/kraft-combined-logs"
BOOTSTRAP_SERVER="localhost:9092"
OUTPUT_BASE="$KAFKA_HOME/output"

# Experiment defaults
NUM_TOPICS="${NUM_TOPICS:-3000}"
NUM_SENDS="${NUM_SENDS:-15}"
RECORD_SIZE="${RECORD_SIZE:-1048576}"
PARTITIONS="${PARTITIONS:-1}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-1}"
ACKS="${ACKS:-1}"

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

# Stop Kafka broker
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

# Generate shared timestamp
EXPERIMENT_TS=$(date '+%Y%m%d_%H%M%S')

# Setup output directories (same structure as run_first_produce_experiments.sh)
OUTPUT_DIR="$OUTPUT_BASE/${SIZE_NAME}"
BROKER_LOG_DIR="$OUTPUT_DIR/logs/broker"
PRODUCER_LOG_DIR="$OUTPUT_DIR/logs/producer"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$BROKER_LOG_DIR"
mkdir -p "$PRODUCER_LOG_DIR"

OUTPUT_FILE="$OUTPUT_DIR/producer_latency_multi_${EXPERIMENT_TS}.csv"
BROKER_LOG="$BROKER_LOG_DIR/${EXPERIMENT_TS}.log"
PRODUCER_LOG="$PRODUCER_LOG_DIR/${EXPERIMENT_TS}.log"

log "============================================"
log "Producer Latency vs Topic Count Experiment"
log "============================================"
log "Kafka home:       $KAFKA_HOME"
log "Size name:        $SIZE_NAME"
log "Num topics:       $NUM_TOPICS"
log "Sends per topic:  $NUM_SENDS"
log "Record size:      $RECORD_SIZE bytes"
log "Partitions:       $PARTITIONS"
log "Replication:      $REPLICATION_FACTOR"
log "Output CSV:       $OUTPUT_FILE"
log "Broker log:       $BROKER_LOG"
log "Producer log:     $PRODUCER_LOG"
log "============================================"

# Step 1: Stop broker (if running)
log ""
log "[Step 1/5] Stopping existing broker..."
stop_kafka

# Step 2: Clean logs & format
log ""
log "[Step 2/5] Cleaning and formatting..."
clean_logs
format_storage

# Step 3: Build Kafka
log ""
log "[Step 3/5] Building Kafka..."
./gradlew jar -PscalaVersion=2.13.17 2>&1 | tail -5

# Step 4: Start broker
log ""
log "[Step 4/5] Starting broker..."
start_kafka "$BROKER_LOG"

# Step 5: Run experiment
log ""
log "[Step 5/5] Running latency experiment..."
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

# Shutdown broker
log ""
log "Shutting down broker..."
stop_kafka

log ""
log "============================================"
log "Experiment complete! (exit code: $EXPERIMENT_EXIT)"
log "============================================"
log "Output CSV:   $OUTPUT_FILE"
log "Broker log:   $BROKER_LOG"
log "Producer log: $PRODUCER_LOG"
log "============================================"

exit $EXPERIMENT_EXIT
