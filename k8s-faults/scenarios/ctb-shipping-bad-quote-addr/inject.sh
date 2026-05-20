#!/usr/bin/env bash
# Inject: set QUOTE_ADDR to a non-existent hostname.
# Simulates: a config migration PR that updated the shipping service to read its
#   quote service endpoint from an env var (previously hardcoded). The env var was
#   set to the old internal hostname that had already been renamed. The pod deploys
#   successfully — shipping only contacts the quote service per-request, not at
#   startup — but every shipping cost calculation fails with a connection error.
# Effect: shipping pod remains 1/1 Running (no CrashLoopBackOff) but every
#   GetQuote call returns a gRPC connection error. All checkouts fail at the
#   shipping step.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set env deployment/shipping \
  -n "$NAMESPACE" \
  QUOTE_ADDR="http://quote-old:8080"

kubectl rollout status deployment/shipping -n "$NAMESPACE" --timeout=120s
