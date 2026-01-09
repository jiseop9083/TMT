# Dynamic Analysis (Kafka Bench + Profiling)

This project runs producer load against a Kafka KRaft cluster and collects JFR + async-profiler data from broker pods.

## Overview
- KRaft-based Kafka cluster (Controller/Broker NodePools)
- Producer load from a loader Pod using `kafka-producer-perf-test.sh`
- JFR and async-profiler collection on broker pods

## Directory Structure
- `bench/`: bench scripts, loader manifests, and output folder
- `kafka/`: Kafka KRaft cluster/NodePool manifests
- `out/`: local output folder

## Prerequisites
- Access to a Kubernetes cluster
- `kubectl` installed
- Strimzi Operator installed with CRDs applied
- Broker image includes `jcmd` (required for JFR start/stop)
- async-profiler binaries available locally
  - `bench/scripts/async-profiler/asprof`
  - `bench/scripts/async-profiler/libasyncProfiler.so`

> Note: The broker NodePool in `kafka/kraft-cluster.yaml` includes perf-related capabilities.

## How To Run
1) Make sure the Kafka cluster is ready.
2) Run the benchmark:

```bash
make load-test
# or
./bench/scripts/run_all.sh
```

3) Check outputs:
- `bench/out/<timestamp>/bench.jfr`
- `bench/out/<timestamp>/async-profiler.html`
- `bench/out/<timestamp>/async-profiler.log`
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
- `ASYNC_EVENT` (default: `cpu`)
- `ASYNC_FALLBACK_EVENT` (default: `itimer`)
- `ASYNC_DURATION` (default: `60`)

Example:
```bash
TOPIC=bench-topic NUM_RECORDS=1000000 THROUGHPUT=20000 ./bench/scripts/run_all.sh
```

## Version Info
- Kafka (cluster): 4.1.1 (`kafka/kraft-cluster.yaml`)
- Kafka loader image: `apache/kafka:4.1.1` (`bench/manifests/kafka-loader.yaml`)
- async-profiler: local binaries in `bench/scripts/async-profiler/`

## Troubleshooting
- async-profiler fails with `perf_event_open` permission errors
  - Check capability settings in `kafka/kraft-cluster.yaml`
  - The node's `kernel.perf_event_paranoid` may need to be lowered
- `libasyncProfiler.so` load failure
  - Verify `bench/scripts/async-profiler/libasyncProfiler.so` exists
  - The script sets `LD_LIBRARY_PATH` automatically
- Loader Pod cannot find `kafka-producer-perf-test.sh`
  - Check the auto-detection logic in `bench/manifests/bench-scripts-cm.yaml`
