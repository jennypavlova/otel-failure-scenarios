#!/usr/bin/env bash
# Inject: two independent faults simultaneously.
#
# Fault 1 — cart: VALKEY_ADDR set to a non-existent Redis hostname.
#   Simulates a cache-migration PR that pointed the cart service at the wrong
#   Redis instance. The cart pod enters CrashLoopBackOff immediately.
#
# Fault 2 — payment: memory limit lowered to 25Mi.
#   Simulates a memory-audit PR that set an aggressive limit without load testing.
#   The Node.js runtime exceeds 25Mi and the pod OOMKills repeatedly.
#
# The two faults are independent — different services, different root causes,
# different failure modes — but both surface as checkout failures, making the
# combined blast radius look like a single systemic issue.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

echo "[1/2] Injecting cart fault (bad VALKEY_ADDR)..."
kubectl set env deployment/cart -n "$NAMESPACE" VALKEY_ADDR=valkey-cart-broken:6379
kubectl rollout status deployment/cart -n "$NAMESPACE" --timeout=120s

echo "[2/2] Injecting payment fault (memory limit 25Mi)..."
kubectl set resources deployment payment -n "$NAMESPACE" \
  -c payment --limits=memory=25Mi

echo "Both faults injected."
