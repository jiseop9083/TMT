#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_OUTPUT_ROOT="${ROOT_DIR}/kafka-4.2/output/jfr-producer-e2e-impact"
INPUT_PATH="${1:-${DEFAULT_OUTPUT_ROOT}}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [run-dir-or-output-root]

If a root directory is given, the latest timestamped run is used.
Outputs:
  report.md
  iteration_delta.csv
  plots/producer_e2e_overlay_scatter.png
  plots/producer_e2e_off_scatter.png
  plots/producer_e2e_default_scatter.png
  plots/producer_e2e_profile_scatter.png
  plots/producer_e2e_custom_scatter.png
EOF
}

if [[ "${INPUT_PATH}" == "--help" || "${INPUT_PATH}" == "-h" ]]; then
  usage
  exit 0
fi

resolve_run_dir() {
  local path="$1"
  if [[ ! -d "${path}" ]]; then
    echo "Path not found: ${path}" >&2
    exit 1
  fi
  local base_name
  base_name="$(basename "${path}")"
  if [[ "${base_name}" == 20* ]]; then
    echo "${path}"
    return
  fi
  local latest=""
  shopt -s nullglob
  for d in "${path}"/20*; do
    if [[ -d "${d}" ]]; then
      latest="${d}"
    fi
  done
  shopt -u nullglob
  if [[ -z "${latest}" ]]; then
    echo "No timestamped run directories found under ${path}" >&2
    exit 1
  fi
  echo "${latest}"
}

RUN_DIR="$(resolve_run_dir "${INPUT_PATH}")"
ITERATION_SUMMARY="${RUN_DIR}/iteration_summary.csv"
CONDITION_SUMMARY="${RUN_DIR}/condition_summary.csv"
COMPARISON_CSV="${RUN_DIR}/comparison.csv"
ITERATION_DELTA="${RUN_DIR}/iteration_delta.csv"
REPORT_MD="${RUN_DIR}/report.md"
PLOTS_DIR="${RUN_DIR}/plots"

for required in "${ITERATION_SUMMARY}" "${CONDITION_SUMMARY}" "${COMPARISON_CSV}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Required file not found: ${required}" >&2
    exit 1
  fi
done

awk -F',' '
  NR == 1 { next }
  {
    iter = $2
    cond = $1
    avg[cond, iter] = $4
    p100[cond, iter] = $5
    p99[cond, iter] = $6
    p95[cond, iter] = $7
    p75[cond, iter] = $8
    p50[cond, iter] = $9
    p25[cond, iter] = $10
    p0[cond, iter] = $11
    seenIter[iter] = 1
    seenCond[cond] = 1
  }
  END {
    print "condition,iteration,avg_delta_ms,p100_delta_ms,p99_delta_ms,p95_delta_ms,p75_delta_ms,p50_delta_ms,p25_delta_ms,p0_delta_ms"
    for (iter in seenIter) {
      for (cond in seenCond) {
        if (cond == "off") continue
        if ((("off", iter) in avg) && ((cond, iter) in avg)) {
          printf "%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
            cond, iter,
            avg[cond, iter] - avg["off", iter],
            p100[cond, iter] - p100["off", iter],
            p99[cond, iter] - p99["off", iter],
            p95[cond, iter] - p95["off", iter],
            p75[cond, iter] - p75["off", iter],
            p50[cond, iter] - p50["off", iter],
            p25[cond, iter] - p25["off", iter],
            p0[cond, iter] - p0["off", iter]
        }
      }
    }
  }' "${ITERATION_SUMMARY}" \
  | sort -t',' -k1,1 -k2,2n >"${ITERATION_DELTA}"

TMP_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_BUILD_DIR}"' EXIT

javac -d "${TMP_BUILD_DIR}" "${SCRIPT_DIR}/ProducerJfrImpactPlot.java"
java -cp "${TMP_BUILD_DIR}" ProducerJfrImpactPlot --run-dir "${RUN_DIR}" --out-dir "${PLOTS_DIR}"

