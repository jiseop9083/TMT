#!/bin/bash
set -euo pipefail

# Job completion index (Indexed Job is 0-based; map to 1-based)
IDX="${RUN_INDEX:-}"
if [[ -z "${IDX}" && -n "${JOB_COMPLETION_INDEX:-}" ]]; then
  IDX="$((JOB_COMPLETION_INDEX + 1))"
fi
IDX="${IDX:-unknown}"

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
java \
  -XX:+UnlockDiagnosticVMOptions \
  -XX:+DebugNonSafepoints \
  -XX:FlightRecorderOptions=stackdepth=256 \
  -XX:StartFlightRecording=settings=profile,filename=${RUN_DIR}/jfr.jfr,dumponexit=true\
  -cp "/app/*:/app/lib/*" \
  ProducerOnce

# kubectl cp를 위한 여유 시간
POST_EXIT_SLEEP_MS="${POST_EXIT_SLEEP_MS:-3000}"
sleep "$(awk "BEGIN {printf \"%.3f\", ${POST_EXIT_SLEEP_MS}/1000}")"

exit 0
