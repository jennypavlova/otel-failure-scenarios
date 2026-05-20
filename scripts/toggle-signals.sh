#!/usr/bin/env bash
# toggle-signals.sh — Enable or disable OTel signal types (traces, logs, metrics)
# flowing through the gateway collector by injecting drop-all filter processors.
#
# The gateway collector (opentelemetry-kube-stack-gateway) is the final stage
# before Elasticsearch. Disabling a signal prepends a filter processor with an
# OTTL expression of 'true' (always matches, always drops) to the relevant
# pipelines. The OTel Operator picks up the CRD patch and rolls the gateway pods.
#
# The CRD itself is the source of truth — no state file is used.
#
# Usage:
#   ./scripts/toggle-signals.sh --status
#   ./scripts/toggle-signals.sh --disable=traces
#   ./scripts/toggle-signals.sh --disable=logs,metrics
#   ./scripts/toggle-signals.sh --enable=traces
#   ./scripts/toggle-signals.sh --enable=logs,metrics
#   ./scripts/toggle-signals.sh --reset
#
# Pipelines affected per signal:
#   traces  → traces
#   logs    → logs
#   metrics → metrics, metrics/otel, metrics/infra/ecs, metrics/aggregated-otel-metrics

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
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

# ── Constants ──────────────────────────────────────────────────────────────────
GATEWAY_CRD="opentelemetry-kube-stack-gateway"
ALL_SIGNALS=("traces" "logs" "metrics")

# Returns a JSON array of pipeline names for a given signal
signal_pipelines() {
  case "$1" in
    traces)  echo '["traces"]' ;;
    logs)    echo '["logs"]' ;;
    metrics) echo '["metrics","metrics/otel","metrics/infra/ecs","metrics/aggregated-otel-metrics"]' ;;
  esac
}

# ── Prerequisite checks ────────────────────────────────────────────────────────
for cmd in kubectl jq; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is not installed or not in PATH."
done

# ── Namespace ──────────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo 'default')}"

# ── Argument parsing ───────────────────────────────────────────────────────────
MODE=""
SIGNALS=()

for arg in "$@"; do
  case "$arg" in
    --status)
      MODE="status"
      ;;
    --disable=*)
      MODE="disable"
      IFS=',' read -ra SIGNALS <<< "${arg#*=}"
      ;;
    --enable=*)
      MODE="enable"
      IFS=',' read -ra SIGNALS <<< "${arg#*=}"
      ;;
    --reset)
      MODE="reset"
      SIGNALS=("${ALL_SIGNALS[@]}")
      ;;
    -h|--help)
      MODE="help"
      ;;
    *)
      die "Unknown argument: $arg"
      ;;
  esac
done

if [[ -z "$MODE" || "$MODE" == "help" ]]; then
  echo "Usage:"
  echo "  $0 --status"
  echo "  $0 --disable=<signals>   (comma-separated: traces, logs, metrics)"
  echo "  $0 --enable=<signals>"
  echo "  $0 --reset               (re-enable all signals)"
  echo ""
  echo "Examples:"
  echo "  $0 --status"
  echo "  $0 --disable=traces"
  echo "  $0 --disable=logs,metrics"
  echo "  $0 --enable=traces"
  echo "  $0 --reset"
  [[ "$MODE" == "help" ]] && exit 0 || exit 1
fi

# ── Validate signal names ──────────────────────────────────────────────────────
validate_signals() {
  for sig in "${SIGNALS[@]}"; do
    case "$sig" in
      traces|logs|metrics) ;;
      *) die "Unknown signal '$sig'. Valid signals: traces, logs, metrics" ;;
    esac
  done
}

