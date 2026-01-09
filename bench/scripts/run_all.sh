#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Assumptions (as requested)
# ----------------------------
NS="kafka"
CLUSTER="my-cluster"
BOOTSTRAP="${CLUSTER}-kafka-bootstrap.${NS}.svc:9092"
LOADER_POD="kafka-loader"

# Bench params (override by env if desired)
TOPIC="${TOPIC:-test-topic}"
NUM_RECORDS="${NUM_RECORDS:-3000000}"
RECORD_SIZE="${RECORD_SIZE:-10240}"
THROUGHPUT="${THROUGHPUT:-10000}"
ACKS="${ACKS:-all}"
LINGER_MS="${LINGER_MS:-0}"
COMPRESSION="${COMPRESSION:-none}"

# Profiling params
JFR_NAME="${JFR_NAME:-bench}"
JFR_SETTINGS="${JFR_SETTINGS:-profile}"          # profile recommended (JDK default)
ASYNC_DURATION="${ASYNC_DURATION:-60}"           # seconds, short sampling
ASYNC_EVENT="${ASYNC_EVENT:-cpu}"                # cpu|alloc|lock, etc
ASYNC_FALLBACK_EVENT="${ASYNC_FALLBACK_EVENT:-itimer}"  # fallback when permissions are missing
ASYNC_OUT="${ASYNC_OUT:-/tmp/async-profiler.html}"
JFR_OUT="${JFR_OUT:-/tmp/bench.jfr}"

# Local async-profiler path (you must have it locally; no internet assumed)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ASYNC_LOCAL_DIR="${SCRIPT_DIR}/async-profiler"
ASYNC_LOCAL_DIR="${ASYNC_LOCAL_DIR:-${DEFAULT_ASYNC_LOCAL_DIR}}"
if [[ -z "${ASYNC_LOCAL_DIR}" || ! -d "${ASYNC_LOCAL_DIR}" ]]; then
  ASYNC_LOCAL_DIR="${DEFAULT_ASYNC_LOCAL_DIR}"
fi
# Normalize Windows path for tar in Git Bash/MSYS if available
if command -v cygpath >/dev/null 2>&1; then
  ASYNC_LOCAL_DIR="$(cygpath -u "${ASYNC_LOCAL_DIR}")"
fi
ASYNC_REMOTE_DIR="/tmp/async-profiler"

# Output dir
TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-$(pwd)/out/${TS}}"
mkdir -p "${OUTDIR}"

echo "[info] namespace=${NS}, cluster=${CLUSTER}, bootstrap=${BOOTSTRAP}"
echo "[info] output dir=${OUTDIR}"

