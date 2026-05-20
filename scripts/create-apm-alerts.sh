#!/usr/bin/env bash
# create-apm-alerts.sh — Provision Kibana alerting rules for APM RED metrics.
#
# Creates four alerting rules for a given APM service:
#   1. Latency anomaly (ML-based)            — apm.anomaly
#   2. Failed transaction rate > 5%          — apm.transaction_error_rate
#   3. Error count > 10 per 5 min           — apm.error_count
#   4. Service down (0 trace docs / 5 min)  — .index-threshold
#
# Rules are tagged so the script is idempotent: re-running it skips rules that
# already exist for the given service.
#
# Usage:
#   ./scripts/create-apm-alerts.sh [--service <name>] [--dry-run]
#
# Options:
#   --service <name>   APM service name in Kibana (default: paymentservice)
#   --dry-run          Print rule payloads without calling the API
#
# Credentials are read from .env:
#   KIBANA_URL         required
#   KIBANA_API_KEY     preferred (used over Basic auth when set)
#   KIBANA_USERNAME    fallback Basic auth username
#   KIBANA_PASSWORD    fallback Basic auth password
#
# Examples:
#   ./scripts/create-apm-alerts.sh
#   ./scripts/create-apm-alerts.sh --service checkoutservice
#   ./scripts/create-apm-alerts.sh --service paymentservice --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────
SERVICE="paymentservice"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)
      [[ $# -lt 2 || "${2:-}" == --* ]] && die "--service requires a value (e.g. --service checkoutservice)"
      SERVICE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--service <name>] [--dry-run]"
      echo ""
      echo "Options:"
      echo "  --service <name>   APM service name in Kibana (default: paymentservice)"
      echo "  --dry-run          Print rule payloads without calling the API"
      echo ""
      echo "Credentials are read from .env:"
      echo "  KIBANA_URL         required"
      echo "  KIBANA_API_KEY     preferred (used over Basic auth when set)"
      echo "  KIBANA_USERNAME    fallback Basic auth username"
      echo "  KIBANA_PASSWORD    fallback Basic auth password"
      echo ""
      echo "Examples:"
      echo "  $0"
      echo "  $0 --service checkoutservice"
      echo "  $0 --service paymentservice --dry-run"
      exit 0
      ;;
    *)
      die "Unknown argument: $1. Use --help for usage."
      ;;
  esac
done

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
else
  warn ".env not found at ${ENV_FILE} — set credentials as environment variables."
fi

# ── Prerequisites ──────────────────────────────────────────────────────────────
for cmd in curl jq; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found in PATH."
done

[[ -z "${KIBANA_URL:-}" ]] && die "KIBANA_URL is not set. Check your .env file."
KIBANA_URL="${KIBANA_URL%/}"  # strip trailing slash

# ── Auth ───────────────────────────────────────────────────────────────────────
if [[ -n "${KIBANA_API_KEY:-}" ]]; then
  AUTH_HEADER="Authorization: ApiKey ${KIBANA_API_KEY}"
  AUTH_DESC="API key"
elif [[ -n "${KIBANA_USERNAME:-}" && -n "${KIBANA_PASSWORD:-}" ]]; then
  AUTH_HEADER="Authorization: Basic $(printf '%s:%s' "${KIBANA_USERNAME}" "${KIBANA_PASSWORD}" | base64)"
  AUTH_DESC="Basic (${KIBANA_USERNAME})"
else
  die "No credentials found. Set KIBANA_API_KEY or KIBANA_USERNAME + KIBANA_PASSWORD in .env"
fi

# ── Header ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}APM RED Metric Alerts — ${SERVICE}${NC}"
echo -e "Kibana:  ${DIM}${KIBANA_URL}${NC}"
echo -e "Auth:    ${DIM}${AUTH_DESC}${NC}"
$DRY_RUN && echo -e "Mode:    ${YELLOW}dry-run — no rules will be created${NC}"
echo ""

