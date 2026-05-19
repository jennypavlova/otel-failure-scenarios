#!/usr/bin/env bash
# Inject: add a 2m CPU limit to the checkout deployment.
# Simulates a VPA/rightsizing tool that generated a 2m limit from quiet-period
# sampling; the PR was approved without understanding millicores.
# Effect: Go runtime CPU-throttled under real load — all checkout transactions
# slow uniformly (3-10x latency). Pod stays Running/Ready. No errors, only latency.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set resources deployment checkout -n "$NAMESPACE" \
  -c checkout --limits=cpu=2m

kubectl rollout status deployment/checkout -n "$NAMESPACE" --timeout=120s
