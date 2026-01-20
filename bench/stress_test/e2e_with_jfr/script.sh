#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 기본 설정
NS="${NS:-kafka}"
IMAGE_NAME="${IMAGE_NAME:-my-kafka-producer:latest}"
JOB_TEMPLATE="${JOB_TEMPLATE:-${SCRIPT_DIR}/kafka_producer_experiment_job.yaml}"
CONFIG_MANIFEST="${CONFIG_MANIFEST:-${SCRIPT_DIR}/producer_config.yaml}"

REPEAT="${REPEAT:-1000}"

KAFKA_CLIENTS_VERSION="${KAFKA_CLIENTS_VERSION:-4.1.1}"
SLF4J_VERSION="${SLF4J_VERSION:-2.0.16}"

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/out/${TS}}"
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

# Job 생성
JOB_NAME="kafka-producer-experiment"
echo "Starting job (completions=${REPEAT})"

kubectl delete -n "${NS}" "job/${JOB_NAME}" --ignore-not-found

sed -e "s/^  name: kafka-producer-experiment/  name: ${JOB_NAME}/" \
    -e "s/^  completions: .*/  completions: ${REPEAT}/" \
    -e "s/^  parallelism: .*/  parallelism: 1/" \
    "${JOB_TEMPLATE}" | kubectl apply -n "${NS}" -f -

echo "Collecting artifacts..."

last_idx=-1

while true; do
  JOB_STATUS=$(kubectl get job -n "${NS}" "${JOB_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)

  [[ "${JOB_STATUS}" == "True" ]] && break

  POD_NAME=$(kubectl get pods -n "${NS}" -l job-name="${JOB_NAME}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  [[ -z "${POD_NAME}" ]] && sleep 0.2 && continue

  idx=$(kubectl get pod -n "${NS}" "${POD_NAME}" \
    -o jsonpath='{.metadata.annotations.batch\.kubernetes\.io/job-completion-index}' 2>/dev/null || true)

  [[ -z "${idx}" || "${idx}" == "${last_idx}" ]] && sleep 0.2 && continue

  run_idx=$((idx + 1))
  job_dir="${OUTDIR}/kafka-producer-experiment-${run_idx}"
  mkdir -p "${job_dir}"

  echo "→ Detected Run-${run_idx}, waiting for files..."

  # 파일 준비 대기
  ready=0
  last_size=0
  stable_cnt=0

  for _ in {1..300}; do
    size=$(kubectl exec -n "${NS}" -c producer "${POD_NAME}" -- \
      stat -c %s "/profiles/run-${run_idx}/jfr.jfr" 2>/dev/null || echo 0)

    if [[ "$size" -gt 0 && "$size" -eq "$last_size" ]]; then
      stable_cnt=$((stable_cnt + 1))
      if [[ "$stable_cnt" -ge 5 ]]; then
        ready=1
        break
      fi
    else
      stable_cnt=0
    fi

    last_size="$size"
    sleep 0.1
  done


  if [[ "${ready}" != "1" ]]; then
    echo "✗ Run-${run_idx}: files not ready"
    last_idx="${idx}"
    continue
  fi

  # kubectl cp race 대비 재시도
  copied=0
  for _ in {1..3}; do
    if kubectl cp -n "${NS}" -c producer \
      "${POD_NAME}:/profiles/run-${run_idx}" "${job_dir}" 2>/dev/null; then
      copied=1
      break
    fi
    sleep 0.2
  done

  if [[ "${copied}" == "1" ]]; then
    echo "✓ Run-${run_idx}/${REPEAT}"
  else
    echo "✗ Run-${run_idx}/${REPEAT}: copy failed"
  fi

  last_idx="${idx}"
  sleep 0.2
done

echo "Done. Output: ${OUTDIR}"
