#!/usr/bin/env bash
# Revert: remove the CPU limit from the frontend deployment.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

CPU_LIMIT=$(kubectl get deployment frontend -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)

if [[ -n "$CPU_LIMIT" ]]; then
  kubectl patch deployment frontend -n "$NAMESPACE" --type=json \
    -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]'
  kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=120s
else
  echo "CPU limit not present — nothing to remove."
fi
