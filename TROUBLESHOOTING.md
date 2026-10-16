# Troubleshooting GKE 1.37 HPA scale-to-zero

This guide covers the three failure modes you are most likely to hit when building PromQL-driven HPA scale-to-zero (`minReplicas: 0`) on GKE 1.37+ with `AutoscalingMetric` and Google Cloud Managed Service for Prometheus.

## 1. Empty Redis lists and `or vector(0)` in `AutoscalingMetric`

### Symptom

When the Redis queue drains to zero items, `kubectl get hpa job-worker-hpa -n hpa-scale-to-zero` shows `<unknown>/20 (avg)` instead of `0/20 (avg)`. `ScalingActive` flips to `False` with `FailedGetExternalMetric`, and HPA leaves the running worker pods alive forever against an empty queue.

### Root cause

In Redis, a list with zero elements does not exist. The moment a worker pops the final item (`RPOP jobs` when `LLEN jobs == 1`), Redis deletes the `jobs` key. On the next `PodMonitoring` scrape, `redis_exporter --check-keys=jobs` omits `redis_key_size{key="jobs"}` from `/metrics`.

Once the Prometheus lookback window expires, a bare PromQL query:

```yaml
query: 'max(redis_key_size{namespace="hpa-scale-to-zero", key="jobs"})'
```

returns an empty vector with zero time series. GKE's `autoscaling-metrics-adapter` treats an empty PromQL vector as a failed metric lookup, and Kubernetes HPA refuses to scale down when a metric is `<unknown>`.

### Fix

Append `or vector(0)` to the PromQL query in `AutoscalingMetric` ([manifests/02-worker-and-hpa.yaml](manifests/02-worker-and-hpa.yaml), [ADR-0001](docs/adr/0001-redis-podmonitoring-over-pubsub-for-fast-scale-to-zero.md)):

```yaml
apiVersion: autoscaling.gke.io/v1beta1
kind: AutoscalingMetric
metadata:
  name: redis-queue-depth
  namespace: hpa-scale-to-zero
spec:
  metrics:
    - promql:
        name: pending-jobs
        type: External
        query: 'max(redis_key_size{namespace="hpa-scale-to-zero", key="jobs"}) or vector(0)'
```

Whenever `redis_key_size{key="jobs"}` is present, `max(...)` returns the queue depth. Whenever the key is deleted, the union falls back to `vector(0)`, giving HPA a valid `0` sample so it can transition to `ScaledToZero: True`.

## 2. Starting at `replicas: 1` instead of `replicas: 0` (`ScalingDisabledReplicaCountZero`)

### Symptom

You deploy `Deployment/job-worker` with `replicas: 0` (or manually run `kubectl scale deployment/job-worker --replicas=0`), push jobs into Redis, and HPA never scales the Deployment up. `kubectl describe hpa job-worker-hpa -n hpa-scale-to-zero` reports:

```bash
Conditions:
  Type            Status  Reason                             Message
  ----            ------  ------                             -------
  AbleToScale     True    SucceededGetScale                  the HPA controller was able to get the target's current scale
  ScalingActive   False   ScalingDisabledReplicaCountZero    scaling is disabled since the replica count of the target is zero
```

If you manually scale an active Deployment to `0` while HPA is attached, GKE reports the companion reason `ScalingDisabledExternalScaleToZero`.

### Root cause

GKE's HPA controller distinguishes between HPA-actuated scale-to-zero and operator-actuated scale-to-zero. If an on-call engineer runs `kubectl scale --replicas=0` during an outage to stop a consumer, HPA should not override them 15 seconds later and spin pods back up. Therefore, when `spec.replicas` is set to `0` by a manifest or `kubectl scale` rather than by HPA's own control loop, GKE disables autoscaling on that target.

### Fix

Declare `replicas: 1` in `Deployment/job-worker` ([manifests/02-worker-and-hpa.yaml](manifests/02-worker-and-hpa.yaml), [ADR-0002](docs/adr/0002-initial-single-replica-for-hpa-actuated-scale-to-zero.md)). On initial `make apply`, one pod starts while `kube-system/autoscaling-metrics-adapter` wakes up. As soon as the adapter serves `0` from `or vector(0)`, HPA itself scales `job-worker` from `1` to `0` and sets `ScaledToZero: True` while keeping `ScalingActive: True`.

If a Deployment is already stuck in `ScalingDisabledReplicaCountZero`, scale it to `1` once to hand control back to HPA:

```bash
kubectl scale deployment/job-worker -n hpa-scale-to-zero --replicas=1
```

## 3. Default `scaleUp` policies cap wake-from-zero at 4 pods

### Symptom

You push 100 jobs with `averageValue: "20"` (`100 / 20 = 5` desired replicas), but when waking from `0` replicas, HPA scales `job-worker` to `4` pods first and waits 15 seconds before adding the 5th pod.

### Root cause

When `spec.behavior.scaleUp.policies` is omitted, Kubernetes `autoscaling/v2` applies two default rules every 15 seconds and takes their maximum:

```yaml
policies:
  - type: Pods
    value: 4
    periodSeconds: 15
  - type: Percent
    value: 100
    periodSeconds: 15
selectPolicy: Max
```

When current replicas is `0`, `100%` of `0` is `0`. Only the `type: Pods` policy contributes on the wake-from-zero tick, capping the initial jump at `4` pods.

### Fix

Configure an explicit `Pods` policy in `spec.behavior.scaleUp.policies` ([manifests/02-worker-and-hpa.yaml](manifests/02-worker-and-hpa.yaml), [ADR-0003](docs/adr/0003-explicit-pods-scaleup-policy-for-wake-from-zero.md)):

```yaml
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 10
          periodSeconds: 15
```
