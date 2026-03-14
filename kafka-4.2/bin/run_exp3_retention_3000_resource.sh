#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KAFKA_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$KAFKA_HOME/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
ANALYSIS_DIR="$REPO_ROOT/analysis"
CLASS_DIR="$SCRIPT_DIR/.exp_classes"

BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-localhost:9092}"
NUM_TOPICS="${NUM_TOPICS:-3000}"
TOPIC_PREFIX="${TOPIC_PREFIX:-exp3_retention_topic_}"
RECORD_SIZE="${RECORD_SIZE:-1}"
ACKS="${ACKS:-1}"
RETRY_BACKOFF_MS="${RETRY_BACKOFF_MS:-1}"
RESOURCE_INTERVAL_SEC="${RESOURCE_INTERVAL_SEC:-0.2}"
RETENTION_MS="${RETENTION_MS:-1000}"
RETENTION_CHECK_INTERVAL_MS="${RETENTION_CHECK_INTERVAL_MS:-1000}"
SEGMENT_ROLL_MS="${SEGMENT_ROLL_MS:-1000}"
RETENTION_WAIT_TIMEOUT_SEC="${RETENTION_WAIT_TIMEOUT_SEC:-1800}"

DATE_TAG="$(date +%Y%m%d_%H%M%S)"
E2E_CSV="$ANALYSIS_DIR/exp3_retention3000_${DATE_TAG}_run_e2e.csv"
RESOURCE_CSV="$ANALYSIS_DIR/exp3_retention3000_${DATE_TAG}_run_resource.csv"
RESOURCE_PNG="$ANALYSIS_DIR/exp3_retention3000_${DATE_TAG}_cpu_memory.png"
RUN_LOG="$ANALYSIS_DIR/exp3_retention3000_${DATE_TAG}_run.log"

MONITOR_PID=""

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$RUN_LOG"
}

set_config() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done=0 }
    {
      if ($0 ~ "^[[:space:]]*" k "=") {
        print k "=" v
        done=1
      } else {
        print $0
      }
    }
    END {
      if (!done) print k "=" v
    }
  ' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
}

