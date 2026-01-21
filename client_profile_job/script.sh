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
JOB_TEMPLATE="${JOB_TEMPLATE:-${SCRIPT_DIR}/kafka_producer_experiment_job.yaml}"
CONFIG_MANIFEST="${CONFIG_MANIFEST:-${SCRIPT_DIR}/producer_config.yaml}"

TOTAL_RUNS=1000
NUM_JOBS=100
RUNS_PER_JOB=10

KAFKA_CLIENTS_VERSION="${KAFKA_CLIENTS_VERSION:-4.1.1}"
SLF4J_VERSION="${SLF4J_VERSION:-2.0.16}"
ASYNC_PROFILER_VERSION="${ASYNC_PROFILER_VERSION:-4.2.1}"
ASYNC_PROFILER_ARCH="${ASYNC_PROFILER_ARCH:-linux-arm64}"

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/out/${TS}}"
mkdir -p "${OUTDIR}"

# 이미지 빌드
echo "Building image..."
docker build \
  --build-arg KAFKA_CLIENTS_VERSION="${KAFKA_CLIENTS_VERSION}" \
  --build-arg SLF4J_VERSION="${SLF4J_VERSION}" \
  --build-arg ASYNC_PROFILER_VERSION="${ASYNC_PROFILER_VERSION}" \
  --build-arg ASYNC_PROFILER_ARCH="${ASYNC_PROFILER_ARCH}" \
  -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

# ConfigMap 적용
echo "Applying config..."
kubectl apply -n "${NS}" -f "${CONFIG_MANIFEST}"

# Job 100개를 순차적으로 실행
for job_num in $(seq 1 ${NUM_JOBS}); do
  JOB_NAME="kafka-producer-experiment-${job_num}"
  # Job별 오프셋 계산 (0-based)
  OFFSET=$(( (job_num - 1) * RUNS_PER_JOB ))
  
  echo ""
  echo "========================================="
  echo "Starting Job ${job_num}/${NUM_JOBS}"
  echo "Global index range: $((OFFSET + 1)) ~ $((OFFSET + RUNS_PER_JOB))"
  echo "========================================="
  
  # 기존 Job 삭제
  kubectl delete job -n "${NS}" "${JOB_NAME}" --ignore-not-found
  
  # Job 생성 (AUTO_CREATE_TOPICS 환경변수 주입)
  sed \
  -e "s/^  name: kafka-producer-experiment/  name: ${JOB_NAME}/" \
  -e "s/^  completions: .*/  completions: ${RUNS_PER_JOB}/" \
  -e "s/REPLACE_AUTO_CREATE_TOPICS/${AUTO_CREATE_TOPICS}/" \
  -e "/- name: JOB_INDEX_OFFSET/,/value:/ s/value: \"0\"/value: \"${OFFSET}\"/" \
  "${JOB_TEMPLATE}" | kubectl apply -n "${NS}" -f -

  
  # 이 Job의 완료를 기다리며 결과 수집
  last_idx=-1
  completed_count=0
  
  while [[ ${completed_count} -lt ${RUNS_PER_JOB} ]]; do
    JOB_STATUS=$(kubectl get job -n "${NS}" "${JOB_NAME}" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
    
    if [[ "${JOB_STATUS}" == "True" ]]; then
      break
    fi
    
    POD_NAME=$(kubectl get pods -n "${NS}" -l job-name="${JOB_NAME}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    
    if [[ -z "${POD_NAME}" ]]; then
      sleep 0.2
      continue
    fi
    
    local_idx=$(kubectl get pod -n "${NS}" "${POD_NAME}" \
      -o jsonpath='{.metadata.annotations.batch\.kubernetes\.io/job-completion-index}' 2>/dev/null || true)
    
    if [[ -z "${local_idx}" || "${local_idx}" == "${last_idx}" ]]; then
      sleep 0.2
      continue
    fi
    
    # 전역 인덱스 계산 (1-based)
    global_idx=$((OFFSET + local_idx + 1))
    job_dir="${OUTDIR}/kafka-producer-experiment-${global_idx}"
    mkdir -p "${job_dir}"
    
    echo "→ Detected Run-${global_idx}, waiting for files..."
    
    # 파일 준비 대기
    ready=0
    for _ in {1..150}; do
      if kubectl exec -n "${NS}" -c producer "${POD_NAME}" -- \
        sh -c "test -f \"/profiles/run-${global_idx}/metrics.txt\" \
              -a -f \"/profiles/run-${global_idx}/jfr.jfr\"" 2>/dev/null; then
        ready=1
        break
      fi
      sleep 0.1
    done
    
    if [[ "${ready}" != "1" ]]; then
      echo "✗ Run-${global_idx}: files not ready"
      last_idx="${local_idx}"
      continue
    fi
    
    # kubectl cp 재시도
    copied=0
    for _ in {1..3}; do
      if kubectl cp -n "${NS}" -c producer \
        "${POD_NAME}:/profiles/run-${global_idx}" "${job_dir}" 2>/dev/null; then
        copied=1
        break
      fi
      sleep 0.2
    done
    
    if [[ "${copied}" == "1" ]]; then
      completed_count=$((completed_count + 1))
      echo "✓ Run-${global_idx}/${TOTAL_RUNS} (Job ${job_num}: ${completed_count}/${RUNS_PER_JOB})"
    else
      echo "✗ Run-${global_idx}/${TOTAL_RUNS}: copy failed"
    fi
    
    last_idx="${local_idx}"
    sleep 0.2
  done
  
  echo "Job ${job_num}/${NUM_JOBS} completed"
done

echo ""
echo "========================================="
echo "All jobs completed. Output: ${OUTDIR}"
echo "========================================="