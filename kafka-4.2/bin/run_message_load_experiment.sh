#!/usr/bin/env bash
# Message Load Experiment
#
# Architecture:
#   - N load producers (configurable): continuously send 1MB to existing topics every LOAD_INTERVAL_SEC
#   - 1 measurement producer (ProducerLatency): sends 1MB to test_topic_1..FIRST_NUM_TOPICS (auto-create)
#   - Yammer resource sampler: records broker system metrics
#
# Output files (all under output/message-load-experiment/<timestamp>/):
#   producer_metrics.csv          topic_num, topic_name, e2e_ms, wait_on_metadata_count
#   broker_proc_metrics.csv       per [TMT-BROKER-PROC] log entry
#   broker_meta_update_metrics.csv per [TMT-META-UPDATE] log entry
#   combined_metrics.csv          all metrics merged per-topic (primary result)
#   yammer.csv                    timestamp,epoch_ms,broker_pid,open_fd_count,...
#
# Instrumentation required (already patched in this repo):
#   KafkaApis.scala               → logs [TMT-BROKER-PROC] on every handleProduceRequest
#   BrokerMetadataPublisher.scala → logs [TMT-META-UPDATE] on every onMetadataUpdate
#   KafkaProducer.java            → exposes TMT_WAIT_ON_METADATA_COUNT ThreadLocal
#   ProducerLatency.java          → writes e2e_ms + wait_on_metadata_count to CSV

set -euo pipefail

KAFKA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
LOG_DIR="/tmp/kraft-combined-logs"
BOOTSTRAP_SERVER="localhost:9092"

# ============================================================
# Experiment configuration — edit these as needed
# ============================================================
LOAD_PRODUCER_COUNT=2           # N: number of background load producers
LOAD_INTERVAL_SEC=0.3           # seconds between sends per load producer
LOAD_RECORD_SIZE=1048576        # 1 MB per load message
# All N load producers send to a single topic (1 partition, 1 replica)
LOAD_TOPIC_PARTITIONS=1
LOAD_TOPIC_REPLICATION_FACTOR=1
LOAD_WARMUP_SEC=10              # warm-up before measurement starts
# NOTE: auto-created test_topic_* partition count is set by broker's num.partitions.
#       Ensure server.properties has: num.partitions=1

FIRST_RECORD_SIZE=1048576       # 1 MB per measurement message
FIRST_NUM_TOPICS=100           # test_topic_1 .. test_topic_N
FIRST_TOPIC_PREFIX="test_topic_"
ACKS="1"

RESOURCE_SAMPLE_INTERVAL_SEC=2

# ============================================================
# Internal state
# ============================================================
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
OUTPUT_DIR="$KAFKA_HOME/output"
LOG_BROKER_DIR="$OUTPUT_DIR/logs/broker"
LOG_PRODUCER_DIR="$OUTPUT_DIR/logs/producer"

BROKER_LOG=""
BROKER_PID=""
FD_SAMPLER_PID=""
declare -a LOAD_PIDS=()

mkdir -p "$OUTPUT_DIR" "$LOG_BROKER_DIR" "$LOG_PRODUCER_DIR"

