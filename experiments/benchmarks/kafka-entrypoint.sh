#!/bin/bash
set -e

# JFR 설정
if [ "${ENABLE_BROKER_JFR}" = "true" ]; then
    echo "Enabling JFR for Kafka broker..."
    # dumponexit 제거하고 duration을 길게 설정 (30분 = 1800초)
    export KAFKA_OPTS="${KAFKA_OPTS} -XX:StartFlightRecording=name=KafkaBroker,settings=profile,maxsize=500M"
    echo "JFR recording started (will be dumped via jcmd)"
else
    echo "JFR disabled for Kafka broker"
fi

# 원래 entrypoint 실행
exec /opt/bitnami/scripts/kafka/entrypoint.sh /opt/bitnami/scripts/kafka/run.sh
