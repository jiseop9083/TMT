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

## Version Info
- Kafka (cluster): 4.1.1 (`kafka/kraft-cluster.yaml`)
- Kafka loader image: `apache/kafka:4.1.1` (`bench/stress_test/manifests/kafka-loader.yaml`)
## Troubleshooting
- Loader Pod cannot find `kafka-producer-perf-test.sh`
  - Check the auto-detection logic in `bench/stress_test/manifests/bench-scripts-cm.yaml`
