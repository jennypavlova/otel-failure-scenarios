#!/usr/bin/env bash
# Revert: restore QUOTE_ADDR to the correct quote service hostname.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set env deployment/shipping \
  -n "$NAMESPACE" \
  QUOTE_ADDR="http://quote:8080"

kubectl rollout status deployment/shipping -n "$NAMESPACE" --timeout=120s
