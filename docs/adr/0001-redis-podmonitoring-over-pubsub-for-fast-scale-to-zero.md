# Use In-Cluster Redis + 5s PodMonitoring Instead of Cloud Pub/Sub

We use an in-cluster Redis Job Queue (`redis:7-alpine` + `oliver006/redis_exporter`) scraped every `5s` via Google Cloud Managed Service for Prometheus (`PodMonitoring`) rather than Cloud Pub/Sub (`num_undelivered_messages`) or a custom-built Go container image. Cloud Pub/Sub system metrics are sampled at 60-second intervals with additional ingestion delay (~60–90s total latency before HPA reacts) and require GCP IAM/Workload Identity setup, whereas a 5s `PodMonitoring` scrape + `AutoscalingMetric` (`promql`) triggers scale-from-zero in ~15–30s using 100% upstream container images and zero IAM configuration.

## Consequences

- When a Redis list empties (`LLEN jobs == 0`), Redis deletes the `jobs` key and `redis_exporter` stops emitting `redis_key_size{key="jobs"}`. Because `autoscaling-metrics-adapter` treats an empty PromQL vector as a missing metric (`<unknown>` in HPA, which blocks scale-down), the `AutoscalingMetric` PromQL query must include an explicit fallback (`max(redis_key_size{key="jobs"}) or vector(0)`).
