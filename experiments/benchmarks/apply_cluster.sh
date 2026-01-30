#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

NS="${NS:-kafka}"
CLUSTER_MANIFEST="${CLUSTER_MANIFEST:-${SCRIPT_DIR}/kafka_cluster.yaml}"

# ===== 인자 처리 =====
AUTO_CREATE="${1:-True}"

if [[ "${AUTO_CREATE}" =~ ^(False|false|0)$ ]]; then
  AUTO_CREATE_VALUE="false"
else
  AUTO_CREATE_VALUE="true"
fi

echo "[info] auto.create.topics.enable = ${AUTO_CREATE_VALUE}"

# ===== 임시 manifest 생성 =====
TMP_MANIFEST="$(mktemp)"

sed "s/auto.create.topics.enable: .*/auto.create.topics.enable: ${AUTO_CREATE_VALUE}/" \
  "${CLUSTER_MANIFEST}" > "${TMP_MANIFEST}"

# ===== 적용 =====
echo "[info] applying cluster manifest ${TMP_MANIFEST}..."
kubectl apply -n "${NS}" -f "${TMP_MANIFEST}"
kubectl wait -n "${NS}" kafka/my-cluster --for=condition=Ready --timeout=600s || true

# ===== 정리 =====
rm -f "${TMP_MANIFEST}"