log()      { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
epoch_ms() { date '+%s%3N' 2>/dev/null || date '+%s000'; }

wait_for_port() {
  local host="$1" port="$2" max_wait="$3" waited=0
  while ! nc -z "$host" "$port" 2>/dev/null; do
    sleep 2; waited=$((waited + 2))
    [[ "$waited" -ge "$max_wait" ]] && return 1
  done
  return 0
}

# ============================================================
# Broker lifecycle
# ============================================================
stop_kafka() {
  log "Stopping broker..."
  "$KAFKA_HOME/bin/kafka-server-stop.sh" 2>/dev/null || true
  sleep 5
  if pgrep -f "kafka.Kafka" >/dev/null 2>&1; then
    pkill -f "kafka.Kafka" 2>/dev/null || true
    sleep 3
  fi
  BROKER_PID=""
  log "Broker stopped."
}

clean_logs() {
  log "Cleaning $LOG_DIR ..."
  rm -rf "$LOG_DIR" 2>/dev/null || true
  log "Log dir cleaned."
}

format_storage() {
  log "Formatting KRaft storage..."
  local cid; cid="$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)"
  "$KAFKA_HOME/bin/kafka-storage.sh" format --standalone -t "$cid" -c "$CONFIG"
  log "Storage formatted (cluster_id=$cid)."
}

start_kafka() {
  BROKER_LOG="$LOG_BROKER_DIR/broker_${TIMESTAMP}.log"
  log "Starting broker → $BROKER_LOG"
  "$KAFKA_HOME/bin/kafka-server-start.sh" "$CONFIG" >"$BROKER_LOG" 2>&1 &
  BROKER_PID=$!
  wait_for_port "127.0.0.1" 9092 90 || { log "ERROR: broker did not start in 90s"; exit 1; }
  sleep 3
  log "Broker ready (PID=$BROKER_PID)."
}

# ============================================================
# Load topics
# ============================================================
LOAD_TOPIC="load_topic"   # single shared topic for all load producers

create_load_topics() {
  log "Creating load topic: $LOAD_TOPIC (partitions=1, replication=1)..."
  "$KAFKA_HOME/bin/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP_SERVER" \
    --create --if-not-exists \
    --topic "$LOAD_TOPIC" \
    --partitions "$LOAD_TOPIC_PARTITIONS" \
    --replication-factor "$LOAD_TOPIC_REPLICATION_FACTOR" >/dev/null
  log "  $LOAD_TOPIC created."
}

# ============================================================
# Load producers
# ============================================================
start_load_producers() {
  LOAD_PIDS=()

  for i in $(seq 1 "$LOAD_PRODUCER_COUNT"); do
    # All load producers send to the same single topic
    local log_file="$LOG_PRODUCER_DIR/load_producer_${i}_${TIMESTAMP}.log"

    (
      while true; do
        "$KAFKA_HOME/bin/kafka-producer-perf-test.sh" \
          --topic "$LOAD_TOPIC" \
          --num-records 1 \
          --record-size "$LOAD_RECORD_SIZE" \
          --throughput -1 \
          --producer-props \
            bootstrap.servers="$BOOTSTRAP_SERVER" \
            acks="$ACKS" \
            max.request.size=2097152 \
          >>"$log_file" 2>&1 || true
        sleep "$LOAD_INTERVAL_SEC"
      done
    ) &
    local pid=$!
    LOAD_PIDS+=("$pid")
    log "  Load producer $i → $LOAD_TOPIC (PID=$pid)"
  done

  log "Warming up load for ${LOAD_WARMUP_SEC}s ..."
  sleep "$LOAD_WARMUP_SEC"
  log "Warm-up done. Load producers active."
}

stop_load_producers() {
  [[ "${#LOAD_PIDS[@]}" -eq 0 ]] && return 0
  log "Stopping ${#LOAD_PIDS[@]} load producer(s)..."
  for pid in "${LOAD_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${LOAD_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  LOAD_PIDS=()
  log "Load producers stopped."
}

# ============================================================
# Resource sampler  (Yammer-style CSV)
# ============================================================
start_resource_sampler() {
  local pid="$1"
  local out_csv="$2"

  if ! command -v lsof >/dev/null 2>&1; then
    log "WARN: lsof not found — fd_count will be empty."
  fi

  printf '%s\n' \
    "timestamp,epoch_ms,broker_pid,open_fd_count,cpu_pct,rss_kb,vsz_kb,heap_used_kb,heap_committed_kb,storage_kb,topic_dir_count,segment_file_count" \
    >"$out_csv"

  (
    while kill -0 "$pid" 2>/dev/null; do
      local now epoch_now fd_count cpu_pct rss_kb vsz_kb
      local heap_used_kb heap_committed_kb storage_kb topic_dir_count segment_file_count

      now="$(date '+%Y-%m-%d %H:%M:%S')"
      epoch_now="$(epoch_ms)"

      # Open file descriptors
      fd_count="$(lsof -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')" || fd_count=""

      # CPU / RSS / VSZ
      local ps_out; ps_out="$(ps -p "$pid" -o %cpu=,rss=,vsz= 2>/dev/null)" || ps_out=""
      read -r cpu_pct rss_kb vsz_kb <<<"$ps_out"

      # Heap (jstat -gc)
      local gc_out; gc_out="$(jstat -gc "$pid" 2>/dev/null | awk 'NR==2{print $1,$2,$3,$4,$5,$6,$7,$8}')" || gc_out=""
      if [[ -n "$gc_out" ]]; then
        local s0c s1c s0u s1u ec eu oc ou
        read -r s0c s1c s0u s1u ec eu oc ou <<<"$gc_out"
        heap_used_kb="$(awk     -v a="${s0u:-0}" -v b="${s1u:-0}" -v c="${eu:-0}" -v d="${ou:-0}"   'BEGIN{printf "%.0f", a+b+c+d}')"
        heap_committed_kb="$(awk -v a="${s0c:-0}" -v b="${s1c:-0}" -v c="${ec:-0}" -v d="${oc:-0}"   'BEGIN{printf "%.0f", a+b+c+d}')"
      else
        heap_used_kb=""; heap_committed_kb=""
      fi

      # Storage / topology
      storage_kb="$(du -sk "$LOG_DIR" 2>/dev/null | awk '{print $1}')" || storage_kb=0
      topic_dir_count="$(find "$LOG_DIR" -maxdepth 1 -type d -name "${FIRST_TOPIC_PREFIX}*" 2>/dev/null | wc -l | tr -d ' ')" || topic_dir_count=0
      segment_file_count="$(find "$LOG_DIR" -type f \( -name '*.log' -o -name '*.index' -o -name '*.timeindex' \) 2>/dev/null | wc -l | tr -d ' ')" || segment_file_count=0

      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$now" "$epoch_now" "$pid" \
        "${fd_count:-}" "${cpu_pct:-}" "${rss_kb:-}" "${vsz_kb:-}" \
        "${heap_used_kb:-}" "${heap_committed_kb:-}" \
        "${storage_kb:-0}" "${topic_dir_count:-0}" "${segment_file_count:-0}" \
        >>"$out_csv"

      sleep "$RESOURCE_SAMPLE_INTERVAL_SEC"
    done
  ) &
  FD_SAMPLER_PID=$!
  log "Resource sampler started (PID=$FD_SAMPLER_PID, interval=${RESOURCE_SAMPLE_INTERVAL_SEC}s) → $out_csv"
}

stop_resource_sampler() {
  if [[ -n "${FD_SAMPLER_PID:-}" ]] && kill -0 "$FD_SAMPLER_PID" 2>/dev/null; then
    kill "$FD_SAMPLER_PID" 2>/dev/null || true
    wait "$FD_SAMPLER_PID" 2>/dev/null || true
  fi
  FD_SAMPLER_PID=""
}

# ============================================================
# Post-processing: parse broker log → merge into combined CSV
# ============================================================
parse_and_merge() {
  local broker_log="$1"
  local producer_csv="$2"
  local combined_csv="$3"
  local broker_proc_csv="$4"
  local broker_meta_csv="$5"
  local metadata_req_csv="$6"

  log "Parsing broker log: $broker_log"

  # ---- broker_proc_metrics.csv ----
  # Log format: ... [TMT-BROKER-PROC] topics=<name> queue_wait_ms=<ms> elapsed_ms=<ms> ...
  printf '%s\n' "topics,produce_queue_wait_ms,broker_proc_time_ms" >"$broker_proc_csv"
  grep '\[TMT-BROKER-PROC\]' "$broker_log" 2>/dev/null \
    | awk '{
        topics=""; queue_wait=""; elapsed=""
        for (i=1; i<=NF; i++) {
          if ($i ~ /^topics=/)         { sub(/^topics=/,         "", $i); topics=$i }
          if ($i ~ /^queue_wait_ms=/)  { sub(/^queue_wait_ms=/,  "", $i); queue_wait=$i }
          if ($i ~ /^elapsed_ms=/)     { sub(/^elapsed_ms=/,     "", $i); elapsed=$i }
        }
        if (topics != "") print topics","queue_wait","elapsed
      }' >>"$broker_proc_csv"
  local proc_count; proc_count="$(tail -n +2 "$broker_proc_csv" | wc -l | tr -d ' ')"
  log "  [TMT-BROKER-PROC] entries parsed: $proc_count → $broker_proc_csv"

  # ---- metadata_req_metrics.csv ----
  # Log format: ... [TMT-METADATA-REQ] topics=<name> queue_wait_ms=<ms> ...
  printf '%s\n' "topics,metadata_req_queue_wait_ms" >"$metadata_req_csv"
  grep '\[TMT-METADATA-REQ\]' "$broker_log" 2>/dev/null \
    | awk '{
        topics=""; queue_wait=""
        for (i=1; i<=NF; i++) {
          if ($i ~ /^topics=/)        { sub(/^topics=/,        "", $i); topics=$i }
          if ($i ~ /^queue_wait_ms=/) { sub(/^queue_wait_ms=/, "", $i); queue_wait=$i }
        }
        if (topics != "") print topics","queue_wait
      }' >>"$metadata_req_csv"
  local meta_req_count; meta_req_count="$(tail -n +2 "$metadata_req_csv" | wc -l | tr -d ' ')"
  log "  [TMT-METADATA-REQ] entries parsed: $meta_req_count → $metadata_req_csv"

  # ---- broker_meta_update_metrics.csv ----
  # Log format: ... [TMT-META-UPDATE] new_topics=<names> offset=<n> elapsed_ms=<ms> ...
  printf '%s\n' "new_topics,offset,broker_meta_update_ms" >"$broker_meta_csv"
  grep '\[TMT-META-UPDATE\]' "$broker_log" 2>/dev/null \
    | awk '{
        new_topics=""; offset=""; elapsed=""
        for (i=1; i<=NF; i++) {
          if ($i ~ /^new_topics=/) { sub(/^new_topics=/, "", $i); new_topics=$i }
          if ($i ~ /^offset=/)     { sub(/^offset=/,     "", $i); offset=$i }
          if ($i ~ /^elapsed_ms=/) { sub(/^elapsed_ms=/, "", $i); elapsed=$i }
        }
        print new_topics","offset","elapsed
      }' >>"$broker_meta_csv"
  local meta_count; meta_count="$(tail -n +2 "$broker_meta_csv" | wc -l | tr -d ' ')"
  log "  [TMT-META-UPDATE] entries parsed: $meta_count → $broker_meta_csv"

  # ---- combined_metrics.csv  (Python join) ----
  log "Merging into combined CSV..."
  python3 - "$producer_csv" "$broker_proc_csv" "$broker_meta_csv" "$metadata_req_csv" "$combined_csv" <<'PYEOF'
