#!/usr/bin/env bash
# End-to-end verification harness for the GKE 1.37+ HPA Scale-to-Zero lifecycle (Ticket #3).
# Exercises and asserts the full 1 -> 0 -> 5 -> 0 lifecycle via Makefile targets and hack/watch.sh:
#   1. `make apply` deploys the stack and reaches the initial Zero-Scale State (1 -> 0 replicas,
#      AbleToScale=True, ScalingActive=True, ScaledToZero=True).
#   2. `make status` ( `./hack/watch.sh --once` ) renders Queue Depth, AMA readiness,
#      AutoscalingMetric status (hpaName), HPA conditions, and job-worker Pods.
#   3. `make burst JOBS=100` pushes 100 synthetic jobs into the Redis Job Queue (LLEN jobs == 100)
#      and prints the updated Queue Depth.
#   4. HPA transitions ScaledToZero from True to False and scales Deployment/job-worker from 0 to 5
#      running replicas (100 / 20 = 5). Captures `make status` at 5 running replicas.
#   5. Running job-worker Pods drain LLEN jobs down to 0.
#   6. After the 15-second Scale-Down Stabilization Window, HPA scales Deployment/job-worker back
#      down from 5 to 0 replicas and sets ScaledToZero=True. Captures `make status` at 0 replicas.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NAMESPACE="hpa-scale-to-zero"
EXPECTED_HPA_METRIC_NAME="autoscaling.gke.io|redis-queue-depth|pending-jobs"

KUBECTL=(kubectl --context="${KUBE_CONTEXT}")

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local description="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail "Assertion failed (${description}): expected output to contain '${needle}'"
  fi
}

log "=== Pre-check: Verifying required CLI files exist ==="
if [[ ! -f "${REPO_ROOT}/Makefile" ]]; then
  fail "Missing ${REPO_ROOT}/Makefile"
fi
if [[ ! -x "${REPO_ROOT}/hack/watch.sh" ]]; then
  fail "Missing or non-executable ${REPO_ROOT}/hack/watch.sh"
fi

log "=== Stage 1/5: Deploying stack via 'make apply' and verifying initial Zero-Scale State (1 -> 0) ==="
make --no-print-directory KUBE_CONTEXT="${KUBE_CONTEXT}" apply

"${KUBECTL[@]}" rollout status deployment/redis-queue -n "${NAMESPACE}" --timeout=180s
"${KUBECTL[@]}" exec -n "${NAMESPACE}" deploy/redis-queue -c redis -- redis-cli del jobs >/dev/null

deadline=$((SECONDS + 180))
asm_hpa_name=""
asm_errors=""
while (( SECONDS < deadline )); do
  asm_hpa_name="$("${KUBECTL[@]}" get autoscalingmetric redis-queue-depth -n "${NAMESPACE}" \
    -o jsonpath='{.status.metricStatuses[0].hpaName}' 2>/dev/null || true)"
  asm_errors="$("${KUBECTL[@]}" get autoscalingmetric redis-queue-depth -n "${NAMESPACE}" \
    -o jsonpath='{.status.metricStatuses[0].errors}' 2>/dev/null || true)"
  if [[ "${asm_hpa_name}" == "${EXPECTED_HPA_METRIC_NAME}" ]] && [[ -z "${asm_errors}" || "${asm_errors}" == "[]" ]]; then
    break
  fi
  sleep 3
done
if [[ "${asm_hpa_name}" != "${EXPECTED_HPA_METRIC_NAME}" ]]; then
  fail "Expected AutoscalingMetric hpaName '${EXPECTED_HPA_METRIC_NAME}', got '${asm_hpa_name}'"
fi

"${KUBECTL[@]}" rollout status deployment/autoscaling-metrics-adapter -n kube-system --timeout=180s

deadline=$((SECONDS + 240))
while (( SECONDS < deadline )); do
  worker_replicas="$("${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')"
  worker_pods="$("${KUBECTL[@]}" get pods -n "${NAMESPACE}" -l app=job-worker --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  able_to_scale="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="AbleToScale")].status}' 2>/dev/null || true)"
  scaling_active="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null || true)"
  scaled_to_zero="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScaledToZero")].status}' 2>/dev/null || true)"

  log "  [init-poll] spec.replicas=${worker_replicas} pods=${worker_pods} | AbleToScale=${able_to_scale} ScalingActive=${scaling_active} ScaledToZero=${scaled_to_zero}"
  if [[ "${worker_replicas}" == "0" && "${worker_pods}" == "0" && "${able_to_scale}" == "True" && "${scaling_active}" == "True" && "${scaled_to_zero}" == "True" ]]; then
    break
  fi
  sleep 4
