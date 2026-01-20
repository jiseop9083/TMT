#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-kafka}"
JOB_NAME="${JOB_NAME:-topic-autocreate}"
LABEL_SELECTOR="${LABEL_SELECTOR:-app=topic-autocreate}"

OUTDIR="${OUTDIR:-out/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "${OUTDIR}"

seen_file="$(mktemp)"
cleanup() { rm -f "${seen_file}"; }
trap cleanup EXIT

is_job_complete() {
  kubectl get job -n "${NS}" "${JOB_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | \
    grep -q "True"
}

while true; do
  pod="$(kubectl get pods -n "${NS}" -l "${LABEL_SELECTOR}" \
    --field-selector=status.phase=Running -o name | head -n 1 || true)"

  if [[ -z "${pod}" ]]; then
    if is_job_complete; then
      break
    fi
    sleep 2
    continue
  fi

  if grep -qx "${pod}" "${seen_file}"; then
    sleep 1
    continue
  fi

  if ! kubectl exec -n "${NS}" "${pod#pod/}" -- test -f /output/.done; then
    sleep 1
    continue
  fi

  pod_name="${pod#pod/}"
  kubectl cp -n "${NS}" "${pod_name}:/output/${pod_name}" "${OUTDIR}/${pod_name}" || true
  kubectl exec -n "${NS}" "${pod#pod/}" -- sh -lc "touch /output/.release" || true
  echo "${pod}" >> "${seen_file}"
done

echo "[info] collected to ${OUTDIR}"

kubectl delete job -n kafka topic-autocreate || true
