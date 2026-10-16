# GKE 1.37 HPA scale-to-zero (`minReplicas: 0`) demo

Zero-build reference for native Kubernetes Horizontal Pod Autoscaler scale-to-zero (`minReplicas: 0`) on GKE 1.37+. Everything runs inside the `hpa-scale-to-zero` namespace using an in-cluster Redis job queue (`redis:7-alpine` and `oliver006/redis_exporter:v1.62.0`), Google Cloud Managed Service for Prometheus (`PodMonitoring`), GKE's `AutoscalingMetric` custom resource (`autoscaling.gke.io/v1beta1`), and the managed `autoscaling-metrics-adapter`.

For the full story, the three failure modes I hit on a live GKE `v1.37.0-gke.3503000` cluster, and the captured scaling trace, read [BLOG.md](BLOG.md).

## Architecture

```mermaid
flowchart LR
  Burst["make burst (JOBS=100)"] -->|"LPUSH jobs"| Redis["Job Queue (redis:7-alpine)"]
  Redis -->|"LLEN jobs"| Exporter["redis_exporter (:9121)"]
  PodMon["PodMonitoring (interval: 5s)"] -->|"scrapes"| Exporter
  PodMon -->|"ingests redis_key_size"| GMP["Managed Service for Prometheus"]
  ASM["AutoscalingMetric (redis-queue-depth)"] -->|"PromQL: max(...) or vector(0)"| AMA["Autoscaling Metrics Adapter (kube-system)"]
  GMP -->|"evaluates PromQL"| AMA
  AMA -->|"autoscaling.gke.io|redis-queue-depth|pending-jobs"| HPA["HorizontalPodAutoscaler (minReplicas: 0, maxReplicas: 10)"]
  HPA -->|"scales 1 -> 0 -> 5 -> 0"| Worker["Job Worker Deployment (redis-cli RPOP jobs)"]
  Worker -->|"RPOP jobs (1 item / 2s)"| Redis
```

## Prerequisites

1. A GKE cluster running version `1.37` or later, verified on `v1.37.0-gke.3503000`, where Kubernetes `HPAScaleToZero` is enabled and GKE's managed `autoscaling-metrics-adapter` is installed in `kube-system`.
2. Google Cloud Managed Service for Prometheus enabled on the cluster so the `monitoring.googleapis.com/v1` `PodMonitoring` CRD is present.
3. `kubectl` and `make` configured locally. Every `Makefile` target accepts `KUBE_CONTEXT=<your-context>` and defaults to your current `kubectl` context.

No custom container builds, Dockerfiles, Cloud Pub/Sub subscriptions, or GCP IAM bindings are required.

## Run it in three commands

### 1. Deploy the stack

```bash
make apply
```

This creates the `hpa-scale-to-zero` namespace, deploys the Redis queue and `5s` `PodMonitoring` scraper from `manifests/01-redis-queue.yaml`, and applies the `AutoscalingMetric`, worker Deployment, and HPA from `manifests/02-worker-and-hpa.yaml`. Within about 45 seconds, `kube-system/autoscaling-metrics-adapter` wakes from `0` to `1` replica and HPA scales `job-worker` from `1` down to `0` replicas.

### 2. Watch the scaling loop in one terminal pane

```bash
make watch
```

`make watch` refreshes every 2 seconds and prints the live queue depth `LLEN jobs`, adapter readiness, `AutoscalingMetric` status, HPA targets and conditions, active worker pods, and the latest processed job log line. For a single snapshot without clearing the screen, run `make status`.

