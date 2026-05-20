#!/usr/bin/env bash
# Inject: scale the product-catalog deployment to 0 replicas.
# Simulates a weekend cost-reduction automation script that identified product-catalog as
# "low-utilization" during off-hours and zeroed its replicas without traffic context.
# Effect: no product-catalog pods — all product browsing fails immediately with gRPC
# UNAVAILABLE. Frontend errors spike on every product listing and product detail call.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl scale deployment product-catalog -n "$NAMESPACE" --replicas=0
kubectl rollout status deployment/product-catalog -n "$NAMESPACE" --timeout=60s
