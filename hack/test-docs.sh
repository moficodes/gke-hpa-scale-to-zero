#!/usr/bin/env bash
# Verification script for Ticket #4: README.md, BLOG.md, and ADR-0003.
# Verifies:
#   1. Required files exist and are non-empty.
#   2. No TODO/FIXME/TBD placeholder markers exist.
#   3. Canonical domain terms from GLOSSARY.md appear in README.md and BLOG.md.
#   4. Mermaid architecture diagrams and real GKE 1.37 (v1.37.0-gke.3503000) outputs & timings from
#      live verification are present.
#   5. All three production lessons (ADR-0001, ADR-0002, ADR-0003) are documented.
#   6. Prose outside fenced code blocks passes humanizer checks (no em/en-dashes, no curly quotes,
#      no AI-tell phrases or chatbot residue).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

README="${REPO_ROOT}/README.md"
BLOG="${REPO_ROOT}/BLOG.md"
ADR3="${REPO_ROOT}/docs/adr/0003-explicit-pods-scaleup-policy-for-wake-from-zero.md"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

assert_file_nonempty() {
  local file="$1"
  if [[ ! -s "${file}" ]]; then
    fail "Required file is missing or empty: ${file}"
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq "${needle}" "${file}"; then
    fail "${file} is missing ${label} ('${needle}')"
  fi
}

