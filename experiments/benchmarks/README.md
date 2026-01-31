# Kafka Producer Benchmark (Docker Compose)

이 벤치마크는 Docker Compose를 사용하여 Kafka 클러스터와 Producer를 실행하고 성능을 측정합니다.

## 구성 요소

- **Kafka**: Bitnami Kafka 4.1.1 (KRaft mode)
- **Producer**: Java 기반 Kafka 메시지 생성기
  - 1000개 토픽에 각각 10MB 메시지 전송
  - JFR(Java Flight Recorder) 프로파일링
  - 네트워크 대역폭 제한 (5Gbps)

## 사용 방법

### 기본 실행

```bash
./script.sh
```

### Auto Create Topics 비활성화

```bash
./script.sh --auto-create-topics=false
```

## 출력

실행 결과는 `out/` 디렉토리에 저장됩니다:

```
out/
├── enabled/              # auto-create-topics=true 결과
│   └── run_YYYYMMDD_HHMMSS/
│       └── run/
│           ├── metrics.txt   # 메시지 전송 메트릭
│           ├── jfr.jfr       # JFR 프로파일
│           └── app.log       # 애플리케이션 로그
└── disabled/             # auto-create-topics=false 결과
    └── run_YYYYMMDD_HHMMSS/
        └── run/
            ├── metrics.txt
            ├── jfr.jfr
            └── app.log
```

## 환경 변수

docker-compose.yml에서 다음 환경 변수를 설정할 수 있습니다:

- `AUTO_CREATE_TOPICS`: 토픽 자동 생성 여부 (default: true)
- `ACKS`: Producer acks 설정 (default: 1)
- `REQUEST_TIMEOUT_MS`: 요청 타임아웃 (default: 15000)
- `DELIVERY_TIMEOUT_MS`: 전송 타임아웃 (default: 30000)
- `MAX_BLOCK_MS`: 최대 블록 시간 (default: 15000)
- `SEND_ACK_TIMEOUT_MS`: 전송 ACK 타임아웃 (default: 15000)

## 리소스 제한

### Kafka
- CPU: 0.75 코어
- Memory: 2GB
- JVM Heap: 1GB

### Producer
- CPU: 1 코어
- Memory: 1GB
- JVM Heap: 512MB
- Network: 5Gbps (tc 사용)

## 분석

결과 분석을 위해 `analyze_experiments.py`를 사용할 수 있습니다:

```bash
python analyze_experiments.py
```
