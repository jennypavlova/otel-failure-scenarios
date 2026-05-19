#!/usr/bin/env bash
# Revert: restore the payment service memory limit to its original value (140Mi).
# The new pod starts cleanly within the original limit; CrashLoopBackOff clears.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set resources deployment payment -n "$NAMESPACE" \
  -c payment --limits=memory=140Mi

kubectl rollout status deployment/payment -n "$NAMESPACE" --timeout=120s