strip_code_blocks() {
  local file="$1"
  awk '
    /^```/ { in_code = !in_code; next }
    !in_code { print }
  ' "${file}"
}

echo "=== 1. Checking file existence ==="
assert_file_nonempty "${README}"
assert_file_nonempty "${BLOG}"
assert_file_nonempty "${ADR3}"

echo "=== 2. Checking ADR-0003 content ==="
assert_contains "${ADR3}" "scaleUp" "scaleUp policy reference"
assert_contains "${ADR3}" "Pods" "Pods policy type"
assert_contains "${ADR3}" "periodSeconds: 15" "periodSeconds: 15"
assert_contains "${ADR3}" "Percent" "Percent policy explanation"

echo "=== 3. Checking for TODO / placeholder markers ==="
for f in "${README}" "${BLOG}" "${ADR3}"; do
  if grep -En '\b(TODO|FIXME|TBD|XXX)\b' "${f}" >/dev/null; then
    fail "${f} contains TODO/FIXME/TBD placeholder markers"
  fi
done

echo "=== 4. Checking GLOSSARY.md canonical terms in README.md and BLOG.md ==="
GLOSSARY_TERMS=(
  "Job Queue"
  "Queue Depth"
  "Job Burst"
  "AutoscalingMetric"
  "Autoscaling Metrics Adapter"
  "Job Worker"
  "Zero-Scale State"
  "External Scale-to-Zero Override"
  "Scale-Down Stabilization Window"
)
for term in "${GLOSSARY_TERMS[@]}"; do
  assert_contains "${README}" "${term}" "glossary term '${term}'"
  assert_contains "${BLOG}" "${term}" "glossary term '${term}'"
done

echo "=== 5. Checking README.md required sections, commands, and live outputs ==="
assert_contains "${README}" '```mermaid' "Mermaid architecture diagram"
assert_contains "${README}" "v1.37.0-gke.3503000" "GKE cluster version v1.37.0-gke.3503000"
assert_contains "${README}" "make apply" "make apply command"
assert_contains "${README}" "make watch" "make watch command"
assert_contains "${README}" "make burst" "make burst command"
assert_contains "${README}" "make status" "make status command"
assert_contains "${README}" "make logs" "make logs command"
assert_contains "${README}" "make verify" "make verify command"
assert_contains "${README}" "make clean" "make clean command"
assert_contains "${README}" "autoscaling.gke.io|redis-queue-depth|pending-jobs" "HPA external metric name"
assert_contains "${README}" "or vector(0)" "ADR-0001 empty-vector fallback"
assert_contains "${README}" "ScalingDisabledReplicaCountZero" "ADR-0002 override reason"
assert_contains "${README}" "scaleUp" "ADR-0003 scaleUp policy"

echo "=== 6. Checking BLOG.md technical walkthrough, ADRs, and live GKE 1.37 capture ==="
assert_contains "${BLOG}" '```mermaid' "Mermaid architecture diagram"
assert_contains "${BLOG}" "v1.37.0-gke.3503000" "GKE cluster version v1.37.0-gke.3503000"
assert_contains "${BLOG}" "KEDA" "comparison with KEDA"
assert_contains "${BLOG}" "custom-metrics-stackdriver-adapter" "comparison with legacy adapter"
assert_contains "${BLOG}" "autoscaling.gke.io|redis-queue-depth|pending-jobs" "AutoscalingMetric hpaName"
assert_contains "${BLOG}" "or vector(0)" "ADR-0001 empty-vector PromQL fallback"
assert_contains "${BLOG}" "ScalingDisabledReplicaCountZero" "ADR-0002 External Scale-to-Zero Override reason"
assert_contains "${BLOG}" "ScalingDisabledExternalScaleToZero" "ADR-0002 External Scale-to-Zero Override secondary reason"
assert_contains "${BLOG}" "scaleUp" "ADR-0003 scaleUp policy explanation"
assert_contains "${BLOG}" "job-worker-755bf6d97d-6zvgf" "authentic captured pod name from live run"
assert_contains "${BLOG}" "ScaledToZero=True (ScaledToZero)" "captured Zero-Scale State condition"
assert_contains "${BLOG}" "ScaledToZero=False (NotScaledToZero)" "captured active scale condition"
assert_contains "${BLOG}" "+5s" "captured +5s HPA wake-up decision timing"
assert_contains "${BLOG}" "+11s" "captured +11s 5/5 Ready timing"
assert_contains "${BLOG}" "+55s" "captured +55s queue drain timing"
assert_contains "${BLOG}" "+20s" "captured +20s scale-to-zero actuation timing"

echo "=== 7. Checking prose against humanizer rules ==="
for f in "${README}" "${BLOG}" "${ADR3}"; do
  prose="$(strip_code_blocks "${f}")"

  if printf '%s\n' "${prose}" | grep -En '[—–]' >/dev/null; then
    printf '%s\n' "${prose}" | grep -En '[—–]' >&2
    fail "${f} contains em-dash or en-dash in prose outside code blocks"
  fi

  if printf '%s\n' "${prose}" | grep -En ' -- ' >/dev/null; then
    printf '%s\n' "${prose}" | grep -En ' -- ' >&2
    fail "${f} contains spaced double-hyphen in prose outside code blocks"
  fi

  if printf '%s\n' "${prose}" | grep -En '[“”‘’]' >/dev/null; then
    printf '%s\n' "${prose}" | grep -En '[“”‘’]' >&2
    fail "${f} contains curly quotes in prose outside code blocks"
  fi

  if printf '%s\n' "${prose}" | grep -Ein 'not (just|only|merely) .+ but' >/dev/null; then
    printf '%s\n' "${prose}" | grep -Ein 'not (just|only|merely) .+ but' >&2
    fail "${f} contains 'not just/only/merely X, but Y' contrast pattern in prose"
  fi

  if printf '%s\n' "${prose}" | grep -Ein '\b(delve|tapestry|testament|pivotal|underscores|showcasing|let us dive|let'\''s dive|let'\''s explore|here'\''s the thing|i hope this helps)\b' >/dev/null; then
    printf '%s\n' "${prose}" | grep -Ein '\b(delve|tapestry|testament|pivotal|underscores|showcasing|let us dive|let'\''s dive|let'\''s explore|here'\''s the thing|i hope this helps)\b' >&2
    fail "${f} contains banned AI-tell vocabulary or staged opener in prose"
  fi
done

echo "=== PASS: All documentation and blog checks succeeded! ==="
