#!/usr/bin/env bash
set -euo pipefail

helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --version 0.49.1 \
  --namespace kafka \
  --create-namespace \
  --set resources.requests.cpu=200m \
  --set resources.requests.memory=384Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=384Mi
