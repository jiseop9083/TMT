# TMT (Topic Management Time) 실험

Kafka 4.2 KRaft 브로커에서 **새 토픽 자동 생성(auto.create.topics.enable=true) 시 발생하는 지연(latency)** 을 측정하고 분석하는 실험입니다.

---

## 1. 실험 목적

프로듀서가 존재하지 않는 토픽에 메시지를 보낼 때 브로커가 토픽을 자동 생성하는 과정에서 발생하는 각 단계별 시간을 정밀하게 측정합니다.

### 측정하려는 핵심 질문
- 새 토픽으로의 첫 번째 Produce가 기존 토픽 대비 얼마나 느린가?
- 지연의 원인은 어느 단계(Metadata 조회, Request 큐 대기, 브로커 처리, Metadata 갱신)에서 발생하는가?
- 백그라운드 부하(Load Producer)가 해당 지연에 얼마나 영향을 주는가?

---

## 2. 실험 구조

```
┌─────────────────────────────────────────────────────────────┐
│                         Kafka Broker (KRaft, 단일 노드)       │
│                                                              │
│  Request Queue                                              │
│  ┌──────────────┐    ┌──────────────────────────────────┐   │
│  │ MetadataReq  │───▶│  handleTopicMetadataRequest()    │   │
│  │ ProduceReq   │───▶│  handleProduceRequest()          │   │
│  └──────────────┘    └──────────────────────────────────┘   │
│                              │                               │
│                              ▼                               │
│                       MetadataPublisher                      │
│                    onMetadataUpdate() ──▶ 토픽 생성 반영     │
└─────────────────────────────────────────────────────────────┘
         ▲                              ▲
         │ (Produce + Metadata req)     │ (Load: 1MB / 0.3s)
┌────────────────┐             ┌────────────────┐
│ 측정 프로듀서  │             │ 부하 프로듀서  │
│ ProducerLatency│             │ N개 (설정 가능)│
│ test_topic_1~N │             │ load_topic     │
└────────────────┘             └────────────────┘
```

### 프로듀서 종류

| 종류 | 역할 | 대상 토픽 |
|---|---|---|
| **측정 프로듀서** (1개) | test_topic_1 ~ N 에 순차적으로 1MB 메시지 전송, 토픽은 자동 생성됨 | `test_topic_1` ~ `test_topic_N` |
| **부하 프로듀서** (N개) | 기존 토픽에 지속적으로 1MB 메시지를 전송하여 브로커에 배경 부하 생성 | `load_topic` (단일, 공유) |

---

## 3. 실험 변수 (독립 변수)

`bin/run_message_load_experiment.sh` 상단에서 설정합니다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `NUM_RUNS` | `3` | 실험 반복 횟수 |
| `LOAD_PRODUCER_COUNT` | `2` | 백그라운드 부하 프로듀서 수 (0으로 설정 시 부하 없음) |
| `LOAD_INTERVAL_SEC` | `0.3` | 부하 프로듀서의 전송 간격 (초) |
| `LOAD_RECORD_SIZE` | `1048576` | 부하 메시지 크기 (bytes, 기본 1MB) |
| `FIRST_NUM_TOPICS` | `3000` | 측정할 신규 토픽 수 |
| `FIRST_RECORD_SIZE` | `1048576` | 측정 메시지 크기 (bytes, 기본 1MB) |
| `ACKS` | `1` | Producer acks 설정 |
| `LOAD_WARMUP_SEC` | `10` | 부하 프로듀서 워밍업 대기 시간 (초) |

---

## 4. 계측 포인트 (Instrumentation)

소스 코드 4곳에 TMT 계측을 추가했습니다.

### 4-1. KafkaProducer.java — `waitOnMetadata()` 루프 횟수
```
파일: clients/src/main/java/org/apache/kafka/clients/producer/KafkaProducer.java
```
- `TMT_WAIT_ON_METADATA_COUNT` (ThreadLocal): `waitOnMetadata()` 내부의 do-while 반복 횟수를 기록
- 횟수 = 1: 첫 번째 metadata 요청에서 토픽 발견 (캐시 히트 또는 즉시 생성)
- 횟수 ≥ 2: 토픽이 없어서 브로커가 생성할 때까지 재시도

