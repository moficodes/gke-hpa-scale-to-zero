#!/usr/bin/env bash
# End-to-end verification of the GKE 1.37 HPA Scale-to-Zero stack (Ticket #2).
# Verifies:
#   1. Manifest files exist and pass server-side dry-run validation.
#   2. Applying manifests creates namespace `hpa-scale-to-zero` and brings `Deployment/redis-queue` to 1/1 Ready.
#   3. `AutoscalingMetric/redis-queue-depth` populates `hpaName: autoscaling.gke.io|redis-queue-depth|pending-jobs` with zero errors.
#   4. `kube-system/autoscaling-metrics-adapter` (AMA) wakes to 1 ready replica.
#   5. With an empty Job Queue (`LLEN jobs == 0`), `HorizontalPodAutoscaler/job-worker-hpa` actuates initial `1 -> 0`
#      scale-down on `Deployment/job-worker` with conditions `AbleToScale: True`, `ScalingActive: True`, and `ScaledToZero: True`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-gke_mofilabs_us-central1-a_ate-cluster}"
NAMESPACE="hpa-scale-to-zero"
EXPECTED_HPA_METRIC_NAME="autoscaling.gke.io|redis-queue-depth|pending-jobs"

KUBECTL=(kubectl --context="${KUBE_CONTEXT}")

log() {
  printf '[%s] %s\n' "$(date -u +'%H:%M:%S')" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "$(date -u +'%H:%M:%S')" "$*" >&2
  exit 1
}

log "Step 1/6: Checking manifest files in ${REPO_ROOT}/manifests ..."
for manifest in \
  "${REPO_ROOT}/manifests/01-redis-queue.yaml" \
  "${REPO_ROOT}/manifests/02-worker-and-hpa.yaml"; do
  if [[ ! -f "${manifest}" ]]; then
    fail "Missing required manifest: ${manifest}"
  fi
done

log "Step 2/6: Applying and validating manifests with server-side dry-run on context ${KUBE_CONTEXT} ..."
"${KUBECTL[@]}" apply -f "${REPO_ROOT}/manifests/01-redis-queue.yaml"
"${KUBECTL[@]}" apply -f "${REPO_ROOT}/manifests/02-worker-and-hpa.yaml"
"${KUBECTL[@]}" apply --dry-run=server -f "${REPO_ROOT}/manifests/01-redis-queue.yaml" >/dev/null
"${KUBECTL[@]}" apply --dry-run=server -f "${REPO_ROOT}/manifests/02-worker-and-hpa.yaml" >/dev/null

log "Step 3/6: Waiting for namespace ${NAMESPACE} and Deployment/redis-queue (1/1 Ready) ..."
ns_phase="$("${KUBECTL[@]}" get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}')"
if [[ "${ns_phase}" != "Active" ]]; then
  fail "Expected namespace ${NAMESPACE} phase Active, got '${ns_phase}'"
fi
"${KUBECTL[@]}" rollout status deployment/redis-queue -n "${NAMESPACE}" --timeout=180s

# Ensure Job Queue is empty for initial 1 -> 0 verification
"${KUBECTL[@]}" exec -n "${NAMESPACE}" deploy/redis-queue -c redis -- redis-cli del jobs >/dev/null

log "Step 4/6: Waiting for AutoscalingMetric/redis-queue-depth status and AMA activation ..."
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
  fail "Expected AutoscalingMetric hpaName '${EXPECTED_HPA_METRIC_NAME}', got '${asm_hpa_name}' (errors: ${asm_errors})"
fi
if [[ -n "${asm_errors}" && "${asm_errors}" != "[]" ]]; then
  fail "AutoscalingMetric/redis-queue-depth reported errors: ${asm_errors}"
fi
log "AutoscalingMetric/redis-queue-depth ready: hpaName=${asm_hpa_name}"

"${KUBECTL[@]}" rollout status deployment/autoscaling-metrics-adapter -n kube-system --timeout=180s
ama_ready="$("${KUBECTL[@]}" get deployment autoscaling-metrics-adapter -n kube-system -o jsonpath='{.status.readyReplicas}')"
if [[ "${ama_ready}" != "1" ]]; then
  fail "Expected kube-system/autoscaling-metrics-adapter readyReplicas=1, got '${ama_ready}'"
fi
log "kube-system/autoscaling-metrics-adapter is 1/1 Ready."

log "Step 5/6: Waiting for HorizontalPodAutoscaler/job-worker-hpa to scale Deployment/job-worker to 0 (Zero-Scale State) ..."
deadline=$((SECONDS + 240))
worker_replicas=""
able_to_scale=""
scaling_active=""
scaled_to_zero=""
while (( SECONDS < deadline )); do
  worker_replicas="$("${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')"
  able_to_scale="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="AbleToScale")].status}' 2>/dev/null || true)"
  scaling_active="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null || true)"
  scaled_to_zero="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScaledToZero")].status}' 2>/dev/null || true)"

  log "  [poll] job-worker spec.replicas=${worker_replicas} | AbleToScale=${able_to_scale} ScalingActive=${scaling_active} ScaledToZero=${scaled_to_zero}"
  if [[ "${worker_replicas}" == "0" && "${able_to_scale}" == "True" && "${scaling_active}" == "True" && "${scaled_to_zero}" == "True" ]]; then
    break
  fi
  sleep 5
done

if [[ "${worker_replicas}" != "0" || "${able_to_scale}" != "True" || "${scaling_active}" != "True" || "${scaled_to_zero}" != "True" ]]; then
  "${KUBECTL[@]}" describe hpa job-worker-hpa -n "${NAMESPACE}" >&2 || true
  fail "HPA did not reach Zero-Scale State (replicas=${worker_replicas}, AbleToScale=${able_to_scale}, ScalingActive=${scaling_active}, ScaledToZero=${scaled_to_zero})"
fi

log "Step 6/6: All Ticket #2 acceptance criteria verified!"
"${KUBECTL[@]}" get autoscalingmetric,hpa,deploy,pods -n "${NAMESPACE}"
