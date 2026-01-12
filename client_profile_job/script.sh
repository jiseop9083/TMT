#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 기본 설정 (환경변수로 override 가능)
NS="${NS:-kafka}"
IMAGE_NAME="${IMAGE_NAME:-my-kafka-producer:latest}"
JOB_TEMPLATE="${JOB_TEMPLATE:-${SCRIPT_DIR}/kafka_producer_experiment_job.yaml}"
CONFIG_MANIFEST="${CONFIG_MANIFEST:-${SCRIPT_DIR}/producer_config.yaml}"

REPEAT="${REPEAT:-1000}"

KAFKA_CLIENTS_VERSION="${KAFKA_CLIENTS_VERSION:-4.1.1}"
SLF4J_VERSION="${SLF4J_VERSION:-2.0.16}"

ASYNC_PROFILER_VERSION="${ASYNC_PROFILER_VERSION:-4.2.1}"
ASYNC_PROFILER_ARCH="${ASYNC_PROFILER_ARCH:-linux-arm64}"
ASYNC_EVENT="${ASYNC_EVENT:-wall}"
ASYNC_DURATION="${ASYNC_DURATION:-30}"
ASYNC_TGZ="async-profiler-${ASYNC_PROFILER_VERSION}-${ASYNC_PROFILER_ARCH}.tar.gz"
ASYNC_DIR="${SCRIPT_DIR}/async-profiler-${ASYNC_PROFILER_VERSION}-${ASYNC_PROFILER_ARCH}"

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/out/${TS}}"
mkdir -p "${OUTDIR}"

# # async-profiler 로컬 준비 (run_all 방식)
# if [[ ! -d "${ASYNC_DIR}" ]]; then
#   echo "[info] downloading async-profiler..."
#   curl -L -o "${ASYNC_TGZ}" \
#     "https://github.com/async-profiler/async-profiler/releases/download/v${ASYNC_PROFILER_VERSION}/${ASYNC_TGZ}"
#   tar -xvf "${ASYNC_TGZ}" -C "${SCRIPT_DIR}"
# fi

# 컨테이너 이미지 빌드 (의존성/async-profiler 포함)
echo "[info] building image..."

docker build \
  --build-arg KAFKA_CLIENTS_VERSION="${KAFKA_CLIENTS_VERSION}" \
  --build-arg SLF4J_VERSION="${SLF4J_VERSION}" \
  --build-arg ASYNC_PROFILER_VERSION="${ASYNC_PROFILER_VERSION}" \
  --build-arg ASYNC_PROFILER_ARCH="${ASYNC_PROFILER_ARCH}" \
  -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

echo "[info] applying producer config..."
kubectl apply -n "${NS}" -f "${CONFIG_MANIFEST}"

for i in $(seq 1 "${REPEAT}"); do
  # 1회 실행 = Job 1개
  JOB_NAME="kafka-producer-experiment-${i}"
  echo "[info] run ${i}/${REPEAT} job=${JOB_NAME}"

  kubectl delete -n "${NS}" "job/${JOB_NAME}" --ignore-not-found

  RUN_TS="$(date +%Y%m%d-%H%M%S-%N)"

  sed -e "s/name: kafka-producer-experiment/name: ${JOB_NAME}/" \
      -e "s/RUN_INDEX_VALUE/${i}/" \
      -e "s/RUN_TS_VALUE/${RUN_TS}/" \
      "${JOB_TEMPLATE}" | kubectl apply -n "${NS}" -f -

  POD_NAME=""
  for _ in $(seq 1 30); do
    POD_NAME="$(kubectl get pods -n "${NS}" -l job-name="${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${POD_NAME}" ]]; then
      break
    fi
    sleep 1
  done
  if [[ -z "${POD_NAME}" ]]; then
    echo "[error] pod not found for job ${JOB_NAME}"
    exit 1
  fi
  kubectl wait -n "${NS}" --for=condition=Ready "pod/${POD_NAME}" --timeout=180s
  sleep 3

  # 결과 파일 생성 확인 후, 완료 전에 결과 수집
  MAX_WAIT_SECS="${MAX_WAIT_SECS:-120}"
  echo "[info] waiting for profile files (max ${MAX_WAIT_SECS}s)..."
  elapsed=0
  files_ready=0
  while (( elapsed < MAX_WAIT_SECS )); do
    phase="$(kubectl get pod -n "${NS}" "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]]; then
      echo "[warn] pod completed before files were detected (phase=${phase})"
      break
    fi
    if kubectl exec -n "${NS}" -c producer "${POD_NAME}" -- bash -lc \
      "ls -1 /profiles/run-${i}/async.collapsed /profiles/run-${i}/jfr.jfr >/dev/null 2>&1"; then
      files_ready=1
      break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  if [[ "${files_ready}" == "1" ]]; then
    echo "[info] collecting artifacts to ${OUTDIR}/${JOB_NAME}"
    mkdir -p "${OUTDIR}/${JOB_NAME}"
    kubectl cp -n "${NS}" "${POD_NAME}:/profiles/run-${i}" "${OUTDIR}/${JOB_NAME}" -c producer || true
  else
    echo "[warn] skipping kubectl cp; files not detected before pod completion"
  fi

  # Job 완료 대기
  kubectl wait -n "${NS}" --for=condition=Complete "job/${JOB_NAME}" --timeout=300s
done
