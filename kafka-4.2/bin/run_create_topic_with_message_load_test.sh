#!/bin/bash

set -euo pipefail

KAFKA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$KAFKA_HOME/config/server.properties"
LOG_DIR="/tmp/kraft-combined-logs"
BOOTSTRAP_SERVER="localhost:9092"
NUM_TOPICS=1000
TOPIC_PREFIX="cp_topic"
PARTITIONS=1
REPLICATION_FACTOR=1
CREATE_INTERVAL_MS=100
REPEAT=1
REPEAT_INTERVAL_MS=5000
OUTPUT_DIR="$KAFKA_HOME/output/topic-create-with-message-load"
RESET_BROKER=true
KEEP_BROKER_RUNNING=false
CONTROLLER_LOG_PATH="$KAFKA_HOME/logs/controller.log"
CONTROLLER_LOG_START_LINE=0
CONTROLLER_RUN_LOG=""
CONTROLLER_PORT=""

PRODUCER_COUNT=10
PRODUCE_INTERVAL_MS=300
LOAD_TOPIC_COUNT=10
LOAD_TOPIC_PREFIX="dp_load_topic"
LOAD_TOPIC_PARTITIONS=1
LOAD_TOPIC_REPLICATION_FACTOR=1
LOAD_PRODUCER_ACKS="1"
# Keep a safety margin under max.request.size(1048576) to avoid RecordTooLargeException
LOAD_MESSAGE_SIZE_BYTES=1040000
FD_SAMPLE_INTERVAL_SEC=2
JMX_PORT=9999
JMX_SNAPSHOT_EVERY_TOPICS=300
JMX_ATTRIBUTES="Count,Mean,Min,Max,95thPercentile,99thPercentile"
declare -a JMX_OBJECTS=(
  "kafka.network:type=RequestMetrics,name=TotalTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=RequestQueueTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=LocalTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=RemoteTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=ResponseQueueTimeMs,request=Produce"
  "kafka.network:type=RequestMetrics,name=ResponseSendTimeMs,request=Produce"
)

HAS_RG=false
if command -v rg >/dev/null 2>&1; then
  HAS_RG=true
fi

BROKER_LOG=""
RESULT_CSV=""
SUMMARY_CSV=""
LOAD_TOPICS_CSV=""
LOAD_PRODUCE_SUMMARY_CSV=""
STOP_SIGNAL_FILE=""
WRITER_PIDS=()
CONSOLE_PRODUCER_PIDS=()
FIFO_PATHS=()
LOAD_MESSAGE_FILE=""
BROKER_PID=""
RESOURCE_SAMPLER_PID=""
BROKER_RESOURCE_CSV=""
JMX_SNAPSHOT_DIR=""
JMX_POST_CSV=""

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

build_load_message_payload() {
  if [[ "$LOAD_MESSAGE_SIZE_BYTES" -lt 1 ]]; then
    echo "ERROR: --load-message-size-bytes must be >= 1"
    exit 1
  fi

  LOAD_MESSAGE_FILE="$OUTPUT_DIR/.load_message_payload_${LOAD_MESSAGE_SIZE_BYTES}.txt"
  if [[ -f "$LOAD_MESSAGE_FILE" ]]; then
    return
  fi
  head -c "$LOAD_MESSAGE_SIZE_BYTES" /dev/zero | tr '\0' 'x' > "$LOAD_MESSAGE_FILE"
}

cleanup_message_payload() {
  if [[ -n "$LOAD_MESSAGE_FILE" && -f "$LOAD_MESSAGE_FILE" ]]; then
    rm -f "$LOAD_MESSAGE_FILE" 2>/dev/null || true
  fi
  LOAD_MESSAGE_FILE=""
}

count_open_fds() {
  local pid=$1
  if ! command -v lsof >/dev/null 2>&1; then
    echo ""
    return 1
  fi
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo ""
    return 1
  fi
  lsof -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
}

count_topic_dirs() {
  local base_dir=$1
  if [[ ! -d "$base_dir" ]]; then
    echo "0"
    return 0
  fi
  find "$base_dir" -maxdepth 1 -type d \( -name "${TOPIC_PREFIX}_*" -o -name "${LOAD_TOPIC_PREFIX}_*" \) 2>/dev/null | wc -l | tr -d ' '
}

count_segment_files() {
  local base_dir=$1
  if [[ ! -d "$base_dir" ]]; then
    echo "0"
    return 0
  fi
  find "$base_dir" -type f \( -name '*.log' -o -name '*.index' -o -name '*.timeindex' \) 2>/dev/null | wc -l | tr -d ' '
}

measure_storage_kb() {
  local base_dir=$1
  if [[ ! -d "$base_dir" ]]; then
    echo "0"
    return 0
  fi
  du -sk "$base_dir" 2>/dev/null | awk '{print $1}'
}

measure_ps_stats() {
  local pid=$1
  if ! command -v ps >/dev/null 2>&1; then
    echo ",,,"
    return 0
  fi
  local row
  row="$(ps -p "$pid" -o %cpu=,rss=,vsz= 2>/dev/null | awk 'NR==1{print $1","$2","$3}')"
  if [[ -z "$row" ]]; then
    echo ",,,"
  else
    echo "$row"
  fi
}

measure_heap_kb() {
  local pid=$1
  if ! command -v jstat >/dev/null 2>&1; then
    echo ","
    return 0
  fi
  local gc_row
  gc_row="$(jstat -gc "$pid" 2>/dev/null | awk 'NR==2{print $1","$2","$3","$4","$5","$6","$7","$8}')"
  if [[ -z "$gc_row" ]]; then
    echo ","
    return 0
  fi
  IFS=',' read -r s0c s1c s0u s1u ec eu oc ou <<<"$gc_row"
  awk -v s0c="${s0c:-0}" -v s1c="${s1c:-0}" -v ec="${ec:-0}" -v oc="${oc:-0}" \
      -v s0u="${s0u:-0}" -v s1u="${s1u:-0}" -v eu="${eu:-0}" -v ou="${ou:-0}" \
      'BEGIN{
        committed=s0c+s1c+ec+oc;
        used=s0u+s1u+eu+ou;
        printf "%.0f,%.0f", used, committed;
      }'
}

resolve_broker_pid() {
  if [[ -n "${KAFKA_PID:-}" ]] && kill -0 "$KAFKA_PID" 2>/dev/null; then
    BROKER_PID="$KAFKA_PID"
    return
  fi
  local pid
  pid=$(pgrep -f "kafka.Kafka" | head -n 1 || true)
  BROKER_PID="$pid"
}