[[ ${#SIGNALS[@]} -gt 0 ]] && validate_signals

# ── Verify kubectl connectivity ────────────────────────────────────────────────
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
[[ -z "$CURRENT_CONTEXT" ]] && die "No kubectl context set."

if ! kubectl get opentelemetrycollector "$GATEWAY_CRD" -n "$NAMESPACE" &>/dev/null; then
  die "Gateway CRD '$GATEWAY_CRD' not found in namespace '$NAMESPACE'."
fi

# ── Helper: check whether a signal is currently disabled ──────────────────────
# Returns 0 (true) if filter/drop_<signal> is in any of the signal's pipelines
is_disabled() {
  local signal="$1"
  local current="$2"
  local filter_name="filter/drop_${signal}"
  local pipeline
  pipeline=$(signal_pipelines "$signal" | jq -r '.[0]')
  echo "$current" \
    | jq -e --arg p "$pipeline" --arg f "$filter_name" \
      '.spec.config.service.pipelines[$p].processors // [] | map(select(. == $f)) | length > 0' \
    &>/dev/null
}

# ── --status ──────────────────────────────────────────────────────────────────
if [[ "$MODE" == "status" ]]; then
  info "Reading gateway CRD '${GATEWAY_CRD}' in namespace '${NAMESPACE}'..."
  CURRENT=$(kubectl get opentelemetrycollector "$GATEWAY_CRD" -n "$NAMESPACE" -o json)

  echo ""
  printf "${BOLD}%-12s  %s${NC}\n" "Signal" "Status"
  printf '%s\n' "──────────────────────"
  for sig in "${ALL_SIGNALS[@]}"; do
    if is_disabled "$sig" "$CURRENT"; then
      printf "%-12s  ${RED}disabled${NC}\n" "$sig"
    else
      printf "%-12s  ${GREEN}enabled${NC}\n" "$sig"
    fi
  done
  echo ""
  exit 0
fi

# ── Build processor definition JSON for a signal ──────────────────────────────
processor_def() {
  local signal="$1"
  case "$signal" in
    traces)
      jq -n '{"error_mode": "ignore", "traces": {"span": ["true"]}}'
      ;;
    logs)
      jq -n '{"error_mode": "ignore", "logs": {"log_record": ["true"]}}'
      ;;
    metrics)
      jq -n '{"error_mode": "ignore", "metrics": {"metric": ["true"]}}'
      ;;
  esac
}

# ── Apply patch to the gateway CRD ────────────────────────────────────────────
apply_patch() {
  local patch="$1"
  kubectl patch opentelemetrycollector "$GATEWAY_CRD" \
    -n "$NAMESPACE" --type=merge -p "$patch"
}

# ── Wait for gateway rollout ───────────────────────────────────────────────────
wait_rollout() {
  info "Waiting for gateway rollout to complete..."
  kubectl rollout status "deployment/${GATEWAY_CRD}-collector" \
    -n "$NAMESPACE" --timeout=120s
}

