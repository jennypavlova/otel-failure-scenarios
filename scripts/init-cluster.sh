#!/usr/bin/env bash
# init-cluster.sh — Post-provisioning setup for the oteldemo cluster.
#
# Run this once after configuring kubectl access to:
#   1. Reset all flagd failure flags to off (the oteldemo template pre-activates several)
#   2. Tune the load generator to stable settings (the template defaults OOMKill the pod)
#
# Usage:
#   ./scripts/init-cluster.sh [cluster-name]
#
# If a cluster-name is provided, kubectl access is configured automatically
# via oblt-cli before running the init steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Optional: configure kubectl via oblt-cli ──────────────────────────────────
CLUSTER_NAME="${1:-}"
if [[ -n "$CLUSTER_NAME" ]]; then
  info "Configuring kubectl for cluster '${CLUSTER_NAME}'..."
  oblt-cli cluster k8s --cluster-name "${CLUSTER_NAME}" || die "Failed to configure kubectl. Check your cluster name and oblt-cli auth."
  echo ""
fi

# ── Verify kubectl can reach a live cluster ───────────────────────────────────
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
if [[ -z "$CURRENT_CONTEXT" ]]; then
  die "No kubectl context set. Run: oblt-cli cluster k8s --cluster-name <your-cluster-name>"
fi

info "Checking cluster connectivity (context: ${CURRENT_CONTEXT})..."
if ! kubectl get nodes &>/dev/null; then
  die "Cannot reach cluster '${CURRENT_CONTEXT}'. Run: oblt-cli cluster k8s --cluster-name <your-cluster-name>"
fi
success "Connected to cluster '${CURRENT_CONTEXT}'"
echo ""

NAMESPACE="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo 'default')}"

echo -e "${BOLD}OTel Demo — cluster initialisation${NC}"
echo "Namespace: ${NAMESPACE}"
echo ""

# ── 1. Sync canonical flagd config and reset all flags to off ────────────────
echo -e "${BOLD}Step 1/2 — Syncing flagd config and resetting flags${NC}"

FLAGD_POD=$(kubectl get po -l app.kubernetes.io/component=flagd \
  -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$FLAGD_POD" ]] && die "flagd pod not found. Is kubectl configured correctly?"

CANONICAL_FILE="${SCRIPT_DIR}/../flagd/demo.flagd.json"
[[ -f "$CANONICAL_FILE" ]] || die "Canonical flagd config not found: ${CANONICAL_FILE}"

# Check what's live vs what should be there
LIVE_FLAGS=$(kubectl exec "$FLAGD_POD" -c flagd-ui -n "$NAMESPACE" -- \
  cat /app/data/demo.flagd.json | jq -r '.flags | keys | sort | @csv' 2>/dev/null)
CANONICAL_FLAGS=$(jq -r '.flags | keys | sort | @csv' "$CANONICAL_FILE")

ACTIVE=$(kubectl exec "$FLAGD_POD" -c flagd-ui -n "$NAMESPACE" -- \
  cat /app/data/demo.flagd.json | jq -r '
    .flags | to_entries[]
    | select(.value.defaultVariant != "off")
    | "  \(.key): \(.value.defaultVariant)"
  ')

NEEDS_SYNC=false
if [[ "$LIVE_FLAGS" != "$CANONICAL_FLAGS" ]]; then
  warn "Live flagd config is missing flags — syncing canonical config from flagd/demo.flagd.json..."
  NEEDS_SYNC=true
fi

if [[ -n "$ACTIVE" ]]; then
  echo "Turning off:"
  echo "$ACTIVE"
  NEEDS_SYNC=true
fi

if [[ "$NEEDS_SYNC" == true ]]; then
  # Always write the full canonical config (all flags present, all set to off)
  CANONICAL_JSON=$(jq '.flags |= with_entries(.value.defaultVariant = "off")' "$CANONICAL_FILE")
  PATCH_PAYLOAD=$(jq -n --arg json "$CANONICAL_JSON" '{"data": {"demo.flagd.json": $json}}')
  kubectl patch configmap flagd-config -n "$NAMESPACE" --type merge --patch "$PATCH_PAYLOAD" &>/dev/null
  kubectl rollout restart deployment/flagd -n "$NAMESPACE" &>/dev/null
  kubectl rollout status deployment/flagd -n "$NAMESPACE" --timeout=120s &>/dev/null
  success "flagd config synced and all flags reset to off"
else
  success "All flags already correct"
fi

echo ""

# ── 2. Tune load generator ────────────────────────────────────────────────────
echo -e "${BOLD}Step 2/2 — Tuning load generator${NC}"

# The oteldemo template sets LOCUST_USERS=50, which consistently OOMKills the
# pod under GKE Autopilot's default memory limits. Drop to 10 users, which
# keeps the pod stable and still generates meaningful load.
CURRENT_USERS=$(kubectl get deployment load-generator -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LOCUST_USERS")].value}' 2>/dev/null || echo "")

TARGET_USERS=10

if [[ "$CURRENT_USERS" == "$TARGET_USERS" ]]; then
  success "Load generator already set to ${TARGET_USERS} users"
else
  info "Setting LOCUST_USERS from ${CURRENT_USERS:-unknown} → ${TARGET_USERS}..."
  kubectl set env deployment/load-generator LOCUST_USERS="${TARGET_USERS}" -n "$NAMESPACE"
  kubectl rollout status deployment/load-generator -n "$NAMESPACE" --timeout=120s
  success "Load generator stable at ${TARGET_USERS} users"
fi

echo ""
echo -e "${GREEN}${BOLD}Cluster ready.${NC} Starting port-forwards..."
echo ""

"${SCRIPT_DIR}/start-demo.sh"