start_resource_sampler() {
  local pid=$1
  local out_csv=$2

  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    log "WARN: Broker PID unavailable; skipping resource sampler."
    return 0
  fi

  printf '%s\n' "timestamp,epoch_ms,broker_pid,open_fd_count,cpu_pct,rss_kb,vsz_kb,heap_used_kb,heap_committed_kb,storage_kb,topic_dir_count,segment_file_count" > "$out_csv"
  (
    while kill -0 "$pid" 2>/dev/null; do
      local now epoch_ms fd_count ps_stats cpu_pct rss_kb vsz_kb heap_stats heap_used_kb heap_committed_kb
      local storage_kb topic_dir_count segment_file_count
      now="$(date '+%Y-%m-%d %H:%M:%S')"
      epoch_ms="$(perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000)')"
      fd_count="$(count_open_fds "$pid")"
      ps_stats="$(measure_ps_stats "$pid")"
      IFS=',' read -r cpu_pct rss_kb vsz_kb <<<"$ps_stats"
      heap_stats="$(measure_heap_kb "$pid")"
      IFS=',' read -r heap_used_kb heap_committed_kb <<<"$heap_stats"
      storage_kb="$(measure_storage_kb "$LOG_DIR")"
      topic_dir_count="$(count_topic_dirs "$LOG_DIR")"
      segment_file_count="$(count_segment_files "$LOG_DIR")"
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$now" "$epoch_ms" "$pid" "${fd_count:-}" "${cpu_pct:-}" "${rss_kb:-}" "${vsz_kb:-}" \
        "${heap_used_kb:-}" "${heap_committed_kb:-}" "${storage_kb:-0}" "${topic_dir_count:-0}" "${segment_file_count:-0}" \
        >> "$out_csv"
      sleep "$FD_SAMPLE_INTERVAL_SEC"
    done
  ) &
  RESOURCE_SAMPLER_PID=$!
  log "Started resource sampler (PID: $RESOURCE_SAMPLER_PID), interval=${FD_SAMPLE_INTERVAL_SEC}s"
}

stop_resource_sampler() {
  if [[ -n "${RESOURCE_SAMPLER_PID:-}" ]] && kill -0 "$RESOURCE_SAMPLER_PID" 2>/dev/null; then
    kill "$RESOURCE_SAMPLER_PID" 2>/dev/null || true
    wait "$RESOURCE_SAMPLER_PID" 2>/dev/null || true
  fi
  RESOURCE_SAMPLER_PID=""
}

collect_jmx_snapshot() {
  local out_csv=$1
  local out_log=$2

  if [[ "$JMX_SNAPSHOT_EVERY_TOPICS" -le 0 ]]; then
    return 0
  fi
  if [[ ! -x "$KAFKA_HOME/bin/kafka-jmx.sh" ]]; then
    log "WARN: kafka-jmx.sh not found; skipping JMX snapshot."
    return 0
  fi

  local jmx_url="service:jmx:rmi:///jndi/rmi://127.0.0.1:${JMX_PORT}/jmxrmi"
  local cmd=(
    "$KAFKA_HOME/bin/kafka-jmx.sh"
    --jmx-url "$jmx_url"
    --wait
    --one-time true
    --report-format csv
    --date-format "yyyy-MM-dd HH:mm:ss.SSS"
    --attributes "$JMX_ATTRIBUTES"
  )
  local obj
  for obj in "${JMX_OBJECTS[@]}"; do
    cmd+=(--object-name "$obj")
  done
  "${cmd[@]}" > "$out_csv" 2> "$out_log" || true
}

extract_metric_values() {
  local file=$1
  local metric_pattern=$2
  local field_name=$3
  local out_file=$4

  if [[ "$HAS_RG" == true ]]; then
    rg "$metric_pattern" "$file" \
      | rg -o "${field_name}=[0-9]+" \
      | cut -d= -f2 > "$out_file" || true
  else
    grep -F "$metric_pattern" "$file" \
      | grep -Eo "${field_name}=[0-9]+" \
      | cut -d= -f2 > "$out_file" || true
  fi
}

count_metric_lines() {
  local file=$1
  local metric_pattern=$2

  if [[ "$HAS_RG" == true ]]; then
    rg -c "$metric_pattern" "$file" || true
  else
    grep -F -c "$metric_pattern" "$file" || true
  fi
}

has_metric_line() {
  local file=$1
  local metric_pattern=$2

  if [[ "$HAS_RG" == true ]]; then
    rg -q "$metric_pattern" "$file"
  else
    grep -F -q "$metric_pattern" "$file"
  fi
}

percentile_from_sorted_file() {
  local file=$1
  local count=$2
  local percentile=$3

  local idx=$(( (count * percentile + 99) / 100 ))
  if [[ $idx -lt 1 ]]; then
    idx=1
  fi
  if [[ $idx -gt $count ]]; then
    idx=$count
  fi

  sed -n "${idx}p" "$file"
}

metric_stats_csv() {
  local value_file=$1

  if [[ ! -s "$value_file" ]]; then
    echo "0,0,0,0,0,0,0"
    return
  fi

  local sorted_file
  sorted_file="$(mktemp)"
  sort -n "$value_file" > "$sorted_file"

  local count min max sum avg p50 p95 p99
  count=$(wc -l < "$sorted_file" | tr -d ' ')
  min=$(head -n 1 "$sorted_file")
  max=$(tail -n 1 "$sorted_file")
  sum=$(awk '{s += $1} END {printf "%.0f", s}' "$sorted_file")
  avg=$((sum / count))
  p50=$(percentile_from_sorted_file "$sorted_file" "$count" 50)
  p95=$(percentile_from_sorted_file "$sorted_file" "$count" 95)
  p99=$(percentile_from_sorted_file "$sorted_file" "$count" 99)

  rm -f "$sorted_file"
  echo "$count,$min,$max,$avg,$p50,$p95,$p99"
}

convert_ns_file_to_us_file() {
  local ns_file=$1
  local us_file=$2

  if [[ -s "$ns_file" ]]; then
    awk '{printf "%.0f\n", $1 / 1000}' "$ns_file" > "$us_file"
  else
    : > "$us_file"
  fi
}

capture_controller_run_log() {
  local run_ts=$1
  local controller_log_dir="$OUTPUT_DIR/logs/controller"
  mkdir -p "$controller_log_dir"
  CONTROLLER_RUN_LOG="$controller_log_dir/${run_ts}.log"
  local copied=false

  if [[ -f "$CONTROLLER_LOG_PATH" ]]; then
    if [[ "$CONTROLLER_LOG_START_LINE" -gt 0 ]]; then
      tail -n +"$((CONTROLLER_LOG_START_LINE + 1))" "$CONTROLLER_LOG_PATH" > "$CONTROLLER_RUN_LOG" || true
      copied=true
    else
      cp "$CONTROLLER_LOG_PATH" "$CONTROLLER_RUN_LOG" || true
      copied=true
    fi
  fi

  if [[ "$copied" == false || ! -s "$CONTROLLER_RUN_LOG" ]]; then
    if [[ -n "${BROKER_LOG:-}" && -f "${BROKER_LOG:-}" ]]; then
      cp "$BROKER_LOG" "$CONTROLLER_RUN_LOG" || true
      log "Controller log source was empty/unavailable; using broker log snapshot for controller metric parsing."
    else
      : > "$CONTROLLER_RUN_LOG"
    fi
  fi

  if [[ ! -s "$CONTROLLER_RUN_LOG" ]]; then
    : > "$CONTROLLER_RUN_LOG"
  fi
}

