#!/bin/bash
set -e

# JFR 설정
if [ "${ENABLE_BROKER_JFR}" = "true" ]; then
    echo "Enabling JFR for Kafka broker..."
    # dumponexit 제거하고 duration을 길게 설정 (30분 = 1800초)
    export KAFKA_OPTS="${KAFKA_OPTS} -XX:StartFlightRecording=name=KafkaBroker,settings=profile,maxsize=500M,filename=/profiles/kafka-broker.jfr,dumponexit=true"
    echo "JFR recording started (will be dumped on exit)"
else
    echo "JFR disabled for Kafka broker"
fi

# apache/kafka 이미지의 원래 entrypoint 실행
exec /__cacert_entrypoint.sh /etc/kafka/docker/run
