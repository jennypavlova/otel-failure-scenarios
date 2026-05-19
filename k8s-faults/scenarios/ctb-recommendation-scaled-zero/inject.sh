#!/usr/bin/env bash
# Inject: scale the recommendation deployment to 0 replicas.
# Simulates an auto-scaling cost-review script that set replicas to 0 and was never restored.
# Effect: no recommendation pods — service completely unavailable. All callers get
# connection refused. Pod list shows nothing for the recommendation selector.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl scale deployment recommendation -n "$NAMESPACE" --replicas=0
kubectl rollout status deployment/recommendation -n "$NAMESPACE" --timeout=60s