# ── --disable ─────────────────────────────────────────────────────────────────
if [[ "$MODE" == "disable" ]]; then
  CURRENT=$(kubectl get opentelemetrycollector "$GATEWAY_CRD" -n "$NAMESPACE" -o json)

  PATCH_PROCESSORS='{}'
  PATCH_PIPELINES='{}'
  CHANGED=()

  for sig in "${SIGNALS[@]}"; do
    filter_name="filter/drop_${sig}"

    if is_disabled "$sig" "$CURRENT"; then
      warn "Signal '${sig}' is already disabled — skipping"
      continue
    fi

    info "Disabling signal '${sig}' (prepending ${filter_name} to pipelines)..."
    CHANGED+=("$sig")

    # Add processor definition
    proc_def=$(processor_def "$sig")
    PATCH_PROCESSORS=$(echo "$PATCH_PROCESSORS" \
      | jq --arg name "$filter_name" --argjson def "$proc_def" \
        '. + {($name): $def}')

    # Prepend filter to each pipeline for this signal
    pipelines=$(signal_pipelines "$sig" | jq -r '.[]')
    while IFS= read -r pipeline; do
      current_procs=$(echo "$CURRENT" \
        | jq --arg p "$pipeline" \
          '.spec.config.service.pipelines[$p].processors // []')
      new_procs=$(echo "$current_procs" \
        | jq --arg f "$filter_name" '[$f] + map(select(. != $f))')
      PATCH_PIPELINES=$(echo "$PATCH_PIPELINES" \
        | jq --arg p "$pipeline" --argjson procs "$new_procs" \
          '. + {($p): {"processors": $procs}}')
    done <<< "$pipelines"
  done

  if [[ ${#CHANGED[@]} -eq 0 ]]; then
    warn "No signals needed to be disabled — gateway unchanged."
    echo ""
    exit 0
  fi

  PATCH=$(jq -n \
    --argjson processors "$PATCH_PROCESSORS" \
    --argjson pipelines  "$PATCH_PIPELINES" \
    '{
      "spec": {
        "config": {
          "processors": $processors,
          "service": {
            "pipelines": $pipelines
          }
        }
      }
    }')

  apply_patch "$PATCH"
  wait_rollout

  for sig in "${CHANGED[@]}"; do
    success "Signal '${sig}' is now ${RED}disabled${NC} — data will be dropped at the gateway"
  done
  echo ""
  exit 0
fi

# ── --enable / --reset ────────────────────────────────────────────────────────
if [[ "$MODE" == "enable" || "$MODE" == "reset" ]]; then
  CURRENT=$(kubectl get opentelemetrycollector "$GATEWAY_CRD" -n "$NAMESPACE" -o json)

  PATCH_PIPELINES='{}'
  PROCESSORS_TO_REMOVE=()

  for sig in "${SIGNALS[@]}"; do
    filter_name="filter/drop_${sig}"

    if ! is_disabled "$sig" "$CURRENT"; then
      warn "Signal '${sig}' is already enabled — skipping"
      continue
    fi

    info "Enabling signal '${sig}' (removing ${filter_name} from pipelines)..."

    PROCESSORS_TO_REMOVE+=("$filter_name")

    # Remove filter from each pipeline for this signal
    pipelines=$(signal_pipelines "$sig" | jq -r '.[]')
    while IFS= read -r pipeline; do
      current_procs=$(echo "$CURRENT" \
        | jq --arg p "$pipeline" \
          '.spec.config.service.pipelines[$p].processors // []')
      new_procs=$(echo "$current_procs" \
        | jq --arg f "$filter_name" 'map(select(. != $f))')
      PATCH_PIPELINES=$(echo "$PATCH_PIPELINES" \
        | jq --arg p "$pipeline" --argjson procs "$new_procs" \
          '. + {($p): {"processors": $procs}}')
    done <<< "$pipelines"
  done

  if [[ ${#PROCESSORS_TO_REMOVE[@]} -eq 0 ]]; then
    warn "No signals needed to be enabled — gateway unchanged."
    echo ""
    exit 0
  fi

  # Build processors patch: set each removed processor to null (strategic merge
  # delete requires the key to be present; null removes it from the map)
  PATCH_PROCESSORS='{}'
  for proc in "${PROCESSORS_TO_REMOVE[@]}"; do
    PATCH_PROCESSORS=$(echo "$PATCH_PROCESSORS" \
      | jq --arg name "$proc" '. + {($name): null}')
  done

  PATCH=$(jq -n \
    --argjson processors "$PATCH_PROCESSORS" \
    --argjson pipelines  "$PATCH_PIPELINES" \
    '{
      "spec": {
        "config": {
          "processors": $processors,
          "service": {
            "pipelines": $pipelines
          }
        }
      }
    }')

  apply_patch "$PATCH"
  wait_rollout

  for proc in "${PROCESSORS_TO_REMOVE[@]}"; do
    sig="${proc#filter/drop_}"
    success "Signal '${sig}' is now ${GREEN}enabled${NC}"
  done
  echo ""
  exit 0
fi
