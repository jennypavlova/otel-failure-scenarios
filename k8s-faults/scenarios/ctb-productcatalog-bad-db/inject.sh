#!/usr/bin/env bash
# Inject: set DB_CONNECTION_STRING to a non-existent PostgreSQL hostname.
# Simulates: a database migration PR that updated the connection string to the new
#   host but used the wrong hostname. The change passed CI (the string is only
#   validated at runtime) and was merged without noticing the pod would crash.
# Effect: product-catalog pod enters CrashLoopBackOff — the Go service calls
#   pg.Connect() at startup, fails to resolve the hostname, and exits immediately.
#   All callers (frontend, checkout) receive errors for every product operation.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

kubectl set env deployment/product-catalog \
  -n "$NAMESPACE" \
  DB_CONNECTION_STRING="postgres://otelu:otelp@postgresql-broken/otel?sslmode=disable"