### 4-2. KafkaApis.scala — `handleTopicMetadataRequest()` 큐 대기 시간
```
파일: core/src/main/scala/kafka/server/KafkaApis.scala
로그 태그: [TMT-METADATA-REQ]
```
```
[TMT-METADATA-REQ] topics=test_topic_1 queue_wait_ms=0.123456
```
- `request.requestDequeueTimeNanos - request.startTimeNanos`: Metadata Request가 네트워크에서 수신된 후 핸들러 스레드에서 처리되기까지 Request Queue에서 대기한 시간

### 4-3. KafkaApis.scala — `handleProduceRequest()` 처리 시간 및 큐 대기 시간
```
파일: core/src/main/scala/kafka/server/KafkaApis.scala
로그 태그: [TMT-BROKER-PROC]
```
```
[TMT-BROKER-PROC] topics=test_topic_1 queue_wait_ms=0.234567 elapsed_ms=5.678901
```
- `queue_wait_ms`: Produce Request가 Request Queue에서 대기한 시간
- `elapsed_ms`: `handleProduceRequest()` 전체 실행 시간 (메서드 시작 ~ 종료)

### 4-4. BrokerMetadataPublisher.scala — `onMetadataUpdate()` 메타데이터 갱신 시간
```
파일: core/src/main/scala/kafka/server/metadata/BrokerMetadataPublisher.scala
로그 태그: [TMT-META-UPDATE]
```
```
[TMT-META-UPDATE] new_topics=test_topic_1 offset=42 elapsed_ms=12.345678
```
- `new_topics`: 이번 메타데이터 배치에서 새로 생성된 토픽명
- `elapsed_ms`: `onMetadataUpdate()` 전체 실행 시간
- 신규 토픽 판별: `TopicsDelta.changedTopics()` 중 이전 이미지에 없는 토픽 (`oldImage.getTopic(id) == null`)

---

## 5. 측정 지표 (종속 변수)

### combined_metrics_\<ts\>.csv 컬럼

| 컬럼 | 출처 | 설명 |
|---|---|---|
| `topic_num` | ProducerLatency | 토픽 순번 (1~N) |
| `topic_name` | ProducerLatency | 토픽명 (`test_topic_N`) |
| `e2e_ms` | ProducerLatency | **E2E 지연**: `send()` 호출 ~ ack 수신 (ms) |
| `wait_on_metadata_count` | KafkaProducer | `waitOnMetadata()` do-while 반복 횟수 |
| `metadata_req_queue_wait_ms` | `[TMT-METADATA-REQ]` | Metadata Request 큐 대기 시간 (ms) |
| `produce_queue_wait_ms` | `[TMT-BROKER-PROC]` | Produce Request 큐 대기 시간 (ms) |
| `broker_proc_time_ms_last` | `[TMT-BROKER-PROC]` | 해당 토픽의 마지막 Produce 처리 시간 (ms) |
| `broker_proc_time_ms_all` | `[TMT-BROKER-PROC]` | 해당 토픽의 모든 Produce 처리 시간 (`\|` 구분) |
| `broker_meta_update_ms` | `[TMT-META-UPDATE]` | 브로커 메타데이터 갱신 시간 (ms) |

### yammer_\<ts\>.csv 컬럼 (브로커 리소스)

| 컬럼 | 설명 |
|---|---|
| `timestamp` | 샘플링 시각 |
| `epoch_ms` | Unix 시각 (ms) |
| `broker_pid` | 브로커 프로세스 PID |
| `open_fd_count` | 열린 파일 디스크립터 수 (`lsof`) |
| `cpu_pct` | CPU 사용률 (%) |
| `rss_kb` | Resident Set Size (KB) |
| `vsz_kb` | Virtual Memory Size (KB) |
| `heap_used_kb` | JVM 힙 사용량 (KB, `jstat -gc`) |
| `heap_committed_kb` | JVM 힙 커밋 크기 (KB) |
| `storage_kb` | Kafka 로그 디렉토리 총 용량 (KB) |
| `topic_dir_count` | `test_topic_*` 디렉토리 수 |
| `segment_file_count` | 세그먼트 파일 수 (`.log`, `.index`, `.timeindex`) |

