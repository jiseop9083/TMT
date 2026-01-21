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
  OFFSET=$(( (job_num - 1) * RUNS_PER_JOB ))
  
  echo ""
  echo "========================================="
  echo "Starting Job ${job_num}/${NUM_JOBS}"
  echo "Global index range: $((OFFSET + 1)) ~ $((OFFSET + RUNS_PER_JOB))"
  echo "========================================="
  
  kubectl delete job -n "${NS}" "${JOB_NAME}" --ignore-not-found
  
  sed \
  -e "s/^  name: kafka-producer-experiment/  name: ${JOB_NAME}/" \
  -e "s/^  completions: .*/  completions: ${RUNS_PER_JOB}/" \
  -e "s/REPLACE_AUTO_CREATE_TOPICS/${AUTO_CREATE_TOPICS}/" \
  -e "/- name: JOB_INDEX_OFFSET/,/value:/ s/value: \"0\"/value: \"${OFFSET}\"/" \
  "${JOB_TEMPLATE}" | kubectl apply -n "${NS}" -f -

  last_idx=-1
  completed_count=0
  
  # 수집 루프 시작
  while [[ ${completed_count} -lt ${RUNS_PER_JOB} ]]; do
    JOB_STATUS=$(kubectl get job -n "${NS}" "${JOB_NAME}" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
    
    POD_NAME=$(kubectl get pods -n "${NS}" -l job-name="${JOB_NAME}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    
    if [[ -z "${POD_NAME}" ]]; then
      # Job이 이미 끝났는데 수집 못한 파일이 있는지 체크
      if [[ "${JOB_STATUS}" == "True" && ${completed_count} -lt ${RUNS_PER_JOB} ]]; then
          echo "Job finished but not all files collected. Checking last completed pod..."
          POD_NAME=$(kubectl get pods -n "${NS}" -l job-name="${JOB_NAME}" \
            -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)
          if [[ -z "${POD_NAME}" ]]; then break; fi
      else
          sleep 0.5
          continue
      fi
    fi
    
    local_idx=$(kubectl get pod -n "${NS}" "${POD_NAME}" \
      -o jsonpath='{.metadata.annotations.batch\.kubernetes\.io/job-completion-index}' 2>/dev/null || true)
    
    # 새로운 인덱스가 감지될 때만 실행
    if [[ -n "${local_idx}" && "${local_idx}" != "${last_idx}" ]]; then
      global_idx=$((OFFSET + local_idx + 1))
      remote_idx=$((local_idx + 1)) # 원격지는 항상 1~10 반복
      
      job_dir="${OUTDIR}/kafka-producer-experiment-${global_idx}"
      mkdir -p "${job_dir}"
      
      echo "→ Run-${global_idx} detected. Copying from pod run-${remote_idx}..."
      
      # 파일 존재 확인 및 대기
      ready=0
      for _ in {1..150}; do
        if kubectl exec -n "${NS}" -c producer "${POD_NAME}" -- \
          sh -c "test -f \"/profiles/run-${remote_idx}/metrics.txt\"" 2>/dev/null; then
          ready=1
          break
        fi
        sleep 0.2
      done
      
      if [[ "${ready}" == "1" ]]; then
        if kubectl cp -n "${NS}" -c producer "${POD_NAME}:/profiles/run-${remote_idx}" "${job_dir}" 2>/dev/null; then
          echo "✓ Run-${global_idx} copied successfully."
          # 복사 후 삭제 (용량 확보 및 중복 방지)
          kubectl exec -n "${NS}" -c producer "${POD_NAME}" -- rm -rf "/profiles/run-${remote_idx}"
          completed_count=$((completed_count + 1))
          last_idx="${local_idx}"
        else
          echo "✗ Run-${global_idx} copy failed."
        fi
      fi
    fi

    # Job 상태가 Complete이고 모든 파일 수집 시 탈출
    if [[ "${JOB_STATUS}" == "True" && ${completed_count} -ge ${RUNS_PER_JOB} ]]; then
      break
    fi
    sleep 0.5
  done 
  
  echo "Job ${job_num}/${NUM_JOBS} completed."
done 

echo ""
echo "========================================="
echo "All jobs completed. Output: ${OUTDIR}"
echo "========================================="