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
PARALLELISM="${PARALLELISM:-1}"

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

JOB_NAME="kafka-producer-experiment"
echo "[info] run job=${JOB_NAME} completions=${REPEAT} parallelism=${PARALLELISM}"

kubectl delete -n "${NS}" "job/${JOB_NAME}" --ignore-not-found

sed -e "s/^  name: kafka-producer-experiment/  name: ${JOB_NAME}/" \
    -e "s/^  completions: .*/  completions: ${REPEAT}/" \
    -e "s/^  parallelism: .*/  parallelism: ${PARALLELISM}/" \
    "${JOB_TEMPLATE}" | kubectl apply -n "${NS}" -f -

# Job ?? ??
kubectl wait -n "${NS}" --for=condition=Complete "job/${JOB_NAME}" --timeout=300s

PODS="$(kubectl get pods -n "${NS}" -l job-name="${JOB_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [[ -z "${PODS}" ]]; then
  echo "[error] pods not found for job ${JOB_NAME}"
  exit 1
fi

MAX_WAIT_SECS="${MAX_WAIT_SECS:-120}"
for POD_NAME in ${PODS}; do
  idx="$(kubectl get pod -n "${NS}" "${POD_NAME}" -o jsonpath='{.metadata.annotations.batch\.kubernetes\.io/job-completion-index}' 2>/dev/null || true)"
  if [[ -z "${idx}" ]]; then
    echo "[warn] completion index not found for pod ${POD_NAME}"
    continue
  fi
  run_idx="$((idx + 1))"
  job_dir="${OUTDIR}/kafka-producer-experiment-${run_idx}"

  echo "[info] collecting artifacts from pod=${POD_NAME} index=${run_idx}"
  elapsed=0
  files_ready=0
  while (( elapsed < MAX_WAIT_SECS )); do
    if kubectl exec -n "${NS}" -c producer "${POD_NAME}" -- bash -lc \
      "ls -1 /profiles/run-${run_idx}/async.collapsed /profiles/run-${run_idx}/jfr.jfr >/dev/null 2>&1"; then
      files_ready=1
      break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  if [[ "${files_ready}" == "1" ]]; then
    mkdir -p "${job_dir}"
    kubectl cp -n "${NS}" "${POD_NAME}:/profiles/run-${run_idx}" "${job_dir}" -c producer || true
  else
    echo "[warn] skipping kubectl cp for ${POD_NAME}; files not detected"
  fi
done