get_log_dirs() {
  awk -F= '
    $1 ~ /^[[:space:]]*log.dirs[[:space:]]*$/ {
      v=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$CONFIG"
}

reset_log_dirs() {
  local log_dirs_csv
  log_dirs_csv="$(get_log_dirs)"
  if [ -z "$log_dirs_csv" ]; then
    log "Failed to read log.dirs from $CONFIG"
    exit 1
  fi

  local d
  IFS=',' read -r -a dirs <<< "$log_dirs_csv"
  for d in "${dirs[@]}"; do
    d="${d#"${d%%[![:space:]]*}"}"
    d="${d%"${d##*[![:space:]]}"}"
    if [ -n "$d" ]; then
      rm -rf "$d"
      mkdir -p "$d"
    fi
  done
}

format_storage() {
  local cluster_id
  cluster_id="$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)"
  "$KAFKA_HOME/bin/kafka-storage.sh" format --standalone -t "$cluster_id" -c "$CONFIG" >/dev/null
}

stop_broker() {
  "$KAFKA_HOME/bin/kafka-server-stop.sh" >/dev/null 2>&1 || true
  sleep 3
  if pgrep -f "kafka.Kafka" >/dev/null 2>&1; then
    pkill -f "kafka.Kafka" >/dev/null 2>&1 || true
  fi
}

start_broker() {
  "$KAFKA_HOME/bin/kafka-server-start.sh" -daemon "$CONFIG"
  local wait_sec=0
  until nc -z localhost 9092 >/dev/null 2>&1; do
    sleep 1
    wait_sec=$((wait_sec + 1))
    if [ "$wait_sec" -ge 60 ]; then
      log "Broker start timeout"
      exit 1
    fi
  done
  sleep 2
}

broker_pid() {
  local pid
  pid="$(pgrep -f "kafka.Kafka.*server.properties" | head -n1 || true)"
  if [ -z "$pid" ]; then
    pid="$(pgrep -f "kafka.Kafka" | head -n1 || true)"
  fi
  echo "$pid"
}

monitor_resource() {
  local pid="$1"
  local outfile="$2"
  local interval="$3"
  local start_epoch
  start_epoch="$(date +%s)"
  echo "sample,elapsed_sec,cpu_percent,memory_rss_mb" > "$outfile"
  local sample=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    sample=$((sample + 1))
    local now cpu rss rss_mb elapsed
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    cpu="$(ps -p "$pid" -o %cpu= | awk '{print $1}')"
    rss="$(ps -p "$pid" -o rss= | awk '{print $1}')"
    if [ -z "$cpu" ]; then cpu="0"; fi
    if [ -z "$rss" ]; then rss="0"; fi
    rss_mb="$(awk -v v="$rss" 'BEGIN { printf "%.2f", v/1024.0 }')"
    echo "$sample,$elapsed,$cpu,$rss_mb" >> "$outfile"
    sleep "$interval"
  done
}

build_kafka() {
  log "Building Kafka (mandatory pre-step)"
  (
    cd "$KAFKA_HOME"
    ./gradlew --no-daemon -x test \
      :clients:jar \
      :core:jar \
      :tools:jar \
      :core:copyDependantLibs \
      :tools:copyDependantLibs
  )
}

build_java_cp() {
  local -a parts
  parts=(
    "$KAFKA_HOME/clients/build/libs/*"
    "$KAFKA_HOME/core/build/libs/*"
    "$KAFKA_HOME/tools/build/libs/*"
  )
  local d
  for d in "$KAFKA_HOME"/core/build/dependant-libs-* "$KAFKA_HOME"/tools/build/dependant-libs-*; do
    if [ -d "$d" ]; then
      parts+=("$d/*")
    fi
  done
  local IFS=:
  echo "${parts[*]}"
}

compile_helper() {
  mkdir -p "$CLASS_DIR"
  local cp
  cp="$(build_java_cp)"
  if [ ! -f "$CLASS_DIR/TopicProduceE2E.class" ] || [ "$SCRIPT_DIR/TopicProduceE2E.java" -nt "$CLASS_DIR/TopicProduceE2E.class" ]; then
    javac -cp "$cp" -d "$CLASS_DIR" "$SCRIPT_DIR/TopicProduceE2E.java"
  fi
  if [ ! -f "$CLASS_DIR/SimpleCsvCpuMemPlotter.class" ] || [ "$SCRIPT_DIR/SimpleCsvCpuMemPlotter.java" -nt "$CLASS_DIR/SimpleCsvCpuMemPlotter.class" ]; then
    javac -cp "$cp" -d "$CLASS_DIR" "$SCRIPT_DIR/SimpleCsvCpuMemPlotter.java"
  fi
}

verify_all_topics_produced() {
  local total_lines
  total_lines="$(awk 'NR>1{count++} END{print count+0}' "$E2E_CSV")"
  local error_lines
  error_lines="$(awk -F, 'NR>1 && $3=="ERROR"{count++} END{print count+0}' "$E2E_CSV")"

  if [ "$total_lines" -ne "$NUM_TOPICS" ]; then
    log "Produce count mismatch: expected=$NUM_TOPICS actual=$total_lines"
    return 1
  fi
  if [ "$error_lines" -ne 0 ]; then
    log "Produce errors found: $error_lines"
    return 1
  fi
  return 0
}

count_non_empty_topic_log_segments() {
  local log_dirs_csv="$1"
  local count=0
  local dir
  IFS=',' read -r -a dirs <<< "$log_dirs_csv"
  for dir in "${dirs[@]}"; do
    dir="${dir#"${dir%%[![:space:]]*}"}"
    dir="${dir%"${dir##*[![:space:]]}"}"
    if [ -d "$dir" ]; then
      local c
      c="$(find "$dir" -type f -path "*/${TOPIC_PREFIX}*-0/*.log" -size +0c 2>/dev/null | wc -l | awk '{print $1}')"
      count=$((count + c))
    fi
  done
  echo "$count"
}

wait_for_retention_completion() {
  local log_dirs_csv="$1"
  local timeout_sec="$2"
  local waited=0
  while true; do
    local remaining
    remaining="$(count_non_empty_topic_log_segments "$log_dirs_csv")"
    log "Retention progress: remaining non-empty log segments = $remaining"
    if [ "$remaining" -eq 0 ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$timeout_sec" ]; then
      log "Timeout waiting retention completion (${timeout_sec}s)"
      return 1
    fi
  done
}

plot_graph() {
  local run_cp
  run_cp="$CLASS_DIR:$(build_java_cp)"
  java -Djava.awt.headless=true -cp "$run_cp" SimpleCsvCpuMemPlotter \
    --csv "$RESOURCE_CSV" \
    --x-col "elapsed_sec" \
    --x-label "Elapsed Time (s)" \
    --cpu-col "cpu_percent" \
    --mem-col "memory_rss_mb" \
    --title "Experiment 3 Broker CPU and Memory (Retention 1s, 3000 topics)" \
    --out "$RESOURCE_PNG"
}

cleanup() {
  if [ -n "$MONITOR_PID" ]; then
    kill "$MONITOR_PID" >/dev/null 2>&1 || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
}

main() {
  mkdir -p "$ANALYSIS_DIR"
  : > "$RUN_LOG"
  trap cleanup EXIT

  build_kafka
  compile_helper

  log "Applying broker config for retention experiment"
  set_config "auto.create.topics.enable" "true"
  set_config "delete.topic.enable" "true"
  set_config "log.retention.ms" "$RETENTION_MS"
  set_config "log.retention.check.interval.ms" "$RETENTION_CHECK_INTERVAL_MS"
  set_config "log.roll.ms" "$SEGMENT_ROLL_MS"
  set_config "log.segment.delete.delay.ms" "1000"
  set_config "file.delete.delay.ms" "1000"

  log "Broker pre-step: stop broker"
  stop_broker
  log "Broker pre-step: delete/recreate log storage"
  reset_log_dirs
  log "Broker pre-step: format KRaft storage"
  format_storage
  log "Broker pre-step: start broker"
  start_broker

  local pid
  pid="$(broker_pid)"
  if [ -z "$pid" ]; then
    log "Broker PID not found"
    exit 1
  fi

  local log_dirs
  log_dirs="$(get_log_dirs)"
  if [ -z "$log_dirs" ]; then
    log "Failed to read log.dirs"
    exit 1
  fi

  log "Starting broker resource monitor: $RESOURCE_CSV"
  monitor_resource "$pid" "$RESOURCE_CSV" "$RESOURCE_INTERVAL_SEC" &
  MONITOR_PID="$!"

  log "Producing 1-byte messages to auto-create $NUM_TOPICS topics"
  local run_cp
  run_cp="$CLASS_DIR:$(build_java_cp)"
  java -cp "$run_cp" TopicProduceE2E \
    --bootstrap-server "$BOOTSTRAP_SERVER" \
    --num-topics "$NUM_TOPICS" \
    --topic-prefix "$TOPIC_PREFIX" \
    --record-size "$RECORD_SIZE" \
    --acks "$ACKS" \
    --retry-backoff-ms "$RETRY_BACKOFF_MS" \
    --output "$E2E_CSV"

  if ! verify_all_topics_produced; then
    log "Produce verification failed"
    exit 1
  fi

  log "Waiting until retention is complete for all produced topics"
  wait_for_retention_completion "$log_dirs" "$RETENTION_WAIT_TIMEOUT_SEC"

  cleanup
  MONITOR_PID=""

  log "Plotting broker CPU/Memory graph"
  plot_graph

  log "Experiment completed"
  log "E2E CSV: $E2E_CSV"
  log "Resource CSV: $RESOURCE_CSV"
  log "Resource Graph: $RESOURCE_PNG"
  log "Run Log: $RUN_LOG"
}

main "$@"
