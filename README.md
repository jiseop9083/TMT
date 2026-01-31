# Kafka 프로듀서 실험 + JFR/샘플링 분석

Kafka KRaft 클러스터의 프로듀서 옵션을 비교하고, 실행 중 수집한 로그/프로파일 결과를 분석·시각화하는 실험 코드입니다.
이 README는 현재 디렉터리의 스크립트를 기준으로 설명합니다(생성물 제외).

## 디렉터리 구조

- `experiments/benchmarks/`: 클러스터 구성, 프로듀서 실행, 실험 출력 수집 스크립트
- `experiments/analyses/`: 결과 분석/시각화 스크립트 및 Java 분석 코드
- `experiments/scripts/`: 실행 자동화/보조 스크립트
- `experiments/output/`: 실험 결과(생성물, Git 제외)
- `experiments/figures/`: 그래프 이미지(생성물, Git 제외)

## 준비사항

- Kubernetes 클러스터 접근 권한
- `kubectl`, `helm`, `docker`
- Python 3 (`matplotlib` 필요)
- JDK 21 이상(분석 도구 `java`, `javac`, `jfr` 사용)

## 실행 흐름 (요약)

1. 모니터링/Strimzi 설치

```bash
cd experiments/benchmarks
./apply_metrics_server.sh
./install_monitoring.sh
./install_strimzi.sh
```

2. Kafka 클러스터 배포 (auto.create.topics.enable 제어)

```bash
cd experiments/benchmarks
./apply_cluster.sh True   # auto.create.topics.enable=true
./apply_cluster.sh False  # auto.create.topics.enable=false
```

3. 프로듀서 실험 실행

```bash
cd experiments/benchmarks
./script.sh --auto-create-topics=true
# 또는
./script.sh --auto-create-topics=false
```

4. 결과 분석 및 시각화

```bash
# CSV 생성
python3 experiments/benchmarks/analyze_experiments.py --out-dir experiments/benchmarks/out

# 그래프 생성
python3 experiments/analyses/plot_experiments.py --out-dir experiments/benchmarks/out
```

## 주요 스크립트/옵션

### `experiments/benchmarks/script.sh`

- 역할: 프로듀서 컨테이너 빌드 및 실험 Pod 실행 후 결과 복사
- 주요 옵션
  - `--auto-create-topics` (`true`/`false`)
- 주요 환경변수
  - `NS`(default `kafka`)
  - `IMAGE_NAME`(default `my-kafka-producer:latest`)
  - `CONFIG_MANIFEST`(default `experiments/benchmarks/producer_config.yaml`)
  - `KAFKA_CLIENTS_VERSION`(default `4.1.1`)
  - `SLF4J_VERSION`(default `2.0.16`)
  - `POD_TEMPLATE`(default `experiments/benchmarks/kafka_producer_experiment_pod.yaml`)
  - `OUTDIR`(default `experiments/benchmarks/out/<enabled|disabled>/run_<timestamp>`)

### `experiments/benchmarks/analyze_experiments.py`

- 역할: 실험 결과를 CSV로 정리
- 입력: 각 run 디렉터리의 `metrics.txt`, `async.collapsed`, `app.log`, `jfr.jfr`
- 옵션
  - `--out-dir`: 특정 run 디렉터리 또는 상위 디렉터리
  - `--full-paths`: `doSend` 하위 호출 전체 경로를 CSV에 포함
  - `--jfr-progress`: JFR 파싱 진행 로그 출력

### `experiments/analyses/plot_experiments.py`

- 역할: CSV를 기반으로 그래프 생성
- 생성 그래프: `e2e_latency.png`, `per_method_latency.png`, `cpu_load.png`, `memory_usage.png`
- 옵션
  - `--out-dir`: 특정 run 디렉터리 또는 상위 디렉터리
  - `--analysis-dir`: 분석 결과 디렉터리 직접 지정
  - `--plot-dir`: 그래프 출력 경로 지정

### `experiments/analyses/run_latency_pipeline.sh`

- 용도: `experiments/output` 아래 `run_*` 결과를 분석해 `latency_breakdown.csv`와 그래프 PNG 생성
- 기본 경로: `experiments/output` (필요 시 `--out-dir` 또는 첫 번째 인자로 경로 지정)
- 그래프/CSV/JSON 저장: `experiments/figures` 아래로 `experiments/output`과 동일한 구조(단, `analysis` 디렉터리는 제외)
- 예:

```bash
# 최신 run 폴더 기준으로 전체 데이터 그래프
experiments/analyses/run_latency_pipeline.sh

# 특정 출력 경로에서 실행 + zscore 필터 + 회귀선
experiments/analyses/run_latency_pipeline.sh experiments/output/disabled_with_jfr --zscore 2.33 --regression

# y축 범위/간격 지정
experiments/analyses/run_latency_pipeline.sh --max-ms 300 --min-ms 10 --interval-ms 25
```

- 옵션
  - `--out-dir <dir>`: 특정 run 디렉터리 또는 상위 디렉터리 지정
  - `--latency-only`: CSV 생성만 하고 그래프는 생성하지 않음
  - `--plot-only`: CSV 생성을 건너뛰고 그래프만 생성
  - `--zscore <number>`: 해당 z-score 기준으로 이상치 제외 (미지정 시 필터링 없음)
  - `--regression`: 그래프에 회귀선 표시
  - `--max-ms <number>`: max-ms 초과 데이터 제외 + y축 상단 값 고정 (기본 200)
  - `--min-ms <number>`: min-ms 미만 데이터 제외 + y축 하단 값 고정 (기본 0)
  - `--interval-ms <number>`: y축 눈금 간격

## 출력물 구조 (예시)

```
experiments/benchmarks/out/
  enabled/
    run_20250130_153000/
      run/
        metrics.txt
        app.log
        async.collapsed
        jfr.jfr
      analysis/
        summary.csv
        metadata_by_frame.csv
        do_send_children.csv
        resources.csv
        plots/
          e2e_latency.png
          per_method_latency.png
          cpu_load.png
          memory_usage.png
```

## 참고/주의

- `experiments/scripts/auto_topic_*.sh`는 `experiments/benchmarks/`의 스크립트를 호출하도록 작성되어 있습니다.
  실제 실행 경로는 `experiments/benchmarks/`에서 실행하거나 경로를 맞춰주세요.
- `experiments/output`, `experiments/figures`는 생성물 디렉터리로 `.gitignore`에 포함되어 있습니다.
