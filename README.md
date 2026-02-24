# Kafka 토픽 생성 지연 실험 실행 가이드 (한국어)

이 문서는 현재 반영된 계측 코드(`forwardToController`, `onMetadataUpdate`, `createTopics`)를 기준으로
토픽 생성 지연 실험을 실행하는 방법을 정리한 가이드입니다.

## 1. 코드 빌드

아래 명령으로 이번 변경이 포함된 모듈을 컴파일합니다.

```bash
./gradlew :core:compileScala :metadata:compileJava -x test
```

## 2. 브로커 초기화/실행

### 2-1. 기존 브로커 중지 (선택)

```bash
bin/kafka-server-stop.sh || true
pkill -f kafka.Kafka || true
```

### 2-2. KRaft 스토리지 포맷

```bash
KAFKA_CLUSTER_ID="$(bin/kafka-storage.sh random-uuid)"
bin/kafka-storage.sh format --standalone -t "$KAFKA_CLUSTER_ID" -c config/server.properties
```

### 2-3. 브로커 실행

```bash
bin/kafka-server-start.sh config/server.properties > /tmp/kafka-broker.log 2>&1 &
```

브로커 기동 확인:

```bash
nc -z localhost 9092 && echo "broker up"
```

## 3. 토픽 생성 지연 실험 실행

새 스크립트:
`bin/run_create_topic_latency_test.sh`

예시 (토픽 1000개, 10ms 간격):

```bash
bin/run_create_topic_latency_test.sh --num-topics 1000 --interval-ms 10
```

주요 옵션:

- `--bootstrap-server` (기본: `localhost:9092`)
- `--num-topics` (기본: `1000`)
- `--topic-prefix` (기본: `cp_topic`)
- `--partitions` (기본: `1`)
- `--replication-factor` (기본: `1`)
- `--interval-ms` (기본: `10`)
- `--repeat` (기본: `1`, 동일 실험 반복 횟수)
- `--repeat-interval-ms` (기본: `5000`, 반복 실험 사이 대기 시간)
- `--output-dir` (기본: `kafka-4.2/output/topic_create_latency`)

실험 요청 결과 CSV는 아래 경로에 생성됩니다.

- `kafka-4.2/output/topic_create_latency/topic_create_requests_<timestamp>.csv`

동일 조건 반복 실행 예시 (5회 반복, 반복 간 5초 대기):

```bash
bin/run_create_topic_latency_test.sh --num-topics 1000 --interval-ms 10 --repeat 5
```

## 4. 계측 로그 확인

브로커 로그에서 계측 로그만 필터링:

```bash
grep "TOPIC_CREATE_METRIC" /tmp/kafka-broker.log
```

현재 계측 로그 종류:

- `metric=forwardToController`
  - CREATE_TOPICS 포워딩 시점 기록
- `metric=onMetadataUpdate`
  - `BrokerMetadataPublisher.onMetadataUpdate` 실행 시간
- `metric=e2e`
  - `forwardToController` 시작부터 broker metadata 반영 완료까지 E2E
- `metric=createTopics`
  - `ReplicationControlManager.createTopics` 실행 시간
  - 집계 시 `logs/controller.log*`(rotate 포함) 전체에서 읽고, 마지막 `NUM_TOPICS`개를 사용

## 5. 자주 발생하는 문제

### 문제: `Timed out waiting for a node assignment`

원인: 브로커가 `localhost:9092`에서 떠 있지 않거나 아직 준비되지 않음.

확인:

```bash
nc -z localhost 9092
```

해결:

1. 브로커를 다시 시작
2. 5~10초 대기 후 실험 스크립트 재실행

### 문제: 요청이 모두 `ERROR`로 기록됨

`topic_create_requests_*.csv`의 `error` 컬럼을 확인하고,
브로커 로그(`/tmp/kafka-broker.log`)에서 동일 시간대 에러를 함께 확인하세요.

## 6. 종료

브로커 종료:

```bash
bin/kafka-server-stop.sh
```

필요시 강제 종료:

```bash
pkill -f kafka.Kafka
```

## 7. 그래프 생성 (Java)

토픽 생성 실험 CSV(`topic_create_requests_*.csv`)를 통합해서 아래 3개 그래프를 생성합니다.

- `e2e_latency.png`
- `on_metadata_duration.png`
- `create_topics_duration.png`

기본 실행:

```bash
analysis/run_create_topic_latency_plot_pipeline.sh
```

기본 입력/출력:

- 입력 디렉토리: `kafka-4.2/output/topic_create_latency`
- 출력 디렉토리: `kafka-4.2/figures/create-topic-latency-test`

특정 CSV 하나만 그리려면:

```bash
analysis/run_create_topic_latency_plot_pipeline.sh \
  --input-csv kafka-4.2/output/topic_create_latency/topic_create_requests_20260223_215534.csv
```

Y축 범위 제한 예시:

```bash
analysis/run_create_topic_latency_plot_pipeline.sh \
  --input-dir kafka-4.2/output/topic_create_latency \
  --e2e-min-ms 20 --e2e-max-ms 80 \
  --on-metadata-min-ms 8 --on-metadata-max-ms 30 \
  --create-topics-min-us 90 --create-topics-max-us 300
```

참고:

- 기본 통합 모드는 입력 디렉토리 내 모든 `topic_create_requests_*.csv`를 합쳐서 그립니다.
- `e2e_latency_us`, `on_metadata_duration_us`는 그래프에서 `ms`로 변환해 표시합니다.
- `create_topics_duration_us`는 `us` 단위 그대로 표시합니다.
