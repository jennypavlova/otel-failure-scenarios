#!/usr/bin/env bash
# setup.sh — provision a cluster and inject a failure scenario for investigation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
bold()    { echo -e "${BOLD}$*${NC}"; }
blank()   { echo ""; }

# ── Defaults ─────────────────────────────────────────────────────────────────
SLACK_ID=""
MODE="human"
SCENARIO="random"
CLUSTER_NAME=""
STACK_VERSION=""

usage() {
  cat <<EOF

${BOLD}OTel Failure Scenarios — Setup${NC}

Provisions a GKE + Elastic Cloud cluster, deploys the OpenTelemetry demo,
and injects a failure scenario ready for investigation.

${BOLD}Usage:${NC}
  ./setup.sh [options]

${BOLD}Options:${NC}
  --slack-id  <id>              Slack member ID for oblt-cli notifications
                                (prompted interactively if omitted)
  --mode      human|ai          Investigation mode  (default: human)
                                  human — shows a vague symptom hint only
                                  ai    — shows a ready-made prompt to give your AI agent
  --scenario  random|infra|<id> Failure scenario to inject  (default: random)
                                  random — any scenario from the full pool
                                  infra  — K8s-native infrastructure faults only
                                           (better for AI agent evaluation)
                                  <id>   — specific scenario, e.g. chaos-env-fail-shipping
  --cluster   <name>            Skip cluster creation and use an existing cluster
                                (e.g. oteldemo-rkznd)
  --stack-version <ver>         Elastic stack version  (default: value in .env)
  --list                        List all available scenario IDs and exit
  --help                        Show this help

${BOLD}Examples:${NC}
  # Full setup — new cluster, human investigation, random scenario
  ./setup.sh --slack-id U03U8RB2Z1V

  # New cluster, AI agent evaluation with infra-only scenario
  ./setup.sh --slack-id U03U8RB2Z1V --mode ai --scenario infra

  # Inject a specific scenario into an existing cluster
  ./setup.sh --cluster oteldemo-rkznd --mode human --scenario chaos-pod-fail-cart

  # See all available scenario IDs
  ./setup.sh --list

EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slack-id)      SLACK_ID="$2";      shift 2 ;;
    --mode)          MODE="$2";          shift 2 ;;
    --scenario)      SCENARIO="$2";      shift 2 ;;
    --cluster)       CLUSTER_NAME="$2";  shift 2 ;;
    --stack-version) STACK_VERSION="$2"; shift 2 ;;
    --list)
      ./scripts/inject-failure.sh --list
      exit 0
      ;;
    --help|-h) usage; exit 0 ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; usage; exit 1 ;;
  esac
done

# Validate --mode
[[ "$MODE" == "human" || "$MODE" == "ai" ]] || \
  die "--mode must be 'human' or 'ai', got: $MODE"

