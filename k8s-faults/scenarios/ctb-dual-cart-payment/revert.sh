#!/usr/bin/env bash
# Revert: restore both cart and payment to healthy configuration.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

echo "[1/2] Reverting cart fault (restoring VALKEY_ADDR)..."
kubectl set env deployment/cart -n "$NAMESPACE" VALKEY_ADDR=valkey-cart:6379
kubectl rollout status deployment/cart -n "$NAMESPACE" --timeout=120s

echo "[2/2] Reverting payment fault (removing memory limit)..."
kubectl set resources deployment payment -n "$NAMESPACE" \
  -c payment --limits=memory=''

echo "Both faults reverted."
