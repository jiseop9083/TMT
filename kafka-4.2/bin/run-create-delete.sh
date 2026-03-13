#!/bin/bash

set -u
set -o pipefail

KAFKA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP_SERVER="localhost:9092"
PHASE2_DURATION_SEC=-1
INTERVAL_MS=200
CREATE_ONLY_COUNT=100
TOPIC_PREFIX="churn_topic_"
PARTITIONS=1
REPLICATION_FACTOR=1
PRODUCER_RECORD_SIZE=512
PRODUCER_ACKS=1
RETRY_BACKOFF_MS=1
PRODUCER_TOPIC_PREFIX="e2e_probe_topic_"
E2E_SAMPLE_INTERVAL_SEC=1
METADATA_SAMPLE_INTERVAL_SEC=1
RESOURCE_SAMPLE_INTERVAL_SEC=1
CONFIG_FILE="$KAFKA_HOME/config/server.properties"
LOG_DIR_OVERRIDE=""
JMX_PORT="${JMX_PORT:-9999}"
JMX_URL=""
OUTPUT_DIR=""
OUTPUT_DIR_EXPLICIT=0
REPEAT_COUNT=1
BROKER_STARTUP_TIMEOUT_SEC=60
BROKER_LOG_DIR=""
BROKER_LOG=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --bootstrap-server <host:port>     (default: localhost:9092)
  --create-only-count <count>        create_only 단계에서 생성할 토픽 수 (default: 100)
  --phase2-duration-sec <seconds>    extra run time after reaching --create-only-count (default: disabled)
  --interval-ms <ms>                 create/delete interval (default: 200)
  --start-delete-at <count>          (deprecated) same as --create-only-count
  --topic-prefix <prefix>            churn topic prefix (default: churn_topic_)
  --partitions <n>                   per-topic partitions (default: 1)
  --replication-factor <n>           per-topic replication-factor (default: 1)
  --producer-record-size <bytes>     e2e probe record size (default: 512)
  --producer-acks <acks>             e2e probe producer acks (default: 1)
  --retry-backoff-ms <ms>            producer/admin retry.backoff.ms (default: 1)
  --producer-topic-prefix <prefix>   e2e probe topic prefix (default: e2e_probe_topic_)
  --e2e-sample-interval-sec <sec>    (default: 1)
  --metadata-sample-interval-sec <sec> (default: 1)
  --resource-sample-interval-sec <sec> (default: 1)
  --config <server.properties>       (default: kafka config/server.properties)
  --log-dir <path>                   override disk target path for df
  --jmx-port <port>                  (default: env JMX_PORT or 9999)
  --jmx-url <url>                    default: service:jmx:rmi:///jndi/rmi://:<jmx-port>/jmxrmi
  --output-dir <path>                default: kafka-4.2/output/create-delete/<timestamp>
  --repeat <n>                       broker start->experiment->broker stop 사이클 반복 횟수 (default: 1)
  -h | --help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bootstrap-server)
      BOOTSTRAP_SERVER="$2"; shift 2 ;;
    --create-only-count)
      CREATE_ONLY_COUNT="$2"; shift 2 ;;
    --phase2-duration-sec)
      PHASE2_DURATION_SEC="$2"; shift 2 ;;
    --interval-ms)
      INTERVAL_MS="$2"; shift 2 ;;
    --start-delete-at)
      CREATE_ONLY_COUNT="$2"; shift 2 ;;
    --topic-prefix)
      TOPIC_PREFIX="$2"; shift 2 ;;
    --partitions)
      PARTITIONS="$2"; shift 2 ;;
    --replication-factor)
      REPLICATION_FACTOR="$2"; shift 2 ;;
    --producer-record-size)
      PRODUCER_RECORD_SIZE="$2"; shift 2 ;;
    --producer-acks)
      PRODUCER_ACKS="$2"; shift 2 ;;
    --retry-backoff-ms)
      RETRY_BACKOFF_MS="$2"; shift 2 ;;
    --producer-topic-prefix)
      PRODUCER_TOPIC_PREFIX="$2"; shift 2 ;;
    --e2e-sample-interval-sec)
      E2E_SAMPLE_INTERVAL_SEC="$2"; shift 2 ;;
    --metadata-sample-interval-sec)
      METADATA_SAMPLE_INTERVAL_SEC="$2"; shift 2 ;;
    --resource-sample-interval-sec)
      RESOURCE_SAMPLE_INTERVAL_SEC="$2"; shift 2 ;;
    --config)
      CONFIG_FILE="$2"; shift 2 ;;
    --log-dir)
      LOG_DIR_OVERRIDE="$2"; shift 2 ;;
    --jmx-port)
      JMX_PORT="$2"; shift 2 ;;
    --jmx-url)
      JMX_URL="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; OUTPUT_DIR_EXPLICIT=1; shift 2 ;;
    --repeat)
      REPEAT_COUNT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [ -z "$JMX_URL" ]; then
  JMX_URL="service:jmx:rmi:///jndi/rmi://:${JMX_PORT}/jmxrmi"
