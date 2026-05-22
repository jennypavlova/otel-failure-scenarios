#!/usr/bin/env bash
# Revert: restore ad and recommendation to healthy configuration.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

echo "[1/2] Reverting ad fault (removing CPU limit)..."
CPU_LIMIT=$(kubectl get deployment ad -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)

if [[ -n "$CPU_LIMIT" ]]; then
  kubectl patch deployment ad -n "$NAMESPACE" --type=json \
    -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]'
  kubectl rollout status deployment/ad -n "$NAMESPACE" --timeout=120s
else
  echo "CPU limit not present — nothing to remove."
fi

echo "[2/2] Reverting recommendation fault (restoring 1 replica)..."
kubectl scale deployment recommendation -n "$NAMESPACE" --replicas=1

echo "Both faults reverted."
