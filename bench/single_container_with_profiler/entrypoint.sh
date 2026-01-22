#!/bin/bash
set -euo pipefail

# timestamp 생성 (한 번만)
RUN_TS="${RUN_TS:-$(date +%Y%m%d-%H%M%S-%N)}"

# 디렉터리 생성 (기본값은 쓰기 가능한 경로)
PROFILES_DIR="${PROFILES_DIR:-/profiles}"
RUN_DIR="${PROFILES_DIR}/run"
rm -rf "${RUN_DIR}"
mkdir -p "${RUN_DIR}"
mkdir -p /tmp

echo "RUN_DIR=${RUN_DIR}, RUN_TS=${RUN_TS}"

export RUN_DIR
export RUN_TS

echo "=== 50Mbps 네트워크 제한 적용 중 ==="

# 기존 qdisc 있으면 제거 (에러 나도 무시)
tc qdisc del dev eth0 root 2>/dev/null || true

# eth0 속도 제한: 50mbit
tc qdisc add dev eth0 root handle 1: htb default 10
tc class add dev eth0 parent 1: classid 1:10 htb rate 50mbit ceil 50mbit

tc qdisc show dev eth0
echo "=== 제한 완료 ==="

# stdout/stderr를 파일로도 남긴다
exec > >(tee -a "${RUN_DIR}/app.log") 2>&1

PROFILE_PATH=/custom_profile.jfc
java \
  -XX:+UnlockDiagnosticVMOptions \
  -XX:+DebugNonSafepoints \
  -XX:FlightRecorderOptions=stackdepth=256 \
  -XX:StartFlightRecording=settings=${PROFILE_PATH},filename=${RUN_DIR}/jfr.jfr,dumponexit=true \
  -cp "/app/*:/app/lib/*" \
  ProduceMessages
  
# kubectl cp를 위한 여유 시간
POST_EXIT_SLEEP_MS="${POST_EXIT_SLEEP_MS:-3000}"
sleep "$(awk "BEGIN {printf \"%.3f\", ${POST_EXIT_SLEEP_MS}/1000}")"

exit 0