fi

if [ -z "$OUTPUT_DIR" ]; then
  TS="$(date '+%Y%m%d_%H%M%S')"
  OUTPUT_DIR="$KAFKA_HOME/output/create-delete/$TS"
fi

if ! [[ "$REPEAT_COUNT" =~ ^[0-9]+$ ]] || [ "$REPEAT_COUNT" -lt 1 ]; then
  echo "--repeat must be a positive integer" >&2
  exit 1
fi

if [ "$REPEAT_COUNT" -gt 1 ]; then
  SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  echo "Running create/delete cycle $REPEAT_COUNT times."
  i=1
  while [ "$i" -le "$REPEAT_COUNT" ]; do
    if [ "$OUTPUT_DIR_EXPLICIT" -eq 1 ]; then
      ITER_DIR="${OUTPUT_DIR}_$(printf '%03d' "$i")"
    else
      ITER_TS="$(date '+%Y%m%d_%H%M%S')"
      ITER_DIR="$KAFKA_HOME/output/create-delete/$ITER_TS"
      if [ -e "$ITER_DIR" ]; then
        ITER_DIR="${ITER_DIR}_$(printf '%03d' "$i")"
      fi
    fi
    echo "[$i/$REPEAT_COUNT] output-dir: $ITER_DIR"
    "$SCRIPT_PATH" \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --create-only-count "$CREATE_ONLY_COUNT" \
      --phase2-duration-sec "$PHASE2_DURATION_SEC" \
      --interval-ms "$INTERVAL_MS" \
      --topic-prefix "$TOPIC_PREFIX" \
      --partitions "$PARTITIONS" \
      --replication-factor "$REPLICATION_FACTOR" \
      --producer-record-size "$PRODUCER_RECORD_SIZE" \
      --producer-acks "$PRODUCER_ACKS" \
      --retry-backoff-ms "$RETRY_BACKOFF_MS" \
      --producer-topic-prefix "$PRODUCER_TOPIC_PREFIX" \
      --e2e-sample-interval-sec "$E2E_SAMPLE_INTERVAL_SEC" \
      --metadata-sample-interval-sec "$METADATA_SAMPLE_INTERVAL_SEC" \
      --resource-sample-interval-sec "$RESOURCE_SAMPLE_INTERVAL_SEC" \
      --config "$CONFIG_FILE" \
      --log-dir "$LOG_DIR_OVERRIDE" \
      --jmx-port "$JMX_PORT" \
      --jmx-url "$JMX_URL" \
      --output-dir "$ITER_DIR" \
      --repeat 1
    i=$((i + 1))
  done
  exit 0
fi

BROKER_LOG_DIR="$OUTPUT_DIR/logs"
BROKER_LOG="$BROKER_LOG_DIR/broker.log"

mkdir -p "$OUTPUT_DIR/tmp"
mkdir -p "$BROKER_LOG_DIR"

E2E_CSV="$OUTPUT_DIR/e2e_latency.csv"
BROKER_META_CSV="$OUTPUT_DIR/broker_metadata_update.csv"
BROKER_META_SNAPSHOT="$OUTPUT_DIR/tmp/broker_metadata_publisher_metrics.csv"
RESOURCE_CSV="$OUTPUT_DIR/resource_usage.csv"
TOPIC_OPS_CSV="$OUTPUT_DIR/topic_ops.csv"
EVENTS_CSV="$OUTPUT_DIR/events.csv"
TOPIC_CREATE_REQUESTS_CSV="$OUTPUT_DIR/topic_create_requests.csv"
TOPIC_DELETE_REQUESTS_CSV="$OUTPUT_DIR/topic_delete_requests.csv"
RUN_LOG="$OUTPUT_DIR/run.log"
STOP_FILE="$OUTPUT_DIR/.stop"
PHASE_FILE="$OUTPUT_DIR/.phase"
BROKER_STARTED_BY_SCRIPT=0
BROKER_STOPPED=0
BROKER_PID=""
RUNNER_PID=""
LOGGER_PID=""

