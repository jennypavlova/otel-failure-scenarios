#!/usr/bin/env bash
# Revert: scale the recommendation deployment back to 1 replica.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl scale deployment recommendation -n "$NAMESPACE" --replicas=1
kubectl rollout status deployment/recommendation -n "$NAMESPACE" --timeout=120s
