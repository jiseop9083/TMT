#!/usr/bin/env bash
set -euo pipefail

AUTO_CREATE_TOPICS="true"
ENABLE_JFR="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-create-topics)
      AUTO_CREATE_TOPICS="$2"
      shift 2
      ;;
    --auto-create-topics=*)
      AUTO_CREATE_TOPICS="${1#*=}"
      shift
      ;;
    --enable-jfr)
      ENABLE_JFR="$2"
      shift 2
      ;;
    --enable-jfr=*)
      ENABLE_JFR="${1#*=}"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

AUTO_CREATE_TOPICS_LOWER="$(echo "${AUTO_CREATE_TOPICS}" | tr '[:upper:]' '[:lower:]')"

case "${AUTO_CREATE_TOPICS_LOWER}" in
  false|0|no) AUTO_CREATE_TOPICS="false" ;;
  true|1|yes) AUTO_CREATE_TOPICS="true" ;;
  *)
    echo "Invalid value for --auto-create-topics: ${AUTO_CREATE_TOPICS}"
    exit 1
    ;;
esac

ENABLE_JFR_LOWER="$(echo "${ENABLE_JFR}" | tr '[:upper:]' '[:lower:]')"

case "${ENABLE_JFR_LOWER}" in
  false|0|no) ENABLE_JFR="false" ;;
  true|1|yes) ENABLE_JFR="true" ;;
  *)
    echo "Invalid value for --enable-jfr: ${ENABLE_JFR}"
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ "${AUTO_CREATE_TOPICS}" == "true" ]]; then
  if [[ "${ENABLE_JFR}" == "true" ]]; then
    MODE_DIR="enabled"
  else
    MODE_DIR="enabled_non_jfr"
  fi
else
  if [[ "${ENABLE_JFR}" == "true" ]]; then
    MODE_DIR="disabled"
  else
    MODE_DIR="disabled_non_jfr"
  fi
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/../output/${MODE_DIR}/run_${TS}}"
mkdir -p "${OUTDIR}"

export AUTO_CREATE_TOPICS
export ENABLE_JFR

# Clean up profiles directory
rm -rf "${SCRIPT_DIR}/profiles"
mkdir -p "${SCRIPT_DIR}/profiles"

# Stop and remove existing containers
echo "Cleaning up existing containers..."
docker compose down -v 2>/dev/null || true

# Build and start services
echo "Building producer image..."
docker compose build producer

echo "Starting Kafka..."
docker compose up -d kafka

echo "Waiting for Kafka to be healthy..."
timeout=60
elapsed=0
while ! docker compose exec kafka kafka-broker-api-versions.sh --bootstrap-server localhost:9092 &>/dev/null; do
  if [ $elapsed -ge $timeout ]; then
    echo "Error: Kafka failed to start within ${timeout} seconds"
    docker compose logs kafka
    exit 1
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

echo "Kafka is ready. Starting producer..."
docker compose up -d producer

echo "Waiting for output files..."

# Wait for files to be created
ready=0
max_wait=10000
waited=0
while [[ "${ready}" -eq 0 && "${waited}" -lt "${max_wait}" ]]; do
  files_check=0

  # 기본 파일 체크
  if [ -f "${SCRIPT_DIR}/profiles/run/metrics.txt" ] && \
     [ -f "${SCRIPT_DIR}/profiles/run/app.log" ]; then

    # JFR 활성화시 jfr.jfr 파일도 체크
    if [[ "${ENABLE_JFR}" == "true" ]]; then
      if [ -f "${SCRIPT_DIR}/profiles/run/jfr.jfr" ]; then
        files_check=1
      fi
    else
      # JFR 비활성화시 jfr.jfr 체크 안함
      files_check=1
    fi
  fi

  if [[ "${files_check}" -eq 1 ]]; then
    ready=1
    break
  fi

  sleep 1
  waited=$((waited + 1))
done

if [[ "${ready}" -eq 0 ]]; then
  echo "Error: Output files not found after ${max_wait} seconds"
  echo "Showing producer logs:"
  docker compose logs producer
  exit 1
fi

echo "Files detected. Copying results..."
cp -r "${SCRIPT_DIR}/profiles/run/"* "${OUTDIR}/"

echo "✓ copied to ${OUTDIR}"

rm -rf "${SCRIPT_DIR}/profiles"

# Clean up
echo ""
echo "Cleaning up containers..."
docker compose down

echo ""
echo "========================================="
echo "All jobs completed. Output: ${OUTDIR}"
echo "========================================="
