#!/usr/bin/env bash
# inject-failure.sh — Randomly inject a failure scenario for "Capture the Bug" demo sessions.
#
# Draws from a unified pool of flagd (application-layer) and Chaos Mesh
# (infrastructure-layer) scenarios. The operator injects a random failure;
# the participant investigates in Kibana.
#
# Usage:
#   ./scripts/inject-failure.sh                             # Random injection (operator sees which)
#   ./scripts/inject-failure.sh --quiet                     # Random injection, scenario hidden
#   ./scripts/inject-failure.sh --chaos-only                # Random Chaos Mesh scenario only (no flagd)
#   ./scripts/inject-failure.sh --scenario=payment-partial  # Inject a specific scenario by ID
#   ./scripts/inject-failure.sh --preview                   # Preview a random scenario (no changes)
#   ./scripts/inject-failure.sh --preview --chaos-only      # Preview a random Chaos Mesh scenario
#   ./scripts/inject-failure.sh --preview --scenario=<id>   # Preview a specific scenario
#   ./scripts/inject-failure.sh --status                    # Show a vague symptom hint
#   ./scripts/inject-failure.sh --reveal                    # Reveal the full scenario explanation
#   ./scripts/inject-failure.sh --revert                    # Reset and reveal what was active
#   ./scripts/inject-failure.sh --list                      # List all available scenarios
#   ./scripts/inject-failure.sh --list --chaos-only         # List only Chaos Mesh scenarios
#
# Use --chaos-only when testing AI agents: flagd failures are well-documented in
# the OpenTelemetry demo and may be known to the model. Chaos Mesh infrastructure
# faults are lower-level and less likely to be in training data.
#
# Scenarios excluded for GCP cost reasons (not in the random pool):
#   flagd: emailMemoryLeak, loadGeneratorFloodHomepage, recommendationCacheFailure,
#          adHighCpu, failedReadinessProbe
#   Chaos Mesh schedules (chaos-mesh/*.yaml) are separate — apply them manually.

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
blank()   { echo ""; }

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_FILE="${REPO_ROOT}/.failure-state"
NAMESPACE="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo 'default')}"

