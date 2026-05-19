#!/usr/bin/env bash
# Revert: remove the CPU limit from the checkout deployment.
# The rolling restart restores pre-fault behaviour; no memory limit is changed.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

# Only remove the CPU limit if it exists (idempotent).
CPU_LIMIT=$(kubectl get deployment checkout -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)

if [[ -n "$CPU_LIMIT" ]]; then
  kubectl patch deployment checkout -n "$NAMESPACE" --type=json \
    -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]'
  kubectl rollout status deployment/checkout -n "$NAMESPACE" --timeout=120s
else
  echo "CPU limit not present — nothing to remove."
fi