touch "$RUN_LOG"

log() {
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $msg" | tee -a "$RUN_LOG"
}

bootstrap_host_port() {
  local first
  first="${BOOTSTRAP_SERVER%%,*}"
  BOOTSTRAP_HOST="${first%%:*}"
  BOOTSTRAP_PORT="${first##*:}"
}

is_port_open() {
  if command -v nc >/dev/null 2>&1; then
    nc -z "$BOOTSTRAP_HOST" "$BOOTSTRAP_PORT" >/dev/null 2>&1
    return $?
  fi
  (echo > "/dev/tcp/$BOOTSTRAP_HOST/$BOOTSTRAP_PORT") >/dev/null 2>&1
}

stop_broker() {
  if [ "$BROKER_STOPPED" -eq 1 ] || [ "$BROKER_STARTED_BY_SCRIPT" -ne 1 ]; then
    return 0
  fi
  BROKER_STOPPED=1
  log "Stopping Kafka broker..."
  "$KAFKA_HOME/bin/kafka-server-stop.sh" >/dev/null 2>&1 || true
  sleep 3
  if [ -n "$BROKER_PID" ] && kill -0 "$BROKER_PID" >/dev/null 2>&1; then
    kill "$BROKER_PID" >/dev/null 2>&1 || true
    sleep 2
  fi
  log "Kafka broker stopped."
}

wait_for_broker_ready() {
  local waited=0
  while [ "$waited" -lt "$BROKER_STARTUP_TIMEOUT_SEC" ]; do
    if is_port_open; then
      if "$KAFKA_HOME/bin/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP_SERVER" --list >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

has_meta_properties() {
  local d
  local trimmed
  IFS=',' read -r -a _log_dirs <<< "$LOG_DIRS_RAW"
  for d in "${_log_dirs[@]}"; do
    trimmed="$(echo "$d" | tr -d '[:space:]')"
    if [ -r "$trimmed/meta.properties" ]; then
      return 0
    fi
  done
  return 1
}

format_storage_if_needed() {
  if has_meta_properties; then
    log "Found existing KRaft meta.properties. Skip storage format."
    return 0
  fi

  log "No readable meta.properties found. Formatting KRaft storage..."
  local cluster_id
  cluster_id="$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)"
  if ! "$KAFKA_HOME/bin/kafka-storage.sh" format --standalone -t "$cluster_id" -c "$CONFIG_FILE" >> "$RUN_LOG" 2>&1; then
    log "ERROR: Failed to format KRaft storage."
    exit 1
  fi
  log "KRaft storage formatted. cluster.id=$cluster_id"
}

clear_log_dirs_before_start() {
  local d
  local trimmed
  local target
  IFS=',' read -r -a _log_dirs <<< "$LOG_DIRS_RAW"
  for d in "${_log_dirs[@]}"; do
    trimmed="$(echo "$d" | tr -d '[:space:]')"
    if [ -z "$trimmed" ]; then
      continue
    fi

    case "$trimmed" in
      /|.|..)
        log "ERROR: Refusing to clear unsafe log.dirs path: $trimmed"
        exit 1
        ;;
    esac

    target="$trimmed"
    mkdir -p "$target"
    log "Clearing broker log.dirs path before start: $target"
    rm -rf "$target"
    mkdir -p "$target"
  done
}

start_broker() {
  bootstrap_host_port

  if is_port_open; then
    log "ERROR: bootstrap endpoint $BOOTSTRAP_SERVER is already in use. Stop existing broker or use another --bootstrap-server."
    exit 1
  fi

  clear_log_dirs_before_start
  format_storage_if_needed

  log "Starting Kafka broker..."
  local broker_kafka_opts
  broker_kafka_opts="-Dkafka.metadata.publisher.metrics.file=$BROKER_META_SNAPSHOT"
  if [ -n "${KAFKA_OPTS:-}" ]; then
    broker_kafka_opts="$broker_kafka_opts $KAFKA_OPTS"
  fi
  KAFKA_OPTS="$broker_kafka_opts" JMX_PORT="$JMX_PORT" \
    "$KAFKA_HOME/bin/kafka-server-start.sh" "$CONFIG_FILE" > "$BROKER_LOG" 2>&1 &
  BROKER_PID=$!
  BROKER_STARTED_BY_SCRIPT=1
  log "Broker PID: $BROKER_PID"
  log "Broker log: $BROKER_LOG"

  if ! wait_for_broker_ready; then
    log "ERROR: Broker did not become ready within ${BROKER_STARTUP_TIMEOUT_SEC}s"
    log "Check broker log: $BROKER_LOG"
    exit 1
  fi

  log "Kafka broker is ready."
}

