#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAFKA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVER_CONFIG="config/server.properties"
OUTPUT_ROOT=""
BOOTSTRAP_SERVER="localhost:9092"
NUM_TOPICS="3000"
TOPIC_PREFIX="test_topic_"
RECORD_SIZE="512"
ACKS="1"
RUN_ID=""
JFC_FILE="${SCRIPT_DIR}/custom-profiling.jfc"
JFR_MAX_SIZE=""
DO_BUILD=1
DO_FORMAT=1
DO_CLEAN=1

read_first_config_value() {
  local key="$1"
  local file="$2"
  local raw
  raw="$(awk -F= -v key="$key" '
    $0 ~ "^[[:space:]]*"key"[[:space:]]*=" {
      sub(/^[[:space:]]+/, "", $2)
      sub(/[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "$file")"
  echo "$raw"
}

discover_existing_cluster_id() {
  local config_file="$1"
  local log_dirs
  log_dirs="$(read_first_config_value "log.dirs" "$config_file")"
  if [[ -z "$log_dirs" ]]; then
    return 0
  fi
  local dir
  IFS=',' read -r -a dirs <<<"$log_dirs"
  for dir in "${dirs[@]}"; do
    dir="${dir#"${dir%%[![:space:]]*}"}"
    dir="${dir%"${dir##*[![:space:]]}"}"
    if [[ -z "$dir" ]]; then
      continue
    fi
    local meta_file="${dir}/meta.properties"
    if [[ -f "$meta_file" ]]; then
      local existing_id
      existing_id="$(read_first_config_value "cluster.id" "$meta_file")"
      if [[ -n "$existing_id" ]]; then
        echo "$existing_id"
        return 0
      fi
    fi
  done
  return 0
}

list_log_dirs() {
  local config_file="$1"
  local log_dirs_raw
  local dir
  log_dirs_raw="$(read_first_config_value "log.dirs" "$config_file")"
  if [[ -z "$log_dirs_raw" ]]; then
    return 0
  fi
  IFS=',' read -r -a dirs <<<"$log_dirs_raw"
  for dir in "${dirs[@]}"; do
    dir="${dir#"${dir%%[![:space:]]*}"}"
    dir="${dir%"${dir##*[![:space:]]}"}"
    if [[ -n "$dir" ]]; then
      echo "$dir"
    fi
  done
  return 0
}

clean_storage_dirs() {
  local config_file="$1"
  local dir
  while IFS= read -r dir; do
    if [[ -z "$dir" ]]; then
      continue
    fi
    echo "Removing storage directory: $dir"
    rm -rf "$dir"
  done < <(list_log_dirs "$config_file")
}

usage() {
  cat <<'EOF'
Usage: run_producer_latency_with_jfr.sh [options]

Runs:
  1) ./gradlew jar -PscalaVersion=2.13.17
  2) kafka-storage format
  3) kafka-server-start with JFR enabled
  4) kafka-producer-latency

Artifacts are saved under:
  kafka-4.2/output/run_YYYYmmdd_HHMMSS/

Options:
  --kafka-dir <dir>               Kafka source dir (default: parent dir of this script)
  --server-config <path>          Broker config relative to kafka-dir (default: config/server.properties)
  --bootstrap-server <host:port>  Kafka bootstrap server (default: localhost:9092)
  --num-topics <n>                Number of topics to test (default: 3000)
  --topic-prefix <prefix>         Topic prefix (default: test_topic_)
  --record-size <bytes>           Producer record size (default: 512)
  --acks <acks>                   Producer acks (default: 1)
  --output-root <dir>             Output root (default: <kafka-dir>/output)
  --run-id <name>                 Run folder name (default: run_YYYYmmdd_HHMMSS)
  --jfc-file <path>               JFR config file (.jfc)
  --jfr-max-size <value>          JFR max size, e.g. 1g
  --skip-build                    Skip ./gradlew jar -PscalaVersion=2.13.17
  --skip-clean                    Skip stopping broker and deleting log.dirs before format
  --skip-format                   Skip kafka-storage format
  --help                          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kafka-dir) KAFKA_DIR="${2:-}"; shift 2 ;;
    --server-config) SERVER_CONFIG="${2:-}"; shift 2 ;;
    --bootstrap-server) BOOTSTRAP_SERVER="${2:-}"; shift 2 ;;
    --num-topics) NUM_TOPICS="${2:-}"; shift 2 ;;
    --topic-prefix) TOPIC_PREFIX="${2:-}"; shift 2 ;;
    --record-size) RECORD_SIZE="${2:-}"; shift 2 ;;
    --acks) ACKS="${2:-}"; shift 2 ;;
    --output-root) OUTPUT_ROOT="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --jfc-file) JFC_FILE="${2:-}"; shift 2 ;;
    --jfr-max-size) JFR_MAX_SIZE="${2:-}"; shift 2 ;;
    --skip-build) DO_BUILD=0; shift ;;
    --skip-clean) DO_CLEAN=0; shift ;;
    --skip-format) DO_FORMAT=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_ROOT" ]]; then
  OUTPUT_ROOT="${KAFKA_DIR}/output/first-produce-with-jfr"
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
fi

