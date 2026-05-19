#!/usr/bin/env bash
# start-demo.sh — Manage background port-forwards for the OTel demo.
#
# Starts kubectl port-forward processes in the background so the demo UI and
# Chaos Mesh dashboard are accessible in a browser without tying up your terminal.
# Running again is idempotent — already-running forwards are left untouched.
#
# Managed forwards:
#   localhost:8080  → svc/frontend-proxy  (shop, flagd UI, load gen UI, Jaeger)
#   localhost:2333  → svc/chaos-dashboard (Chaos Mesh UI)
#
# Logs: /tmp/otel-demo-forward-*.log
#
# Usage:
#   ./scripts/start-demo.sh           # Ensure all port-forwards are running
#   ./scripts/start-demo.sh --stop    # Kill all demo port-forwards
#   ./scripts/start-demo.sh --status  # Print health of each port-forward

set -euo pipefail

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
blank()   { echo ""; }

NAMESPACE="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo 'default')}"
LOG_DIR="/tmp"

# ── Forward definitions: "label|svc|local-port|remote-port|url|description" ──
declare -a FORWARDS=(
  "frontend|svc/frontend-proxy|8080|8080|http://localhost:8080|Demo shop, flagd UI (/feature), load gen UI (/loadgen)"
  "chaos|svc/chaos-dashboard|2333|2333|http://localhost:2333|Chaos Mesh dashboard"
)

# ── Helper: check if a port is actively listening ─────────────────────────────
port_in_use() {
  local port="$1"
  lsof -ti :"$port" &>/dev/null
}

# ── Helper: return the PID of an existing kubectl port-forward for a port ──────
pf_pid() {
  local port="$1"
  pgrep -f "kubectl port-forward.*:${port}" 2>/dev/null | head -1 || true
}

# ── Helper: start one forward in the background ───────────────────────────────
start_forward() {
  local label="$1" svc="$2" local_port="$3" remote_port="$4"
  local log_file="${LOG_DIR}/otel-demo-forward-${label}.log"

  kubectl port-forward -n "$NAMESPACE" "$svc" "${local_port}:${remote_port}" \
    > "$log_file" 2>&1 &
  disown $!

  # Give kubectl a moment to bind the port
  local attempts=0
  while ! port_in_use "$local_port" && (( attempts < 10 )); do
    sleep 0.5
    (( attempts++ )) || true
  done

  if port_in_use "$local_port"; then
    return 0
  else
    warn "Port-forward for ${svc} did not start cleanly. Check ${log_file}"
    return 1
  fi
}

# ── Command: --status ──────────────────────────────────────────────────────────
cmd_status() {
  blank
  echo -e "${BOLD}Port-forward status:${NC}"
  blank
  for fwd in "${FORWARDS[@]}"; do
    local label svc local_port remote_port url description
    label=$(echo "$fwd" | cut -d'|' -f1)
    svc=$(echo "$fwd" | cut -d'|' -f2)
    local_port=$(echo "$fwd" | cut -d'|' -f3)
    url=$(echo "$fwd" | cut -d'|' -f5)
    description=$(echo "$fwd" | cut -d'|' -f6)

    if port_in_use "$local_port"; then
      local pid
      pid=$(pf_pid "$local_port")
      echo -e "  ${GREEN}●${NC} ${BOLD}${url}${NC}  ${DIM}(pid ${pid:-?})${NC}"
      echo -e "    ${DIM}${description}${NC}"
    else
      echo -e "  ${RED}○${NC} ${BOLD}localhost:${local_port}${NC}  ${DIM}(not running — ${svc})${NC}"
      echo -e "    ${DIM}${description}${NC}"
    fi
    echo ""
  done
  echo -e "  ${DIM}Run ./scripts/start-demo.sh to start any that are stopped.${NC}"
  blank
}

# ── Command: --stop ────────────────────────────────────────────────────────────
cmd_stop() {
  blank
  info "Stopping demo port-forwards..."
  local stopped=0
  for fwd in "${FORWARDS[@]}"; do
    local label local_port svc
    label=$(echo "$fwd" | cut -d'|' -f1)
    local_port=$(echo "$fwd" | cut -d'|' -f3)
    svc=$(echo "$fwd" | cut -d'|' -f2)

    local pid
    pid=$(pf_pid "$local_port")
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      success "Stopped ${svc} (pid ${pid})"
      (( stopped++ )) || true
    else
      echo -e "  ${DIM}${svc} — not running${NC}"
    fi
  done

  if (( stopped == 0 )); then
    info "No demo port-forwards were running."
  fi
  blank
}

# ── Command: start (default) ───────────────────────────────────────────────────
cmd_start() {
  command -v kubectl &>/dev/null || die "'kubectl' is required but not installed."

  local context
  context=$(kubectl config current-context 2>/dev/null || true)
  [[ -z "$context" ]] && die "No kubectl context set. Run: oblt-cli cluster k8s --cluster-name <name>"

  blank
  echo -e "${BOLD}Starting demo port-forwards${NC}  ${DIM}(namespace: ${NAMESPACE})${NC}"
  blank

  local all_ok=true
  for fwd in "${FORWARDS[@]}"; do
    local label svc local_port remote_port url description
    label=$(echo "$fwd" | cut -d'|' -f1)
    svc=$(echo "$fwd" | cut -d'|' -f2)
    local_port=$(echo "$fwd" | cut -d'|' -f3)
    remote_port=$(echo "$fwd" | cut -d'|' -f4)
    url=$(echo "$fwd" | cut -d'|' -f5)
    description=$(echo "$fwd" | cut -d'|' -f6)

    if port_in_use "$local_port"; then
      local pid
      pid=$(pf_pid "$local_port")
      success "${url}  ${DIM}already running (pid ${pid:-?})${NC}"
    else
      info "Starting ${svc} → localhost:${local_port}..."
      if start_forward "$label" "$svc" "$local_port" "$remote_port"; then
        local pid
        pid=$(pf_pid "$local_port")
        success "${url}  ${DIM}(pid ${pid:-?})${NC}"
      else
        all_ok=false
      fi
    fi
  done

  blank
  if [[ "$all_ok" == true ]]; then
    echo -e "${BOLD}${GREEN}All port-forwards running.${NC} Your terminal is free."
    blank
    echo -e "  ${BOLD}Demo shop:${NC}      http://localhost:8080"
    echo -e "  ${BOLD}Feature flags:${NC}  http://localhost:8080/feature"
    echo -e "  ${BOLD}Load generator:${NC} http://localhost:8080/loadgen"
    echo -e "  ${BOLD}Jaeger UI:${NC}      http://localhost:8080/jaeger/ui"
    echo -e "  ${BOLD}Chaos Mesh:${NC}     http://localhost:2333"
    blank
    echo -e "  ${DIM}To stop:   ./scripts/start-demo.sh --stop${NC}"
    echo -e "  ${DIM}To check:  ./scripts/start-demo.sh --status${NC}"
  else
    warn "One or more port-forwards failed to start. Run --status to check."
  fi
  blank
}

# ── Main ───────────────────────────────────────────────────────────────────────
case "${1:-start}" in
  --stop)   cmd_stop ;;
  --status) cmd_status ;;
  start)    cmd_start ;;
  --help|-h)
    blank
    echo -e "${BOLD}start-demo.sh${NC} — manage background port-forwards for the OTel demo"
    blank
    echo "  (no args)   Start all port-forwards (idempotent)"
    echo "  --stop      Kill all demo port-forwards"
    echo "  --status    Show health of each port-forward"
    blank
    ;;
  *)
    die "Unknown command '${1}'. Run --help for usage."
    ;;
esac
