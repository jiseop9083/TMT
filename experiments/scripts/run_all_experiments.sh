#!/bin/sh

# 각 실험 스크립트를 50번씩 반복 실행하는 스크립트

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPEAT_COUNT=50

echo "========================================="
echo "Starting experiments - ${REPEAT_COUNT} iterations each"
echo "========================================="

# 1. auto_topic_disabled 실험 (50회)
echo ""
echo "=== Experiment 1/3: AUTO_CREATE_TOPICS=false ==="
echo "Running ${REPEAT_COUNT} iterations..."
for i in $(seq 1 ${REPEAT_COUNT}); do
    echo "[${i}/${REPEAT_COUNT}] Running auto_topic_disabled.sh..."
    sh "${SCRIPT_DIR}/auto_topic_disabled.sh"
    if [ $? -ne 0 ]; then
        echo "Error occurred at iteration ${i} of auto_topic_disabled"
        exit 1
    fi
done
echo "✓ Completed auto_topic_disabled (${REPEAT_COUNT} runs)"

# 2. auto_topic_enabled 실험 (50회)
echo ""
echo "=== Experiment 2/3: AUTO_CREATE_TOPICS=true ==="
echo "Running ${REPEAT_COUNT} iterations..."
for i in $(seq 1 ${REPEAT_COUNT}); do
    echo "[${i}/${REPEAT_COUNT}] Running auto_topic_enabled.sh..."
    sh "${SCRIPT_DIR}/auto_topic_enabled.sh"
    if [ $? -ne 0 ]; then
        echo "Error occurred at iteration ${i} of auto_topic_enabled"
        exit 1
    fi
done
echo "✓ Completed auto_topic_enabled (${REPEAT_COUNT} runs)"

# 3. auto_topic_enabled_non_jfr 실험 (50회)
echo ""
echo "=== Experiment 3/3: AUTO_CREATE_TOPICS=true (non-JFR) ==="
echo "Running ${REPEAT_COUNT} iterations..."
for i in $(seq 1 ${REPEAT_COUNT}); do
    echo "[${i}/${REPEAT_COUNT}] Running auto_topic_enabled_non_jfr.sh..."
    sh "${SCRIPT_DIR}/auto_topic_enabled_non_jfr.sh"
    if [ $? -ne 0 ]; then
        echo "Error occurred at iteration ${i} of auto_topic_enabled_non_jfr"
        exit 1
    fi
done
echo "✓ Completed auto_topic_enabled_non_jfr (${REPEAT_COUNT} runs)"

echo ""
echo "========================================="
echo "All experiments completed successfully!"
echo "Total runs: $((${REPEAT_COUNT} * 3))"
echo "========================================="