collect_topic_metric_pairs_ns() {
  local log_file=$1
  local metric_name=$2
  local value_field=$3
  local out_file=$4

  if [[ -z "$log_file" || ! -f "$log_file" ]]; then
    : > "$out_file"
    return
  fi

  awk -v metric="$metric_name" -v valueField="$value_field" '
    $0 ~ ("TOPIC_CREATE_METRIC metric=" metric " ") {
      topic = ""
      value = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^topic=/) topic = substr($i, 7)
        if ($i ~ ("^" valueField "=")) value = substr($i, length(valueField) + 2)
      }
      if (topic != "" && value != "") {
        print topic "," value
      }
    }
  ' "$log_file" > "$out_file"
}

convert_pairs_ns_to_us() {
  local ns_pair_file=$1
  local us_pair_file=$2

  if [[ -s "$ns_pair_file" ]]; then
    awk -F, '{printf "%s,%.0f\n", $1, $2 / 1000}' "$ns_pair_file" > "$us_pair_file"
  else
    : > "$us_pair_file"
  fi
}

enrich_request_results_with_metrics() {
  local broker_log_path="${BROKER_LOG:-}"
  local controller_log_path="${CONTROLLER_RUN_LOG:-}"
  local temp_dir
  temp_dir="$(mktemp -d)"

  local e2e_pairs_ns_file="$temp_dir/e2e_pairs_ns.csv"
  local e2e_pairs_file="$temp_dir/e2e_pairs_us.csv"
  local on_metadata_pairs_ns_file="$temp_dir/on_metadata_pairs_ns.csv"
  local on_metadata_pairs_file="$temp_dir/on_metadata_pairs_us.csv"
  local create_topic_pairs_ns_file="$temp_dir/create_topic_pairs_ns.csv"
  local create_topic_pairs_file="$temp_dir/create_topic_pairs_us.csv"
  local enriched_csv="$temp_dir/topic_create_requests_enriched.csv"

  : > "$e2e_pairs_ns_file"
  : > "$e2e_pairs_file"
  : > "$on_metadata_pairs_ns_file"
  : > "$on_metadata_pairs_file"
  : > "$create_topic_pairs_ns_file"
  : > "$create_topic_pairs_file"

  if [[ -n "$broker_log_path" && -f "$broker_log_path" ]]; then
    collect_topic_metric_pairs_ns "$broker_log_path" "e2e" "latency_ns" "$e2e_pairs_ns_file"
    collect_topic_metric_pairs_ns "$broker_log_path" "onMetadataUpdate" "duration_ns" "$on_metadata_pairs_ns_file"
  fi

  collect_topic_metric_pairs_ns "$controller_log_path" "createTopic" "duration_ns" "$create_topic_pairs_ns_file"

  convert_pairs_ns_to_us "$e2e_pairs_ns_file" "$e2e_pairs_file"
  convert_pairs_ns_to_us "$on_metadata_pairs_ns_file" "$on_metadata_pairs_file"
  convert_pairs_ns_to_us "$create_topic_pairs_ns_file" "$create_topic_pairs_file"

  local e2e_count on_metadata_count create_topic_count
  e2e_count=$(wc -l < "$e2e_pairs_file" | tr -d ' ')
  on_metadata_count=$(wc -l < "$on_metadata_pairs_file" | tr -d ' ')
  create_topic_count=$(wc -l < "$create_topic_pairs_file" | tr -d ' ')

  if [[ "$e2e_count" -gt 0 && "$on_metadata_count" -eq 0 ]]; then
    log "WARNING: e2e metric은 있는데 onMetadataUpdate metric 파싱 결과가 0건입니다. broker log를 확인하세요: $broker_log_path"
  fi
  if [[ "$e2e_count" -gt 0 && "$create_topic_count" -eq 0 ]]; then
    log "WARNING: e2e metric은 있는데 createTopic metric 파싱 결과가 0건입니다. controller log를 확인하세요: $controller_log_path"
    log "WARNING: createTopic metric이 로그에 없다면 metadata 모듈 계측 코드가 반영되지 않았을 수 있습니다. './gradlew :core:jar :metadata:jar :server:jar :tools:jar -x test' 후 재실행하세요."
  fi

  printf "%s\n" \
    "seq,topic_name,request_latency_us,e2e_latency_us,broker_metadata_update_us,controller_topic_creation_us,status,error" \
    > "$enriched_csv"

  while IFS=',' read -r seq topic_name request_latency_us status error; do
    if [[ "$seq" == "seq" ]]; then
      continue
    fi

    local e2e_latency_us on_metadata_duration_us create_topic_duration_us
    e2e_latency_us=$(awk -F, -v topic="$topic_name" '$1 == topic { print $2; exit }' "$e2e_pairs_file")
    on_metadata_duration_us=$(awk -F, -v topic="$topic_name" '$1 == topic { print $2; exit }' "$on_metadata_pairs_file")
    create_topic_duration_us=$(awk -F, -v topic="$topic_name" '$1 == topic { print $2; exit }' "$create_topic_pairs_file")

    printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$seq" "$topic_name" "$request_latency_us" "${e2e_latency_us:-}" "${on_metadata_duration_us:-}" "${create_topic_duration_us:-}" "$status" "$error" \
      >> "$enriched_csv"
  done < "$RESULT_CSV"

  mv "$enriched_csv" "$RESULT_CSV"
  rm -rf "$temp_dir"
}

