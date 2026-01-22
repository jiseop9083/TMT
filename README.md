# Dynamic Analysis (Kafka Bench + Profiling)

This project runs producer load against a Kafka KRaft cluster and collects JFR data from broker pods.

## Overview
- KRaft-based Kafka cluster (Controller/Broker NodePools)
- Producer load from a loader Pod using `kafka-producer-perf-test.sh`
- JFR collection on broker pods

## Directory Structure
- `bench/stress_test/`: bench scripts, loader manifests, and output folder
- `kafka/`: Kafka KRaft cluster/NodePool manifests
- `out/`: local output folder

## Prerequisites
- Access to a Kubernetes cluster
- `kubectl` installed
- Strimzi Operator installed with CRDs applied
- Broker image includes `jcmd` (required for JFR start/stop)
> Note: The broker NodePool in `kafka/kraft-cluster.yaml` includes perf-related capabilities.

## How To Run
1) Make sure the Kafka cluster is ready.
2) Run the benchmark:

```bash
make load-test
# or
./bench/stress_test/scripts/run_all.sh
```

3) Check outputs:
- `bench/out/<timestamp>/bench.jfr`
- `bench/out/<timestamp>/producer-perf-test.log`

## Environment Variables (run_all.sh)
- `NS` (default: `kafka`)
- `CLUSTER` (default: `my-cluster`)
- `TOPIC` (default: `test-topic`)
- `NUM_RECORDS` (default: `3000000`)
- `RECORD_SIZE` (default: `10240`)
- `THROUGHPUT` (default: `10000`)
- `ACKS` (default: `all`)
- `LINGER_MS` (default: `0`)
- `COMPRESSION` (default: `none`)
Example:
```bash
TOPIC=bench-topic NUM_RECORDS=1000000 THROUGHPUT=20000 ./bench/stress_test/scripts/run_all.sh
```

## Analyzer Usage (CSV + Plots)
The analyzer reads `app.log`, `metrics*.txt`, and `*.jfr` from each experiment directory and writes CSVs + plots.

### One-shot pipeline (Docker)
Run everything (JFR → JSONL → CSVs → plots) in Docker:
```bash
analyzer/run_latency_pipeline.sh client_profile_job/out
```
Run only JfrLatencyBreakdown in Docker:
```bash
analyzer/run_latency_pipeline.sh --latency-only client_profile_job/out
```
Run only plots in Docker (requires existing latency_breakdown.csv):
```bash
analyzer/run_latency_pipeline.sh --plot-only client_profile_job/out
```
Outputs are written under `analysis/` in the selected run directory:
- `analysis/latency_breakdown.csv`
- `analysis/json/*.jsonl`
 - `analysis/plots/e2e_latency.png`
 - `analysis/plots/delay_message_send.png`
 - `analysis/plots/delay_wait_on_metadata.png`

### Manual steps (local)
Generate latency breakdown CSV:
```bash
java -cp analyzer JfrLatencyBreakdown --out-dir client_profile_job/out
```
Generate plots from latency_breakdown.csv:
```bash
java -cp analyzer JfrLatencyPlot --out-dir client_profile_job/out
```
Enable Z-score filtering (default threshold 3.0):
```bash
java -cp analyzer JfrLatencyPlot --out-dir client_profile_job/out --zscore-filter
```
Change Z-score threshold:
```bash
java -cp analyzer JfrLatencyPlot --out-dir client_profile_job/out --zscore-filter --zscore-threshold 2.5
```

### Export JFR to JSON (optional)
Export JSON files under `analysis/json`:
```bash
java -cp analyzer JfrJsonExport --out-dir client_profile_job/out
```

## Version Info
- Kafka (cluster): 4.1.1 (`kafka/kraft-cluster.yaml`)
- Kafka loader image: `apache/kafka:4.1.1` (`bench/stress_test/manifests/kafka-loader.yaml`)
## Troubleshooting
- Loader Pod cannot find `kafka-producer-perf-test.sh`
  - Check the auto-detection logic in `bench/stress_test/manifests/bench-scripts-cm.yaml`