# ----------------------------
# Helpers
# ----------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[error] missing command: $1" >&2; exit 1; }; }
is_windows() {
  case "$(uname -s 2>/dev/null || echo)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}
if is_windows; then
  # Prevent MSYS path mangling (e.g., /tmp -> C:\Users\...\Temp) for kubectl exec args
  export MSYS2_ARG_CONV_EXCL="*"
fi
need_cmd kubectl
TAR_BIN="tar"
if [[ -x /usr/bin/tar ]]; then
  TAR_BIN="/usr/bin/tar"
fi

apply_manifests() {
  local manifests_dir
  manifests_dir="$(cd "$(dirname "$0")/.." && pwd)/manifests"
  if is_windows && command -v cygpath >/dev/null 2>&1; then
    manifests_dir="$(cygpath -w "${manifests_dir}")"
  fi
  kubectl apply -f "${manifests_dir}/bench-scripts-cm.yaml"
  kubectl apply -f "${manifests_dir}/kafka-loader.yaml"
  kubectl wait -n "${NS}" --for=condition=Ready pod/"${LOADER_POD}" --timeout=180s
}

pick_broker_pod() {
  # In KRaft NodePools, broker pods are usually named like my-cluster-broker-0
  local pod
  pod="$(kubectl get pods -n "${NS}" -o name | grep -E "^pod/${CLUSTER}-broker-[0-9]+$" | head -n 1 || true)"
  if [[ -z "${pod}" ]]; then
    # Fallback: find by Strimzi labels (labels may vary by environment)
    pod="$(kubectl get pods -n "${NS}" -l "strimzi.io/cluster=${CLUSTER}" -o name | grep -i broker | head -n 1 || true)"
  fi
  if [[ -z "${pod}" ]]; then
    echo "[error] cannot find broker pod in namespace ${NS} for cluster ${CLUSTER}" >&2
    echo "[hint] run: kubectl get pods -n ${NS} | grep ${CLUSTER}" >&2
    exit 1
  fi
  echo "${pod#pod/}"
}

get_kafka_pid() {
  local pod="$1"
  # Grab Kafka broker PID from jcmd -l output
  kubectl exec -n "${NS}" "${pod}" -- bash -lc \
    "jcmd -l 2>/dev/null | awk '/kafka\\.Kafka/ {print \$1; exit}'"
}

ensure_async_profiler_on_pod() {
  local pod="$1"

  echo "[info] async-profiler dir=${ASYNC_LOCAL_DIR}"
  if [[ ! -d "${ASYNC_LOCAL_DIR}" ]]; then
    echo "[error] async-profiler dir not found: ${ASYNC_LOCAL_DIR}" >&2
    exit 1
  fi
  if [[ ! -f "${ASYNC_LOCAL_DIR}/asprof" ]]; then
    echo "[error] async-profiler not found at: ${ASYNC_LOCAL_DIR}/asprof" >&2
    echo "[hint] download async-profiler release locally and extract into ${ASYNC_LOCAL_DIR}" >&2
    exit 1
  fi

  # copy directory to pod
  echo "[info] copying async-profiler to broker pod..."
  kubectl exec -n "${NS}" "${pod}" -- bash -lc "rm -rf '${ASYNC_REMOTE_DIR}' && mkdir -p '${ASYNC_REMOTE_DIR}'"
  # Copy directory contents via tar to avoid kubectl cp path parsing on Windows
  "${TAR_BIN}" -C "${ASYNC_LOCAL_DIR}" -cf - . | \
    kubectl exec -i -n "${NS}" "${pod}" -- tar -C "${ASYNC_REMOTE_DIR}" -xf -
  # Fix execute permissions
  kubectl exec -n "${NS}" "${pod}" -- bash -lc "chmod +x '${ASYNC_REMOTE_DIR}/asprof' || true"
}

start_jfr() {
  local pod="$1" pid="$2"
  echo "[info] starting JFR on ${pod} (pid=${pid})..."
  kubectl exec -n "${NS}" "${pod}" -- bash -lc \
    "jcmd '${pid}' JFR.start name='${JFR_NAME}' settings='${JFR_SETTINGS}' filename='${JFR_OUT}' dumponexit=true"
}

stop_jfr() {
  local pod="$1" pid="$2"
  echo "[info] stopping JFR on ${pod}..."
  # On stop, dump to filename and finish
  kubectl exec -n "${NS}" "${pod}" -- bash -lc \
    "jcmd '${pid}' JFR.stop name='${JFR_NAME}' filename='${JFR_OUT}' || true"
}

run_async_profiler_window() {
  local pod="$1" pid="$2"
  echo "[info] running async-profiler window: event=${ASYNC_EVENT}, duration=${ASYNC_DURATION}s"
  # Use nohup to run in background (less sensitive to kubectl exec session)
  kubectl exec -n "${NS}" "${pod}" -- bash -lc "
    set -e
    PROF='${ASYNC_REMOTE_DIR}/asprof'
    PROF_DIR='${ASYNC_REMOTE_DIR}'
    export LD_LIBRARY_PATH=\"\$PROF_DIR:\$PROF_DIR/lib:\${LD_LIBRARY_PATH:-}\"
    nohup \"\$PROF\" -e '${ASYNC_EVENT}' -d '${ASYNC_DURATION}' -f '${ASYNC_OUT}' '${pid}' >/tmp/async-profiler.log 2>&1 &
    echo \$! > /tmp/async-profiler.nohup.pid
  "
}

async_profiler_failed() {
  local pod="$1"
  kubectl exec -n "${NS}" "${pod}" -- bash -lc \
    "test -f /tmp/async-profiler.log && grep -E -i 'perf_event_open|Operation not permitted|No permission|Failed to open|not supported|Profiler failed|cannot open shared object file' /tmp/async-profiler.log >/dev/null 2>&1"
}

print_async_profiler_log() {
  local pod="$1"
  echo "[warn] async-profiler log from pod ${pod}:"
  kubectl exec -n "${NS}" "${pod}" -- bash -lc "cat /tmp/async-profiler.log || true"
}

run_async_profiler_with_fallback() {
  local pod="$1" pid="$2"
  run_async_profiler_window "${pod}" "${pid}"
  sleep 2
  if async_profiler_failed "${pod}"; then
    print_async_profiler_log "${pod}"
    if [[ "${ASYNC_EVENT}" != "${ASYNC_FALLBACK_EVENT}" ]]; then
      echo "[warn] async-profiler failed with event=${ASYNC_EVENT}; retrying with ${ASYNC_FALLBACK_EVENT}"
      kubectl exec -n "${NS}" "${pod}" -- bash -lc "
        set -e
        PROF='${ASYNC_REMOTE_DIR}/asprof'
        PROF_DIR='${ASYNC_REMOTE_DIR}'
        export LD_LIBRARY_PATH=\"\$PROF_DIR:\$PROF_DIR/lib:\${LD_LIBRARY_PATH:-}\"
        nohup \"\$PROF\" -e '${ASYNC_FALLBACK_EVENT}' -d '${ASYNC_DURATION}' -f '${ASYNC_OUT}' '${pid}' >/tmp/async-profiler.log 2>&1 &
        echo \$! > /tmp/async-profiler.nohup.pid
      "
    fi
  fi
}
run_load() {
  echo "[info] running producer-perf-test from loader pod..."
  kubectl exec -n "${NS}" "${LOADER_POD}" -- bash -lc "
    export BOOTSTRAP='${BOOTSTRAP}'
    export TOPIC='${TOPIC}'
    export NUM_RECORDS='${NUM_RECORDS}'
    export RECORD_SIZE='${RECORD_SIZE}'
    export THROUGHPUT='${THROUGHPUT}'
    export ACKS='${ACKS}'
    export LINGER_MS='${LINGER_MS}'
    export COMPRESSION='${COMPRESSION}'
    /opt/bench/run-producer.sh | tee /tmp/producer-perf-test.log
  "
  kubectl cp -n "${NS}" "${LOADER_POD}:/tmp/producer-perf-test.log" "${OUTDIR}/producer-perf-test.log" || true
}

collect_artifacts() {
  local pod="$1"
  echo "[info] collecting artifacts..."
  kubectl cp -n "${NS}" "${pod}:${JFR_OUT}" "${OUTDIR}/bench.jfr" || true
  kubectl cp -n "${NS}" "${pod}:${ASYNC_OUT}" "${OUTDIR}/async-profiler.html" || true
  kubectl cp -n "${NS}" "${pod}:/tmp/async-profiler.log" "${OUTDIR}/async-profiler.log" || true
}

# ----------------------------
# Main
# ----------------------------
apply_manifests

BROKER_POD="$(pick_broker_pod)"
echo "[info] broker pod=${BROKER_POD}"

PID="$(get_kafka_pid "${BROKER_POD}")"
if [[ -z "${PID}" ]]; then
  echo "[error] cannot find kafka pid via jcmd in ${BROKER_POD}. Is jcmd available in the image?" >&2
  echo "[hint] try: kubectl exec -n ${NS} ${BROKER_POD} -- bash -lc 'ls -la; which jcmd; jcmd -l'" >&2
  exit 1
fi
echo "[info] kafka pid=${PID}"

# JFR: long-running over the whole load
start_jfr "${BROKER_POD}" "${PID}"

# async-profiler: short sampling window during the run
ensure_async_profiler_on_pod "${BROKER_POD}"
run_async_profiler_with_fallback "${BROKER_POD}" "${PID}"

# Load generation
run_load

# Stop JFR and collect
stop_jfr "${BROKER_POD}" "${PID}"
collect_artifacts "${BROKER_POD}"

echo "[done] artifacts saved to: ${OUTDIR}"
ls -lah "${OUTDIR}" || true