generate_experiment_summary() {
  local run_ts=$1
  local summary_csv="$OUTPUT_DIR/experiment_summary_${run_ts}.csv"
  local broker_log_path="${BROKER_LOG:-}"
  local controller_log_path="${CONTROLLER_RUN_LOG:-}"
  local temp_dir
  temp_dir="$(mktemp -d)"

  local e2e_pairs_ns_file="$temp_dir/e2e_pairs_ns.csv"
  local e2e_values_ns_file="$temp_dir/e2e_values_ns.txt"
  local e2e_values_file="$temp_dir/e2e_values_us.txt"
  local on_metadata_pairs_ns_file="$temp_dir/on_metadata_pairs_ns.csv"
  local on_metadata_values_ns_file="$temp_dir/on_metadata_values_ns.txt"
  local on_metadata_values_file="$temp_dir/on_metadata_values_us.txt"
  local create_topic_pairs_ns_file="$temp_dir/create_topic_pairs_ns.csv"
  local create_topic_values_ns_file="$temp_dir/create_topic_values_ns.txt"
  local create_topic_values_file="$temp_dir/create_topic_values_us.txt"
  local request_values_file="$temp_dir/request_values_us.txt"

  if [[ -n "$broker_log_path" && -f "$broker_log_path" ]]; then
    collect_topic_metric_pairs_ns "$broker_log_path" "e2e" "latency_ns" "$e2e_pairs_ns_file"
    collect_topic_metric_pairs_ns "$broker_log_path" "onMetadataUpdate" "duration_ns" "$on_metadata_pairs_ns_file"
    cut -d, -f2 "$e2e_pairs_ns_file" > "$e2e_values_ns_file" || true
    cut -d, -f2 "$on_metadata_pairs_ns_file" > "$on_metadata_values_ns_file" || true
  else
    : > "$e2e_pairs_ns_file"
    : > "$on_metadata_pairs_ns_file"
    : > "$e2e_values_ns_file"
    : > "$on_metadata_values_ns_file"
  fi

  collect_topic_metric_pairs_ns "$controller_log_path" "createTopic" "duration_ns" "$create_topic_pairs_ns_file"
  cut -d, -f2 "$create_topic_pairs_ns_file" > "$create_topic_values_ns_file" || true

  convert_ns_file_to_us_file "$e2e_values_ns_file" "$e2e_values_file"
  convert_ns_file_to_us_file "$on_metadata_values_ns_file" "$on_metadata_values_file"
  convert_ns_file_to_us_file "$create_topic_values_ns_file" "$create_topic_values_file"

  tail -n +2 "$RESULT_CSV" | cut -d, -f3 > "$request_values_file"

  local forward_count
  if [[ -n "$broker_log_path" && -f "$broker_log_path" ]]; then
    forward_count=$(count_metric_lines "$broker_log_path" "TOPIC_CREATE_METRIC metric=forwardToController ")
    if [[ -z "$forward_count" ]]; then
      forward_count=0
    fi
  else
    forward_count=0
  fi

  local e2e_stats on_metadata_stats create_topic_stats request_stats
  e2e_stats=$(metric_stats_csv "$e2e_values_file")
  on_metadata_stats=$(metric_stats_csv "$on_metadata_values_file")
  create_topic_stats=$(metric_stats_csv "$create_topic_values_file")
  request_stats=$(metric_stats_csv "$request_values_file")

  printf "%s\n" \
    "timestamp,num_topics,create_interval_ms,producer_count,produce_interval_ms,load_topic_count,partitions,replication_factor,forward_count,e2e_count,e2e_min_us,e2e_max_us,e2e_avg_us,e2e_p50_us,e2e_p95_us,e2e_p99_us,on_metadata_count,on_metadata_min_us,on_metadata_max_us,on_metadata_avg_us,on_metadata_p50_us,on_metadata_p95_us,on_metadata_p99_us,create_topic_count,create_topic_min_us,create_topic_max_us,create_topic_avg_us,create_topic_p50_us,create_topic_p95_us,create_topic_p99_us,request_count,request_min_us,request_max_us,request_avg_us,request_p50_us,request_p95_us,request_p99_us" \
    > "$summary_csv"

  printf "%s\n" \
    "$run_ts,$NUM_TOPICS,$CREATE_INTERVAL_MS,$PRODUCER_COUNT,$PRODUCE_INTERVAL_MS,$LOAD_TOPIC_COUNT,$PARTITIONS,$REPLICATION_FACTOR,$forward_count,$e2e_stats,$on_metadata_stats,$create_topic_stats,$request_stats" \
    >> "$summary_csv"

  rm -rf "$temp_dir"
  SUMMARY_CSV="$summary_csv"
}

now_ns() {
  perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000000000)'
}

ns_to_iso() {
  local ns=$1
  if [[ -z "$ns" || "$ns" -le 0 ]]; then
    echo ""
    return
  fi

  perl -MPOSIX=strftime -e '
    my $ns = shift;
    my $sec = int($ns / 1000000000);
    my $msec = int(($ns % 1000000000) / 1000000);
    print strftime("%Y-%m-%d %H:%M:%S", localtime($sec)) . sprintf(".%03d\n", $msec);
  ' "$ns"
}