# ── Helper: check if a rule already exists for this service + metric ───────────
# Rules are tagged "apm-red-alert", "service:<name>", and "metric:<type>" so
# this query uniquely identifies each rule regardless of its display name.
rule_exists() {
  local service="$1" metric="$2"
  local filter="alert.attributes.tags:\"apm-red-alert\" AND alert.attributes.tags:\"service:${service}\" AND alert.attributes.tags:\"metric:${metric}\""
  local result
  result=$(curl -sf -G \
    -H "$AUTH_HEADER" \
    --data-urlencode "filter=${filter}" \
    --data-urlencode "per_page=1" \
    "${KIBANA_URL}/api/alerting/rules/_find" 2>/dev/null) || {
    warn "Could not query existing rules (is Kibana reachable?) — proceeding as if none exist"
    return 1
  }
  [[ "$(echo "$result" | jq '.total // 0')" -gt 0 ]]
}

# ── Helper: POST a new rule and report its ID ──────────────────────────────────
create_rule() {
  local name="$1" payload="$2"

  if $DRY_RUN; then
    echo -e "  ${DIM}[dry-run] Payload for '${name}':${NC}"
    echo "$payload" | jq .
    echo ""
    return 0
  fi

  local response http_code body
  response=$(curl -s \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -w "\n%{http_code}" \
    "${KIBANA_URL}/api/alerting/rule")

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    local rule_id
    rule_id=$(echo "$body" | jq -r '.id // "unknown"')
    success "Created '${name}'"
    echo -e "  ${DIM}Rule ID: ${rule_id}${NC}"
  else
    warn "Failed to create '${name}' — HTTP ${http_code}"
    echo "$body" | jq -r '.message // .error // .' 2>/dev/null | sed 's/^/  /' >&2
    return 1
  fi
  echo ""
}

# ── Rule 1: Latency anomaly (apm.anomaly) ─────────────────────────────────────
# Uses ML to detect statistically abnormal latency without a static threshold.
# The same job also scores throughput anomalies, providing an early signal
# for service slowdowns before they breach a fixed latency budget.
#
# Requires APM anomaly detection ML jobs to be running:
#   Kibana → Observability → APM → Anomaly Detection → Enable jobs
# The rule is created regardless and activates once ML jobs are configured.

METRIC="latency"
RULE_NAME="${SERVICE} — Latency Anomaly"

if rule_exists "$SERVICE" "$METRIC"; then
  warn "Skipping '${RULE_NAME}' — rule already exists for service:${SERVICE} metric:${METRIC}"
  echo ""
else
  info "Creating: ${RULE_NAME}"
  create_rule "$RULE_NAME" "$(jq -n \
    --arg name   "$RULE_NAME" \
    --arg service "$SERVICE" \
    '{
      name:         $name,
      rule_type_id: "apm.anomaly",
      consumer:     "apm",
      schedule:     { interval: "5m" },
      params: {
        windowSize:      30,
        windowUnit:      "m",
        anomalySeverity: "critical",
        serviceName:     $service,
        transactionType: "",
        environment:     "ENVIRONMENT_ALL",
        mlJobIds:        []
      },
      tags:        ["apm-red-alert", ("service:" + $service), "metric:latency"],
      alert_delay: { active: 1 }
    }')"
fi

# ── Rule 2: Failed transaction rate (apm.transaction_error_rate) ───────────────
# Fires when more than 5% of transactions fail over a rolling 5-minute window.
# alert_delay of 2 means the threshold must be exceeded on two consecutive checks
# (every 5 min), so a single-window spike does not page.

METRIC="error-rate"
RULE_NAME="${SERVICE} — Failed Transaction Rate > 5%"

if rule_exists "$SERVICE" "$METRIC"; then
  warn "Skipping '${RULE_NAME}' — rule already exists for service:${SERVICE} metric:${METRIC}"
  echo ""