```bash
================================================================================
GKE HPA Scale-to-Zero Observer | 2026-10-16T21:32:59Z | context: gke_mofilabs_us-central1-a_ate-cluster
================================================================================
Job Queue (redis-queue)        : Queue Depth (LLEN jobs) = 0
AMA (kube-system)              : autoscaling-metrics-adapter = 1/1 Ready
AutoscalingMetric              : redis-queue-depth -> hpaName=autoscaling.gke.io|redis-queue-depth|pending-jobs (errors=none)
HPA (job-worker-hpa)           : desired=0 (min=0, max=10) | metric: avg=0 (value=0) / target=20 (avg)
HPA Conditions                 : AbleToScale=True | ScalingActive=True (ValidMetricFound) | ScaledToZero=True (ScaledToZero)
Job Worker (Deployment)        : job-worker = 0/0 Ready
--------------------------------------------------------------------------------
Job Worker Pods (namespace: hpa-scale-to-zero):
  (0 pods running - Zero-Scale State)
================================================================================
```

### 3. Trigger a 100-item job burst

In a second terminal, push 100 synthetic work items into Redis:

```bash
make burst JOBS=100
```

```bash
Pushing 100 synthetic jobs into Redis Job Queue (namespace: hpa-scale-to-zero)...
Job Burst complete: pushed 100 items -> updated Queue Depth (LLEN jobs) = 100
```

Within 5 seconds of the burst, HPA sees the external metric `autoscaling.gke.io|redis-queue-depth|pending-jobs` jump to `100`, computes `100 / 20 = 5` desired replicas, sets `ScaledToZero=False`, and scales `Deployment/job-worker` from `0` to `5` running pods:

```bash
================================================================================
GKE HPA Scale-to-Zero Observer | 2026-10-16T21:33:38Z | context: gke_mofilabs_us-central1-a_ate-cluster
================================================================================
Job Queue (redis-queue)        : Queue Depth (LLEN jobs) = 80
AMA (kube-system)              : autoscaling-metrics-adapter = 1/1 Ready
AutoscalingMetric              : redis-queue-depth -> hpaName=autoscaling.gke.io|redis-queue-depth|pending-jobs (errors=none)
HPA (job-worker-hpa)           : desired=5 (min=0, max=10) | metric: avg=13 (value=65) / target=20 (avg)
HPA Conditions                 : AbleToScale=True | ScalingActive=True (ValidMetricFound) | ScaledToZero=False (NotScaledToZero)
Job Worker (Deployment)        : job-worker = 5/5 Ready
--------------------------------------------------------------------------------
Job Worker Pods (namespace: hpa-scale-to-zero):
  NAME                          READY   STATUS    RESTARTS   AGE
  job-worker-755bf6d97d-6zvgf   1/1     Running   0          20s
  job-worker-755bf6d97d-8dvdz   1/1     Running   0          20s
  job-worker-755bf6d97d-cxqvw   1/1     Running   0          20s
  job-worker-755bf6d97d-fbxhq   1/1     Running   0          20s
  job-worker-755bf6d97d-fmf7p   1/1     Running   0          20s
Latest Worker Log              : [pod/job-worker-755bf6d97d-fmf7p/worker] [2026-10-16T21:33:38Z] [job-worker-755bf6d97d-fmf7p] Processed job: job-051@2026-10-16T21:33:14Z
================================================================================
```

Each worker pod pops 1 item every 2 seconds. Once the queue drains to `0` around 55 seconds after the burst and stays at `0` for the 15-second `scaleDown.stabilizationWindowSeconds` window, HPA scales the Deployment back to `0/0` Ready.

## Makefile targets

| Target | Command | What it does |
| :--- | :--- | :--- |
| `apply` | `make apply` | Deploys `manifests/01-redis-queue.yaml` and `manifests/02-worker-and-hpa.yaml` |
| `burst` | `make burst JOBS=100` | Pushes `JOBS` synthetic items into the Redis queue in one `LPUSH` call |
| `watch` | `make watch INTERVAL=2` | Refreshes the single-pane observer every `INTERVAL` seconds |
| `status` | `make status` | Prints a one-shot observer snapshot via `./hack/watch.sh --once` |
| `logs` | `make logs` | Prints recent processed job log lines across running worker pods |
| `verify` | `make verify` | Runs `./hack/verify-e2e.sh` to assert the full `1 -> 0 -> 5 -> 0` cycle |
| `clean` | `make clean` | Deletes all demo manifests and the `hpa-scale-to-zero` namespace |