now_epoch_ms() {
  perl -MTime::HiRes=time -e 'printf("%.0f", time()*1000)'
}

now_iso8601_ms() {
  perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time(); $s=int($t); $ms=int(($t-$s)*1000); print strftime("%Y-%m-%dT%H:%M:%S", localtime($s)).sprintf(".%03d", $ms);'
}

calc_elapsed_ms() {
  local start_ms="$1"
  local end_ms="$2"
  awk -v s="$start_ms" -v e="$end_ms" 'BEGIN { printf "%.3f", (e - s) }'
}

phase_for_created_count() {
  local created_count="$1"
  if [ "$created_count" -lt "$CREATE_ONLY_COUNT" ]; then
    echo "create_only"
  else
    echo "create_delete"
  fi
}

cleanup() {
  touch "$STOP_FILE"
  if [ -n "${RUNNER_PID:-}" ] && kill -0 "$RUNNER_PID" >/dev/null 2>&1; then kill "$RUNNER_PID" >/dev/null 2>&1 || true; fi
  if [ -n "${LOGGER_PID:-}" ] && kill -0 "$LOGGER_PID" >/dev/null 2>&1; then kill "$LOGGER_PID" >/dev/null 2>&1 || true; fi
  if [ -n "${E2E_PID:-}" ]; then kill "$E2E_PID" >/dev/null 2>&1 || true; fi
  if [ -n "${META_PID:-}" ]; then kill "$META_PID" >/dev/null 2>&1 || true; fi
  if [ -n "${RESOURCE_PID:-}" ]; then kill "$RESOURCE_PID" >/dev/null 2>&1 || true; fi
  wait >/dev/null 2>&1 || true
  stop_broker
}

trap cleanup EXIT INT TERM

compile_kafka() {
  local gradlew="$KAFKA_HOME/gradlew"
  local normalized_java_home java_cmd inferred_java_home

  if [ ! -f "$gradlew" ]; then
    log "ERROR: gradlew not found at $gradlew"
    exit 1
  fi

  if [ ! -x "$gradlew" ]; then
    chmod +x "$gradlew" >/dev/null 2>&1 || true
  fi

  # Handle common misconfiguration where JAVA_HOME points to ".../bin".
  if [ -n "${JAVA_HOME:-}" ]; then
    normalized_java_home="$(printf '%s' "$JAVA_HOME" | sed -E 's#[/\\]+bin$##')"
    if [ "$normalized_java_home" != "$JAVA_HOME" ]; then
      log "JAVA_HOME points to a bin directory. Normalizing to: $normalized_java_home"
      JAVA_HOME="$normalized_java_home"
      export JAVA_HOME
    fi
  fi

  # In Git Bash/Cygwin, convert Windows-style JAVA_HOME if needed.
  if [ -n "${JAVA_HOME:-}" ] && [ ! -x "$JAVA_HOME/bin/java" ] && command -v cygpath >/dev/null 2>&1; then
    normalized_java_home="$(cygpath -u "$JAVA_HOME" 2>/dev/null || true)"
    if [ -n "$normalized_java_home" ] && [ -x "$normalized_java_home/bin/java" ]; then
      log "Converted JAVA_HOME to POSIX path for current shell: $normalized_java_home"
      JAVA_HOME="$normalized_java_home"
      export JAVA_HOME
    fi
  fi

  # Fallback: infer JAVA_HOME from java on PATH.
  if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    java_cmd="$(command -v java || true)"
    if [ -n "$java_cmd" ]; then
      inferred_java_home="$(cd "$(dirname "$java_cmd")/.." 2>/dev/null && pwd || true)"
      if [ -n "$inferred_java_home" ] && [ -x "$inferred_java_home/bin/java" ]; then
        log "Using JAVA_HOME inferred from PATH: $inferred_java_home"
        JAVA_HOME="$inferred_java_home"
        export JAVA_HOME
      fi
    fi
  fi

  if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    log "ERROR: JAVA_HOME is invalid (${JAVA_HOME:-unset}). Set it to your JDK root (not the bin directory)."
    exit 1
  fi

  log "Compiling Kafka artifacts (:core:jar :clients:jar, -x test)..."
  if ! (cd "$KAFKA_HOME" && ./gradlew --no-daemon :core:jar :clients:jar -x test >> "$RUN_LOG" 2>&1); then
    log "ERROR: Kafka compile failed."
    exit 1
  fi
  log "Kafka compile completed."
}

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