---

## 6. 지연 발생 흐름

```
Producer.send("test_topic_N", payload)
    │
    ▼
waitOnMetadata("test_topic_N")
    │   ← 토픽 미존재 → do-while 루프 시작 (wait_on_metadata_count++)
    │
    ▼
[Broker] MetadataRequest 수신
    ├── queue_wait_ms: Request Queue 대기
    └── handleTopicMetadataRequest() 실행
           └── nonExistingTopics → auto.create.topics.enable=true → 토픽 생성 트리거
    │
    ▼
[Broker] 컨트롤러가 TopicRecord 커밋 → MetadataLog 반영
    │
    ▼
[Broker] BrokerMetadataPublisher.onMetadataUpdate()
    └── broker_meta_update_ms: 메타데이터 갱신 시간
    │
    ▼
waitOnMetadata() 루프 종료 → 토픽 발견
    │
    ▼
ProduceRequest 전송
    ├── produce_queue_wait_ms: Request Queue 대기
    └── handleProduceRequest()
           └── broker_proc_time_ms: 처리 시간
    │
    ▼
Ack 수신 → send() 반환
    └── e2e_ms = 전체 경과 시간
```

---

## 7. 실험 실행 방법

```bash
# Kafka 홈 디렉토리에서 실행
cd /path/to/kafka-4.2
bash bin/run_message_load_experiment.sh
```

스크립트가 자동으로:
1. JAR 빌드 (`:core:jar :clients:jar :tools:jar`)
2. 브로커 재시작 (KRaft storage 포맷 포함)
3. `load_topic` 생성
4. 부하 프로듀서 N개 시작 + 워밍업
5. 측정 프로듀서 실행
6. 로그 파싱 → CSV 병합
7. `NUM_RUNS`번 반복

---

## 8. 출력 파일 구조

```
output/
├── combined_metrics_<ts>.csv          ← 주요 결과 (모든 지표 병합)
├── producer_metrics_<ts>.csv          ← e2e_ms, wait_on_metadata_count
├── broker_proc_metrics_<ts>.csv       ← produce_queue_wait_ms, broker_proc_time_ms
├── broker_meta_update_metrics_<ts>.csv← new_topics, offset, broker_meta_update_ms
├── metadata_req_metrics_<ts>.csv      ← metadata_req_queue_wait_ms
├── yammer_<ts>.csv                    ← 브로커 리소스 샘플 (2s 간격)
└── logs/
    ├── broker/broker_<ts>.log
    └── producer/
        ├── measurement_producer_<ts>.log
        └── load_producer_N_<ts>.log
```

---

## 9. 소스 코드 수정 파일 목록

| 파일 | 수정 내용 |
|---|---|
| `clients/src/main/java/org/apache/kafka/clients/producer/KafkaProducer.java` | `TMT_WAIT_ON_METADATA_COUNT` ThreadLocal 추가, `waitOnMetadata()` 루프 카운터 |
| `core/src/main/scala/kafka/server/KafkaApis.scala` | `[TMT-BROKER-PROC]`, `[TMT-METADATA-REQ]` 로그 추가 |
| `core/src/main/scala/kafka/server/metadata/BrokerMetadataPublisher.scala` | `[TMT-META-UPDATE]` 로그 추가 |
| `tools/src/main/java/org/apache/kafka/tools/ProducerLatency.java` | 신규 생성: 토픽별 새 KafkaProducer, E2E 지연 측정 |
| `bin/run_message_load_experiment.sh` | 신규 생성: 실험 자동화 스크립트 |
| `bin/kafka-producer-latency.sh` | 신규 생성: ProducerLatency 실행 스크립트 |

---

## 10. 브로커 설정 전제 조건

`config/server.properties`:
```properties
auto.create.topics.enable=true
num.partitions=1
default.replication.factor=1
```
