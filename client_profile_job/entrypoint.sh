#!/bin/bash
set -euo pipefail

# Job completion index
IDX="${RUN_INDEX:-${JOB_COMPLETION_INDEX:-unknown}}"

# timestamp 생성 (한 번만)
RUN_TS="${RUN_TS:-$(date +%Y%m%d-%H%M%S-%N)}"

# 디렉터리 생성 (기본값은 쓰기 가능한 경로)
PROFILES_DIR="${PROFILES_DIR:-/profiles}"
RUN_DIR="${PROFILES_DIR}/run-${IDX}"
rm -rf "${RUN_DIR}"
mkdir -p "${RUN_DIR}"
mkdir -p /tmp

echo "RUN_DIR=${RUN_DIR}, RUN_TS=${RUN_TS}"

export RUN_DIR
export RUN_TS

# stdout/stderr를 파일로도 남긴다
exec > >(tee -a "${RUN_DIR}/app.log") 2>&1

# JVM 실행 (JFR은 시작 시점에 활성화)
ASYNC_AGENT_ARGS=""
PROF_START_MS=""
if [[ "${ASYNC_PROFILER_ENABLE:-1}" == "1" ]]; then
  ASYNC_AGENT_ARGS="-agentpath:/async-profiler/lib/libasyncProfiler.so=start,event=${ASYNC_EVENT:-wall},timeout=${ASYNC_DURATION:-30},file=${RUN_DIR}/async.collapsed,format=collapsed"
  if [[ -n "${ASYNC_INTERVAL:-}" ]]; then
    ASYNC_AGENT_ARGS="${ASYNC_AGENT_ARGS},interval=${ASYNC_INTERVAL}"
  fi
  PROF_START_MS="$(date +%s%3N)"
  echo "async-profiler start_ms=${PROF_START_MS}, timeout_s=${ASYNC_DURATION:-30}"
fi

java \
  ${ASYNC_AGENT_ARGS} \
  -XX:StartFlightRecording=settings=profile,filename=${RUN_DIR}/jfr.jfr,dumponexit=true \
  -cp "/app/*:/app/lib/*" \
  ProducerOnce
exit_code=$?
if [[ -n "${PROF_START_MS}" ]]; then
  PROF_END_MS="$(date +%s%3N)"
  PROF_ELAPSED_MS="$((PROF_END_MS - PROF_START_MS))"
  echo "async-profiler end_ms=${PROF_END_MS}, elapsed_ms=${PROF_ELAPSED_MS}"
fi

# kubectl cp를 위한 여유 시간
POST_EXIT_SLEEP_MS="${POST_EXIT_SLEEP_MS:-15000}"
sleep "$(awk "BEGIN {printf \"%.3f\", ${POST_EXIT_SLEEP_MS}/1000}")"

exit "${exit_code}"