generate_load_produce_summary() {
  local run_ts=$1
  local writer_log_dir="$OUTPUT_DIR/logs/load_writer"
  local summary_csv="$OUTPUT_DIR/load_produce_summary_${run_ts}.csv"
  local temp_dir
  temp_dir="$(mktemp -d)"

  local total_intervals_us_file="$temp_dir/total_intervals_us.txt"
  : > "$total_intervals_us_file"

  printf "%s\n" \
    "producer_idx,topic_name,start_time,end_time,duration_sec,message_count,interval_count,interval_min_ms,interval_avg_ms,interval_p50_ms,interval_p95_ms,interval_p99_ms,interval_max_ms,send_rate_msg_per_sec" \
    > "$summary_csv"

  local total_messages=0
  local total_start_ns=0
  local total_end_ns=0

  local event_files=()
  while IFS= read -r f; do
    event_files+=("$f")
  done < <(ls -1 "$writer_log_dir/${run_ts}"_p*.csv 2>/dev/null | sort -V || true)

  if [[ ${#event_files[@]} -eq 0 ]]; then
    LOAD_PRODUCE_SUMMARY_CSV="$summary_csv"
    rm -rf "$temp_dir"
    return
  fi

  local event_file
  for event_file in "${event_files[@]}"; do
    local producer_idx topic_name message_count start_ns end_ns
    producer_idx=$(awk -F, 'NR==2 {print $1; exit}' "$event_file")
    topic_name=$(awk -F, 'NR==2 {print $2; exit}' "$event_file")
    message_count=$(awk -F, 'NR>1 && $4 ~ /^[0-9]+$/ {c++} END {print c+0}' "$event_file")
    start_ns=$(awk -F, 'NR==2 {print $4; exit}' "$event_file")
    end_ns=$(awk -F, 'NR>1 {v=$4} END {print v+0}' "$event_file")

    if [[ -z "$producer_idx" ]]; then
      producer_idx="NA"
    fi
    if [[ -z "$topic_name" ]]; then
      topic_name="NA"
    fi
    if [[ -z "$start_ns" ]]; then
      start_ns=0
    fi
    if [[ -z "$end_ns" ]]; then
      end_ns=0
    fi

    local duration_sec send_rate
    if [[ "$message_count" -gt 0 && "$end_ns" -ge "$start_ns" ]]; then
      duration_sec=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN {printf "%.6f", (e - s) / 1000000000}')
    else
      duration_sec="0.000000"
    fi

    send_rate=$(awk -v c="$message_count" -v d="$duration_sec" 'BEGIN { if (d > 0) printf "%.3f", c / d; else printf "0.000" }')

    if [[ "$message_count" -gt 0 ]]; then
      total_messages=$((total_messages + message_count))
      if [[ "$total_start_ns" -eq 0 || "$start_ns" -lt "$total_start_ns" ]]; then
        total_start_ns="$start_ns"
      fi
      if [[ "$end_ns" -gt "$total_end_ns" ]]; then
        total_end_ns="$end_ns"
      fi
    fi

    local interval_us_file="$temp_dir/intervals_p${producer_idx}.us"
    awk -F, 'NR>1 && $5 ~ /^[0-9]+$/ && $5 > 0 {printf "%.0f\n", $5 / 1000}' "$event_file" > "$interval_us_file"
    cat "$interval_us_file" >> "$total_intervals_us_file"

    local interval_stats
    interval_stats=$(metric_stats_csv "$interval_us_file")
    IFS=',' read -r interval_count interval_min_us interval_max_us interval_avg_us interval_p50_us interval_p95_us interval_p99_us <<< "$interval_stats"

    local interval_min_ms interval_avg_ms interval_p50_ms interval_p95_ms interval_p99_ms interval_max_ms
    interval_min_ms=$(awk -v us="$interval_min_us" 'BEGIN {printf "%.3f", us / 1000}')
    interval_avg_ms=$(awk -v us="$interval_avg_us" 'BEGIN {printf "%.3f", us / 1000}')
    interval_p50_ms=$(awk -v us="$interval_p50_us" 'BEGIN {printf "%.3f", us / 1000}')
    interval_p95_ms=$(awk -v us="$interval_p95_us" 'BEGIN {printf "%.3f", us / 1000}')
    interval_p99_ms=$(awk -v us="$interval_p99_us" 'BEGIN {printf "%.3f", us / 1000}')
    interval_max_ms=$(awk -v us="$interval_max_us" 'BEGIN {printf "%.3f", us / 1000}')

    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$producer_idx" \
      "$topic_name" \
      "$(ns_to_iso "$start_ns")" \
      "$(ns_to_iso "$end_ns")" \
      "$duration_sec" \
      "$message_count" \
      "$interval_count" \
      "$interval_min_ms" \
      "$interval_avg_ms" \
      "$interval_p50_ms" \
      "$interval_p95_ms" \
      "$interval_p99_ms" \
      "$interval_max_ms" \
      "$send_rate" \
      >> "$summary_csv"
  done

  local total_duration_sec total_send_rate total_interval_stats
  if [[ "$total_messages" -gt 0 && "$total_end_ns" -ge "$total_start_ns" ]]; then
    total_duration_sec=$(awk -v s="$total_start_ns" -v e="$total_end_ns" 'BEGIN {printf "%.6f", (e - s) / 1000000000}')
  else
    total_duration_sec="0.000000"
  fi
  total_send_rate=$(awk -v c="$total_messages" -v d="$total_duration_sec" 'BEGIN { if (d > 0) printf "%.3f", c / d; else printf "0.000" }')

  total_interval_stats=$(metric_stats_csv "$total_intervals_us_file")
  IFS=',' read -r t_interval_count t_interval_min_us t_interval_max_us t_interval_avg_us t_interval_p50_us t_interval_p95_us t_interval_p99_us <<< "$total_interval_stats"

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "TOTAL" \
    "ALL_TOPICS" \
    "$(ns_to_iso "$total_start_ns")" \
    "$(ns_to_iso "$total_end_ns")" \
    "$total_duration_sec" \
    "$total_messages" \
    "$t_interval_count" \
    "$(awk -v us="$t_interval_min_us" 'BEGIN {printf "%.3f", us / 1000}')" \
    "$(awk -v us="$t_interval_avg_us" 'BEGIN {printf "%.3f", us / 1000}')" \
    "$(awk -v us="$t_interval_p50_us" 'BEGIN {printf "%.3f", us / 1000}')" \
    "$(awk -v us="$t_interval_p95_us" 'BEGIN {printf "%.3f", us / 1000}')" \
    "$(awk -v us="$t_interval_p99_us" 'BEGIN {printf "%.3f", us / 1000}')" \
    "$(awk -v us="$t_interval_max_us" 'BEGIN {printf "%.3f", us / 1000}')" \
    "$total_send_rate" \
    >> "$summary_csv"

  LOAD_PRODUCE_SUMMARY_CSV="$summary_csv"
  rm -rf "$temp_dir"
}

parse_bootstrap_endpoint() {
  local endpoint host port
  endpoint="${BOOTSTRAP_SERVER%%,*}"
  host="${endpoint%%:*}"
  port="${endpoint##*:}"

  if [[ "$host" == "$port" ]]; then
    port="9092"
  fi

  BOOTSTRAP_HOST="$host"
  BOOTSTRAP_PORT="$port"
}

parse_controller_port_from_config() {
  local listeners_line controller_listener controller_host_port controller_port
  listeners_line=$(awk -F= '/^[[:space:]]*listeners[[:space:]]*=/ {print $2; exit}' "$CONFIG" | tr -d ' ')

  controller_listener=$(echo "$listeners_line" | tr ',' '\n' | awk '/^CONTROLLER:\/\// {print; exit}')
  if [[ -n "$controller_listener" ]]; then
    controller_host_port="${controller_listener#CONTROLLER://}"
    controller_port="${controller_host_port##*:}"
    if [[ "$controller_port" =~ ^[0-9]+$ ]]; then
      CONTROLLER_PORT="$controller_port"
      return
    fi
  fi

  CONTROLLER_PORT="9093"
}

is_port_in_use() {
  local port=$1
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  return 1
}

has_fatal_startup_error_in_log() {
  local log_file=$1
  if [[ ! -f "$log_file" ]]; then
    return 1
  fi
  if [[ "$HAS_RG" == true ]]; then
    rg -q "Unable to start acceptor|Address already in use|Encountered fatal fault|FATAL" "$log_file"
  else
    grep -E -q "Unable to start acceptor|Address already in use|Encountered fatal fault|FATAL" "$log_file"
  fi
}

stop_kafka() {
  stop_resource_sampler
  log "Stopping Kafka broker..."
  "$KAFKA_HOME/bin/kafka-server-stop.sh" 2>/dev/null || true
  sleep 5

  if pgrep -f "kafka.Kafka" > /dev/null 2>&1; then
    log "Force killing remaining Kafka processes..."
    pkill -f "kafka.Kafka" 2>/dev/null || true
    sleep 3
  fi

  log "Kafka broker stopped."
  BROKER_PID=""
}

clean_logs() {
  log "Cleaning log directory: $LOG_DIR"
  local max_attempts=8
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    rm -rf "$LOG_DIR" 2>/dev/null || true
    if [[ ! -e "$LOG_DIR" ]]; then
      log "Log directory cleaned."
      return
    fi
    log "Log directory cleanup retry (${attempt}/${max_attempts})..."
    sleep 2
    attempt=$((attempt + 1))
  done

  if [[ -d "$LOG_DIR" ]]; then
    find "$LOG_DIR" -mindepth 1 -depth -exec rm -rf {} + 2>/dev/null || true
    rmdir "$LOG_DIR" 2>/dev/null || true
  fi

  if [[ -e "$LOG_DIR" ]]; then
    log "ERROR: Failed to clean log directory after retries: $LOG_DIR"
    exit 1
  fi

  log "Log directory cleaned."
}

format_storage() {
  log "Formatting KRaft storage..."
  local cluster_id
  cluster_id=$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)
  log "Generated new Cluster ID: $cluster_id"
  "$KAFKA_HOME/bin/kafka-storage.sh" format --standalone -t "$cluster_id" -c "$CONFIG"
  log "Storage formatted."
}

start_kafka() {
  local run_ts=$1
  local broker_log_dir="$OUTPUT_DIR/logs/broker"
  mkdir -p "$broker_log_dir"
  BROKER_LOG="$broker_log_dir/${run_ts}.log"

  parse_bootstrap_endpoint
  parse_controller_port_from_config

  if is_port_in_use "$BOOTSTRAP_PORT"; then
    log "ERROR: Broker port ${BOOTSTRAP_PORT} is already in use before startup."
    log "       Stop the conflicting process and retry."
    exit 1
  fi
  if [[ -n "$CONTROLLER_PORT" ]] && is_port_in_use "$CONTROLLER_PORT"; then
    log "ERROR: Controller port ${CONTROLLER_PORT} is already in use before startup."
    log "       Stop the conflicting process and retry."
    exit 1
  fi

  log "Starting Kafka broker with JMX_PORT=${JMX_PORT}..."
  JMX_PORT="$JMX_PORT" "$KAFKA_HOME/bin/kafka-server-start.sh" "$CONFIG" > "$BROKER_LOG" 2>&1 &
  KAFKA_PID=$!
  BROKER_PID="$KAFKA_PID"
  log "Kafka broker starting (PID: $KAFKA_PID)"
  log "Broker log: $BROKER_LOG"
  log "Waiting for broker/controller to be ready on ${BOOTSTRAP_HOST}:${BOOTSTRAP_PORT} and localhost:${CONTROLLER_PORT}..."

  local max_wait=60
  local waited=0
  while true; do
    if ! kill -0 "$KAFKA_PID" 2>/dev/null; then
      log "ERROR: Kafka process exited during startup. Check broker log: $BROKER_LOG"
      exit 1
    fi
    if has_fatal_startup_error_in_log "$BROKER_LOG"; then
      log "ERROR: Fatal startup error detected in broker log. Check: $BROKER_LOG"
      exit 1
    fi

    local broker_ready=false
    local controller_ready=true

    if nc -z "$BOOTSTRAP_HOST" "$BOOTSTRAP_PORT" 2>/dev/null; then
      broker_ready=true
    fi
    if [[ -n "$CONTROLLER_PORT" ]]; then
      if ! nc -z "localhost" "$CONTROLLER_PORT" 2>/dev/null; then
        controller_ready=false
      fi
    fi

    if [[ "$broker_ready" == true && "$controller_ready" == true ]]; then
      break
    fi

    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge $max_wait ]]; then
      log "ERROR: Broker/controller did not become ready within ${max_wait}s. Check broker log: $BROKER_LOG"
      exit 1
    fi
  done

  sleep 5
  if [[ "$JMX_SNAPSHOT_EVERY_TOPICS" -gt 0 ]]; then
    if nc -z "127.0.0.1" "$JMX_PORT" 2>/dev/null; then
      log "JMX port is ready on 127.0.0.1:${JMX_PORT}"
    else
      log "WARN: JMX port 127.0.0.1:${JMX_PORT} is not reachable. JMX snapshot may fail."
    fi
  fi
  log "Kafka broker is ready."
}

