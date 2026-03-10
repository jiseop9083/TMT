#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KAFKA_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$KAFKA_HOME/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
ANALYSIS_DIR="$REPO_ROOT/analysis"
CLASS_DIR="$SCRIPT_DIR/.exp_classes"

BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-localhost:9092}"
NUM_TOPICS="${NUM_TOPICS:-1500}"
TOPIC_PREFIX="${TOPIC_PREFIX:-topic_}"
RECORD_SIZE="1"
ACKS="${ACKS:-1}"
RETRY_BACKOFF_MS="${RETRY_BACKOFF_MS:-0.5}"
RESOURCE_INTERVAL_SEC="${RESOURCE_INTERVAL_SEC:-0.2}"

DATE_TAG="$(date +%Y%m%d)"
E2E_CSV="$ANALYSIS_DIR/exp1_java_pre0_autocreate1500_${DATE_TAG}_run_e2e.csv"
RESOURCE_CSV="$ANALYSIS_DIR/exp1_java_pre0_autocreate1500_${DATE_TAG}_run_resource.csv"
E2E_PNG="$ANALYSIS_DIR/exp1_java_pre0_autocreate1500_${DATE_TAG}_e2e.png"
MEM_PNG="$ANALYSIS_DIR/exp1_java_pre0_autocreate1500_${DATE_TAG}_memory.png"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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

compile_helper() {
  mkdir -p "$CLASS_DIR"
  local cp
  cp="$(build_java_cp)"
  if [ ! -f "$CLASS_DIR/TopicProduceE2E.class" ] || [ "$SCRIPT_DIR/TopicProduceE2E.java" -nt "$CLASS_DIR/TopicProduceE2E.class" ]; then
    javac -cp "$cp" -d "$CLASS_DIR" "$SCRIPT_DIR/TopicProduceE2E.java"
  fi
  if [ ! -f "$CLASS_DIR/SimpleCsvLinePlotter.class" ] || [ "$SCRIPT_DIR/SimpleCsvLinePlotter.java" -nt "$CLASS_DIR/SimpleCsvLinePlotter.class" ]; then
    javac -cp "$cp" -d "$CLASS_DIR" "$SCRIPT_DIR/SimpleCsvLinePlotter.java"
  fi
  if [ ! -f "$CLASS_DIR/SimpleCsvCpuMemPlotter.class" ] || [ "$SCRIPT_DIR/SimpleCsvCpuMemPlotter.java" -nt "$CLASS_DIR/SimpleCsvCpuMemPlotter.class" ]; then
    javac -cp "$cp" -d "$CLASS_DIR" "$SCRIPT_DIR/SimpleCsvCpuMemPlotter.java"
  fi
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

plot_graphs() {
  local run_cp
  run_cp="$CLASS_DIR:$(build_java_cp)"
  java -Djava.awt.headless=true -cp "$run_cp" SimpleCsvLinePlotter \
    --csv "$E2E_CSV" \
    --x-col "topic_num" \
    --y-col "latency_ms" \
    --title "Experiment 1 Produce E2E" \
    --x-label "experiment count" \
    --y-label "E2E (ms)" \
    --style "scatter" \
    --y-min "0" \
    --y-max "150" \
    --color "#2F6BFF" \
    --out "$E2E_PNG"

  java -Djava.awt.headless=true -cp "$run_cp" SimpleCsvCpuMemPlotter \
    --csv "$RESOURCE_CSV" \
    --x-col "sample" \
    --cpu-col "cpu_percent" \
    --mem-col "memory_rss_mb" \
    --title "Experiment 1 Broker CPU and Memory" \
    --out "$MEM_PNG"
}

main() {
  mkdir -p "$ANALYSIS_DIR"

  log "Applying common experiment configs"
  set_config "auto.create.topics.enable" "true"
  set_config "log.segment.delete.delay.ms" "1000"
  set_config "file.delete.delay.ms" "1000"

  log "Restarting broker to apply config"
  stop_broker
  log "Resetting log.dirs (delete + recreate)"
  reset_log_dirs
  log "Formatting KRaft storage"
  format_storage
  start_broker

  local pid
  pid="$(broker_pid)"
  if [ -z "$pid" ]; then
    log "Broker PID not found"
    exit 1
  fi

  compile_helper

  log "Starting broker resource monitor: $RESOURCE_CSV"
  monitor_resource "$pid" "$RESOURCE_CSV" "$RESOURCE_INTERVAL_SEC" &
  local monitor_pid=$!

  # Kafka retry.backoff.ms is integer ms; 0.5ms is rounded to 1ms in helper.
  log "Running experiment 1 producer loop"
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

  kill "$monitor_pid" >/dev/null 2>&1 || true
  wait "$monitor_pid" 2>/dev/null || true

  log "Plotting E2E and memory graphs"
  plot_graphs

  log "Experiment 1 completed"
  log "E2E CSV: $E2E_CSV"
  log "Resource CSV: $RESOURCE_CSV"
  log "E2E plot: $E2E_PNG"
  log "Memory plot: $MEM_PNG"
}

main "$@"
