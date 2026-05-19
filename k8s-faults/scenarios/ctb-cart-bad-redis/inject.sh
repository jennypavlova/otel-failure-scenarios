#!/usr/bin/env bash
# Inject: point the cart service at a non-existent Valkey/Redis instance.
# Simulates a config PR that updated VALKEY_ADDR to the wrong hostname
# during a cache migration. The pod stays Running/Ready (kubelet probes pass);
# only application-layer cart operations fail with Redis connection errors.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set env deployment/cart -n "$NAMESPACE" VALKEY_ADDR=valkey-cart-broken:6379
kubectl rollout status deployment/cart -n "$NAMESPACE" --timeout=120s