python - <<'PY' "${RUN_DIR}" "${CONDITION_SUMMARY}" "${COMPARISON_CSV}" "${ITERATION_DELTA}" "${REPORT_MD}"
import csv
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
condition_summary = Path(sys.argv[2])
comparison_csv = Path(sys.argv[3])
iteration_delta = Path(sys.argv[4])
report_md = Path(sys.argv[5])

def read_csv(path):
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

condition_rows = read_csv(condition_summary)
comparison_rows = read_csv(comparison_csv)
iteration_rows = read_csv(iteration_delta)

def fmt(v):
    try:
        return f"{float(v):.3f}"
    except Exception:
        return str(v)

def delta_word(v):
    try:
        x = float(v)
    except Exception:
        return "unknown"
    if x > 0:
        return "increased"
    if x < 0:
        return "decreased"
    return "unchanged"

lines = []
lines.append("# Producer E2E JFR Impact Report")
lines.append("")
lines.append(f"Run directory: `{run_dir}`")
lines.append("")
lines.append("## Condition Summary")
lines.append("")
lines.append("| condition | iteration_count | sample_count | avg_ms | p100_ms | p99_ms | p95_ms | p75_ms | p50_ms | p25_ms | p0_ms |")
lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for row in condition_rows:
    lines.append(
        f"| {row['condition']} | {row['iteration_count']} | {row['sample_count']} | "
        f"{fmt(row['avg_ms'])} | {fmt(row['p100_ms'])} | {fmt(row['p99_ms'])} | "
        f"{fmt(row['p95_ms'])} | {fmt(row['p75_ms'])} | {fmt(row['p50_ms'])} | "
        f"{fmt(row['p25_ms'])} | {fmt(row['p0_ms'])} |"
    )

lines.append("")
lines.append("## Delta Vs Off")
lines.append("")
lines.append("| condition | metric | off_ms | condition_ms | delta_ms | delta_pct |")
lines.append("| --- | --- | ---: | ---: | ---: | ---: |")
for row in comparison_rows:
    lines.append(
        f"| {row['condition']} | {row['metric']} | {fmt(row['off_ms'])} | {fmt(row['condition_ms'])} | "
        f"{fmt(row['delta_ms'])} | {fmt(row['delta_pct'])} |"
    )

lines.append("")
lines.append("## Per-Iteration Delta Vs Off")
lines.append("")
lines.append("| condition | iteration | avg_delta_ms | p100_delta_ms | p99_delta_ms | p95_delta_ms | p75_delta_ms | p50_delta_ms | p25_delta_ms | p0_delta_ms |")
lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for row in iteration_rows:
    lines.append(
        f"| {row['condition']} | {row['iteration']} | {fmt(row['avg_delta_ms'])} | {fmt(row['p100_delta_ms'])} | "
        f"{fmt(row['p99_delta_ms'])} | {fmt(row['p95_delta_ms'])} | {fmt(row['p75_delta_ms'])} | "
        f"{fmt(row['p50_delta_ms'])} | {fmt(row['p25_delta_ms'])} | {fmt(row['p0_delta_ms'])} |"
    )

lines.append("")
lines.append("## Interpretation")
lines.append("")
for row in comparison_rows:
    lines.append(
        f"- {row['condition']} {row['metric']}: {delta_word(row['delta_ms'])} by "
        f"{fmt(row['delta_ms'])} ms ({fmt(row['delta_pct'])}%) versus off."
    )

lines.append("")
lines.append("## Plots")
lines.append("")
lines.append("- `plots/producer_e2e_overlay_scatter.png`: off/default/profile/custom raw latency overlay 점그래프")
lines.append("- `plots/producer_e2e_off_scatter.png`: off raw latency 점그래프")
lines.append("- `plots/producer_e2e_default_scatter.png`: default raw latency 점그래프")
lines.append("- `plots/producer_e2e_profile_scatter.png`: profile raw latency 점그래프")
lines.append("- `plots/producer_e2e_custom_scatter.png`: custom raw latency 점그래프")

report_md.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

echo "Run directory: ${RUN_DIR}"
echo "Report: ${REPORT_MD}"
echo "Iteration delta CSV: ${ITERATION_DELTA}"
echo "Plots: ${PLOTS_DIR}"
