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
JFR_OUT="${JFR_OUT:-/tmp/bench.jfr}"

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

# Load generation
run_load

# Stop JFR and collect
stop_jfr "${BROKER_POD}" "${PID}"
collect_artifacts "${BROKER_POD}"

echo "[done] artifacts saved to: ${OUTDIR}"
ls -lah "${OUTDIR}" || true