# ── Banner ────────────────────────────────────────────────────────────────────
blank
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  OTel Failure Scenarios — Setup${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${DIM}Mode:      ${NC}${BOLD}$MODE${NC}"
echo -e "  ${DIM}Scenario:  ${NC}${BOLD}$SCENARIO${NC}"
[[ -n "$CLUSTER_NAME" ]] && echo -e "  ${DIM}Cluster:   ${NC}${BOLD}$CLUSTER_NAME${NC} ${DIM}(existing)${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
blank

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
bold "Step 1/5 — Checking prerequisites"

check_tool() {
  local tool=$1 install_hint=$2
  if command -v "$tool" &>/dev/null; then
    ok "$tool found ($(command -v "$tool"))"
  else
    warn "$tool not found — $install_hint"
    return 1
  fi
}

MISSING=0
check_tool gh       "brew install gh"                           || MISSING=1
check_tool kubectl  "brew install kubectl"                      || MISSING=1
check_tool jq       "brew install jq"                           || MISSING=1

# oblt-cli needs special handling
if ! command -v oblt-cli &>/dev/null; then
  info "oblt-cli not found — installing via Homebrew..."
  export HOMEBREW_GITHUB_API_TOKEN
  HOMEBREW_GITHUB_API_TOKEN=$(gh auth token 2>/dev/null) || \
    die "gh not authenticated. Run: gh auth login"
  brew tap elastic/oblt-cli 2>/dev/null || true
  brew install elastic/oblt-cli/oblt-cli
  ok "oblt-cli installed"
else
  ok "oblt-cli found"
fi

[[ $MISSING -eq 0 ]] || die "Install missing tools above, then re-run."

# Check gh auth
if ! gh auth status &>/dev/null; then
  die "GitHub CLI not authenticated. Run: gh auth login"
fi
GH_USER=$(gh api user --jq .login 2>/dev/null)
ok "GitHub authenticated as ${BOLD}$GH_USER${NC}"

blank

# ── Step 2: Slack ID + oblt-cli config ───────────────────────────────────────
if [[ -z "$CLUSTER_NAME" ]]; then
  bold "Step 2/5 — Configuring oblt-cli"

  # Prompt for Slack ID if not passed as a param
  if [[ -z "$SLACK_ID" ]]; then
    blank
    echo -e "  ${DIM}Your Slack member ID is used by oblt-robot-ci to DM you cluster credentials.${NC}"
    echo -e "  ${DIM}Find it in Slack: Profile → ⋮ → Copy member ID  (e.g. U03U8RB2Z1V)${NC}"
    blank
    read -rp "  Enter your Slack member ID: " SLACK_ID
    [[ -n "$SLACK_ID" ]] || die "Slack ID cannot be empty."
  fi

  info "Configuring oblt-cli for user ${BOLD}$GH_USER${NC}, Slack ${BOLD}@$SLACK_ID${NC}..."
  oblt-cli configure \
    --slack-channel="@${SLACK_ID}" \
    --username="$GH_USER" \
    --git-http-mode 2>&1 | grep -E "\[info\]|\[warn\]|\[error\]" || true
  ok "oblt-cli configured"
  blank
else
  info "Skipping oblt-cli config — using existing cluster ${BOLD}$CLUSTER_NAME${NC}"
  blank
fi

# ── Step 3: Cluster creation ──────────────────────────────────────────────────
if [[ -z "$CLUSTER_NAME" ]]; then
  bold "Step 3/5 — Creating cluster"

  # Load .env for STACK_VERSION
  [[ -f .env ]] || cp .env.example .env
  # shellcheck source=/dev/null
  source .env 2>/dev/null || true
  [[ -n "$STACK_VERSION" ]] || STACK_VERSION="${STACK_VERSION:-9.4.0-SNAPSHOT}"

  info "Creating ESS + GKE cluster with template ${BOLD}oteldemo${NC}, stack ${BOLD}$STACK_VERSION${NC}..."
  blank

  CREATION_OUTPUT=$(oblt-cli cluster create custom \
    --template oteldemo \
    --parameter "StackVersion=${STACK_VERSION}" \
    --parameter "Template=observability" 2>&1)

  echo "$CREATION_OUTPUT" | grep -E "\[info\]|\[warn\]|\[error\]" || true

  # Parse cluster name from output
  CLUSTER_NAME=$(echo "$CREATION_OUTPUT" | grep -oE 'oteldemo-[a-z0-9]+' | head -1)
  [[ -n "$CLUSTER_NAME" ]] || die "Could not parse cluster name from oblt-cli output."

  ok "Cluster name: ${BOLD}$CLUSTER_NAME${NC}"
  blank

  # Poll GitHub PR until cluster is ready
  bold "  Waiting for cluster to be ready (~5–10 min)..."
  info "  Tracking: https://github.com/elastic/observability-test-environments/pulls?q=$CLUSTER_NAME"
  blank

  PR_NUMBER=""
  for i in $(seq 1 10); do
    PR_NUMBER=$(gh pr list \
      --repo elastic/observability-test-environments \
      --search "$CLUSTER_NAME" --state all \
      --json number --jq '.[0].number' 2>/dev/null || true)
    [[ -n "$PR_NUMBER" ]] && break
    sleep 10
  done
  [[ -n "$PR_NUMBER" ]] || die "Could not find CI PR for $CLUSTER_NAME"

  ELAPSED=0
  while true; do
    STATUS=$(gh pr checks "$PR_NUMBER" \
      --repo elastic/observability-test-environments 2>&1 \
      | grep "create (environments/users/${GH_USER}/${CLUSTER_NAME}.yml)" || true)

    if echo "$STATUS" | grep -q "pass"; then
      ok "Cluster ready after ${ELAPSED}s"
      break
    elif echo "$STATUS" | grep -q "fail"; then
      die "Cluster creation failed. Check: https://github.com/elastic/observability-test-environments/pull/$PR_NUMBER"
    fi

    printf "  ${DIM}[%3ds] still provisioning...${NC}\r" "$ELAPSED"
    sleep 15
    ELAPSED=$((ELAPSED + 15))

    [[ $ELAPSED -lt 900 ]] || die "Cluster creation timed out after 15 min."
  done
  blank
else
  info "Step 3/5 — Skipping cluster creation (using ${BOLD}$CLUSTER_NAME${NC})"
  blank
fi

# ── Step 4: Initialise cluster ────────────────────────────────────────────────
bold "Step 4/5 — Initialising cluster"
./scripts/init-cluster.sh "$CLUSTER_NAME"
blank

# ── Step 5: Inject scenario ───────────────────────────────────────────────────
bold "Step 5/5 — Injecting failure scenario"

case "$SCENARIO" in
  random)
    ./scripts/inject-failure.sh --quiet
    ;;
  infra)
    ./scripts/inject-failure.sh --infra-only --quiet
    ;;
  *)
    ./scripts/inject-failure.sh --scenario="$SCENARIO" --quiet
    ;;