import sys, csv
from collections import defaultdict

producer_csv, broker_proc_csv, broker_meta_csv, metadata_req_csv, combined_csv = sys.argv[1:]

# ---- producer data (primary, indexed by topic_name) ----
producer_rows = {}   # topic_name -> row dict
with open(producer_csv, newline='') as f:
    for row in csv.DictReader(f):
        producer_rows[row['topic_name']] = row

# ---- broker proc data (multiple entries per topic) ----
broker_proc_all       = defaultdict(list)  # topic_name -> [elapsed_ms, ...]
broker_proc_last      = {}                 # topic_name -> last elapsed_ms
broker_proc_queue_last = {}               # topic_name -> last produce_queue_wait_ms
with open(broker_proc_csv, newline='') as f:
    for row in csv.DictReader(f):
        t = row.get('topics', '').strip()
        v = row.get('broker_proc_time_ms', '').strip()
        q = row.get('produce_queue_wait_ms', '').strip()
        if t and v:
            broker_proc_all[t].append(v)
            broker_proc_last[t] = v
            broker_proc_queue_last[t] = q

# ---- metadata request queue wait (first request per topic) ----
metadata_req_queue = {}   # topic_name -> first metadata_req_queue_wait_ms
with open(metadata_req_csv, newline='') as f:
    for row in csv.DictReader(f):
        names_field = row.get('topics', '').strip()
        q           = row.get('metadata_req_queue_wait_ms', '').strip()
        if not names_field or not q:
            continue
        for name in names_field.split(','):
            name = name.strip()
            if name and name not in metadata_req_queue:
                metadata_req_queue[name] = q