else
  info "Creating: ${RULE_NAME}"
  create_rule "$RULE_NAME" "$(jq -n \
    --arg name    "$RULE_NAME" \
    --arg service "$SERVICE" \
    '{
      name:         $name,
      rule_type_id: "apm.transaction_error_rate",
      consumer:     "apm",
      schedule:     { interval: "5m" },
      params: {
        windowSize:      5,
        windowUnit:      "m",
        threshold:       5,
        serviceName:     $service,
        transactionType: "",
        environment:     "ENVIRONMENT_ALL"
      },
      tags:        ["apm-red-alert", ("service:" + $service), "metric:error-rate"],
      alert_delay: { active: 2 }
    }')"
fi

# ── Rule 3: Error count (apm.error_count) ─────────────────────────────────────
# Fires when the absolute error count exceeds 10 in a 5-minute window.
# Complements the error-rate rule: catches high error volume even when throughput
# is low (e.g. a service receiving few calls but 100% failing produces a low
# error rate percentage but a nonzero absolute count).

METRIC="error-count"
RULE_NAME="${SERVICE} — Error Count > 10 / 5 min"

if rule_exists "$SERVICE" "$METRIC"; then
  warn "Skipping '${RULE_NAME}' — rule already exists for service:${SERVICE} metric:${METRIC}"
  echo ""
else
  info "Creating: ${RULE_NAME}"
  create_rule "$RULE_NAME" "$(jq -n \
    --arg name    "$RULE_NAME" \
    --arg service "$SERVICE" \
    '{
      name:         $name,
      rule_type_id: "apm.error_count",
      consumer:     "apm",
      schedule:     { interval: "5m" },
      params: {
        windowSize:   5,
        windowUnit:   "m",
        threshold:    10,
        serviceName:  $service,
        environment:  "ENVIRONMENT_ALL"
      },
      tags:        ["apm-red-alert", ("service:" + $service), "metric:error-count"],
      alert_delay: { active: 1 }
    }')"
fi

# ── Rule 4: Service down / no data (.index-threshold) ─────────────────────────
# Fires when zero trace documents arrive from the service in the last 5 minutes.
# This catches hard outages immediately — the ML anomaly model (Rule 1) requires
# several data points before it can score a throughput drop as anomalous.
#
# Checks every 2 min. alert_delay of 2 means the service must be silent for
# ~4 minutes before this rule pages, filtering out brief pod restarts.

METRIC="service-down"
RULE_NAME="${SERVICE} — Service Down (no traces / 5 min)"

if rule_exists "$SERVICE" "$METRIC"; then
  warn "Skipping '${RULE_NAME}' — rule already exists for service:${SERVICE} metric:${METRIC}"
  echo ""
else
  info "Creating: ${RULE_NAME}"
  create_rule "$RULE_NAME" "$(jq -n \
    --arg name    "$RULE_NAME" \
    --arg service "$SERVICE" \
    --arg filter  "service.name: \"${SERVICE}\"" \
    '{
      name:         $name,
      rule_type_id: ".index-threshold",
      consumer:     "stackAlerts",
      schedule:     { interval: "2m" },
      params: {
        index:               ["traces-apm*"],
        timeField:           "@timestamp",
        aggType:             "count",
        groupBy:             "all",
        threshold:           [1],
        thresholdComparator: "<",
        timeWindowSize:      5,
        timeWindowUnit:      "m",
        filterKuery:         $filter
      },
      tags:        ["apm-red-alert", ("service:" + $service), "metric:service-down"],
      alert_delay: { active: 2 }
    }')"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}Done.${NC}"
echo ""
echo -e "  View active alerts:  ${KIBANA_URL}/app/observability/alerts"
echo -e "  Manage rules:        ${KIBANA_URL}/app/management/insightsAndAlerting/triggersActions/rules"
echo ""
echo -e "${DIM}To create rules for another service:${NC}"
echo -e "  ${DIM}$0 --service checkoutservice${NC}"
echo ""