done

if [[ "${worker_replicas}" != "0" || "${scaled_to_zero}" != "True" ]]; then
  fail "Stack did not settle into initial Zero-Scale State (replicas=${worker_replicas}, ScaledToZero=${scaled_to_zero})"
fi

log "=== Stage 2/5: Verifying 'make status' in initial Zero-Scale State (0 replicas) ==="
status_initial="$(make --no-print-directory KUBE_CONTEXT="${KUBE_CONTEXT}" status)"
printf '%s\n' "${status_initial}"

assert_contains "${status_initial}" "Queue Depth" "status includes Queue Depth"
assert_contains "${status_initial}" "autoscaling-metrics-adapter" "status includes AMA readiness"
assert_contains "${status_initial}" "${EXPECTED_HPA_METRIC_NAME}" "status includes AutoscalingMetric hpaName"
assert_contains "${status_initial}" "AbleToScale=True" "status includes AbleToScale=True"
assert_contains "${status_initial}" "ScalingActive=True" "status includes ScalingActive=True"
assert_contains "${status_initial}" "ScaledToZero=True" "status includes ScaledToZero=True"

log "=== Stage 3/5: Triggering 100-job burst via 'make burst JOBS=100' and verifying 0 -> 5 scale-from-zero ==="
burst_start_sec=${SECONDS}
burst_out="$(make --no-print-directory KUBE_CONTEXT="${KUBE_CONTEXT}" burst JOBS=100)"
printf '%s\n' "${burst_out}"

llen_after_burst="$("${KUBECTL[@]}" exec -n "${NAMESPACE}" deploy/redis-queue -c redis -- redis-cli llen jobs | tr -d '\r[:space:]')"
log "Redis LLEN jobs immediately after burst: ${llen_after_burst}"
if (( llen_after_burst < 95 || llen_after_burst > 100 )); then
  fail "Expected LLEN jobs in [95..100] immediately after burst, got '${llen_after_burst}'"
fi
assert_contains "${burst_out}" "100" "make burst output prints updated Queue Depth (100)"

deadline=$((SECONDS + 180))
first_scale_logged=0
reached_five_replicas=0
while (( SECONDS < deadline )); do
  q_depth="$("${KUBECTL[@]}" exec -n "${NAMESPACE}" deploy/redis-queue -c redis -- redis-cli llen jobs | tr -d '\r[:space:]')"
  spec_replicas="$("${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')"
  ready_replicas="$("${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}')"
  ready_replicas="${ready_replicas:-0}"
  hpa_desired="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" -o jsonpath='{.status.desiredReplicas}')"
  scaled_to_zero="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScaledToZero")].status}' 2>/dev/null || true)"
  elapsed=$((SECONDS - burst_start_sec))

  log "  [scale-up poll +${elapsed}s] LLEN=${q_depth} | HPA desired=${hpa_desired} ScaledToZero=${scaled_to_zero} | deploy spec=${spec_replicas} ready=${ready_replicas}"

  if (( first_scale_logged == 0 && spec_replicas > 0 )); then
    log "  --> HPA actuated scale-from-zero (0 -> ${spec_replicas}) at +${elapsed}s (ScaledToZero=${scaled_to_zero})"
    first_scale_logged=1
  fi

  if [[ "${spec_replicas}" == "5" && "${ready_replicas}" == "5" && "${scaled_to_zero}" == "False" ]]; then
    log "  --> Reached target scale of 5/5 Ready job-worker replicas at +${elapsed}s!"
    reached_five_replicas=1
    break
  fi
  sleep 2
done

if (( reached_five_replicas == 0 )); then
  "${KUBECTL[@]}" describe hpa job-worker-hpa -n "${NAMESPACE}" >&2 || true
  fail "HPA did not scale Deployment/job-worker to 5/5 Ready replicas with ScaledToZero=False"
fi

log "=== Capturing 'make status' while at 5/5 running Job Worker replicas ==="
status_scaled_up="$(make --no-print-directory KUBE_CONTEXT="${KUBE_CONTEXT}" status)"
printf '%s\n' "${status_scaled_up}"

