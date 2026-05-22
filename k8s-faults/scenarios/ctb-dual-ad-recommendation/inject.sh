#!/usr/bin/env bash
# Inject: two independent non-critical-path faults simultaneously.
#
# Fault 1 — ad: CPU limit set to 20m.
#   Simulates a rightsizing tool that sampled CPU during a quiet overnight
#   window and generated an aggressive limit. The JVM cannot keep up under
#   daytime load — GetAds latency spikes while the pod stays Running.
#
# Fault 2 — recommendation: replica count set to 0.
#   Simulates a cost-optimisation script that flagged recommendation as
#   'infrequently used' based on a 24h window that missed peak hours.
#   A GitOps PR zeroed the replicas; product pages now fail recommendations.
#
# The two faults are independent — different services, different root causes,
# different failure modes — but both surface as product page degradation,
# while checkout continues to work normally.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

echo "[1/2] Injecting ad fault (CPU limit 20m)..."
kubectl set resources deployment ad -n "$NAMESPACE" \
  -c ad --limits=cpu=20m
kubectl rollout status deployment/ad -n "$NAMESPACE" --timeout=120s

echo "[2/2] Injecting recommendation fault (scaled to 0 replicas)..."
kubectl scale deployment recommendation -n "$NAMESPACE" --replicas=0

echo "Both faults injected."
