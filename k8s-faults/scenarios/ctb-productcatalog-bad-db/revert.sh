#!/usr/bin/env bash
# Revert: restore DB_CONNECTION_STRING to the correct PostgreSQL hostname.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set env deployment/product-catalog \
  -n "$NAMESPACE" \
  DB_CONNECTION_STRING="postgres://otelu:otelp@postgresql/otel?sslmode=disable"

kubectl rollout status deployment/product-catalog -n "$NAMESPACE" --timeout=120s