create_load_topics() {
  local run_ts=$1
  LOAD_TOPICS_CSV="$OUTPUT_DIR/load_topics_${run_ts}.csv"
  printf "idx,topic_name\n" > "$LOAD_TOPICS_CSV"

  log "Preparing load topics (count=$LOAD_TOPIC_COUNT, prefix=$LOAD_TOPIC_PREFIX)"
  for i in $(seq 1 "$LOAD_TOPIC_COUNT"); do
    local topic_name="${LOAD_TOPIC_PREFIX}_${run_ts}_${i}"
    if output=$("$KAFKA_HOME/bin/kafka-topics.sh" \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --create \
      --if-not-exists \
      --topic "$topic_name" \
      --partitions "$LOAD_TOPIC_PARTITIONS" \
      --replication-factor "$LOAD_TOPIC_REPLICATION_FACTOR" 2>&1); then
      printf "%s,%s\n" "$i" "$topic_name" >> "$LOAD_TOPICS_CSV"
    else
      log "ERROR: Failed to create load topic $topic_name"
      log "ERROR detail: $(echo "$output" | tr '\n' ' ' | cut -c1-300)"
      exit 1
    fi
  done

  log "Load topic list saved: $LOAD_TOPICS_CSV"
}

cleanup_load_producers() {
  if [[ -n "$STOP_SIGNAL_FILE" ]]; then
    touch "$STOP_SIGNAL_FILE" 2>/dev/null || true
  fi

  local pid
  for pid in "${WRITER_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done

  for pid in "${CONSOLE_PRODUCER_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done

  sleep 1

  for pid in "${WRITER_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done

  for pid in "${CONSOLE_PRODUCER_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done

  local fifo_path
  for fifo_path in "${FIFO_PATHS[@]:-}"; do
    rm -f "$fifo_path" 2>/dev/null || true
  done

  if [[ -n "$STOP_SIGNAL_FILE" ]]; then
    rm -f "$STOP_SIGNAL_FILE" 2>/dev/null || true
  fi

  WRITER_PIDS=()
  CONSOLE_PRODUCER_PIDS=()
  FIFO_PATHS=()
  STOP_SIGNAL_FILE=""
}

start_load_producers() {
  local run_ts=$1
  local producer_log_dir="$OUTPUT_DIR/logs/load_producer"
  local writer_log_dir="$OUTPUT_DIR/logs/load_writer"
  mkdir -p "$producer_log_dir"
  mkdir -p "$writer_log_dir"

  STOP_SIGNAL_FILE="$(mktemp)"
  rm -f "$STOP_SIGNAL_FILE"

  WRITER_PIDS=()
  CONSOLE_PRODUCER_PIDS=()
  FIFO_PATHS=()

  log "Starting data-plane load producers (count=$PRODUCER_COUNT, interval_ms=$PRODUCE_INTERVAL_MS)"

  local produce_sleep_sec
  produce_sleep_sec=$(awk "BEGIN { printf \"%.6f\", $PRODUCE_INTERVAL_MS / 1000 }")

  for producer_idx in $(seq 1 "$PRODUCER_COUNT"); do
    local topic_slot=$(( ((producer_idx - 1) % LOAD_TOPIC_COUNT) + 1 ))
    local topic_name
    topic_name=$(awk -F, -v idx="$topic_slot" '$1 == idx { print $2; exit }' "$LOAD_TOPICS_CSV")

    if [[ -z "$topic_name" ]]; then
      log "ERROR: Failed to map producer $producer_idx to load topic index $topic_slot"
      cleanup_load_producers
      exit 1
    fi

    local fifo_path="$OUTPUT_DIR/.producer_fifo_${run_ts}_${producer_idx}"
    rm -f "$fifo_path"
    mkfifo "$fifo_path"
    FIFO_PATHS+=("$fifo_path")

    local producer_log="$producer_log_dir/${run_ts}_p${producer_idx}.log"
    local writer_event_csv="$writer_log_dir/${run_ts}_p${producer_idx}.csv"
    printf "producer_idx,topic_name,seq,send_ns,interval_ns\n" > "$writer_event_csv"
    "$KAFKA_HOME/bin/kafka-console-producer.sh" \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --topic "$topic_name" \
      --producer-property "acks=$LOAD_PRODUCER_ACKS" \
      < "$fifo_path" > "$producer_log" 2>&1 &
    local console_pid=$!
    CONSOLE_PRODUCER_PIDS+=("$console_pid")

    (
      local seq=0
      local prev_send_ns=0
      exec 3> "$fifo_path"
      while [[ ! -f "$STOP_SIGNAL_FILE" ]]; do
        if ! { cat "$LOAD_MESSAGE_FILE"; printf "\n"; } >&3; then
          break
        fi
        seq=$((seq + 1))
        local send_ns interval_ns
        send_ns=$(now_ns)
        if [[ "$prev_send_ns" -gt 0 ]]; then
          interval_ns=$((send_ns - prev_send_ns))
        else
          interval_ns=0
        fi
        printf "%s,%s,%s,%s,%s\n" "$producer_idx" "$topic_name" "$seq" "$send_ns" "$interval_ns" >> "$writer_event_csv"
        prev_send_ns="$send_ns"

        if [[ "$PRODUCE_INTERVAL_MS" -gt 0 ]]; then
          sleep "$produce_sleep_sec"
        fi
      done
      exec 3>&-
    ) &
    local writer_pid=$!
    WRITER_PIDS+=("$writer_pid")
  done

  sleep 1

  local pid
  for pid in "${CONSOLE_PRODUCER_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "ERROR: A background load producer terminated unexpectedly."
      cleanup_load_producers
      exit 1
    fi
  done

  log "Data-plane load producers are running."
}

