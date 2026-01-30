# Kafka 프로듀서 실험 + JFR/샘플링 분석

Kafka KRaft 클러스터에 프로듀서 부하를 걸고, 실행 중 수집한 로그/프로파일링 결과를 분석·시각화하는 실험용 코드입니다.  
이 README는 현재 디렉터리의 파일만 기준으로 설명합니다(압축 파일 제외).

## 디렉터리 구조

- `experiments/benchmarks/`: 클러스터 구성, 프로듀서 실행, 실험 출력 수집 스크립트
- `experiments/analyses/`: 결과 분석/시각화 스크립트 및 Java 분석 코드
- `experiments/scripts/`: 자동 실행용 래퍼 스크립트
- `experiments/output/`: 실험 결과(생성물, Git 제외)
- `experiments/figures/`: 그래프 이미지(생성물, Git 제외)

## 요구사항

- Kubernetes 클러스터 접근 권한
- `kubectl`, `helm`, `docker`
- Python 3 (`matplotlib` 필요)
- JDK 21 이상(분석 시 `java`, `javac`, `jfr` 사용)

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

- 역할: 프로듀서 컨테이너 빌드 → 실험 Pod 실행 → 결과 복사
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

- 역할: 실험 결과를 CSV로 집계
- 입력: 각 실험 디렉터리의 `metrics.txt`, `async.collapsed`, `app.log`, `jfr.jfr`
- 옵션
  - `--out-dir`: 특정 run 디렉터리 또는 상위 디렉터리
  - `--full-paths`: `doSend` 하위 스택 전체 경로 CSV 생성
  - `--jfr-progress`: JFR 파싱 진행 로그 출력

### `experiments/analyses/plot_experiments.py`

- 역할: CSV를 기반으로 그래프 생성
- 생성 그래프: `e2e_latency.png`, `per_method_latency.png`, `cpu_load.png`, `memory_usage.png`
- 옵션
  - `--out-dir`: 특정 run 디렉터리 또는 상위 디렉터리
  - `--analysis-dir`: 분석 결과 디렉터리 직접 지정
  - `--plot-dir`: 그래프 출력 경로 지정

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

- `experiments/scripts/auto_topic_*.sh`는 동일 디렉터리에 있는 스크립트를 호출하도록 작성되어 있습니다.  
  현재 실제 스크립트는 `experiments/benchmarks/`에 있으므로, 실행 시 경로를 맞추거나 직접 `experiments/benchmarks/`에서 실행하는 것을 권장합니다.
- `experiments/output`, `experiments/figures`는 생성물 디렉터리로 `.gitignore`에 포함되어 있습니다.
