#!/bin/bash
set -e

# Job completion index
IDX="${JOB_COMPLETION_INDEX:-unknown}"

# timestamp 생성 (한 번만)
RUN_TS="$(date +%Y%m%d-%H%M%S-%N)"

# 디렉터리 생성
RUN_DIR="/profiles/run-${IDX}"
mkdir -p "${RUN_DIR}"

echo "RUN_DIR=${RUN_DIR}, RUN_TS=${RUN_TS}"

# JVM 실행
exec java \
  -XX:StartFlightRecording=settings=profile,filename=${RUN_DIR}/producer-${RUN_TS}.jfr,dumponexit=true \
  -agentpath:/async-profiler/build/libasyncProfiler.so=event=wall,file=${RUN_DIR}/async-${RUN_TS}.html \
  -cp "/app/*" \
  ProducerOnce