on_exit() {
  cleanup_load_producers
  stop_resource_sampler
  cleanup_message_payload
}

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --bootstrap-server <host:port>      (default: localhost:9092)
  --num-topics <n>                    (default: 1000)
  --topic-prefix <prefix>             (default: cp_topic)
  --partitions <n>                    (default: 1)
  --replication-factor <n>            (default: 1)
  --create-interval-ms <ms>           (default: 100)
  --producer-count <n>                (default: 10)
  --produce-interval-ms <ms>          (default: 300)
  --load-topic-count <n>              (default: 10)
  --load-topic-prefix <prefix>        (default: dp_load_topic)
  --load-topic-partitions <n>         (default: 1)
  --load-topic-replication-factor <n> (default: 1)
  --load-message-size-bytes <n>       (default: 1040000; ~1MB)
  --fd-sample-interval-sec <n>        (default: 2)
  --jmx-port <n>                      (default: 9999)
  --jmx-snapshot-every-topics <n>     (default: 300; 0 to disable)
  --repeat <n>                        Repeat whole experiment n times (default: 1)
  --repeat-interval-ms <ms>           Wait between repeated experiments (default: 5000)
  --output-dir <path>                 (default: kafka-4.2/output/topic-create-with-message-load)
  --skip-broker-reset                 Skip stop/clean/format/start sequence
  --keep-broker-running               Do not stop broker after test (only when this script started it)
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap-server)
      BOOTSTRAP_SERVER="$2"; shift 2 ;;
    --num-topics)
      NUM_TOPICS="$2"; shift 2 ;;
    --topic-prefix)
      TOPIC_PREFIX="$2"; shift 2 ;;
    --partitions)
      PARTITIONS="$2"; shift 2 ;;
    --replication-factor)
      REPLICATION_FACTOR="$2"; shift 2 ;;
    --create-interval-ms)
      CREATE_INTERVAL_MS="$2"; shift 2 ;;
    --producer-count)
      PRODUCER_COUNT="$2"; shift 2 ;;
    --produce-interval-ms)
      PRODUCE_INTERVAL_MS="$2"; shift 2 ;;
    --load-topic-count)
      LOAD_TOPIC_COUNT="$2"; shift 2 ;;
    --load-topic-prefix)
      LOAD_TOPIC_PREFIX="$2"; shift 2 ;;
    --load-topic-partitions)
      LOAD_TOPIC_PARTITIONS="$2"; shift 2 ;;
    --load-topic-replication-factor)
      LOAD_TOPIC_REPLICATION_FACTOR="$2"; shift 2 ;;
    --load-message-size-bytes)
      LOAD_MESSAGE_SIZE_BYTES="$2"; shift 2 ;;
    --fd-sample-interval-sec)
      FD_SAMPLE_INTERVAL_SEC="$2"; shift 2 ;;
    --jmx-port)
      JMX_PORT="$2"; shift 2 ;;
    --jmx-snapshot-every-topics)
      JMX_SNAPSHOT_EVERY_TOPICS="$2"; shift 2 ;;
    --repeat)
      REPEAT="$2"; shift 2 ;;
    --repeat-interval-ms)
      REPEAT_INTERVAL_MS="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --skip-broker-reset)
      RESET_BROKER=false; shift ;;
    --keep-broker-running)
      KEEP_BROKER_RUNNING=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1 ;;
  esac
done

if [[ "$PRODUCER_COUNT" -lt 1 ]]; then
  echo "ERROR: --producer-count must be >= 1"
  exit 1
fi
if [[ "$LOAD_TOPIC_COUNT" -lt 1 ]]; then
  echo "ERROR: --load-topic-count must be >= 1"
  exit 1
fi
if [[ "$LOAD_MESSAGE_SIZE_BYTES" -lt 1 ]]; then
  echo "ERROR: --load-message-size-bytes must be >= 1"
  exit 1
fi
if [[ "$FD_SAMPLE_INTERVAL_SEC" -lt 1 ]]; then
  echo "ERROR: --fd-sample-interval-sec must be >= 1"
  exit 1
fi
if [[ "$JMX_PORT" -lt 1 ]]; then
  echo "ERROR: --jmx-port must be >= 1"
  exit 1
fi
if [[ "$JMX_SNAPSHOT_EVERY_TOPICS" -lt 0 ]]; then
  echo "ERROR: --jmx-snapshot-every-topics must be >= 0"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
CREATE_SLEEP_SEC=$(awk "BEGIN { printf \"%.6f\", $CREATE_INTERVAL_MS / 1000 }")
REPEAT_SLEEP_SEC=$(awk "BEGIN { printf \"%.6f\", $REPEAT_INTERVAL_MS / 1000 }")
build_load_message_payload