## Three sharp edges and how the manifests solve them

### 1. HPA shows `<unknown>` when the Redis list is empty

When a Redis list empties (`LLEN jobs == 0`), Redis deletes the `jobs` key. `redis_exporter` then stops emitting `redis_key_size{key="jobs"}`. A bare `max(redis_key_size{namespace="hpa-scale-to-zero", key="jobs"})` query returns an empty vector, which `autoscaling-metrics-adapter` treats as a missing metric (`<unknown>` in HPA) and refuses to scale down to zero.

Append `or vector(0)` in `AutoscalingMetric` so an empty list returns a `0` series. Details are in [ADR-0001](docs/adr/0001-redis-podmonitoring-over-pubsub-for-fast-scale-to-zero.md):

```yaml
query: 'max(redis_key_size{namespace="hpa-scale-to-zero", key="jobs"}) or vector(0)'
```

### 2. HPA pauses with `ScalingDisabledReplicaCountZero`

If you create a Deployment with `replicas: 0` before the metrics adapter has published initial metric samples, or if you manually run `kubectl scale deployment/job-worker --replicas=0`, GKE's HPA controller sets `ScalingActive: False` with reason `ScalingDisabledReplicaCountZero` or `ScalingDisabledExternalScaleToZero`. GKE assumes an operator intentionally turned the workload off and does not wake it back up.

Declare `replicas: 1` in `Deployment/job-worker` so HPA itself actuates the `1 -> 0` transition (`ScaledToZero: True`, `ScalingActive: True`). Details are in [ADR-0002](docs/adr/0002-initial-single-replica-for-hpa-actuated-scale-to-zero.md). If a Deployment is already stuck in `ScalingDisabledReplicaCountZero`, run `kubectl scale deployment/job-worker -n hpa-scale-to-zero --replicas=1` once to hand control back to HPA.

### 3. Wake-from-zero stops at 4 replicas on the first tick

Kubernetes HPA's default `scaleUp` policy allows the maximum of `100%` of current replicas or `4` pods per 15 seconds. When waking from `0` replicas, `100%` of `0` is `0`, so the default `Pods: 4` limit caps the initial wake-from-zero step at `4` replicas even when a 100-item burst needs `5` pods.

Set an explicit `Pods` policy in `spec.behavior.scaleUp.policies` as documented in [ADR-0003](docs/adr/0003-explicit-pods-scaleup-policy-for-wake-from-zero.md):

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0
    policies:
      - type: Pods
        value: 10
        periodSeconds: 15
```

## Repository layout

**`manifests/01-redis-queue.yaml`.** Defines `Namespace/hpa-scale-to-zero`, `Deployment/redis-queue`, `Service/redis-queue`, and `PodMonitoring/redis-queue-monitoring`.

**`manifests/02-worker-and-hpa.yaml`.** Defines `AutoscalingMetric/redis-queue-depth`, `Deployment/job-worker`, and `HorizontalPodAutoscaler/job-worker-hpa` with `minReplicas: 0`.

**`Makefile`.** Provides `apply`, `burst`, `watch`, `status`, `logs`, `verify`, and `clean`.

**`hack/watch.sh`.** Renders the single-pane terminal observer in live or `--once` mode.

**`hack/verify-e2e.sh`.** Runs the automated end-to-end `1 -> 0 -> 5 -> 0` test against a live cluster.

**`GLOSSARY.md` and `docs/adr/`.** Document the domain terms and architecture decision records `ADR-0001`, `ADR-0002`, and `ADR-0003`.

**`BLOG.md`.** Full blog post with the walkthrough, production lessons, and captured GKE 1.37 outputs.