LOG_DIR=""
LOG_DIRS_RAW=""
if [ -n "$LOG_DIR_OVERRIDE" ]; then
  LOG_DIR="$LOG_DIR_OVERRIDE"
  LOG_DIRS_RAW="$LOG_DIR_OVERRIDE"
else
  LOG_DIRS_RAW="$(awk -F= '/^[[:space:]]*log\.dirs[[:space:]]*=/{print $2; exit}' "$CONFIG_FILE")"
  LOG_DIRS_RAW="$(echo "$LOG_DIRS_RAW" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  LOG_DIR="$(echo "$LOG_DIRS_RAW" | tr -d '[:space:]')"
  LOG_DIR="${LOG_DIR%%,*}"
fi
if [ -z "$LOG_DIR" ]; then
  LOG_DIR="/tmp"
fi
if [ -z "$LOG_DIRS_RAW" ]; then
  LOG_DIRS_RAW="$LOG_DIR"
fi

cat > "$OUTPUT_DIR/params.env" <<PARAMS
BOOTSTRAP_SERVER=$BOOTSTRAP_SERVER
CREATE_ONLY_COUNT=$CREATE_ONLY_COUNT
PHASE2_DURATION_SEC=$PHASE2_DURATION_SEC
INTERVAL_MS=$INTERVAL_MS
TOPIC_PREFIX=$TOPIC_PREFIX
PARTITIONS=$PARTITIONS
REPLICATION_FACTOR=$REPLICATION_FACTOR
PRODUCER_RECORD_SIZE=$PRODUCER_RECORD_SIZE
PRODUCER_ACKS=$PRODUCER_ACKS
RETRY_BACKOFF_MS=$RETRY_BACKOFF_MS
PRODUCER_TOPIC_PREFIX=$PRODUCER_TOPIC_PREFIX
E2E_SAMPLE_INTERVAL_SEC=$E2E_SAMPLE_INTERVAL_SEC
METADATA_SAMPLE_INTERVAL_SEC=$METADATA_SAMPLE_INTERVAL_SEC
RESOURCE_SAMPLE_INTERVAL_SEC=$RESOURCE_SAMPLE_INTERVAL_SEC
CONFIG_FILE=$CONFIG_FILE
LOG_DIR=$LOG_DIR
LOG_DIRS_RAW=$LOG_DIRS_RAW
JMX_PORT=$JMX_PORT
JMX_URL=$JMX_URL
OUTPUT_DIR=$OUTPUT_DIR
BROKER_LOG=$BROKER_LOG
PARAMS

printf "timestamp,epoch_ms,event,created_count,deleted_count,phase,note\n" > "$EVENTS_CSV"
printf "timestamp,epoch_ms,topic,phase,e2e_latency_ms,broker_metadata_update_ms,status,error\n" > "$E2E_CSV"
printf "timestamp,sample_id,phase,metric_name,metric_object,count,mean,p50,p95,p99,max,status,error\n" > "$BROKER_META_CSV"
printf "timestamp,epoch_ms,sample_id,phase,broker_pid,open_fd_count,cpu_pct,rss_kb,vsz_kb,heap_used_kb,heap_committed_kb,storage_kb,topic_dir_count,segment_file_count\n" > "$RESOURCE_CSV"
printf "timestamp,epoch_ms,op,topic,idx,phase,elapsed_ms,status,error\n" > "$TOPIC_OPS_CSV"
printf "seq,topic_name,request_latency_us,e2e_latency_us,on_metadata_duration_us,produce_duration_us,status,error\n" > "$TOPIC_CREATE_REQUESTS_CSV"
printf "timestamp,epoch_ms,topic,phase,delete_latency_ms,broker_metadata_update_ms,status,error\n" > "$TOPIC_DELETE_REQUESTS_CSV"

