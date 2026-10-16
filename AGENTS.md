# GKE HPA Scale-to-Zero Demo (`moficodes/gke-hpa-scale-to-zero`)

Hands-on demo and blog post repository for GKE 1.37+ native **HPA Scale-to-Zero** (`minReplicas: 0`) using the managed `AutoscalingMetric` CRD (`autoscaling.gke.io/v1beta1`), Google Cloud Managed Service for Prometheus (`PodMonitoring`), and a Redis job queue (`redis` + `redis_exporter`).

## Commands

- **Deploy demo**: `make apply`
- **Trigger burst**: `make burst JOBS=100`
- **Watch scaling**: `make watch`
- **Inspect status**: `make status`
- **Clean up**: `make clean`

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues (`moficodes/gke-hpa-scale-to-zero`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Uses the five default canonical triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (`GLOSSARY.md` at the repo root and ADRs in `docs/adr/`). See `docs/agents/domain.md`.