# ── Scenario catalogue ─────────────────────────────────────────────────────────
# Format: "id|type|target|variant|hint|symptoms|root_cause|kibana_path"
#   type       — "flagd" or "chaos-mesh"
#   target     — flag name (flagd) or manifest path relative to REPO_ROOT (chaos-mesh)
#   variant    — flag variant (flagd) or "-" (chaos-mesh, not applicable)
#   hint       — vague symptom hint, safe to share with participant
#   symptoms   — detailed observable effects shown on --reveal
#   root_cause — the underlying cause of the failure shown on --reveal
#   kibana_path — where to look in Kibana to investigate
declare -a SCENARIOS=(

  # ── flagd scenarios (application-layer) ──────────────────────────────────────

  "payment-partial|flagd|paymentFailure|50%|\
Customers are reporting intermittent checkout failures. Roughly half of purchase \
attempts seem to be failing, but it's not consistent.|\
Roughly 50% of checkout attempts fail with a payment error. The error rate on \
checkoutservice spikes noticeably. Individual failing traces show the paymentservice \
span erroring — not a connection failure, but an explicit error response from the \
payment service itself. Error volume is steady, not spiking or recovering.|\
The paymentFailure flagd flag is set to 50%, instructing the payment service charge \
method to return a failure on half of all calls. This is a deliberate application-level \
fault — the pod is healthy, the network is fine, and the service is reachable. The \
error is injected in code, not at the infrastructure layer.|\
APM → Services → checkoutservice → Transactions → POST /hipstershop.CheckoutService/PlaceOrder — drill into a failing trace and inspect the paymentservice span"

  "payment-down|flagd|paymentUnreachable|on|\
The checkout flow appears to be completely broken. Users cannot complete any purchases.|\
100% of checkout attempts fail. Traces show the error occurring before the \
paymentservice span even executes — the connection is refused or the address is \
unreachable. The Service Map shows the checkoutservice to paymentservice edge as \
broken. Unlike partial failures, every single checkout fails immediately.|\
The paymentUnreachable flagd flag is enabled, reconfiguring checkoutservice to use \
an invalid address for paymentservice. The error happens at the TCP connection level \
before any application code runs on the payment side. This is distinct from \
paymentFailure — the service is not returning errors, it is simply not being reached.|\
APM → Service Map — broken edge between checkoutservice and paymentservice. APM → Services → checkoutservice → Transactions — 100% error rate, connection errors in trace waterfall"

  "cart-errors|flagd|cartFailure|on|\
Users are having trouble with their shopping carts. Adding items seems fine but \
something goes wrong at checkout.|\
Cart browsing and adding items works normally. Failures only appear at checkout. \
The cartservice shows a 100% error rate specifically on EmptyCart RPC calls. Other \
cart operations (GetCart, AddItem) are unaffected. The error is consistent — every \
single checkout attempt fails at the same point.|\
The cartFailure flagd flag is enabled, causing cartservice to return an error on \
every EmptyCart call. EmptyCart is invoked by checkoutservice at the end of a \
successful order to clear the basket — so all checkouts fail at the final step \
despite earlier steps succeeding. The cart pod is healthy; the fault is in the \
application logic.|\
APM → Services → cartservice → Transactions → grpc — filter to EmptyCart, 100% error rate. Cross-reference with APM → Services → checkoutservice failing at the cart call step"

  "product-missing|flagd|productCatalogFailure|on|\
A specific product page is returning errors. The rest of the catalogue seems fine.|\
The product catalogue loads normally for almost all products. One specific product \
(ID: OLJCESPC7Z) consistently returns an error every time its page is loaded. \
There is no intermittency — every request for this product fails, every request \
for other products succeeds.|\
The productCatalogFailure flagd flag is enabled, making productcatalogservice return \
an error specifically on GetProduct requests for product ID OLJCESPC7Z. All other \
product IDs are unaffected. The fault is targeted at a single resource, simulating \
a corrupted or missing product entry.|\
APM → Services → productcatalogservice → Transactions → GetProduct — filter traces by error, confirm all errors reference the same product ID"

  "ad-errors|flagd|adFailure|on|\
The site is running but there are some intermittent errors occurring in a background \
service. Users may not notice directly.|\
A low but steady error rate appears on the adservice — roughly 1 in 10 GetAds calls \
return an error. The failures are probabilistic with no consistent pattern (not tied \
to a specific user, product, or time). The shopping experience is largely unaffected \
since ads are non-critical, but the error rate is clearly visible in APM.|\
The adFailure flagd flag is enabled, making adservice return an error on approximately \
10% of GetAds requests. The selection of which requests fail is random. This simulates \
an unreliable downstream dependency that fails sporadically without a clear cause.|\
APM → Services → adservice → Transactions → oteldemo.AdService/GetAds — error rate chart shows ~10% steady failure rate"

  "llm-rate-limit|flagd|llmRateLimitError|on|\
The AI product review feature is behaving erratically — sometimes it works, \
sometimes it doesn't.|\
The AI product review summary feature works on some requests and fails on others \
with no clear pattern. Failed requests return HTTP 429 errors. The failure is \
intermittent — refreshing the page sometimes returns a review, sometimes an error. \
No other services are affected.|\
The llmRateLimitError flagd flag is enabled, causing llmservice to intermittently \
return HTTP 429 (Too Many Requests) responses. This simulates a real-world LLM API \
rate limit being hit in production. The fault is in the llmservice application code, \
not the underlying LLM infrastructure.|\
APM → Services → llmservice → Errors — HTTP 429 errors. APM → Services → llmservice → Transactions — intermittent error rate"

  "image-slow|flagd|imageSlowLoad|5sec|\
The website feels sluggish. Page loads are completing but something is noticeably \
slower than usual.|\
The storefront loads but product images each take approximately 5 seconds to appear. \
The page structure, navigation, and API responses are all fast — only image loading \
is slow. Frontend p99 latency is significantly elevated. The slowness is consistent \
across all product images on every page.|\
The imageSlowLoad flagd flag is set to 5sec, which activates Envoy fault injection \
on the frontend proxy. A 5-second artificial delay is added to every HTTP response \
serving product images. This is an Envoy-level fault, not an application code change \
— the delay is injected at the proxy layer before the response reaches the browser.|\
APM → Services → frontend → Transactions — filter to image GET requests, elevated p99. Compare image request latency vs API call latency to confirm only images are affected"

  "kafka-lag|flagd|kafkaQueueProblems|on|\
Some backend processing seems to be falling behind. Orders are completing but \
downstream services appear delayed.|\
Checkout completes successfully and the frontend reports orders as placed. However, \
downstream accounting and fraud detection services show growing latency and \
increasing consumer lag. The Kafka consumer group is falling behind — messages \
are produced faster than they are consumed. Over time the lag grows.|\
The kafkaQueueProblems flagd flag is enabled, which overloads the Kafka topic with \
excess messages and introduces an artificial consumer-side processing delay in \
accountingservice and frauddetectionservice. The fault is in the message processing \
pipeline, not the order placement flow — which is why checkout appears to succeed \
while downstream processing silently falls behind.|\
APM → Services → accountingservice and frauddetectionservice — consumer lag metric and latency spike. Logs → filter to kafka consumer errors or slow processing messages"

  # ── Chaos Mesh scenarios (infrastructure-layer) ───────────────────────────────

  "chaos-net-delay-checkout|chaos-mesh|chaos-mesh/scenarios/ctb-network-delay-checkout.yaml|-|\
Checkout is extremely slow. Users can still place orders but it takes much longer \
than expected — the issue doesn't look like a normal application error.|\
Checkout transactions complete but take 2+ seconds longer than normal. The p95 and \
p99 latency on checkoutservice are sharply elevated. Error rates remain low — \
requests are slow, not failing. Other services appear unaffected. The latency \
increase is uniform across all checkout transactions with no correlation to user, \
product, or time of day.|\
Chaos Mesh is injecting a 2-second network delay with 500ms jitter at the kernel \
network layer on the checkoutservice pod. Unlike an application-level slowdown, \
this affects all network I/O to and from the pod — including health checks and \
service-to-service calls. The pod is healthy and the application code is running \
normally; only its network is throttled. This cannot be detected by inspecting \
application logs or error rates — only latency metrics reveal the fault.|\
APM → Services → checkoutservice → Latency tab — p95/p99 spike with low error rate. Compare with other services to confirm the fault is isolated to checkout"

  "chaos-pod-fail-cart|chaos-mesh|chaos-mesh/scenarios/ctb-pod-failure-cart.yaml|-|\
The cart service appears to be completely unavailable. Users cannot add items or \
proceed to checkout.|\
The cart service is completely unreachable. Unlike the flagd cartFailure scenario \
where the pod is healthy but returns application-layer gRPC errors, here all network \
traffic to the cart pod is dropped. Dependent services receive connection timeouts \
rather than error responses — traces show requests hanging until they time out \
rather than failing fast. The cart pod itself stays healthy and Ready; the fault \
is at the network layer.|\
Chaos Mesh is injecting 100% packet loss on the cartservice pod using NetworkChaos. \
GKE Autopilot does not grant the device cgroup access that Chaos Mesh pod-failure \
requires, so network-level isolation is used instead — the effect is equivalent. \
Key diagnostic difference from flagd cart-errors: APM traces show connection \
timeouts not gRPC error codes, and the cart pod shows as Ready in Infrastructure.|\
APM → Services → cartservice — connection timeout errors. APM → Service Map — broken edges from checkout and frontend to cart. Compare trace error type to flagd cart-errors: timeout vs gRPC error response"

  "chaos-cpu-stress-frontend|chaos-mesh|chaos-mesh/scenarios/ctb-cpu-stress-frontend.yaml|-|\
The frontend is noticeably slower than usual. Everything is technically working \
but response times are up across the board. The issue seems to be at the \
infrastructure level rather than in the application code.|\
All frontend transactions show elevated latency — not a single slow endpoint but \
everything is slower uniformly. Error rates are not elevated. CPU utilisation on \
the frontend pod is abnormally high. The latency increase correlates with the CPU \
spike. No application errors are logged — the service is resource-starved, not broken.|\
Chaos Mesh is running 2 CPU stress workers at 80% load on the frontend pod at the \
OS level, consuming CPU cycles that would otherwise serve HTTP requests. The Go \
HTTP server has fewer resources available, causing across-the-board latency \
increases. There are no application errors because the code is functioning \
correctly — it is simply waiting for CPU time. The fault is invisible to application \
logs and only visible in infrastructure metrics.|\
Infrastructure → Kubernetes → Pods — frontend pod CPU spike. APM → Services → frontend → Transactions — all transactions show increased latency (not isolated to one endpoint)"

  "chaos-net-loss-payment|chaos-mesh|chaos-mesh/scenarios/ctb-network-loss-payment.yaml|-|\
Payment is failing intermittently and inconsistently. Sometimes it works, sometimes \
it doesn't — and the pattern doesn't seem related to any specific user or product.|\
Payment errors are intermittent with no consistent pattern — sometimes checkout \
succeeds, sometimes it fails, with no correlation to user, product, or time. Traces \
show TCP-level connection failures or timeouts rather than clean application error \
responses. The error signature differs from the flagd paymentFailure scenario: \
instead of a clear error message from the payment service, traces show retries, \
timeouts, or abrupt connection closes.|\
Chaos Mesh is dropping 50% of network packets with 25% correlation to and from \
the paymentservice pod at the kernel network layer. Unlike the flagd paymentFailure \
flag (which returns a deliberate error from application code), this fault causes \
TCP connections to degrade — packets are silently dropped and the connection times \
out or retries. This is harder to diagnose because there is no error message from \
the payment service itself; the failure manifests as a network timeout upstream.|\
APM → Services → paymentservice — intermittent errors with inconsistent messages (timeouts vs errors). Compare trace error type to flagd payment failures: TCP timeout vs application error response is the key diagnostic difference"

  "chaos-pod-fail-recommendation|chaos-mesh|chaos-mesh/scenarios/ctb-pod-failure-recommendation.yaml|-|\
Product recommendations have stopped appearing on product pages. Everything else \
on the site seems fine.|\
Product recommendation widgets are absent from product pages. The frontend degrades \
gracefully — no hard error is shown, recommendations simply do not appear. APM \
traces show calls to the recommendation service timing out rather than returning \
errors. The recommendation pod itself is healthy and Ready in Kubernetes; the fault \
is at the network layer causing the frontend to time out waiting for a response.|\
Chaos Mesh is injecting a 10-second network delay on the recommendationservice pod. \
GKE Autopilot does not grant the device cgroup access that Chaos Mesh pod-failure \
requires, so a high-latency network delay is used instead — the frontend times out \
waiting for recommendations and falls back to showing none. Key diagnostic \
difference from a pod failure: the recommendation pod shows as Ready in \
Infrastructure, but APM traces show high latency and timeouts rather than \
connection refused errors.|\
APM → Service Map — frontend to recommendationservice edge showing high latency or timeouts. APM → Services → frontend — traces show recommendation calls timing out. Infrastructure → Kubernetes → Pods — recommendation pod shows Ready (distinguishes this from a real pod failure)"

)

