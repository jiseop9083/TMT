#!/bin/bash
# Producer Latency Test for Multiple Topics (1 to N topics)
# Measures: send() -> ack time (includes metadata fetch for new topics)
# Usage: ./run-e2e-multi-topic-test.sh [max_topics] [num_records_per_topic] [record_size] [bootstrap_server]

set -e

# Default parameters
MAX_TOPICS=${1:-3000}
NUM_RECORDS=${2:-1}
RECORD_SIZE=${3:-512}
BOOTSTRAP_SERVER=${4:-localhost:9092}
ACKS="1"

# Output file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="producer_latency_results_${TIMESTAMP}.csv"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "Producer Latency Multi-Topic Test"
echo "(send -> ack, includes metadata fetch)"
echo "============================================"
echo "Max Topics: $MAX_TOPICS"
echo "Records per topic: $NUM_RECORDS"
echo "Record size: $RECORD_SIZE bytes"
echo "Bootstrap server: $BOOTSTRAP_SERVER"
echo "Output file: $OUTPUT_FILE"
echo "============================================"

# CSV header
echo "num_topics,topic_name,avg_latency_ms,p50_ms,p99_ms,p999_ms,min_ms,max_ms" > "$OUTPUT_FILE"

# Test with increasing number of topics
for num_topics in $(seq 1 $MAX_TOPICS); do
    topic_name="test_topic_${num_topics}"

    echo ""
    echo "[Topic $num_topics/$MAX_TOPICS] Testing topic: $topic_name"

    # Run Producer latency test and capture output
    output=$("$SCRIPT_DIR/kafka-producer-latency.sh" \
        --bootstrap-server "$BOOTSTRAP_SERVER" \
        --topic "$topic_name" \
        --num-records "$NUM_RECORDS" \
        --acks "$ACKS" \
        --record-size "$RECORD_SIZE" 2>&1) || {
        echo "  [ERROR] Failed to test topic $topic_name"
        echo "$num_topics,$topic_name,ERROR,ERROR,ERROR,ERROR,ERROR,ERROR" >> "$OUTPUT_FILE"
        continue
    }

    # Parse results
    avg_latency=$(echo "$output" | grep "Avg latency:" | awk '{print $3}')
    percentiles=$(echo "$output" | grep "Percentiles:" | sed 's/Percentiles: //')
    p50=$(echo "$percentiles" | awk -F', ' '{print $1}' | awk -F' = ' '{print $2}')
    p99=$(echo "$percentiles" | awk -F', ' '{print $2}' | awk -F' = ' '{print $2}')
    p999=$(echo "$percentiles" | awk -F', ' '{print $3}' | awk -F' = ' '{print $2}')

    minmax=$(echo "$output" | grep "Min:")
    min_val=$(echo "$minmax" | awk '{print $2}')
    max_val=$(echo "$minmax" | awk '{print $5}')

    echo "  Avg: ${avg_latency}ms, P50: ${p50}ms, P99: ${p99}ms, P99.9: ${p999}ms, Min: ${min_val}ms, Max: ${max_val}ms"

    # Append to CSV
    echo "$num_topics,$topic_name,$avg_latency,$p50,$p99,$p999,$min_val,$max_val" >> "$OUTPUT_FILE"
done

echo ""
echo "============================================"
echo "Test completed! Results saved to: $OUTPUT_FILE"
echo "============================================"