compile_kafka
start_broker

METRIC_NAME="BrokerMetadataPublisherOnMetadataUpdateTimeUs"
METRIC_OBJECT="kafka.server:type=BrokerMetadataPublisher,name=OnMetadataUpdateTimeUs"
log "Using in-broker metadata timing snapshot file: $BROKER_META_SNAPSHOT"

# Ensure probe topic exists.
PROBE_TOPIC="${PRODUCER_TOPIC_PREFIX}1"
"$KAFKA_HOME/bin/kafka-topics.sh" \
  --bootstrap-server "$BOOTSTRAP_SERVER" \
  --create \
  --topic "$PROBE_TOPIC" \
  --partitions "$PARTITIONS" \
  --replication-factor "$REPLICATION_FACTOR" \
  --if-not-exists >/dev/null 2>&1 || true

echo "create_only" > "$PHASE_FILE"

current_phase() {
  if [ -f "$PHASE_FILE" ]; then
    cat "$PHASE_FILE"
  else
    echo "create_only"
  fi
}

sample_e2e_loop() {
  local sample_id=0
  local tmp_csv="$OUTPUT_DIR/tmp/e2e_probe.csv"

  while [ ! -f "$STOP_FILE" ]; do
    sample_id=$((sample_id + 1))
    local ts epoch_ms phase latency status err
    ts="$(now_iso8601_ms)"
    epoch_ms="$(now_epoch_ms)"
    phase="$(current_phase)"
    status="ok"
    err=""

    "$KAFKA_HOME/bin/kafka-producer-latency.sh" \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --num-topics 1 \
      --topic-prefix "$PRODUCER_TOPIC_PREFIX" \
      --record-size "$PRODUCER_RECORD_SIZE" \
      --acks "$PRODUCER_ACKS" \
      --retry-backoff-ms "$RETRY_BACKOFF_MS" \
      --output "$tmp_csv" >/dev/null 2>&1 || {
        status="error"
        err="producer-latency-command-failed"
      }

    latency=""
    if [ "$status" = "ok" ] && [ -f "$tmp_csv" ]; then
      latency="$(awk -F, 'NR==2 {print $3}' "$tmp_csv")"
      case "$latency" in
        "")
          status="error"
          err="latency-parse-failed"
          ;;
        ERROR|error)
          status="error"
          err="producer-send-failed"
          ;;
        *[!0-9.]*)
          status="error"
          err="latency-not-numeric"
          ;;
      esac
    fi

    printf "%s,%s,%s,%s,%s,%s,%s\n" \
      "$ts" "$epoch_ms" "$sample_id" "$phase" "${latency:-}" "$status" "${err//,/;}" >> "$E2E_CSV"

    sleep "$E2E_SAMPLE_INTERVAL_SEC"
  done
}

