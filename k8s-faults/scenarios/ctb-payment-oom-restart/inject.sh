#!/usr/bin/env bash
# Inject: lower the payment service memory limit to 25Mi.
# Simulates a memory-audit PR that set an aggressive limit without load testing.
# Effect: Node.js runtime exceeds 25Mi immediately — pod OOMKills and enters
# CrashLoopBackOff. Payments fail intermittently during restart windows.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set resources deployment payment -n "$NAMESPACE" \
  -c payment --limits=memory=25Mi