SERVER_CONFIG_PATH="${KAFKA_DIR}/${SERVER_CONFIG}"
RUN_DIR="${OUTPUT_ROOT%/}/${RUN_ID}"
mkdir -p "$RUN_DIR"

BROKER_LOG_DIR="${RUN_DIR}/broker-logs"
mkdir -p "$BROKER_LOG_DIR"

BROKER_JFR="${RUN_DIR}/broker.jfr"
PRODUCER_CSV="${RUN_DIR}/producer_latency_results.csv"
PRODUCER_STDOUT="${RUN_DIR}/producer_latency.stdout.log"
PRODUCER_STDERR="${RUN_DIR}/producer_latency.stderr.log"
BROKER_WAIT_LOG="${RUN_DIR}/broker_wait.log"
META_FILE="${RUN_DIR}/run-meta.txt"

if [[ ! -d "$KAFKA_DIR" ]]; then
  echo "Kafka directory not found: $KAFKA_DIR" >&2
  exit 1
fi
if [[ ! -f "$SERVER_CONFIG_PATH" ]]; then
  echo "Server config not found: $SERVER_CONFIG_PATH" >&2
  exit 1
fi
if [[ ! -f "$JFC_FILE" ]]; then
  echo "JFC file not found: $JFC_FILE" >&2
  exit 1
fi

BROKER_PID=""

find_broker_pid() {
  local pid=""
  pid="$(pgrep -f "kafka\\.Kafka.*${SERVER_CONFIG}" | head -n1 || true)"
  if [[ -n "$pid" ]]; then
    echo "$pid"
    return
  fi
  if command -v jps >/dev/null 2>&1; then
    pid="$(jps -l | awk '/kafka\.Kafka/{print $1; exit}')"
    echo "${pid:-}"
    return
  fi
  echo ""
}

wait_for_broker_ready() {
  local tries=60
  local i
  for i in $(seq 1 "$tries"); do
    if (cd "$KAFKA_DIR" && ./bin/kafka-broker-api-versions.sh --bootstrap-server "$BOOTSTRAP_SERVER" >/dev/null 2>&1); then
      return 0
    fi
    sleep 1
  done
  return 1
}

stop_broker() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    (cd "$KAFKA_DIR" && ./bin/kafka-server-stop.sh >/dev/null 2>&1) || true
    for _ in $(seq 1 20); do
      if ! kill -0 "$pid" 2>/dev/null; then
        return 0
      fi
      sleep 1
    done
    kill -TERM "$pid" >/dev/null 2>&1 || true
  fi
  return 0
}

cleanup() {
  local rc="$1"
  if [[ -n "$BROKER_PID" ]]; then
    stop_broker "$BROKER_PID" || true
  fi
  {
    echo "end_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "exit_code=${rc}"
  } >>"$META_FILE"
}

trap 'rc=$?; cleanup "$rc"; exit "$rc"' EXIT

