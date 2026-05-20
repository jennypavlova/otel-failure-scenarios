#!/usr/bin/env bash
# Revert: restore the product-catalog deployment to 1 replica.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl scale deployment product-catalog -n "$NAMESPACE" --replicas=1
kubectl rollout status deployment/product-catalog -n "$NAMESPACE" --timeout=120s
