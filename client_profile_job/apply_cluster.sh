#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

NS="${NS:-kafka}"
CLUSTER_MANIFEST="${CLUSTER_MANIFEST:-${SCRIPT_DIR}/kafka_cluster.yaml}"

echo "[info] applying cluster manifest ${CLUSTER_MANIFEST}..."
kubectl apply -n "${NS}" -f "${CLUSTER_MANIFEST}"
kubectl wait -n "${NS}" kafka/my-cluster --for=condition=Ready --timeout=600s || true
