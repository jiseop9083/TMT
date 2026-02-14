#!/bin/bash
#
# 20 Producer Latency Experiments
# 4 message sizes (1KB, 10KB, 1MB, 10MB) x 5 iterations each
# Between each experiment: stop broker, delete logs, reformat, restart broker
#

set -e

KAFKA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
LOG_DIR="/tmp/kraft-combined-logs"
BOOTSTRAP_SERVER="localhost:9092"
NUM_TOPICS=3000
OUTPUT_BASE="$KAFKA_HOME/output"

# Message sizes: name -> bytes
declare -a SIZE_NAMES=("1KB" "10KB" "1MB" "10MB")
declare -a SIZE_BYTES=(1024 10240 1048576 10485760)
ITERATIONS=5

mkdir -p "$OUTPUT_BASE"

# Log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Stop Kafka broker
stop_kafka() {
    log "Stopping Kafka broker..."
    "$KAFKA_HOME/bin/kafka-server-stop.sh" 2>/dev/null || true
    # Wait for process to fully exit
    sleep 5
    # Double check - kill any remaining Kafka processes
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
    local size_name=$1
    local timestamp=$2
    local broker_log_dir="$KAFKA_HOME/output/${size_name}/logs/broker"
    mkdir -p "$broker_log_dir"
    local broker_log="$broker_log_dir/${timestamp}.log"

    log "Starting Kafka broker..."
    "$KAFKA_HOME/bin/kafka-server-start.sh" "$CONFIG" > "$broker_log" 2>&1 &
    KAFKA_PID=$!
    log "Broker log: $broker_log"
    log "Kafka broker starting (PID: $KAFKA_PID)..."

    # Wait for broker to be ready by checking the port
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
    # Give a bit more time for full initialization
    sleep 5
    log "Kafka broker is ready."
}

# Run a single experiment
run_experiment() {
    local size_name=$1
    local size_bytes=$2
    local iteration=$3
    local timestamp=$4

    local output_dir="$KAFKA_HOME/output/${size_name}"
    local producer_log_dir="$KAFKA_HOME/output/${size_name}/logs/producer"
    mkdir -p "$output_dir"
    mkdir -p "$producer_log_dir"

    local output_file="$output_dir/producer_latency_results_${timestamp}.csv"
    local producer_log="$producer_log_dir/${timestamp}.log"

    log "=========================================="
    log "Experiment: size=${size_name}, iteration=${iteration}/5"
    log "Record size: ${size_bytes} bytes"
    log "Output CSV: ${output_file}"
    log "Producer log: ${producer_log}"
    log "=========================================="

    "$KAFKA_HOME/bin/kafka-producer-latency.sh" \
        --bootstrap-server "$BOOTSTRAP_SERVER" \
        --num-topics "$NUM_TOPICS" \
        --record-size "$size_bytes" \
        --acks 1 \
        --output "$output_file" \
        > "$producer_log" 2>&1

    log "Experiment completed: ${size_name} iteration ${iteration}"
}

# Main execution
log "============================================"
log "Starting 20 Producer Latency Experiments"
log "Sizes: ${SIZE_NAMES[*]}"
log "Iterations per size: $ITERATIONS"
log "Num topics per experiment: $NUM_TOPICS"
log "============================================"

EXPERIMENT_NUM=0
TOTAL_EXPERIMENTS=$((${#SIZE_NAMES[@]} * ITERATIONS))

for i in "${!SIZE_NAMES[@]}"; do
    size_name="${SIZE_NAMES[$i]}"
    size_bytes="${SIZE_BYTES[$i]}"

    for iter in $(seq 1 $ITERATIONS); do
        EXPERIMENT_NUM=$((EXPERIMENT_NUM + 1))
        log ""
        log ">>>>>>>>>> Experiment $EXPERIMENT_NUM / $TOTAL_EXPERIMENTS <<<<<<<<<<<"
        log ""

        # 1. Stop broker (if running)
        stop_kafka

        # 2. Clean logs
        clean_logs

        # 3. Format storage
        format_storage

        # Generate shared timestamp for this experiment
        EXPERIMENT_TS=$(date '+%Y%m%d_%H%M%S')

        # 4. Start broker
        start_kafka "$size_name" "$EXPERIMENT_TS"

        # 5. Run experiment
        run_experiment "$size_name" "$size_bytes" "$iter" "$EXPERIMENT_TS"
    done
done

# Final cleanup - stop broker
stop_kafka

log ""
log "============================================"
log "All $TOTAL_EXPERIMENTS experiments completed!"
log "Results saved in: $OUTPUT_BASE/"
log "============================================"
ls -la "$OUTPUT_BASE/"