# ---- broker meta update data ----
broker_meta = {}   # topic_name -> first elapsed_ms found
with open(broker_meta_csv, newline='') as f:
    for row in csv.DictReader(f):
        names_field = row.get('new_topics', '').strip()
        elapsed     = row.get('broker_meta_update_ms', '').strip()
        if not names_field or not elapsed:
            continue
        for name in names_field.split(','):
            name = name.strip()
            if name and name not in broker_meta:
                broker_meta[name] = elapsed

# ---- write combined CSV ----
with open(combined_csv, 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow([
        'topic_num', 'topic_name',
        'e2e_ms', 'wait_on_metadata_count',
        'metadata_req_queue_wait_ms',
        'produce_queue_wait_ms',
        'broker_proc_time_ms_last',
        'broker_proc_time_ms_all',
        'broker_meta_update_ms',
    ])
    for topic_name, prow in sorted(
        producer_rows.items(),
        key=lambda x: int(x[1].get('topic_num', 0)) if x[1].get('topic_num', '').isdigit() else 0
    ):
        writer.writerow([
            prow.get('topic_num', ''),
            topic_name,
            prow.get('e2e_ms', ''),
            prow.get('wait_on_metadata_count', ''),
            metadata_req_queue.get(topic_name, ''),
            broker_proc_queue_last.get(topic_name, ''),
            broker_proc_last.get(topic_name, ''),
            '|'.join(broker_proc_all.get(topic_name, [])),
            broker_meta.get(topic_name, ''),
        ])

print(f"Combined CSV: {combined_csv}  ({len(producer_rows)} rows)")
PYEOF

  log "Merge complete: $combined_csv"
}

