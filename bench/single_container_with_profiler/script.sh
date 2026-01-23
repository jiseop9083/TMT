#!/usr/bin/env bash
set -euo pipefail

AUTO_CREATE_TOPICS="true"

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 기본 설정
NS="${NS:-kafka}"
IMAGE_NAME="${IMAGE_NAME:-my-kafka-producer:latest}"
CONFIG_MANIFEST="${CONFIG_MANIFEST:-${SCRIPT_DIR}/producer_config.yaml}"

KAFKA_CLIENTS_VERSION="${KAFKA_CLIENTS_VERSION:-4.1.1}"
SLF4J_VERSION="${SLF4J_VERSION:-2.0.16}"
POD_TEMPLATE="${POD_TEMPLATE:-${SCRIPT_DIR}/kafka_producer_experiment_pod.yaml}"

if [[ "${AUTO_CREATE_TOPICS}" == "true" ]]; then
  MODE_DIR="enabled"
else
  MODE_DIR="disabled"
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/out/${MODE_DIR}/run_${TS}}"
mkdir -p "${OUTDIR}"


# 이미지 빌드
echo "Building image..."
docker build \
  --build-arg KAFKA_CLIENTS_VERSION="${KAFKA_CLIENTS_VERSION}" \
  --build-arg SLF4J_VERSION="${SLF4J_VERSION}" \
  -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

# ConfigMap 적용
echo "Applying config..."
kubectl apply -n "${NS}" -f "${CONFIG_MANIFEST}"

mkdir -p "${OUTDIR}"
POD_NAME="kafka-producer-experiment"

echo "Applying pod: ${POD_NAME}"

# 기존 Pod 삭제
kubectl delete pod -n "${NS}" "${POD_NAME}" --ignore-not-found

# Pod 생성 (AUTO_CREATE_TOPICS 치환 + 이름 치환)
sed \
  -e "s/REPLACE_AUTO_CREATE_TOPICS/${AUTO_CREATE_TOPICS}/g" \
  "${POD_TEMPLATE}" | kubectl apply -n "${NS}" -f -

echo "Waiting pod to be Running..."
kubectl wait -n "${NS}" --for=condition=Ready pod/"${POD_NAME}" --timeout=120s

echo "Pod is Ready. Waiting files..."

ready=0
while [[ "${ready}" -eq 0 ]]; do
  if kubectl exec -n "${NS}" -c producer "${POD_NAME}" -- sh -c '
    test -f /profiles/run/metrics.txt &&
    test -f /profiles/run/jfr.jfr &&
    test -f /profiles/run/app.log
  ' 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.2
done
echo "Files detected. Copying /profiles/run ..."

dst="${OUTDIR}"
mkdir -p "${dst}"

kubectl cp -n "${NS}" -c producer "${POD_NAME}:/profiles/run" "${dst}"

echo "✓ copied to ${dst}/run"

# (선택) 복사 후 원격 삭제
kubectl exec -n "${NS}" -c producer "${POD_NAME}" -- rm -rf /profiles/run

echo "Done."


echo ""
echo "========================================="
echo "All jobs completed. Output: ${OUTDIR}"
echo "========================================="