sample_metadata_loop() {
  local sample_id=0

  while [ ! -f "$STOP_FILE" ]; do
    sample_id=$((sample_id + 1))
    local ts phase status err row
    local last_update_ms
    local count mean p50 p95 p99 max
    ts="$(now_iso8601_ms)"
    phase="$(current_phase)"
    status="ok"
    err=""
    count=""; mean=""; p50=""; p95=""; p99=""; max=""
    last_update_ms=""

    if [ ! -s "$BROKER_META_SNAPSHOT" ]; then
      status="error"
      err="snapshot-file-empty-or-missing"
    else
      row="$(tail -n 1 "$BROKER_META_SNAPSHOT")"
      IFS=',' read -r last_update_ms count mean p50 p95 p99 max <<< "$row"
      if [ -z "$count" ] || [ -z "$mean" ]; then
        status="error"
        err="snapshot-parse-failed"
      fi
    fi

    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$ts" "$sample_id" "$phase" "$METRIC_NAME" "$METRIC_OBJECT" \
      "${count//,/;}" "${mean//,/;}" "${p50//,/;}" "${p95//,/;}" "${p99//,/;}" "${max//,/;}" \
      "$status" "${err//,/;}" >> "$BROKER_META_CSV"

    sleep "$METADATA_SAMPLE_INTERVAL_SEC"
  done
}

append_err() {
  local cur="$1"
  local add="$2"
  if [ -z "$cur" ]; then
    echo "$add"
  else
    echo "$cur;$add"
  fi
}

count_open_fds() {
  local pid="$1"
  if ! command -v lsof >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  if [ -z "$pid" ] || ! kill -0 "$pid" >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  lsof -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
}

count_topic_dirs() {
  local base_dir="$1"
  if [ ! -d "$base_dir" ]; then
    echo "0"
    return 0
  fi
  find "$base_dir" -maxdepth 1 -type d -name "${TOPIC_PREFIX}*" 2>/dev/null | wc -l | tr -d ' '
}

count_segment_files() {
  local base_dir="$1"
  if [ ! -d "$base_dir" ]; then
    echo "0"
    return 0
  fi
  find "$base_dir" -type f \( -name '*.log' -o -name '*.index' -o -name '*.timeindex' \) 2>/dev/null | wc -l | tr -d ' '
}

measure_storage_kb() {
  local base_dir="$1"
  if [ ! -d "$base_dir" ]; then
    echo "0"
    return 0
  fi
  du -sk "$base_dir" 2>/dev/null | awk '{print $1}'
}

measure_ps_stats() {
  local pid="$1"
  if ! command -v ps >/dev/null 2>&1; then
    echo ",,"
    return 0
  fi
  local row
  row="$(ps -p "$pid" -o %cpu=,rss=,vsz= 2>/dev/null | awk 'NR==1{print $1","$2","$3}')"
  if [ -z "$row" ]; then
    echo ",,"
  else
    echo "$row"
  fi
}

measure_heap_kb() {
  local pid="$1"
  if ! command -v jstat >/dev/null 2>&1; then
    echo ","
    return 0
  fi
  local gc_row
  gc_row="$(jstat -gc "$pid" 2>/dev/null | awk 'NR==2{print $1","$2","$3","$4","$5","$6","$7","$8}')"
  if [ -z "$gc_row" ]; then
    echo ","
    return 0
  fi
  local s0c s1c s0u s1u ec eu oc ou
  IFS=',' read -r s0c s1c s0u s1u ec eu oc ou <<< "$gc_row"
  awk -v s0c="${s0c:-0}" -v s1c="${s1c:-0}" -v ec="${ec:-0}" -v oc="${oc:-0}" \
      -v s0u="${s0u:-0}" -v s1u="${s1u:-0}" -v eu="${eu:-0}" -v ou="${ou:-0}" \
      'BEGIN{
        committed=s0c+s1c+ec+oc;
        used=s0u+s1u+eu+ou;
        printf "%.0f,%.0f", used, committed;
      }'
}