esac

blank

# ── Investigation prompt ──────────────────────────────────────────────────────
source .env 2>/dev/null || true

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "$MODE" == "human" ]]; then
  echo -e "${BOLD}  Your investigation starts now${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
  ./scripts/inject-failure.sh --status
  blank
  echo -e "  ${BOLD}Kibana:${NC}  ${KIBANA_URL:-<see .env>}"
  echo -e "  ${BOLD}Login:${NC}   ${KIBANA_USERNAME:-elastic} / ${KIBANA_PASSWORD:-(see .env)}"
  blank
  echo -e "  ${DIM}Demo shop:      http://localhost:8080${NC}"
  echo -e "  ${DIM}Feature flags:  http://localhost:8080/feature${NC}"
  blank
  echo -e "  ${DIM}When done: ./scripts/inject-failure.sh --reveal${NC}"
  echo -e "  ${DIM}Clean up:  ./cleanup.sh --cluster $CLUSTER_NAME${NC}"

else
  echo -e "${BOLD}  AI agent investigation prompt${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
  echo -e "  ${DIM}Give this prompt to your AI agent (Kibana AI Assistant, Elastic Agent, etc.):${NC}"
  blank
  echo -e "${BOLD}  ┌─────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}  │${NC}  We have a problem in production. Some users are    ${BOLD}│${NC}"
  echo -e "${BOLD}  │${NC}  experiencing issues with the application.          ${BOLD}│${NC}"
  echo -e "${BOLD}  │${NC}  Please investigate using Kibana APM, logs, and     ${BOLD}│${NC}"
  echo -e "${BOLD}  │${NC}  infrastructure metrics. Start from the service map  ${BOLD}│${NC}"
  echo -e "${BOLD}  │${NC}  or the alerts page and find the root cause.         ${BOLD}│${NC}"
  echo -e "${BOLD}  └─────────────────────────────────────────────────────┘${NC}"
  blank
  echo -e "  ${BOLD}Kibana:${NC}  ${KIBANA_URL:-<see .env>}"
  echo -e "  ${BOLD}Login:${NC}   ${KIBANA_USERNAME:-elastic} / ${KIBANA_PASSWORD:-(see .env)}"
  blank
  echo -e "  ${DIM}Alerts page:    ${KIBANA_URL:-<kibana-url>}/app/observability/alerts${NC}"
  echo -e "  ${DIM}Service map:    ${KIBANA_URL:-<kibana-url>}/app/apm/service-map${NC}"
  blank
  echo -e "  ${DIM}Reveal answer:  ./scripts/inject-failure.sh --reveal${NC}"
  echo -e "  ${DIM}Clean up:       ./cleanup.sh --cluster $CLUSTER_NAME${NC}"
fi

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
blank