# ============================================================
# Cleanup
# ============================================================
cleanup_on_exit() {
  stop_resource_sampler
  stop_load_producers
  stop_kafka
}
trap cleanup_on_exit EXIT

# ============================================================
# Main
# ============================================================
cat <<BANNER
============================================================
  Message Load Experiment
  Load producers   : $LOAD_PRODUCER_COUNT (interval=${LOAD_INTERVAL_SEC}s, size=${LOAD_RECORD_SIZE}B)
  Load topic       : $LOAD_TOPIC (partitions=1, replication=1)
  Measurement      : $FIRST_NUM_TOPICS topics × ${FIRST_RECORD_SIZE}B  (auto-create)
  Topic prefix     : $FIRST_TOPIC_PREFIX
  Acks             : $ACKS
  Output dir       : $OUTPUT_DIR
============================================================
BANNER

# 0. Build JARs (applies instrumentation changes)
log "Building JAR artifacts (:core :clients :tools) ..."
"$KAFKA_HOME/gradlew" -p "$KAFKA_HOME" :core:jar :clients:jar :tools:jar --no-daemon -q
log "Build complete."

# 1. Fresh broker
stop_kafka
clean_logs
format_storage
start_kafka

# 2. Setup load infrastructure
create_load_topics
start_resource_sampler "$BROKER_PID" "$OUTPUT_DIR/yammer_${TIMESTAMP}.csv"
start_load_producers

# 3. Measurement producer
PRODUCER_CSV="$OUTPUT_DIR/producer_metrics_${TIMESTAMP}.csv"
log "Starting measurement producer (${FIRST_NUM_TOPICS} topics, ${FIRST_RECORD_SIZE}B each) ..."
"$KAFKA_HOME/bin/kafka-producer-latency.sh" \
  --bootstrap-server "$BOOTSTRAP_SERVER" \
  --num-topics      "$FIRST_NUM_TOPICS" \
  --topic-prefix    "$FIRST_TOPIC_PREFIX" \
  --record-size     "$FIRST_RECORD_SIZE" \
  --acks            "$ACKS" \
  --output          "$PRODUCER_CSV" \
  2>&1 | tee "$LOG_PRODUCER_DIR/measurement_producer_${TIMESTAMP}.log"
log "Measurement producer finished."

# 4. Stop load + sampler
stop_resource_sampler
stop_load_producers

# 5. Parse + merge
parse_and_merge \
  "$BROKER_LOG" \
  "$PRODUCER_CSV" \
  "$OUTPUT_DIR/combined_metrics_${TIMESTAMP}.csv" \
  "$OUTPUT_DIR/broker_proc_metrics_${TIMESTAMP}.csv" \
  "$OUTPUT_DIR/broker_meta_update_metrics_${TIMESTAMP}.csv" \
  "$OUTPUT_DIR/metadata_req_metrics_${TIMESTAMP}.csv"

stop_kafka
trap - EXIT

cat <<SUMMARY

============================================================
  Experiment complete!  [$TIMESTAMP]
  ┌───────────────────────────────────────────────────────────────┐
  │ Location                    File                              │
  ├───────────────────────────────────────────────────────────────┤
  │ output/                     producer_metrics_$TIMESTAMP.csv   │
  │ output/                     broker_proc_metrics_$TIMESTAMP.csv│
  │ output/                     broker_meta_update_$TIMESTAMP.csv │
  │ output/                     combined_metrics_$TIMESTAMP.csv   │
  │ output/                     yammer_$TIMESTAMP.csv             │
  │ output/logs/broker/         broker_$TIMESTAMP.log             │
  │ output/logs/producer/       measurement_producer_$TIMESTAMP.log│
  │ output/logs/producer/       load_producer_*_$TIMESTAMP.log   │
  └───────────────────────────────────────────────────────────────┘
============================================================
SUMMARY