run_single_experiment() {
  local run_idx=$1
  local run_ts=$2
  local script_started_broker=false

  RESULT_CSV="$OUTPUT_DIR/topic_create_requests_${run_ts}.csv"
  SUMMARY_CSV=""
  BROKER_LOG=""
  CONTROLLER_RUN_LOG=""
  LOAD_TOPICS_CSV=""
  LOAD_PRODUCE_SUMMARY_CSV=""
  BROKER_RESOURCE_CSV=""
  JMX_SNAPSHOT_DIR=""
  JMX_POST_CSV=""
  CONTROLLER_LOG_START_LINE=0

  log "Starting create-topic latency test with data-plane load (${run_idx}/${REPEAT})"
  log "bootstrap-server: $BOOTSTRAP_SERVER"
  log "num-topics: $NUM_TOPICS"
  log "topic-prefix: $TOPIC_PREFIX"
  log "create-interval-ms: $CREATE_INTERVAL_MS"
  log "producer-count: $PRODUCER_COUNT"
  log "produce-interval-ms: $PRODUCE_INTERVAL_MS"
  log "load-message-size-bytes: $LOAD_MESSAGE_SIZE_BYTES"
  log "fd-sample-interval-sec: $FD_SAMPLE_INTERVAL_SEC"
  log "jmx-port: $JMX_PORT"
  log "jmx-snapshot-every-topics: $JMX_SNAPSHOT_EVERY_TOPICS"
  log "load-topic-count: $LOAD_TOPIC_COUNT"
  log "partitions: $PARTITIONS"
  log "replication-factor: $REPLICATION_FACTOR"
  log "request result csv: $RESULT_CSV"

  if [[ "$RESET_BROKER" == true ]]; then
    log "Preparing broker before test (stop -> clean logs -> format -> start)"
    stop_kafka
    clean_logs
    format_storage
    start_kafka "$run_ts"
    script_started_broker=true
  fi

  if [[ -f "$CONTROLLER_LOG_PATH" ]]; then
    CONTROLLER_LOG_START_LINE=$(wc -l < "$CONTROLLER_LOG_PATH" | tr -d ' ')
  fi

  local resource_dir="$OUTPUT_DIR/system"
  JMX_SNAPSHOT_DIR="$OUTPUT_DIR/jmx"
  mkdir -p "$resource_dir" "$JMX_SNAPSHOT_DIR"
  BROKER_RESOURCE_CSV="$resource_dir/${run_ts}_broker_resource.csv"
  JMX_POST_CSV="$JMX_SNAPSHOT_DIR/${run_ts}_post.csv"

  resolve_broker_pid
  start_resource_sampler "$BROKER_PID" "$BROKER_RESOURCE_CSV"

  create_load_topics "$run_ts"
  start_load_producers "$run_ts"

  printf "seq,topic_name,request_latency_us,status,error\n" > "$RESULT_CSV"

  for i in $(seq 1 "$NUM_TOPICS"); do
    local topic_name="${TOPIC_PREFIX}_${run_ts}_${i}"
    local start_ns
    start_ns=$(now_ns)

    local output status error
    if output=$("$KAFKA_HOME/bin/kafka-topics.sh" \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --create \
      --topic "$topic_name" \
      --partitions "$PARTITIONS" \
      --replication-factor "$REPLICATION_FACTOR" 2>&1); then
      status="OK"
      error=""
    else
      status="ERROR"
      error=$(echo "$output" | tr '\n' ' ' | tr ',' ';' | cut -c1-300)
    fi

    local end_ns latency_ns latency_us
    end_ns=$(now_ns)
    latency_ns=$((end_ns - start_ns))
    latency_us=$((latency_ns / 1000))

    printf "%s,%s,%s,%s,%s\n" "$i" "$topic_name" "$latency_us" "$status" "$error" >> "$RESULT_CSV"

    if [[ "$i" == "1" || $((i % 100)) == 0 || "$i" == "$NUM_TOPICS" ]]; then
      log "[$i/$NUM_TOPICS] topic=$topic_name request_latency_us=$latency_us status=$status"
    fi

    if [[ "$JMX_SNAPSHOT_EVERY_TOPICS" -gt 0 && $((i % JMX_SNAPSHOT_EVERY_TOPICS)) -eq 0 ]]; then
      local jmx_step_csv="$JMX_SNAPSHOT_DIR/${run_ts}_${i}topics.csv"
      local jmx_step_log="$JMX_SNAPSHOT_DIR/${run_ts}_${i}topics.stderr.log"
      if [[ ! -f "$jmx_step_csv" ]]; then
        log "Collecting JMX snapshot at ${i} topics: $jmx_step_csv"
        collect_jmx_snapshot "$jmx_step_csv" "$jmx_step_log"
      fi
    fi

    if [[ "$CREATE_INTERVAL_MS" -gt 0 ]]; then
      sleep "$CREATE_SLEEP_SEC"
    fi
  done

  cleanup_load_producers
  generate_load_produce_summary "$run_ts"
  stop_resource_sampler

  if [[ "$JMX_SNAPSHOT_EVERY_TOPICS" -gt 0 ]]; then
    local jmx_post_log="$JMX_SNAPSHOT_DIR/${run_ts}_post.stderr.log"
    log "Collecting JMX post snapshot: $JMX_POST_CSV"
    collect_jmx_snapshot "$JMX_POST_CSV" "$jmx_post_log"
  fi

  if [[ "$script_started_broker" == true && "$KEEP_BROKER_RUNNING" == false ]]; then
    stop_kafka
  fi

  capture_controller_run_log "$run_ts"
  enrich_request_results_with_metrics
  generate_experiment_summary "$run_ts"

  log "Test completed (${run_idx}/${REPEAT})"
  log "CSV: $RESULT_CSV"
  log "Summary CSV: $SUMMARY_CSV"
  if [[ -n "${LOAD_TOPICS_CSV:-}" ]]; then
    log "Load topic list CSV: $LOAD_TOPICS_CSV"
  fi
  if [[ -n "${LOAD_PRODUCE_SUMMARY_CSV:-}" ]]; then
    log "Load produce summary CSV: $LOAD_PRODUCE_SUMMARY_CSV"
  fi
  if [[ -n "${BROKER_RESOURCE_CSV:-}" ]]; then
    log "Broker resource CSV: $BROKER_RESOURCE_CSV"
  fi
  if [[ -n "${JMX_POST_CSV:-}" && "$JMX_SNAPSHOT_EVERY_TOPICS" -gt 0 ]]; then
    log "JMX snapshot dir: $JMX_SNAPSHOT_DIR"
  fi
  if [[ -n "${BROKER_LOG:-}" ]]; then
    log "Broker log: $BROKER_LOG"
  fi
  if [[ -n "${CONTROLLER_RUN_LOG:-}" ]]; then
    log "Controller log: $CONTROLLER_RUN_LOG"
  fi
  log "Broker/Controller log에서 아래 문자열로 계측 결과를 확인하세요:"
  log "TOPIC_CREATE_METRIC"
  if [[ -n "${BROKER_LOG:-}" ]] && ! has_metric_line "$BROKER_LOG" "TOPIC_CREATE_METRIC"; then
    log "WARNING: broker log에 TOPIC_CREATE_METRIC가 없습니다. 코드 수정 후에는 './gradlew :core:jar :metadata:jar :server:jar :tools:jar -x test'를 먼저 실행하세요."
  fi
}

trap on_exit EXIT INT TERM

for run_idx in $(seq 1 "$REPEAT"); do
  RUN_TS=$(date '+%Y%m%d_%H%M%S')
  run_single_experiment "$run_idx" "$RUN_TS"
  if [[ "$run_idx" -lt "$REPEAT" && "$REPEAT_INTERVAL_MS" -gt 0 ]]; then
    log "Waiting ${REPEAT_INTERVAL_MS}ms before next experiment..."
    sleep "$REPEAT_SLEEP_SEC"
  fi
done
