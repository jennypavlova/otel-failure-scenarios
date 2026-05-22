#!/usr/bin/env bash
# cleanup.sh — tear down the cluster and reset all local state
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
blank() { echo ""; }

CLUSTER_NAME=""
SKIP_CONFIRM=false

usage() {
  cat <<EOF

${BOLD}OTel Failure Scenarios — Cleanup${NC}

Resets all active failures, destroys the GKE + ESS cluster,
and cleans up local credentials and kubectl context.

${BOLD}Usage:${NC}
  ./cleanup.sh [options]

${BOLD}Options:${NC}
  --cluster <name>   Cluster name to destroy (reads from .env if omitted)
  --yes              Skip confirmation prompt
  --help             Show this help

${BOLD}Examples:${NC}
  ./cleanup.sh --cluster oteldemo-rkznd
  ./cleanup.sh --yes

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER_NAME="$2"; shift 2 ;;
    --yes|-y)  SKIP_CONFIRM=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; usage; exit 1 ;;
  esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
blank
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  OTel Failure Scenarios — Cleanup${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
blank

# ── Resolve cluster name ──────────────────────────────────────────────────────
if [[ -z "$CLUSTER_NAME" ]]; then
  if [[ -f .env ]]; then
    # shellcheck source=/dev/null
    source .env 2>/dev/null || true
    # Try to derive cluster name from KIBANA_URL (e.g. oteldemo-rkznd.kb.us-west2...)
    CLUSTER_NAME=$(echo "${KIBANA_URL:-}" | grep -oE 'oteldemo-[a-z0-9]+' | head -1 || true)
  fi
fi

if [[ -z "$CLUSTER_NAME" ]]; then
  blank
  read -rp "  Enter cluster name to destroy (e.g. oteldemo-rkznd): " CLUSTER_NAME
  [[ -n "$CLUSTER_NAME" ]] || die "Cluster name cannot be empty."
fi

echo -e "  ${DIM}Cluster:${NC}  ${BOLD}$CLUSTER_NAME${NC}"
blank

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ "$SKIP_CONFIRM" == false ]]; then
  echo -e "  ${YELLOW}This will:${NC}"
  echo -e "  ${DIM}  • Reset all active failure scenarios${NC}"
  echo -e "  ${DIM}  • Stop all port-forwards${NC}"
  echo -e "  ${DIM}  • Destroy the GKE cluster and ESS deployment${NC}"
  echo -e "  ${DIM}  • Remove credentials from .env${NC}"
  echo -e "  ${DIM}  • Remove kubectl context for $CLUSTER_NAME${NC}"
  blank
  read -rp "  Type 'yes' to confirm: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { info "Aborted."; exit 0; }
  blank
fi

# ── Step 1: Reset all active failures ────────────────────────────────────────
echo -e "${BOLD}Step 1/4 — Resetting failure scenarios${NC}"
if [[ -f ./scripts/inject-failure.sh ]]; then
  ./scripts/inject-failure.sh --reset-all 2>&1 || warn "Could not reset failures (cluster may already be gone)"
else
  warn "inject-failure.sh not found — skipping"
fi
blank

# ── Step 2: Stop port-forwards ────────────────────────────────────────────────
echo -e "${BOLD}Step 2/4 — Stopping port-forwards${NC}"
if [[ -f ./scripts/start-demo.sh ]]; then
  ./scripts/start-demo.sh --stop 2>&1 || warn "Could not stop port-forwards"
else
  # Fallback: kill kubectl port-forward processes
  pkill -f "kubectl port-forward" 2>/dev/null && ok "Port-forwards stopped" || info "No port-forwards running"
fi
blank

# ── Step 3: Destroy cluster ───────────────────────────────────────────────────
echo -e "${BOLD}Step 3/4 — Destroying cluster ${CLUSTER_NAME}${NC}"
if command -v oblt-cli &>/dev/null; then
  info "Submitting destroy request via oblt-cli..."
  info "oblt-robot-ci will DM you on Slack when teardown is complete (~5 min)"
  oblt-cli cluster destroy --cluster-name "$CLUSTER_NAME" --force 2>&1 \
    | grep -E "\[info\]|\[warn\]|\[error\]" || true
  ok "Destroy request submitted"
else
  warn "oblt-cli not found — cluster must be destroyed manually:"
  echo -e "  ${DIM}oblt-cli cluster destroy --cluster-name $CLUSTER_NAME${NC}"
fi
blank

# ── Step 4: Clean up local state ──────────────────────────────────────────────
echo -e "${BOLD}Step 4/4 — Cleaning up local state${NC}"

# Remove credentials from .env (keep template structure, blank the values)
if [[ -f .env ]]; then
  sed -i.bak \
    -e 's|^KIBANA_URL=.*|KIBANA_URL=|' \
    -e 's|^KIBANA_PASSWORD=.*|KIBANA_PASSWORD=|' \
    -e 's|^KIBANA_API_KEY=.*|KIBANA_API_KEY=|' \
    -e 's|^ELASTICSEARCH_URL=.*|ELASTICSEARCH_URL=|' \
    -e 's|^ELASTICSEARCH_PASSWORD=.*|ELASTICSEARCH_PASSWORD=|' \
    .env && rm -f .env.bak
  ok "Credentials cleared from .env"
fi

# Remove failure state file
if [[ -f .failure-state ]]; then
  rm -f .failure-state
  ok ".failure-state removed"
fi

# Remove kubectl context
if command -v kubectl &>/dev/null; then
  if kubectl config get-contexts "$CLUSTER_NAME" &>/dev/null 2>&1; then
    kubectl config delete-context "$CLUSTER_NAME" &>/dev/null && ok "kubectl context removed"
  else
    info "kubectl context not found — skipping"
  fi
fi

blank
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Cleanup complete.${NC}"
echo -e "  ${DIM}oblt-robot-ci will DM you on Slack when the cluster is fully destroyed.${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
blank
