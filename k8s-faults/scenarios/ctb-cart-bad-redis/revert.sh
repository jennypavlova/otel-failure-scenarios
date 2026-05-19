#!/usr/bin/env bash
# Revert: restore the correct VALKEY_ADDR for the cart service.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set env deployment/cart -n "$NAMESPACE" VALKEY_ADDR=valkey-cart:6379
kubectl rollout status deployment/cart -n "$NAMESPACE" --timeout=120s
