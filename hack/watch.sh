#!/usr/bin/env bash
# Single-pane terminal observer for the GKE 1.37+ HPA Scale-to-Zero demo.
# Usage:
#   ./hack/watch.sh --once   # Print a one-shot snapshot (used by `make status`)
#   ./hack/watch.sh          # Continuously refresh every INTERVAL seconds (used by `make watch`)

set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || echo "gke_mofilabs_us-central1-a_ate-cluster")}"
NAMESPACE="${NAMESPACE:-hpa-scale-to-zero}"
INTERVAL="${INTERVAL:-2}"

ONCE=0
if [[ "${1:-}" == "--once" ]]; then
  ONCE=1
fi

KUBECTL=(kubectl --context="${KUBE_CONTEXT}")

render_snapshot() {
  local now_utc
  now_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  local queue_depth
  queue_depth="$("${KUBECTL[@]}" exec -n "${NAMESPACE}" deploy/redis-queue -c redis -- redis-cli llen jobs 2>/dev/null | tr -d '\r[:space:]' || echo "N/A")"
  if [[ -z "${queue_depth}" ]]; then
    queue_depth="N/A"
  fi

  local ama_ready ama_desired
  ama_ready="$("${KUBECTL[@]}" get deployment autoscaling-metrics-adapter -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  ama_desired="$("${KUBECTL[@]}" get deployment autoscaling-metrics-adapter -n kube-system -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ama_ready="${ama_ready:-0}"
  ama_desired="${ama_desired:-0}"

  local asm_hpa_name asm_errors
  asm_hpa_name="$("${KUBECTL[@]}" get autoscalingmetric redis-queue-depth -n "${NAMESPACE}" \
    -o jsonpath='{.status.metricStatuses[0].hpaName}' 2>/dev/null || true)"
  asm_errors="$("${KUBECTL[@]}" get autoscalingmetric redis-queue-depth -n "${NAMESPACE}" \
    -o jsonpath='{.status.metricStatuses[0].errors}' 2>/dev/null || true)"
  asm_hpa_name="${asm_hpa_name:-<pending>}"
  if [[ -z "${asm_errors}" || "${asm_errors}" == "[]" ]]; then
    asm_errors="none"
  fi

  local worker_ready worker_spec
  worker_ready="$("${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  worker_spec="$("${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  worker_ready="${worker_ready:-0}"
  worker_spec="${worker_spec:-0}"

  local hpa_desired hpa_min hpa_max hpa_target_avg hpa_curr_val hpa_curr_avg
  hpa_desired="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)"
  hpa_min="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)"
  hpa_max="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || true)"
  hpa_target_avg="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" -o jsonpath='{.spec.metrics[0].external.target.averageValue}' 2>/dev/null || true)"
  hpa_curr_val="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" -o jsonpath='{.status.currentMetrics[0].external.current.value}' 2>/dev/null || true)"
  hpa_curr_avg="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" -o jsonpath='{.status.currentMetrics[0].external.current.averageValue}' 2>/dev/null || true)"

  local metric_display
  if [[ "${hpa_curr_avg}" == "-9223372036854775808" || -z "${hpa_curr_avg}" ]]; then
    metric_display="value=${hpa_curr_val:-0} (0 pods) / target=${hpa_target_avg:-20} (avg)"
  else
    metric_display="avg=${hpa_curr_avg} (value=${hpa_curr_val:-?}) / target=${hpa_target_avg:-20} (avg)"
  fi

  local able_to_scale scaling_active scaled_to_zero scaling_reason zero_reason
  able_to_scale="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="AbleToScale")].status}' 2>/dev/null || true)"
  scaling_active="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null || true)"
  scaling_reason="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].reason}' 2>/dev/null || true)"
  scaled_to_zero="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScaledToZero")].status}' 2>/dev/null || true)"
  zero_reason="$("${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="ScaledToZero")].reason}' 2>/dev/null || true)"

  printf '================================================================================\n'
  printf 'GKE HPA Scale-to-Zero Observer | %s | context: %s\n' "${now_utc}" "${KUBE_CONTEXT}"
  printf '================================================================================\n'
  printf 'Job Queue (redis-queue)        : Queue Depth (LLEN jobs) = %s\n' "${queue_depth}"
  printf 'AMA (kube-system)              : autoscaling-metrics-adapter = %s/%s Ready\n' "${ama_ready}" "${ama_desired}"
  printf 'AutoscalingMetric              : redis-queue-depth -> hpaName=%s (errors=%s)\n' "${asm_hpa_name}" "${asm_errors}"
  printf 'HPA (job-worker-hpa)           : desired=%s (min=%s, max=%s) | metric: %s\n' \
    "${hpa_desired:-0}" "${hpa_min:-0}" "${hpa_max:-10}" "${metric_display}"
  printf 'HPA Conditions                 : AbleToScale=%s | ScalingActive=%s (%s) | ScaledToZero=%s (%s)\n' \
    "${able_to_scale:-Unknown}" "${scaling_active:-Unknown}" "${scaling_reason:-N/A}" \
    "${scaled_to_zero:-Unknown}" "${zero_reason:-N/A}"
  printf 'Job Worker (Deployment)        : job-worker = %s/%s Ready\n' "${worker_ready}" "${worker_spec}"
  printf -- '--------------------------------------------------------------------------------\n'
  printf 'Job Worker Pods (namespace: %s):\n' "${NAMESPACE}"

  local pods_out
  pods_out="$("${KUBECTL[@]}" get pods -n "${NAMESPACE}" -l app=job-worker 2>/dev/null || true)"
  if [[ -z "${pods_out}" ]]; then
    printf '  (0 pods running — Zero-Scale State)\n'
  else
    printf '%s\n' "${pods_out}" | sed 's/^/  /'
    local latest_log
    latest_log="$("${KUBECTL[@]}" logs -n "${NAMESPACE}" -l app=job-worker --tail=1 --prefix=true 2>/dev/null | tail -n 1 || true)"
    if [[ -n "${latest_log}" ]]; then
      printf 'Latest Worker Log              : %s\n' "${latest_log}"
    fi
  fi
  printf '================================================================================\n'
}

if (( ONCE == 1 )); then
  render_snapshot
  exit 0
fi

while true; do
   snap="$(render_snapshot)"
  clear 2>/dev/null || true
  printf '%s\n' "${snap}"
  printf 'Refreshing every %ss... (Press Ctrl+C to exit)\n' "${INTERVAL}"
  sleep "${INTERVAL}"
done
