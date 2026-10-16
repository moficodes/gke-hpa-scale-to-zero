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
# When 0 pods are running, Kubernetes HPA reports INT64_MIN for external.current.averageValue.
readonly K8S_ZERO_PODS_AVG_SENTINEL="-9223372036854775808"

render_snapshot() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  # Run independent cluster queries in parallel for fast (~1s) single-pane refresh
  (
    "${KUBECTL[@]}" exec -n "${NAMESPACE}" deploy/redis-queue -c redis -- redis-cli llen jobs 2>/dev/null \
      | tr -d '\r[:space:]' > "${tmp_dir}/queue_depth" || true
  ) &
  (
    "${KUBECTL[@]}" get deployment autoscaling-metrics-adapter -n kube-system \
      -o jsonpath='{.status.readyReplicas}~{.spec.replicas}' 2>/dev/null > "${tmp_dir}/ama" || true
  ) &
  (
    "${KUBECTL[@]}" get autoscalingmetric redis-queue-depth -n "${NAMESPACE}" \
      -o jsonpath='{.status.metricStatuses[0].hpaName}~{.status.metricStatuses[0].errors}' 2>/dev/null > "${tmp_dir}/asm" || true
  ) &
  (
    "${KUBECTL[@]}" get deployment job-worker -n "${NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}~{.spec.replicas}' 2>/dev/null > "${tmp_dir}/worker" || true
  ) &
  (
    "${KUBECTL[@]}" get hpa job-worker-hpa -n "${NAMESPACE}" \
      -o jsonpath='{.status.desiredReplicas}~{.spec.minReplicas}~{.spec.maxReplicas}~{.spec.metrics[0].external.target.averageValue}~{.status.currentMetrics[0].external.current.value}~{.status.currentMetrics[0].external.current.averageValue}~{.status.conditions[?(@.type=="AbleToScale")].status}~{.status.conditions[?(@.type=="ScalingActive")].status}~{.status.conditions[?(@.type=="ScalingActive")].reason}~{.status.conditions[?(@.type=="ScaledToZero")].status}~{.status.conditions[?(@.type=="ScaledToZero")].reason}' \
      2>/dev/null > "${tmp_dir}/hpa" || true
  ) &
  (
    local p_out
    p_out="$("${KUBECTL[@]}" get pods -n "${NAMESPACE}" -l app=job-worker 2>/dev/null || true)"
    printf '%s' "${p_out}" > "${tmp_dir}/pods"
    if [[ -n "${p_out}" ]]; then
      "${KUBECTL[@]}" logs -n "${NAMESPACE}" -l app=job-worker --tail=1 --prefix=true 2>/dev/null \
        | tail -n 1 > "${tmp_dir}/latest_log" || true
    fi
  ) &
  wait

  local queue_depth
  queue_depth="$(<"${tmp_dir}/queue_depth")"
  queue_depth="${queue_depth:-N/A}"

  local ama_raw ama_ready ama_desired _rest
  ama_raw="$(<"${tmp_dir}/ama")"
  IFS='~' read -r ama_ready ama_desired _rest <<< "${ama_raw}~~"
  ama_ready="${ama_ready:-0}"
  ama_desired="${ama_desired:-0}"

  local asm_raw asm_hpa_name asm_errors
  asm_raw="$(<"${tmp_dir}/asm")"
  IFS='~' read -r asm_hpa_name asm_errors _rest <<< "${asm_raw}~~"
  asm_hpa_name="${asm_hpa_name:-<pending>}"
  if [[ -z "${asm_errors}" || "${asm_errors}" == "[]" ]]; then
    asm_errors="none"
  fi

  local worker_raw worker_ready worker_spec
  worker_raw="$(<"${tmp_dir}/worker")"
  IFS='~' read -r worker_ready worker_spec _rest <<< "${worker_raw}~~"
  worker_ready="${worker_ready:-0}"
  worker_spec="${worker_spec:-0}"

  local hpa_raw hpa_desired hpa_min hpa_max hpa_target_avg hpa_curr_val hpa_curr_avg
  local able_to_scale scaling_active scaling_reason scaled_to_zero zero_reason
  hpa_raw="$(<"${tmp_dir}/hpa")"
  IFS='~' read -r hpa_desired hpa_min hpa_max hpa_target_avg hpa_curr_val hpa_curr_avg \
    able_to_scale scaling_active scaling_reason scaled_to_zero zero_reason _rest <<< "${hpa_raw}~~~~~~~~~~~"

  local metric_display
  if [[ "${hpa_curr_avg}" == "${K8S_ZERO_PODS_AVG_SENTINEL}" || -z "${hpa_curr_avg}" ]]; then
    metric_display="value=${hpa_curr_val:-0} (0 pods) / target=${hpa_target_avg:-20} (avg)"
  else
    metric_display="avg=${hpa_curr_avg} (value=${hpa_curr_val:-?}) / target=${hpa_target_avg:-20} (avg)"
  fi

  local pods_out="" latest_log=""
  [[ -f "${tmp_dir}/pods" ]] && pods_out="$(<"${tmp_dir}/pods")"
  [[ -f "${tmp_dir}/latest_log" ]] && latest_log="$(<"${tmp_dir}/latest_log")"
  rm -rf "${tmp_dir}"

  local now_utc
  now_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

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
  if [[ -z "${pods_out}" ]]; then
    printf '  (0 pods running - Zero-Scale State)\n'
  else
    printf '%s\n' "${pods_out}" | sed 's/^/  /'
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
