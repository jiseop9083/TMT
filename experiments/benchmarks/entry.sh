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

echo "=== 5Gbps 네트워크 제한 적용 중 ==="

# Find the primary network interface (usually eth0 in Docker)
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
echo "Using network interface: ${NETWORK_INTERFACE}"

# Apply network rate limit
tc qdisc add dev "${NETWORK_INTERFACE}" root handle 1: htb default 10
tc class add dev "${NETWORK_INTERFACE}" parent 1: classid 1:10 htb rate 5gbit ceil 5gbit

tc qdisc show dev "${NETWORK_INTERFACE}"
echo "=== 제한 완료 ==="

# stdout/stderr를 파일로도 남긴다
exec > >(tee -a "${RUN_DIR}/app.log") 2>&1

# JFR 활성화 여부 (기본값: true)
ENABLE_JFR="${ENABLE_JFR:-true}"
echo "ENABLE_JFR: ${ENABLE_JFR}"

if [[ "${ENABLE_JFR}" == "true" ]]; then
  echo "=== JFR 프로파일링 활성화 ==="
  PROFILE_PATH=/custom_profile.jfc
  java \
    -XX:+UnlockDiagnosticVMOptions \
    -XX:+DebugNonSafepoints \
    -XX:FlightRecorderOptions=stackdepth=256 \
    -XX:StartFlightRecording=settings=${PROFILE_PATH},filename=${RUN_DIR}/jfr.jfr,dumponexit=true \
    -cp "/app/*:/app/lib/*" \
    ProduceMessages
else
  echo "=== JFR 비활성화 모드 ==="
  java \
    -cp "/app/*:/app/lib/*" \
    ProduceMessages
fi

# Sleep to ensure files are written
POST_EXIT_SLEEP_MS="${POST_EXIT_SLEEP_MS:-3000}"
sleep "$(awk "BEGIN {printf \"%.3f\", ${POST_EXIT_SLEEP_MS}/1000}")"

exit 0
