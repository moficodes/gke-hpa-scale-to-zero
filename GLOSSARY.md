# GKE HPA Scale-to-Zero Demo

Demonstrates native Kubernetes Horizontal Pod Autoscaler (HPA) scaling to and from zero replicas (`minReplicas: 0`) on GKE 1.37+ using managed `AutoscalingMetric` PromQL queries and a zero-build Redis job queue in the `hpa-scale-to-zero` namespace.

## Language

**Job Queue**:
The single-replica Redis list (`jobs` on `redis-queue`) in namespace `hpa-scale-to-zero` that buffers pending background work items before workers claim them.
_Avoid_: Message broker, topic, stream

**Queue Depth**:
The instantaneous number of unprocessed items waiting in the Job Queue (`LLEN jobs`), exposed as the Prometheus gauge `redis_key_size{namespace="hpa-scale-to-zero", key="jobs"}`.
_Avoid_: Backlog size, queue length, lag

**Job Burst**:
A batch of synthetic work items pushed into the Job Queue (`make burst JOBS=100`) to trigger an HPA scale-from-zero transition.
_Avoid_: Load test, traffic spike, flood

**AutoscalingMetric**:
The GKE-native `autoscaling.gke.io/v1beta1` custom resource (`redis-queue-depth`) that evaluates a PromQL query against Google Cloud Managed Service for Prometheus and exposes the result to HPA under the `autoscaling.gke.io|<asm-name>|<metric-name>` identifier.
_Avoid_: Custom metrics adapter config, KEDA ScaledObject, ServiceMonitor

**Autoscaling Metrics Adapter (AMA)**:
The GKE-managed `kube-system/autoscaling-metrics-adapter` Deployment that automatically activates from `0` to `1` replica when an `AutoscalingMetric` with a `promql` specification is present in the cluster.
_Avoid_: Stackdriver adapter, Prometheus adapter

**Job Worker**:
The stateless consumer Deployment (`job-worker`) governed by HPA that scales between `0` and `maxReplicas` (`10`) Pods, popping and processing 1 item every 2 seconds from the Job Queue.
_Avoid_: Consumer pod, processor, runner

**Zero-Scale State**:
The steady-state condition where the Job Worker Deployment has `0` desired and `0` running replicas while HPA maintains `ScalingActive: True` and `ScaledToZero: True`.
_Avoid_: Paused deployment, disabled autoscaler, hibernation

**External Scale-to-Zero Override**:
The paused HPA state (`ScalingActive: False` with reason `ScalingDisabledReplicaCountZero` or `ScalingDisabledExternalScaleToZero`) triggered when an operator or manifest sets `replicas: 0` manually rather than letting HPA actuate the scale-down.
_Avoid_: Broken HPA, stuck zero state

**Scale-Down Stabilization Window**:
The duration (`spec.behavior.scaleDown.stabilizationWindowSeconds: 15`) of continuous zero Queue Depth that HPA waits before transitioning the Job Worker back into the Zero-Scale State.
_Avoid_: Cooldown timer, grace period, idle timeout