{
  echo "run_id=${RUN_ID}"
  echo "run_dir=${RUN_DIR}"
  echo "start_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kafka_dir=${KAFKA_DIR}"
  echo "server_config=${SERVER_CONFIG_PATH}"
  echo "bootstrap_server=${BOOTSTRAP_SERVER}"
  echo "num_topics=${NUM_TOPICS}"
  echo "topic_prefix=${TOPIC_PREFIX}"
  echo "record_size=${RECORD_SIZE}"
  echo "acks=${ACKS}"
  echo "jfc_file=${JFC_FILE}"
  echo "broker_jfr=${BROKER_JFR}"
  echo "producer_csv=${PRODUCER_CSV}"
} >"$META_FILE"

if [[ "$DO_BUILD" -eq 1 ]]; then
  echo "Building Kafka jars..."
  (cd "$KAFKA_DIR" && ./gradlew jar -PscalaVersion=2.13.17)
fi

if [[ "$DO_CLEAN" -eq 1 ]]; then
  echo "Stopping existing broker (if running)..."
  EXISTING_BROKER_PID="$(find_broker_pid)"
  if [[ -n "$EXISTING_BROKER_PID" ]]; then
    stop_broker "$EXISTING_BROKER_PID" || true
  fi
  if pgrep -f "kafka\\.Kafka" >/dev/null 2>&1; then
    pkill -f "kafka\\.Kafka" >/dev/null 2>&1 || true
    sleep 2
  fi

  echo "Cleaning Kafka log.dirs from server config..."
  clean_storage_dirs "$SERVER_CONFIG_PATH"
fi

if [[ "$DO_FORMAT" -eq 1 ]]; then
  echo "Formatting storage..."
  KAFKA_CLUSTER_ID="$(discover_existing_cluster_id "$SERVER_CONFIG_PATH")"
  if [[ -n "$KAFKA_CLUSTER_ID" ]]; then
    echo "Reusing existing cluster.id from log.dirs meta.properties"
  else
    KAFKA_CLUSTER_ID="$(cd "$KAFKA_DIR" && ./bin/kafka-storage.sh random-uuid)"
  fi
  echo "cluster_id=${KAFKA_CLUSTER_ID}" >>"$META_FILE"
  (cd "$KAFKA_DIR" && ./bin/kafka-storage.sh format --ignore-formatted --standalone --cluster-id "$KAFKA_CLUSTER_ID" --config "$SERVER_CONFIG")
fi

JFR_OPTS="-XX:StartFlightRecording=name=kafka-broker,settings=${JFC_FILE},filename=${BROKER_JFR},dumponexit=true"
if [[ -n "$JFR_MAX_SIZE" ]]; then
  JFR_OPTS="${JFR_OPTS},maxsize=${JFR_MAX_SIZE}"
fi

echo "Starting broker with JFR..."
(
  cd "$KAFKA_DIR"
  LOG_DIR="$BROKER_LOG_DIR" \
  KAFKA_OPTS="${JFR_OPTS} ${KAFKA_OPTS:-}" \
    ./bin/kafka-server-start.sh -daemon "$SERVER_CONFIG"
)

BROKER_PID="$(find_broker_pid)"
if [[ -z "$BROKER_PID" ]]; then
  echo "Failed to detect broker PID" >&2
  exit 1
fi
echo "broker_pid=${BROKER_PID}" >>"$META_FILE"

echo "Waiting for broker readiness..."
if ! wait_for_broker_ready >"$BROKER_WAIT_LOG" 2>&1; then
  echo "Broker did not become ready in time. See $BROKER_WAIT_LOG" >&2
  exit 1
fi

echo "Running producer latency test..."
(
  cd "$KAFKA_DIR"
  ./bin/kafka-producer-latency.sh \
    --bootstrap-server "$BOOTSTRAP_SERVER" \
    --num-topics "$NUM_TOPICS" \
    --topic-prefix "$TOPIC_PREFIX" \
    --record-size "$RECORD_SIZE" \
    --acks "$ACKS" \
    --output "$PRODUCER_CSV"
) > >(tee "$PRODUCER_STDOUT") 2> >(tee "$PRODUCER_STDERR" >&2)

echo "Completed successfully."
echo "Artifacts saved to: $RUN_DIR"
echo "  - ${BROKER_JFR}"
echo "  - ${PRODUCER_CSV}"
echo "  - ${BROKER_LOG_DIR}"
echo "  - ${PRODUCER_STDOUT}"
echo "  - ${PRODUCER_STDERR}"
echo "  - ${META_FILE}"