# ── Helper: filter scenario pool by type ─────────────────────────────────────
# Returns a new array (by printing entries) filtered to the given type.
# Usage: pool=(); while IFS= read -r s; do pool+=("$s"); done < <(filter_scenarios "chaos-mesh")
filter_scenarios() {
  local filter_type="$1"
  for scenario in "${SCENARIOS[@]}"; do
    local type
    type=$(scenario_field "$scenario" 2)
    if [[ "$type" == "$filter_type" ]]; then
      echo "$scenario"
    fi
  done
}

# ── Helper: check demo port-forwards are running ──────────────────────────────
check_port_forwards() {
  local missing=()

  if ! lsof -ti :8080 &>/dev/null; then
    missing+=("frontend-proxy → localhost:8080  (demo shop + flagd UI)")
  fi
  if ! lsof -ti :2333 &>/dev/null; then
    missing+=("chaos-dashboard → localhost:2333  (Chaos Mesh UI)")
  fi

  if (( ${#missing[@]} > 0 )); then
    blank
    echo -e "${YELLOW}┌─ Port-forward warning ────────────────────────────────────┐${NC}"
    for entry in "${missing[@]}"; do
      echo -e "${YELLOW}│${NC}  ${DIM}Not running: ${entry}${NC}"
    done
    echo -e "${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  Run ${BOLD}./scripts/start-demo.sh${NC} to start them."
    echo -e "${YELLOW}└───────────────────────────────────────────────────────────┘${NC}"
    blank
  fi
}

# ── Helper: look up a scenario by ID ──────────────────────────────────────────
get_scenario() {
  local target_id="$1"
  for scenario in "${SCENARIOS[@]}"; do
    local id
    id=$(echo "$scenario" | cut -d'|' -f1)
    if [[ "$id" == "$target_id" ]]; then
      echo "$scenario"
      return 0
    fi
  done
  return 1
}

# ── Helper: parse a field from a scenario string ──────────────────────────────
scenario_field() {
  local scenario="$1"
  local field_num="$2"
  echo "$scenario" | cut -d'|' -f"${field_num}"
}

# ── Helper: apply a flagd scenario ────────────────────────────────────────────
apply_flag() {
  local flag_name="$1"
  local target_variant="$2"

  for cmd in kubectl jq; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
  done

  local flagd_pod
  flagd_pod=$(kubectl get po -l app.kubernetes.io/component=flagd \
    -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -z "$flagd_pod" ]] && die "flagd pod not found in namespace '$NAMESPACE'. Is kubectl configured?"

  local current_json
  current_json=$(kubectl exec "$flagd_pod" -c flagd-ui -n "$NAMESPACE" -- \
    cat /app/data/demo.flagd.json)

  if ! echo "$current_json" | jq -e ".flags[\"${flag_name}\"]" &>/dev/null; then
    die "Flag '${flag_name}' not found in flagd config."
  fi

  local updated_json
  updated_json=$(echo "$current_json" | \
    jq ".flags[\"${flag_name}\"].defaultVariant = \"${target_variant}\"")

  local patch_payload
  patch_payload=$(jq -n --arg json "$updated_json" '{"data": {"demo.flagd.json": $json}}')

  kubectl patch configmap flagd-config \
    -n "$NAMESPACE" --type merge --patch "$patch_payload" &>/dev/null

  kubectl rollout restart deployment/flagd -n "$NAMESPACE" &>/dev/null
  kubectl rollout status deployment/flagd -n "$NAMESPACE" --timeout=120s &>/dev/null
}

# ── Helper: apply a Chaos Mesh scenario ───────────────────────────────────────
apply_chaos() {
  local manifest_rel="$1"
  local manifest_path="${REPO_ROOT}/${manifest_rel}"

  [[ -f "$manifest_path" ]] || die "Chaos Mesh manifest not found: ${manifest_path}"
  command -v kubectl &>/dev/null || die "'kubectl' is required but not installed."

  sed "s/MY_NAMESPACE/${NAMESPACE}/g" "$manifest_path" | kubectl apply -f - &>/dev/null
}

# ── Helper: revert a Chaos Mesh scenario ──────────────────────────────────────
revert_chaos() {
  local manifest_rel="$1"
  local manifest_path="${REPO_ROOT}/${manifest_rel}"

  [[ -f "$manifest_path" ]] || { warn "Manifest not found: ${manifest_path} — may already be deleted."; return 0; }

  sed "s/MY_NAMESPACE/${NAMESPACE}/g" "$manifest_path" | \
    kubectl delete -f - --ignore-not-found &>/dev/null
}

# ── Helper: print a formatted scenario reveal ─────────────────────────────────
print_reveal() {
  local scenario_id="$1"
  local scenario
  scenario=$(get_scenario "$scenario_id") || { warn "Unknown scenario: ${scenario_id}"; return 1; }

  local type target variant symptoms root_cause kibana_path
  type=$(scenario_field "$scenario" 2)
  target=$(scenario_field "$scenario" 3)
  variant=$(scenario_field "$scenario" 4)
  symptoms=$(scenario_field "$scenario" 6)
  root_cause=$(scenario_field "$scenario" 7)
  kibana_path=$(scenario_field "$scenario" 8)

  local type_label
  [[ "$type" == "flagd" ]] && type_label="flagd (application)" || type_label="Chaos Mesh (infrastructure)"

  blank
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Scenario: ${CYAN}${scenario_id}${NC}  ${DIM}[${type_label}]${NC}"
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
  if [[ "$type" == "flagd" ]]; then
    echo -e "  ${BOLD}Flag:${NC}     ${target} = ${variant}"
  else
    echo -e "  ${BOLD}Manifest:${NC} ${target}"
  fi
  blank
  echo -e "  ${BOLD}Symptoms:${NC}"
  echo "  ${symptoms}" | fold -s -w 72 | sed 's/^/  /'
  blank
  echo -e "  ${BOLD}Root cause:${NC}"
  echo "  ${root_cause}" | fold -s -w 72 | sed 's/^/  /'
  blank
  echo -e "  ${BOLD}Where to look in Kibana:${NC}"
  echo -e "  ${CYAN}${kibana_path}${NC}"
  blank
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
}

# ── Command: --list ────────────────────────────────────────────────────────────
cmd_list() {
  local chaos_only=false
  for arg in "$@"; do
    [[ "$arg" == "--chaos-only" ]] && chaos_only=true
  done

  local -a pool
  if [[ "$chaos_only" == true ]]; then
    pool=(); while IFS= read -r s; do pool+=("$s"); done < <(filter_scenarios "chaos-mesh")
    blank
    echo -e "${BOLD}Chaos Mesh scenarios (infrastructure-layer):${NC}"
  else
    pool=("${SCENARIOS[@]}")
    blank
    echo -e "${BOLD}Available failure scenarios:${NC}"
  fi

  blank
  printf "  ${BOLD}%-38s %-14s %-14s${NC}\n" "SCENARIO ID" "TYPE" "TARGET"
  printf "  ${DIM}%-38s %-14s %-14s${NC}\n" "─────────────────────────────────────" "─────────────" "─────────────"
  for scenario in "${pool[@]}"; do
    local id type target variant
    id=$(scenario_field "$scenario" 1)
    type=$(scenario_field "$scenario" 2)
    target=$(scenario_field "$scenario" 3)
    variant=$(scenario_field "$scenario" 4)
    if [[ "$type" == "flagd" ]]; then
      printf "  %-38s %-14s %s = %s\n" "$id" "flagd" "$target" "$variant"
    else
      local manifest_name
      manifest_name=$(basename "$target" .yaml)
      printf "  %-38s %-14s %s\n" "$id" "chaos-mesh" "$manifest_name"
    fi
  done
  blank
  echo -e "  ${DIM}Total: ${#pool[@]} scenario(s) shown.${NC}"
  echo -e "  ${DIM}Use --scenario=<id> to inject a specific one.${NC}"
  blank
}

# ── Command: --status ──────────────────────────────────────────────────────────
cmd_status() {
  if [[ ! -f "$STATE_FILE" ]]; then
    blank
    echo -e "  ${GREEN}No active failure scenario.${NC} The demo is running clean."
    blank
    return 0
  fi

  local scenario_id type injected_at hint
  scenario_id=$(grep '^scenario=' "$STATE_FILE" | cut -d= -f2)
  type=$(grep '^type=' "$STATE_FILE" | cut -d= -f2)
  injected_at=$(grep '^injected_at=' "$STATE_FILE" | cut -d= -f2-)

  local scenario
  scenario=$(get_scenario "$scenario_id") || { warn "State file references unknown scenario '${scenario_id}'."; return 1; }
  hint=$(scenario_field "$scenario" 5)

  local type_label
  [[ "$type" == "flagd" ]] && type_label="flagd (application)" || type_label="Chaos Mesh (infrastructure)"

  blank
  echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Active Failure — Status${NC}"
  echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
  echo -e "  ${BOLD}Injected at:${NC}  ${injected_at}"
  echo -e "  ${BOLD}Type:${NC}         ${type_label}"
  blank
  echo -e "  ${BOLD}Symptom hint:${NC}"
  echo -e "  ${hint}" | fold -s -w 72 | sed 's/^/  /'
  blank
  echo -e "  ${DIM}Run --reveal to see the full answer.${NC}"
  echo -e "  ${DIM}Run --revert to reset the demo.${NC}"
  echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
}

# ── Command: --reveal ──────────────────────────────────────────────────────────
cmd_reveal() {
  if [[ ! -f "$STATE_FILE" ]]; then
    blank
    echo -e "  ${GREEN}No active failure scenario.${NC}"
    blank
    return 0
  fi

  local scenario_id
  scenario_id=$(grep '^scenario=' "$STATE_FILE" | cut -d= -f2)
  print_reveal "$scenario_id"
}

# ── Command: --revert ──────────────────────────────────────────────────────────
cmd_revert() {
  if [[ ! -f "$STATE_FILE" ]]; then
    blank
    echo -e "  ${GREEN}No active failure scenario to revert.${NC}"
    blank
    return 0
  fi

  local scenario_id type
  scenario_id=$(grep '^scenario=' "$STATE_FILE" | cut -d= -f2)
  type=$(grep '^type=' "$STATE_FILE" | cut -d= -f2)

  blank
  info "Reverting scenario '${scenario_id}'..."

  if [[ "$type" == "flagd" ]]; then
    local flag
    flag=$(grep '^flag=' "$STATE_FILE" | cut -d= -f2)
    apply_flag "$flag" "off"
    success "Flag '${flag}' reset to 'off'"
  else
    local manifest
    manifest=$(grep '^manifest=' "$STATE_FILE" | cut -d= -f2-)
    revert_chaos "$manifest"
    success "Chaos Mesh experiment removed"
  fi

  rm -f "$STATE_FILE"

  print_reveal "$scenario_id"
  echo -e "  ${GREEN}Demo restored to clean state.${NC}"
  blank
}

# ── Command: --preview ────────────────────────────────────────────────────────
cmd_preview() {
  local specific_scenario=""
  local chaos_only=false
  for arg in "$@"; do
    case "$arg" in
      --scenario=*)  specific_scenario="${arg#*=}" ;;
      --chaos-only)  chaos_only=true ;;
    esac
  done

  local chosen_scenario
  if [[ -n "$specific_scenario" ]]; then
    chosen_scenario=$(get_scenario "$specific_scenario") || \
      die "Unknown scenario '${specific_scenario}'. Run --list to see available scenarios."
  else
    local -a pool
    if [[ "$chaos_only" == true ]]; then
      pool=(); while IFS= read -r s; do pool+=("$s"); done < <(filter_scenarios "chaos-mesh")
      (( ${#pool[@]} == 0 )) && die "No Chaos Mesh scenarios found."
    else
      pool=("${SCENARIOS[@]}")
    fi
    local idx=$(( RANDOM % ${#pool[@]} ))
    chosen_scenario="${pool[$idx]}"
  fi

  local scenario_id type target variant hint symptoms root_cause kibana_path
  scenario_id=$(scenario_field "$chosen_scenario" 1)
  type=$(scenario_field "$chosen_scenario" 2)
  target=$(scenario_field "$chosen_scenario" 3)
  variant=$(scenario_field "$chosen_scenario" 4)
  hint=$(scenario_field "$chosen_scenario" 5)
  symptoms=$(scenario_field "$chosen_scenario" 6)
  root_cause=$(scenario_field "$chosen_scenario" 7)
  kibana_path=$(scenario_field "$chosen_scenario" 8)

  local type_label target_display
  if [[ "$type" == "flagd" ]]; then
    type_label="flagd (application)"
    target_display="${target} = ${variant}"
  else
    type_label="Chaos Mesh (infrastructure)"
    target_display="$(basename "$target" .yaml)"
  fi

  blank
  echo -e "${BOLD}${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Preview: ${CYAN}${scenario_id}${NC}  ${DIM}[${type_label}] (nothing has been triggered)${NC}"
  echo -e "${BOLD}${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
  echo -e "  ${BOLD}Type:${NC}   ${type_label}"
  echo -e "  ${BOLD}Target:${NC} ${target_display}"
  blank
  echo -e "  ${BOLD}What the operator would see after injection:${NC}"
  blank
  echo -e "${BOLD}${RED}  ──────────────────────────────────────────────────────${NC}"
  echo -e "${BOLD}    Injected: ${CYAN}${scenario_id}${NC}  ${DIM}[${type_label}]${NC}"
  echo -e "${BOLD}${RED}  ──────────────────────────────────────────────────────${NC}"
  blank
  echo -e "    ${BOLD}Symptom hint (share with participant):${NC}"
  echo -e "    ${YELLOW}${hint}${NC}" | fold -s -w 68 | sed 's/^/    /'
  blank
  echo -e "    ${DIM}Run --reveal for the full explanation and Kibana path.${NC}"
  echo -e "    ${DIM}Run --revert when the session is done.${NC}"
  echo -e "${BOLD}${RED}  ──────────────────────────────────────────────────────${NC}"
  blank
  echo -e "  ${BOLD}What --reveal would show:${NC}"
  blank
  echo -e "    ${BOLD}Symptoms:${NC}"
  echo "    ${symptoms}" | fold -s -w 68 | sed 's/^/    /'
  blank
  echo -e "    ${BOLD}Root cause:${NC}"
  echo "    ${root_cause}" | fold -s -w 68 | sed 's/^/    /'
  blank
  echo -e "    ${BOLD}Where to look in Kibana:${NC}"
  echo -e "    ${CYAN}${kibana_path}${NC}"
  blank
  echo -e "${BOLD}${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${DIM}No flags were changed. Run without --preview to inject for real.${NC}"
  echo -e "${BOLD}${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
}

# ── Command: inject (default) ─────────────────────────────────────────────────
cmd_inject() {
  local quiet=false
  local chaos_only=false
  local specific_scenario=""

  for arg in "$@"; do
    case "$arg" in
      --quiet)       quiet=true ;;
      --chaos-only)  chaos_only=true ;;
      --scenario=*)  specific_scenario="${arg#*=}" ;;
    esac
  done

  # Warn if port-forwards are not running (participants won't see the shop)
  check_port_forwards

  # Guard: warn if a failure is already active
  if [[ -f "$STATE_FILE" ]]; then
    local active_id active_type
    active_id=$(grep '^scenario=' "$STATE_FILE" | cut -d= -f2)
    active_type=$(grep '^type=' "$STATE_FILE" | cut -d= -f2)
    blank
    warn "A failure scenario is already active: ${active_id} [${active_type}]"
    warn "Run --revert first, or --status to check the current state."
    blank
    read -r -p "Replace it anyway? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
    # Silently revert before injecting new one
    if [[ "$active_type" == "flagd" ]]; then
      local old_flag
      old_flag=$(grep '^flag=' "$STATE_FILE" | cut -d= -f2)
      apply_flag "$old_flag" "off"
    else
      local old_manifest
      old_manifest=$(grep '^manifest=' "$STATE_FILE" | cut -d= -f2-)
      revert_chaos "$old_manifest"
    fi
    rm -f "$STATE_FILE"
    blank
  fi

  # Pick the scenario
  local chosen_scenario
  if [[ -n "$specific_scenario" ]]; then
    chosen_scenario=$(get_scenario "$specific_scenario") || \
      die "Unknown scenario '${specific_scenario}'. Run --list to see available scenarios."
  else
    local -a pool
    if [[ "$chaos_only" == true ]]; then
      pool=(); while IFS= read -r s; do pool+=("$s"); done < <(filter_scenarios "chaos-mesh")
      (( ${#pool[@]} == 0 )) && die "No Chaos Mesh scenarios found."
    else
      pool=("${SCENARIOS[@]}")
    fi
    local idx=$(( RANDOM % ${#pool[@]} ))
    chosen_scenario="${pool[$idx]}"
  fi

  local scenario_id type target variant hint
  scenario_id=$(scenario_field "$chosen_scenario" 1)
  type=$(scenario_field "$chosen_scenario" 2)
  target=$(scenario_field "$chosen_scenario" 3)
  variant=$(scenario_field "$chosen_scenario" 4)
  hint=$(scenario_field "$chosen_scenario" 5)

  blank
  info "Injecting failure scenario..."

  if [[ "$type" == "flagd" ]]; then
    apply_flag "$target" "$variant"
    # Write state file
    cat > "$STATE_FILE" <<EOF
type=flagd
scenario=${scenario_id}
flag=${target}
variant=${variant}
injected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  else
    apply_chaos "$target"
    cat > "$STATE_FILE" <<EOF
type=chaos-mesh
scenario=${scenario_id}
manifest=${target}
injected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  fi

  success "Failure injected."
  blank

  local type_label
  [[ "$type" == "flagd" ]] && type_label="flagd (application)" || type_label="Chaos Mesh (infrastructure)"

  if [[ "$quiet" == true ]]; then
    echo -e "  ${DIM}Running in quiet mode — scenario hidden.${NC}"
    echo -e "  ${DIM}Run --status for a hint, --reveal for the full answer.${NC}"
  else
    echo -e "${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Injected: ${CYAN}${scenario_id}${NC}  ${DIM}[${type_label}]${NC}"
    echo -e "${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    blank
    if [[ "$type" == "flagd" ]]; then
      echo -e "  ${BOLD}Flag set:${NC}   ${target} = ${variant}"
    else
      echo -e "  ${BOLD}Manifest:${NC}   $(basename "$target" .yaml)"
    fi
    blank
    echo -e "  ${BOLD}Symptom hint (share with participant):${NC}"
    echo -e "  ${YELLOW}${hint}${NC}" | fold -s -w 72 | sed 's/^/  /'
    blank
    if [[ "$type" == "chaos-mesh" ]]; then
      echo -e "  ${DIM}Note: Chaos Mesh effects auto-revert after 30 min if not reverted manually.${NC}"
      blank
    fi
    echo -e "  ${DIM}./scripts/inject-failure.sh --status   # check current failure${NC}"
    echo -e "  ${DIM}./scripts/inject-failure.sh --reveal   # full explanation + Kibana path${NC}"
    echo -e "  ${DIM}./scripts/inject-failure.sh --revert   # reset when done${NC}"
    echo -e "${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  fi

  blank
}

# ── Main ───────────────────────────────────────────────────────────────────────
MODE="${1:-inject}"

case "$MODE" in
  --list)               cmd_list "${@:2}" ;;
  --status)             cmd_status ;;
  --reveal)             cmd_reveal ;;
  --revert)             cmd_revert ;;
  --preview)            cmd_preview "${@:2}" ;;
  --quiet | --chaos-only | --scenario=*) cmd_inject "$@" ;;
  inject)               cmd_inject ;;
  --help|-h)
    blank
    echo -e "${BOLD}inject-failure.sh${NC} — Capture the Bug demo failure injection"
    blank
    echo "  (no args)                            Inject a random failure (operator sees which one)"
    echo "  --quiet                              Inject without revealing the scenario"
    echo "  --chaos-only                         Random Chaos Mesh scenario only (excludes flagd)"
    echo "  --quiet --chaos-only                 Quiet + Chaos Mesh only"
    echo "  --scenario=<id>                      Inject a specific scenario by ID"
    echo "  --preview                            Preview a random scenario without triggering it"
    echo "  --preview --chaos-only               Preview a random Chaos Mesh scenario"
    echo "  --preview --scenario=<id>            Preview a specific scenario without triggering it"
    echo "  --status                             Show a hint about the active failure"
    echo "  --reveal                             Reveal the full scenario explanation"
    echo "  --revert                             Reset flags/chaos, clear state, reveal what was active"
    echo "  --list                               List all available scenarios"
    echo "  --list --chaos-only                  List only Chaos Mesh scenarios"
    blank
    echo -e "  ${DIM}Use --chaos-only when testing AI agents: flagd failures are well-documented${NC}"
    echo -e "  ${DIM}in the OTel demo and may be known to the model. Chaos Mesh faults are not.${NC}"
    blank
    ;;
  *)
    die "Unknown command: '${MODE}'. Run --help for usage."
    ;;
esac
