#!/usr/bin/env bash
# Inject: add a 5m CPU limit to the frontend deployment.
# Simulates a platform script that auto-generated resource limits with a unit
# conversion bug — writing 5m instead of 500m.
# Effect: frontend CPU-throttled — all pages and endpoints uniformly slower.
# No errors, only elevated p99 latency. Pod stays Running/Ready.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set resources deployment frontend -n "$NAMESPACE" \
  -c frontend --limits=cpu=5m

kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=120s