assert_contains "${status_scaled_up}" "ScaledToZero=False" "scaled-up status shows ScaledToZero=False"
assert_contains "${status_scaled_up}" "5/5" "scaled-up status shows 5/5 ready replicas"

log "=== Capturing sample 'make logs' from active Job Worker pods ==="
make --no-print-directory KUBE_CONTEXT="${KUBE_CONTEXT}" logs

log "=== Stage 4/5: Waiting for 5 Job Worker replicas to drain Queue Depth (LLEN jobs) to 0 ==="
drain_start_sec=${SECONDS}
deadline=$((SECONDS + 180))
drained=0
while (( SECONDS < deadline )); do
  q_depth="$("${KUBECTL[@]}" exec -n "${NAMESPACE}" deploy/redis-queue -c redis -- redis-cli llen jobs | tr -d '\r[:space:]')"
  spec_replicas="$("${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')"
  ready_replicas="$("${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}')"
  ready_replicas="${ready_replicas:-0}"
  elapsed_total=$((SECONDS - burst_start_sec))

  log "  [drain poll +${elapsed_total}s] LLEN=${q_depth} | deploy spec=${spec_replicas} ready=${ready_replicas}"
  if [[ "${q_depth}" == "0" ]]; then
    drain_elapsed=$((SECONDS - drain_start_sec))
    log "  --> Job Queue drained to 0 at +${elapsed_total}s since burst (${drain_elapsed}s drain duration)"
    drained=1
    break
  fi
  sleep 3
done

if (( drained == 0 )); then
  fail "Job Queue did not drain to 0 within timeout"
fi

log "=== Stage 5/5: Waiting for HPA to scale Deployment/job-worker from 5 -> 0 after 15s Scale-Down Stabilization Window ==="
empty_queue_sec=${SECONDS}
deadline=$((SECONDS + 240))
scaled_back_to_zero=0
while (( SECONDS < deadline )); do
  q_depth="$("${KUBECTL[@]}" exec -n "${NAMESPACE}" deploy/redis-queue -c redis -- redis-cli llen jobs | tr -d '\r[:space:]')"
  spec_replicas="$("${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')"
  worker_pods="$("${KUBECTL[@]}" get pods -n "${NAMESPACE}" -l app=job-worker --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  able_to_scale="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="AbleToScale")].status}' 2>/dev/null || true)"
  scaling_active="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null || true)"
  scaled_to_zero="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScaledToZero")].status}' 2>/dev/null || true)"
  since_empty=$((SECONDS - empty_queue_sec))
  elapsed_total=$((SECONDS - burst_start_sec))

  log "  [scale-down poll +${since_empty}s after drain / +${elapsed_total}s total] LLEN=${q_depth} | spec.replicas=${spec_replicas} pods=${worker_pods} | AbleToScale=${able_to_scale} ScalingActive=${scaling_active} ScaledToZero=${scaled_to_zero}"

  if [[ "${spec_replicas}" == "0" && "${worker_pods}" == "0" && "${able_to_scale}" == "True" && "${scaling_active}" == "True" && "${scaled_to_zero}" == "True" ]]; then
    log "  --> Returned to Zero-Scale State (5 -> 0) at +${since_empty}s after queue drain (+${elapsed_total}s total since burst)!"
    scaled_back_to_zero=1
    break
  fi
  sleep 3
done

if (( scaled_back_to_zero == 0 )); then
  "${KUBECTL[@]}" describe hpa job-worker-hpa -n "${NAMESPACE}" >&2 || true
  fail "HPA did not scale Deployment/job-worker back to 0 replicas with ScaledToZero=True"
fi

log "=== Capturing final 'make status' after returning to Zero-Scale State (0 replicas) ==="
status_final="$(make --no-print-directory KUBE_CONTEXT="${KUBE_CONTEXT}" status)"
printf '%s\n' "${status_final}"

assert_contains "${status_final}" "Queue Depth" "final status includes Queue Depth"
assert_contains "${status_final}" "0/0" "final status shows 0/0 ready replicas"
assert_contains "${status_final}" "AbleToScale=True" "final status shows AbleToScale=True"
assert_contains "${status_final}" "ScalingActive=True" "final status shows ScalingActive=True"
assert_contains "${status_final}" "ScaledToZero=True" "final status shows ScaledToZero=True"

log "=== SUCCESS: Full 1 -> 0 -> 5 -> 0 HPA Scale-to-Zero E2E verification passed! ==="