sample_resource_loop() {
  local sample_id=0

  while [ ! -f "$STOP_FILE" ]; do
    sample_id=$((sample_id + 1))
    local ts epoch_ms phase
    local broker_pid fd_count ps_stats cpu_pct rss_kb vsz_kb heap_stats heap_used_kb heap_committed_kb
    local storage_kb topic_dir_count segment_file_count
    ts="$(now_iso8601_ms)"
    epoch_ms="$(now_epoch_ms)"
    phase="$(current_phase)"

    broker_pid="$BROKER_PID"
    fd_count="$(count_open_fds "$broker_pid")"
    ps_stats="$(measure_ps_stats "$broker_pid")"
    IFS=',' read -r cpu_pct rss_kb vsz_kb <<< "$ps_stats"
    heap_stats="$(measure_heap_kb "$broker_pid")"
    IFS=',' read -r heap_used_kb heap_committed_kb <<< "$heap_stats"
    storage_kb="$(measure_storage_kb "$LOG_DIR")"
    topic_dir_count="$(count_topic_dirs "$LOG_DIR")"
    segment_file_count="$(count_segment_files "$LOG_DIR")"

    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$ts" "$epoch_ms" "$sample_id" "$phase" \
      "${broker_pid//,/;}" "${fd_count//,/;}" "${cpu_pct//,/;}" "${rss_kb//,/;}" "${vsz_kb//,/;}" \
      "${heap_used_kb//,/;}" "${heap_committed_kb//,/;}" \
      "${storage_kb//,/;}" "${topic_dir_count//,/;}" "${segment_file_count//,/;}" >> "$RESOURCE_CSV"

    sleep "$RESOURCE_SAMPLE_INTERVAL_SEC"
  done
}

log "Starting create/delete experiment"
log "Output directory: $OUTPUT_DIR"
log "Bootstrap server: $BOOTSTRAP_SERVER"
log "Create-only topic count: $CREATE_ONLY_COUNT"
log "Phase2 duration(after create-only): ${PHASE2_DURATION_SEC}s"
log "Create/Delete interval: ${INTERVAL_MS}ms"
log "Client retry.backoff.ms: ${RETRY_BACKOFF_MS}ms"
log "Metadata metric source file: $BROKER_META_SNAPSHOT"
log "JMX URL: $JMX_URL"

printf "%s,%s,experiment_start,0,0,create_only,-\n" "$(now_iso8601_ms)" "$(now_epoch_ms)" >> "$EVENTS_CSV"

sample_metadata_loop &
META_PID=$!
sample_resource_loop &
RESOURCE_PID=$!

CLIENT_JAR="$(ls "$KAFKA_HOME"/clients/build/libs/kafka-clients-*.jar 2>/dev/null | head -n 1)"
if [ -z "$CLIENT_JAR" ]; then
  log "ERROR: kafka-clients jar not found under $KAFKA_HOME/clients/build/libs"
  exit 1
fi

RUNNER_CP="$OUTPUT_DIR/tmp:$CLIENT_JAR"
for dep_dir in \
  "$KAFKA_HOME"/core/build/dependant-libs-* \
  "$KAFKA_HOME"/tools/build/dependant-libs-* \
  "$KAFKA_HOME"/trogdor/build/dependant-libs-* \
  "$KAFKA_HOME"/shell/build/dependant-libs-*; do
  if [ -d "$dep_dir" ]; then
    RUNNER_CP="$RUNNER_CP:$dep_dir/*"
  fi
done

if ! javac -cp "$CLIENT_JAR" -d "$OUTPUT_DIR/tmp" "$KAFKA_HOME/bin/TopicChurnRunner.java" >> "$RUN_LOG" 2>&1; then
  log "ERROR: Failed to compile TopicChurnRunner.java"
  exit 1
fi

RUNNER_PIPE="$OUTPUT_DIR/tmp/topic_churn_runner.pipe"
rm -f "$RUNNER_PIPE"
mkfifo "$RUNNER_PIPE"

while IFS= read -r line; do
  log "$line"
done < "$RUNNER_PIPE" &
LOGGER_PID=$!

java -cp "$RUNNER_CP" TopicChurnRunner \
  "$BOOTSTRAP_SERVER" \
  "$CREATE_ONLY_COUNT" \
  "$PHASE2_DURATION_SEC" \
  "$INTERVAL_MS" \
  "$TOPIC_PREFIX" \
  "$PARTITIONS" \
  "$REPLICATION_FACTOR" \
  "$RETRY_BACKOFF_MS" \
  "$TOPIC_OPS_CSV" \
  "$EVENTS_CSV" \
  "$PHASE_FILE" \
  "$TOPIC_CREATE_REQUESTS_CSV" \
  "$E2E_CSV" \
  "$TOPIC_DELETE_REQUESTS_CSV" \
  "$BROKER_LOG" > "$RUNNER_PIPE" 2>&1 &
RUNNER_PID=$!

wait "$RUNNER_PID"
runner_rc=$?
RUNNER_PID=""
wait "$LOGGER_PID" >/dev/null 2>&1 || true
LOGGER_PID=""
rm -f "$RUNNER_PIPE"

if [ "$runner_rc" -ne 0 ]; then
  log "ERROR: Topic churn runner failed."
  exit 1
fi

created_count="$(tail -n 1 "$EVENTS_CSV" | awk -F, '{print $4}')"
deleted_count="$(tail -n 1 "$EVENTS_CSV" | awk -F, '{print $5}')"

log "Experiment finished"
log "Created topics: $created_count"
log "Delete requests (successful): $deleted_count"
log "Stopping samplers"

touch "$STOP_FILE"
wait "$META_PID" "$RESOURCE_PID" >/dev/null 2>&1 || true
stop_broker

log "Artifacts:"
log "  - $E2E_CSV"
log "  - $BROKER_META_CSV"
log "  - $RESOURCE_CSV"
log "  - $TOPIC_OPS_CSV"
log "  - $TOPIC_CREATE_REQUESTS_CSV"
log "  - $TOPIC_DELETE_REQUESTS_CSV"
log "  - $EVENTS_CSV"
log "  - $RUN_LOG"
log "  - $BROKER_LOG"
