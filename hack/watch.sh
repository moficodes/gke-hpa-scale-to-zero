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

# Enable Gruvbox-tuned 256-color ANSI highlights when attached to a terminal or when FORCE_COLOR=1 is set
if [[ -z "${NO_COLOR:-}" && ( -t 1 || "${FORCE_COLOR:-0}" == "1" ) ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[38;5;245m'
  C_BOLD_GREEN=$'\033[1;38;5;142m'
  C_GREEN=$'\033[38;5;142m'
  C_BOLD_YELLOW=$'\033[1;38;5;214m'
  C_YELLOW=$'\033[38;5;214m'
  C_BOLD_BLUE=$'\033[1;38;5;109m'
  C_BOLD_MAGENTA=$'\033[1;38;5;175m'
  C_BOLD_CYAN=$'\033[1;38;5;108m'
  C_CYAN=$'\033[38;5;108m'
else
  C_RESET=""
  C_DIM=""
  C_BOLD_GREEN=""
  C_GREEN=""
  C_BOLD_YELLOW=""
  C_YELLOW=""
  C_BOLD_BLUE=""
  C_BOLD_MAGENTA=""
  C_BOLD_CYAN=""
  C_CYAN=""
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

  local q_color="${C_BOLD_GREEN}"
  if [[ "${queue_depth}" != "0" && "${queue_depth}" != "N/A" ]]; then
    q_color="${C_BOLD_YELLOW}"
  fi

  local s2z_color="${C_BOLD_CYAN}"
  if [[ "${scaled_to_zero:-Unknown}" == "False" ]]; then
    s2z_color="${C_BOLD_YELLOW}"
  fi

  local worker_color="${C_BOLD_CYAN}"
  if [[ "${worker_ready}" != "0" ]]; then
    worker_color="${C_BOLD_GREEN}"
  fi

  printf '%s================================================================================%s\n' "${C_DIM}" "${C_RESET}"
  printf '%sGKE HPA Scale-to-Zero Observer%s | %s%s%s | context: %s%s%s\n' \
    "${C_BOLD_YELLOW}" "${C_RESET}" "${C_CYAN}" "${now_utc}" "${C_RESET}" "${C_BOLD_BLUE}" "${KUBE_CONTEXT}" "${C_RESET}"
  printf '%s================================================================================%s\n' "${C_DIM}" "${C_RESET}"
  printf '%sJob Queue (redis-queue)%s        : Queue Depth (LLEN jobs) = %s%s%s\n' \
    "${C_BOLD_CYAN}" "${C_RESET}" "${q_color}" "${queue_depth}" "${C_RESET}"
  printf '%sAMA (kube-system)%s              : autoscaling-metrics-adapter = %s%s/%s Ready%s\n' \
    "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_GREEN}" "${ama_ready}" "${ama_desired}" "${C_RESET}"
  printf '%sAutoscalingMetric%s              : %sredis-queue-depth%s -> hpaName=%s%s%s (%serrors=%s%s)\n' \
    "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_BLUE}" "${C_RESET}" "${C_YELLOW}" "${asm_hpa_name}" "${C_RESET}" "${C_GREEN}" "${asm_errors}" "${C_RESET}"
  printf '%sHPA (job-worker-hpa)%s           : desired=%s%s%s (min=%s, max=%s) | metric: %s%s%s\n' \
    "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_YELLOW}" "${hpa_desired:-0}" "${C_RESET}" "${hpa_min:-0}" "${hpa_max:-10}" "${C_CYAN}" "${metric_display}" "${C_RESET}"
  printf '%sHPA Conditions%s                 : %sAbleToScale=%s%s | %sScalingActive=%s%s (%s) | %sScaledToZero=%s%s (%s)\n' \
    "${C_BOLD_CYAN}" "${C_RESET}" \
    "${C_BOLD_GREEN}" "${able_to_scale:-Unknown}" "${C_RESET}" \
    "${C_BOLD_GREEN}" "${scaling_active:-Unknown}" "${C_RESET}" "${scaling_reason:-N/A}" \
    "${s2z_color}" "${scaled_to_zero:-Unknown}" "${C_RESET}" "${zero_reason:-N/A}"
  printf '%sJob Worker (Deployment)%s        : job-worker = %s%s/%s Ready%s\n' \
    "${C_BOLD_CYAN}" "${C_RESET}" "${worker_color}" "${worker_ready}" "${worker_spec}" "${C_RESET}"
  printf '%s--------------------------------------------------------------------------------%s\n' "${C_DIM}" "${C_RESET}"
  printf '%sJob Worker Pods (namespace: %s):%s\n' "${C_BOLD_CYAN}" "${NAMESPACE}" "${C_RESET}"
  if [[ -z "${pods_out}" ]]; then
    printf '  %s(0 pods running - Zero-Scale State)%s\n' "${C_CYAN}" "${C_RESET}"
  else
    printf '%s\n' "${pods_out}" | awk -v hdr="${C_BOLD_YELLOW}" -v grn="${C_BOLD_GREEN}" -v rst="${C_RESET}" '
      NR==1 { print "  " hdr $0 rst; next }
      { gsub(/Running/, grn "Running" rst); print "  " $0 }
    '
    if [[ -n "${latest_log}" ]]; then
      printf '%sLatest Worker Log%s              : %s\n' "${C_BOLD_MAGENTA}" "${C_RESET}" "${latest_log}"
    fi
  fi
  printf '%s================================================================================%s\n' "${C_DIM}" "${C_RESET}"
}

if (( ONCE == 1 )); then
  render_snapshot
  exit 0
fi

while true; do
  snap="$(render_snapshot)"
  clear 2>/dev/null || true
  printf '%s\n' "${snap}"
  printf '%sRefreshing every %ss... (Press Ctrl+C to exit)%s\n' "${C_DIM}" "${INTERVAL}" "${C_RESET}"
  sleep "${INTERVAL}"
done
