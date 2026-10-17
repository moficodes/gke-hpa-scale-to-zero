SHELL := /usr/bin/env bash

KUBE_CONTEXT ?= $(shell kubectl config current-context 2>/dev/null)
NAMESPACE ?= hpa-scale-to-zero
JOBS ?= 100
INTERVAL ?= 2

KUBECTL := kubectl --context=$(KUBE_CONTEXT)

.PHONY: apply burst watch status logs verify clean

apply: ## Deploy the Redis Job Queue, PodMonitoring, AutoscalingMetric, Job Worker, and HPA
	$(KUBECTL) apply -f manifests/01-redis-queue.yaml
	$(KUBECTL) apply -f manifests/02-worker-and-hpa.yaml
	$(KUBECTL) rollout status deployment/redis-queue -n $(NAMESPACE) --timeout=180s

burst: ## Push $(JOBS) synthetic work items into the Redis Job Queue in a single command
	@echo "Pushing $(JOBS) synthetic jobs into Redis Job Queue (namespace: $(NAMESPACE))..."
	@QUEUE_DEPTH="$$( $(KUBECTL) exec -n $(NAMESPACE) deploy/redis-queue -c redis -- sh -c \
		'ts=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); i=1; set --; while [ $$i -le $(JOBS) ]; do set -- "$$@" "$$(printf "job-%03d@%s" "$$i" "$$ts")"; i=$$((i + 1)); done; redis-cli lpush jobs "$$@" | tr -d "\r"' )" && \
	echo "Job Burst complete: pushed $(JOBS) items -> updated Queue Depth (LLEN jobs) = $${QUEUE_DEPTH}"

watch: ## Watch live HPA Scale-to-Zero state in a single terminal pane (refresh every $(INTERVAL)s)
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" NAMESPACE="$(NAMESPACE)" INTERVAL="$(INTERVAL)" ./hack/watch.sh

status: ## Print a one-shot summary of Queue Depth, AMA, AutoscalingMetric, HPA conditions, and Job Worker pods
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" NAMESPACE="$(NAMESPACE)" ./hack/watch.sh --once

logs: ## Show recent processed job log lines from running Job Worker pods
	@POD_COUNT="$$( $(KUBECTL) get pods -n $(NAMESPACE) -l app=job-worker --no-headers 2>/dev/null | wc -l | tr -d ' ' )"; \
	if [ "$${POD_COUNT}" = "0" ]; then \
		echo "No Job Worker pods currently running in $(NAMESPACE) (Zero-Scale State)."; \
	else \
		$(KUBECTL) logs -n $(NAMESPACE) -l app=job-worker --tail=1 --prefix=true; \
	fi

verify: ## Run the automated end-to-end 1 -> 0 -> 5 -> 0 verification harness
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/verify-e2e.sh

clean: ## Delete all demo resources and the hpa-scale-to-zero namespace
	$(KUBECTL) delete -f manifests/02-worker-and-hpa.yaml --ignore-not-found=true
	$(KUBECTL) delete -f manifests/01-redis-queue.yaml --ignore-not-found=true
