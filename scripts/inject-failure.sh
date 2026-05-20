#!/usr/bin/env bash
# inject-failure.sh — Randomly inject a failure scenario for "Capture the Bug" demo sessions.
#
# Draws from a unified pool of flagd (application-layer) and k8s-fault
# (infrastructure-layer) scenarios. The operator injects a random failure;
# the participant investigates in Kibana.
#
# Usage:
#   ./scripts/inject-failure.sh                             # Random injection (operator sees which)
#   ./scripts/inject-failure.sh --quiet                     # Random injection, scenario hidden
#   ./scripts/inject-failure.sh --infra-only                # Random infrastructure scenario only (no flagd)
#   ./scripts/inject-failure.sh --scenario=payment-partial  # Inject a specific scenario by ID
#   ./scripts/inject-failure.sh --preview                   # Preview a random scenario (no changes)
#   ./scripts/inject-failure.sh --preview --infra-only      # Preview a random infrastructure scenario
#   ./scripts/inject-failure.sh --preview --scenario=<id>   # Preview a specific scenario
#   ./scripts/inject-failure.sh --status                    # Show a vague symptom hint
#   ./scripts/inject-failure.sh --reveal                    # Reveal the full scenario explanation
#   ./scripts/inject-failure.sh --revert                    # Reset and reveal what was active
#   ./scripts/inject-failure.sh --list                      # List all available scenarios
#   ./scripts/inject-failure.sh --list --infra-only         # List only infrastructure scenarios
#
# Use --infra-only when testing AI agents: flagd failures are well-documented in
# the OpenTelemetry demo and may be known to the model. K8s-native infrastructure
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

  # ── K8s-native scenarios (infrastructure-layer) ───────────────────────────────

  "chaos-net-delay-checkout|k8s-fault|k8s-faults/scenarios/ctb-checkout-cpu-throttle|-|\
Checkout is noticeably slower than usual. Users can still place orders but it \
takes much longer than expected — no errors are visible, just elevated latency.|\
Checkout transactions complete but take significantly longer than normal. The p95 \
and p99 latency on the checkout service are sharply elevated. Error rates remain \
low — requests are slow, not failing. Other services appear unaffected. The \
latency increase is uniform across all checkout transactions. Infrastructure \
metrics show the checkout pod is CPU-throttled; it is consuming its full CPU \
allotment and the kernel is rate-limiting its execution time.|\
A recent resource-governance deployment added a CPU limit of 2m to the checkout \
service. The Go runtime under real load requires significantly more than 2m, \
causing kernel-level CPU throttling. All checkout processing — including \
downstream gRPC calls to cart, payment, and shipping — is serialised slowly. \
The pod is Running and Ready, and application logs are clean. The fault is only \
visible in infrastructure CPU metrics and APM latency data. Root cause: \
kubectl get deployment checkout -o yaml shows cpu: 2m under resources.limits, \
which should not be present.|\
APM → Services → checkout → Latency tab — p95/p99 spike with low error rate. Infrastructure → Kubernetes → Pods → checkout pod — CPU throttling visible. kubectl top pod confirms CPU at limit"

  "chaos-pod-fail-cart|k8s-fault|k8s-faults/scenarios/ctb-cart-bad-redis|-|\
The cart service is broken — users cannot add items, view their cart, or \
proceed to checkout. The cart pod looks healthy.|\
Cart is completely unavailable. The cart pod is in CrashLoopBackOff — it \
starts, crashes immediately with a Redis connection error, and loops. \
kubectl logs on the cart pod shows the app crashing on startup: \
'Wasn't able to connect to redis'. The fault is not in the network or \
a NetworkPolicy — it is a misconfigured environment variable.|\
A cache-migration PR updated the VALKEY_ADDR environment variable to \
valkey-cart-broken:6379 — pointing the cart service at a Redis hostname that \
does not exist. The cart app (a .NET service) validates its Redis connection \
at startup and exits with a fatal error if the connection fails. The pod \
enters CrashLoopBackOff. The init container still passes (it checks the real \
valkey-cart service, not VALKEY_ADDR) so the misconfiguration is subtle. \
Root cause: kubectl get deployment cart -o yaml shows \
VALKEY_ADDR=valkey-cart-broken:6379 under env. kubectl logs on the \
cart pod shows the startup crash.|\
kubectl get pods — cart pod in CrashLoopBackOff. kubectl logs cart — fatal startup error: Wasn't able to connect to redis. kubectl describe deployment cart — VALKEY_ADDR=valkey-cart-broken:6379. APM → Services → cart — no recent throughput. Infrastructure → Kubernetes → Pods — cart pod shows Error/CrashLoopBackOff"

  "chaos-cpu-stress-frontend|k8s-fault|k8s-faults/scenarios/ctb-frontend-cpu-throttle|-|\
The frontend is noticeably slower than usual. Everything is technically working \
but response times are up across the board.|\
All frontend transactions show elevated latency — not a single slow endpoint but \
everything is uniformly slower. Error rates are not elevated. CPU utilisation on \
the frontend pod is abnormally high. The latency increase correlates with the CPU \
spike. No application errors are logged — the service is resource-constrained, \
not broken.|\
A resource governance PR added a CPU limit of 5m to the frontend deployment. \
The frontend handles all load-generator traffic and requires far more than 5m, \
causing kernel-level CPU throttling under normal load. The Node.js HTTP server \
has fewer CPU cycles available, causing across-the-board latency increases with \
no application-layer errors. Root cause: kubectl get deployment frontend -o yaml \
shows cpu: 5m under resources.limits, which should not be present.|\
Infrastructure → Kubernetes → Pods → frontend pod — CPU at limit. APM → Services → frontend → Transactions — all endpoints show increased latency (not isolated to one). kubectl top pod confirms CPU throttling"

  "chaos-net-loss-payment|k8s-fault|k8s-faults/scenarios/ctb-payment-oom-restart|-|\
Payment is failing intermittently and inconsistently. Sometimes checkout \
completes, sometimes it doesn't — with no obvious pattern.|\
Payment errors are intermittent with no consistent pattern. Unlike the flagd \
paymentFailure scenario (which returns a clean error response on exactly 50% of \
calls), here failures are bursty — many succeed in a row, then a window of \
failures, then recovery. kubectl get pods shows the payment pod has an elevated \
RESTARTS count. During each restart window, in-flight payment requests fail. \
Between restarts the service is healthy.|\
A memory-audit PR set the payment service memory limit to 25Mi. The Node.js \
runtime alone requires more than this — the pod starts, immediately exhausts \
its memory allowance, and is OOMKilled by the kernel. Kubernetes restarts it \
(CrashLoopBackOff backoff grows over time). During each restart window payment \
calls fail; between restarts they succeed. Root cause: kubectl describe pod \
<payment-pod> shows Last State: OOMKilled under Last State and the memory limit \
under Limits. kubectl get events shows OOMKilling events.|\
kubectl get pods — payment pod RESTARTS count is elevated. kubectl describe pod <payment-pod> — Last State OOMKilled, Limits memory 25Mi. APM → Services → payment — bursty intermittent errors coinciding with pod restarts"

  "chaos-pod-fail-productcatalog|k8s-fault|k8s-faults/scenarios/ctb-productcatalog-scaled-zero|-|\
Product browsing is completely broken — the entire shop catalogue is unavailable \
and no products can be viewed or loaded.|\
All product listing and product detail pages fail. The frontend's gRPC calls to the \
product-catalog service return UNAVAILABLE immediately. The product-catalog deployment \
exists but has 0 replicas — kubectl get deployment product-catalog shows READY 0/0 \
and no pods are listed for the product-catalog selector. The frontend error rate \
spikes sharply: roughly 50–60% of all frontend transactions fail because the product \
catalog is the critical dependency for browsing, listing, and loading any product.|\
A weekend cost-reduction automation script identified product-catalog as \
"low-utilization" during off-hours (European evening, low US traffic) and set its \
replica count to 0. The script calculated utilization using absolute request counts \
against a static threshold — it failed to account for the fact that low traffic \
reflected time-of-day, not genuine idleness. The automation committed through GitOps \
and was approved without review of the replica-count diffs. Root cause: \
kubectl get deployment product-catalog shows replicas: 0. \
kubectl get pods -l app.kubernetes.io/component=product-catalog returns \
no resources — there is nothing to serve product catalog requests.|\
kubectl get deployment product-catalog — READY 0/0, replicas 0. kubectl get pods -l app.kubernetes.io/component=product-catalog — no resources found. APM → Service Map — frontend to product-catalog edge shows errors. APM → Services → frontend — error rate spike on all product-related transactions"

  "chaos-db-fail-productcatalog|k8s-fault|k8s-faults/scenarios/ctb-productcatalog-bad-db|-|\
The product catalogue is completely broken — all product pages and listings are \
returning errors. The pod looks like it might be starting up, but nothing is serving.|\
All product browsing fails immediately with errors. The product-catalog pod is in \
CrashLoopBackOff — it starts, crashes within one second, and loops. kubectl logs \
shows a fatal database connection error at startup. Unlike a scale-to-zero scenario \
the pod exists and keeps restarting, but it never stays up long enough to serve a \
request. The frontend error rate spikes to 30–57%% of all transactions because \
product-catalog is the critical dependency for every browsing and listing operation.|\
A database migration PR updated DB_CONNECTION_STRING to point at the new PostgreSQL \
instance (postgresql-new) but the target hostname was a typo — the correct name is \
postgresql. The deployment rolled out without failing (the env var is only validated \
at runtime, not at deploy time), so CI was green. The app calls pg.Connect() at \
startup, DNS resolution fails for the non-existent hostname, and the process exits \
with code 1. Kubernetes restarts it with exponential backoff. Root cause: \
kubectl get deployment product-catalog -o yaml shows \
DB_CONNECTION_STRING pointing to postgresql-broken. kubectl get pods shows \
CrashLoopBackOff with RESTARTS climbing.|\
kubectl get pods -l app.kubernetes.io/component=product-catalog — STATUS CrashLoopBackOff, RESTARTS climbing. kubectl describe pod <product-catalog-pod> — Last State Terminated, Exit Code 1, runtime < 2 seconds. kubectl get deployment product-catalog -o yaml — DB_CONNECTION_STRING set to non-existent hostname. APM → Services → product-catalog — zero throughput (pod never runs). APM → Services → frontend — error rate spike on all product-related transactions"

  "chaos-pod-fail-recommendation|k8s-fault|k8s-faults/scenarios/ctb-recommendation-scaled-zero|-|\
Product pages are completely broken — they time out and never load. The \
recommendation service has no running pods.|\
Product pages hang and timeout. APM traces show the frontend waiting \
indefinitely on a gRPC call to the recommendation service before the request \
times out. The recommendation deployment exists but has 0 replicas — \
kubectl get deployment recommendation shows READY 0/0 and no pods are listed \
for the recommendation selector. The timeout cascades: since the frontend \
waits for recommendations before rendering the page, every product page \
request stalls for the full gRPC timeout duration.|\
An auto-scaling cost-review script evaluated recommendation as idle (low \
traffic during a maintenance window) and set its replica count to 0. The \
change was applied via a GitOps PR that was approved without noticing the \
replica count was being zeroed rather than reduced. Root cause: \
kubectl get deployment recommendation shows replicas: 0. \
kubectl get pods -l app.kubernetes.io/component=recommendation returns \
no resources — there is nothing to serve traffic.|\
kubectl get deployment recommendation — READY 0/0, replicas 0. kubectl get pods -l app.kubernetes.io/component=recommendation — no resources found. APM → Service Map — frontend to recommendation edge shows timeouts/errors. APM → Services → recommendation — no recent throughput"

)

# ── Helper: filter scenario pool by type ─────────────────────────────────────
# Returns a new array (by printing entries) filtered to the given type.
# Pass "infra" to match both "chaos-mesh" and "k8s-fault" types.
# Usage: pool=(); while IFS= read -r s; do pool+=("$s"); done < <(filter_scenarios "k8s-fault")
filter_scenarios() {
  local filter_type="$1"
  for scenario in "${SCENARIOS[@]}"; do
    local type
    type=$(scenario_field "$scenario" 2)
    if [[ "$filter_type" == "infra" ]]; then
      [[ "$type" == "chaos-mesh" || "$type" == "k8s-fault" ]] && echo "$scenario"
    elif [[ "$type" == "$filter_type" ]]; then
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

# ── Helper: apply a K8s-native fault scenario ─────────────────────────────────
apply_k8s_fault() {
  local fault_dir_rel="$1"
  local inject_script="${REPO_ROOT}/${fault_dir_rel}/inject.sh"

  [[ -f "$inject_script" ]] || die "inject.sh not found: ${inject_script}"
  command -v kubectl &>/dev/null || die "'kubectl' is required but not installed."

  NAMESPACE="$NAMESPACE" bash "$inject_script" &>/dev/null
}

# ── Helper: revert a K8s-native fault scenario ────────────────────────────────
revert_k8s_fault() {
  local fault_dir_rel="$1"
  local revert_script="${REPO_ROOT}/${fault_dir_rel}/revert.sh"

  [[ -f "$revert_script" ]] || { warn "revert.sh not found: ${revert_script} — may already be reverted."; return 0; }

  NAMESPACE="$NAMESPACE" bash "$revert_script" &>/dev/null
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
  case "$type" in
    flagd)      type_label="flagd (application)" ;;
    k8s-fault)  type_label="K8s native (infrastructure)" ;;
    *)          type_label="Chaos Mesh (infrastructure)" ;;
  esac

  blank
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Scenario: ${CYAN}${scenario_id}${NC}  ${DIM}[${type_label}]${NC}"
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
  if [[ "$type" == "flagd" ]]; then
    echo -e "  ${BOLD}Flag:${NC}     ${target} = ${variant}"
  elif [[ "$type" == "k8s-fault" ]]; then
    echo -e "  ${BOLD}Fault dir:${NC} ${target}"
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
  local infra_only=false
  for arg in "$@"; do
    [[ "$arg" == "--infra-only" ]] && infra_only=true
  done

  local -a pool
  if [[ "$infra_only" == true ]]; then
    pool=(); while IFS= read -r s; do pool+=("$s"); done < <(filter_scenarios "infra")
    blank
    echo -e "${BOLD}Infrastructure scenarios (K8s-native):${NC}"
  else
    pool=("${SCENARIOS[@]}")
    blank
    echo -e "${BOLD}Available failure scenarios:${NC}"
  fi

  blank
  printf "  ${BOLD}%-38s %-22s %-14s${NC}\n" "SCENARIO ID" "TYPE" "TARGET"
  printf "  ${DIM}%-38s %-22s %-14s${NC}\n" "─────────────────────────────────────" "─────────────────────" "─────────────"
  for scenario in "${pool[@]}"; do
    local id type target variant
    id=$(scenario_field "$scenario" 1)
    type=$(scenario_field "$scenario" 2)
    target=$(scenario_field "$scenario" 3)
    variant=$(scenario_field "$scenario" 4)
    if [[ "$type" == "flagd" ]]; then
      printf "  %-38s %-22s %s = %s\n" "$id" "flagd" "$target" "$variant"
    elif [[ "$type" == "k8s-fault" ]]; then
      local fault_name
      fault_name=$(basename "$target")
      printf "  %-38s %-22s %s\n" "$id" "k8s-native" "$fault_name"
    else
      local manifest_name
      manifest_name=$(basename "$target" .yaml)
      printf "  %-38s %-22s %s\n" "$id" "chaos-mesh" "$manifest_name"
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
  case "$type" in
    flagd)      type_label="flagd (application)" ;;
    k8s-fault)  type_label="K8s native (infrastructure)" ;;
    *)          type_label="Chaos Mesh (infrastructure)" ;;
  esac

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
  elif [[ "$type" == "k8s-fault" ]]; then
    local fault_dir
    fault_dir=$(grep '^fault_dir=' "$STATE_FILE" | cut -d= -f2-)
    revert_k8s_fault "$fault_dir"
    success "K8s fault reverted"
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

# ── Command: --check ──────────────────────────────────────────────────────────
# Shows the full picture: k8s state file AND live flagd flag variants.
cmd_check() {
  local any_active=false

  blank
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Failure scenario health check${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank

  # ── K8s-native / Chaos Mesh state file ────────────────────────────────────
  echo -e "  ${BOLD}K8s scenario (state file):${NC}"
  if [[ -f "$STATE_FILE" ]]; then
    local scenario_id type injected_at
    scenario_id=$(grep '^scenario=' "$STATE_FILE" | cut -d= -f2)
    type=$(grep '^type='     "$STATE_FILE" | cut -d= -f2)
    injected_at=$(grep '^injected_at=' "$STATE_FILE" | cut -d= -f2-)
    echo -e "    ${RED}ACTIVE${NC}  ${BOLD}${scenario_id}${NC} [${type}]  injected ${injected_at}"
    any_active=true
  else
    echo -e "    ${GREEN}clean${NC}  no active scenario"
  fi
  blank

  # ── flagd live flags ───────────────────────────────────────────────────────
  echo -e "  ${BOLD}flagd flags (live configmap):${NC}"
  local active_flags
  active_flags=$(kubectl get configmap flagd-config -n "$NAMESPACE" -o json 2>/dev/null \
    | python3 -c "
import sys, json
try:
    flags = json.loads(list(json.load(sys.stdin)['data'].values())[0])['flags']
    active = [(k, v['defaultVariant']) for k, v in sorted(flags.items()) if v['defaultVariant'] != 'off']
    for k, v in active:
        print(f'{k}={v}')
except Exception as e:
    pass
" 2>/dev/null)

  if [[ -n "$active_flags" ]]; then
    while IFS='=' read -r flag variant; do
      echo -e "    ${RED}ACTIVE${NC}  ${BOLD}${flag}${NC} = ${variant}"
      any_active=true
    done <<< "$active_flags"
  else
    echo -e "    ${GREEN}clean${NC}  all flags off"
  fi
  blank

  # ── Summary ───────────────────────────────────────────────────────────────
  if [[ "$any_active" == true ]]; then
    echo -e "  ${RED}Something is active.${NC} Run ${BOLD}--reset-all${NC} to clear everything."
  else
    echo -e "  ${GREEN}All clear.${NC} No failures active."
  fi
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
}

# ── Command: --reset-all ──────────────────────────────────────────────────────
# Reverts any active k8s fault AND resets every non-off flagd flag to off.
cmd_reset_all() {
  blank
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Reset all — clearing every active failure${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank

  local did_something=false

  # ── Revert k8s state file if present ──────────────────────────────────────
  if [[ -f "$STATE_FILE" ]]; then
    local scenario_id type
    scenario_id=$(grep '^scenario=' "$STATE_FILE" | cut -d= -f2)
    type=$(grep '^type='     "$STATE_FILE" | cut -d= -f2)
    info "Reverting k8s scenario '${scenario_id}'..."
    if [[ "$type" == "flagd" ]]; then
      local flag
      flag=$(grep '^flag=' "$STATE_FILE" | cut -d= -f2)
      apply_flag "$flag" "off"
    elif [[ "$type" == "k8s-fault" ]]; then
      local fault_dir
      fault_dir=$(grep '^fault_dir=' "$STATE_FILE" | cut -d= -f2-)
      revert_k8s_fault "$fault_dir"
    else
      local manifest
      manifest=$(grep '^manifest=' "$STATE_FILE" | cut -d= -f2-)
      revert_chaos "$manifest"
    fi
    rm -f "$STATE_FILE"
    success "K8s scenario '${scenario_id}' reverted"
    did_something=true
  else
    echo -e "  ${DIM}K8s state file: nothing to revert${NC}"
  fi

  blank

  # ── Reset all non-off flagd flags ─────────────────────────────────────────
  info "Checking flagd flags..."
  local active_flags
  active_flags=$(kubectl get configmap flagd-config -n "$NAMESPACE" -o json 2>/dev/null \
    | python3 -c "
import sys, json
try:
    flags = json.loads(list(json.load(sys.stdin)['data'].values())[0])['flags']
    active = [(k, v['defaultVariant']) for k, v in flags.items() if v['defaultVariant'] != 'off']
    for k, v in active:
        print(f'{k}')
except Exception:
    pass
" 2>/dev/null)

  if [[ -n "$active_flags" ]]; then
    while IFS= read -r flag; do
      info "Resetting flag '${flag}' → off"
      apply_flag "$flag" "off"
      success "Flag '${flag}' reset to off"
      did_something=true
    done <<< "$active_flags"
  else
    echo -e "  ${DIM}flagd flags: all already off${NC}"
  fi

  blank
  if [[ "$did_something" == true ]]; then
    echo -e "  ${GREEN}All failures cleared. Demo is running clean.${NC}"
  else
    echo -e "  ${GREEN}Already clean — nothing to reset.${NC}"
  fi
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  blank
}

# ── Command: --preview ────────────────────────────────────────────────────────
cmd_preview() {
  local specific_scenario=""
  local infra_only=false
  for arg in "$@"; do
    case "$arg" in
      --scenario=*)  specific_scenario="${arg#*=}" ;;
      --infra-only)  infra_only=true ;;
    esac
  done

  local chosen_scenario
  if [[ -n "$specific_scenario" ]]; then
    chosen_scenario=$(get_scenario "$specific_scenario") || \
      die "Unknown scenario '${specific_scenario}'. Run --list to see available scenarios."
  else
    local -a pool
    if [[ "$infra_only" == true ]]; then
      pool=(); while IFS= read -r s; do pool+=("$s"); done < <(filter_scenarios "infra")
      (( ${#pool[@]} == 0 )) && die "No infrastructure scenarios found."
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
  elif [[ "$type" == "k8s-fault" ]]; then
    type_label="K8s native (infrastructure)"
    target_display="$(basename "$target")"
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
  local infra_only=false
  local specific_scenario=""

  for arg in "$@"; do
    case "$arg" in
      --quiet)       quiet=true ;;
      --infra-only)  infra_only=true ;;
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
    elif [[ "$active_type" == "k8s-fault" ]]; then
      local old_fault_dir
      old_fault_dir=$(grep '^fault_dir=' "$STATE_FILE" | cut -d= -f2-)
      revert_k8s_fault "$old_fault_dir"
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
    if [[ "$infra_only" == true ]]; then
      pool=(); while IFS= read -r s; do pool+=("$s"); done < <(filter_scenarios "infra")
      (( ${#pool[@]} == 0 )) && die "No infrastructure scenarios found."
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
    cat > "$STATE_FILE" <<EOF
type=flagd
scenario=${scenario_id}
flag=${target}
variant=${variant}
injected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  elif [[ "$type" == "k8s-fault" ]]; then
    apply_k8s_fault "$target"
    cat > "$STATE_FILE" <<EOF
type=k8s-fault
scenario=${scenario_id}
fault_dir=${target}
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
  case "$type" in
    flagd)      type_label="flagd (application)" ;;
    k8s-fault)  type_label="K8s native (infrastructure)" ;;
    *)          type_label="Chaos Mesh (infrastructure)" ;;
  esac

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
    elif [[ "$type" == "k8s-fault" ]]; then
      echo -e "  ${BOLD}Fault:${NC}      $(basename "$target")"
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
  --check)              cmd_check ;;
  --reset-all)          cmd_reset_all ;;
  --reveal)             cmd_reveal ;;
  --revert)             cmd_revert ;;
  --preview)            cmd_preview "${@:2}" ;;
  --quiet | --infra-only | --scenario=*) cmd_inject "$@" ;;
  inject)               cmd_inject ;;
  --help|-h)
    blank
    echo -e "${BOLD}inject-failure.sh${NC} — Capture the Bug demo failure injection"
    blank
    echo "  (no args)                            Inject a random failure (operator sees which one)"
    echo "  --quiet                              Inject without revealing the scenario"
    echo "  --infra-only                         Random infrastructure scenario only (excludes flagd)"
    echo "  --quiet --infra-only                 Quiet + infrastructure only"
    echo "  --scenario=<id>                      Inject a specific scenario by ID"
    echo "  --preview                            Preview a random scenario without triggering it"
    echo "  --preview --infra-only               Preview a random infrastructure scenario"
    echo "  --preview --scenario=<id>            Preview a specific scenario without triggering it"
  echo "  --status                             Show a hint about the active failure"
  echo "  --check                              Show full health: k8s state + all live flagd flags"
  echo "  --reset-all                          Clear everything — revert k8s fault + reset all flagd flags to off"
  echo "  --reveal                             Reveal the full scenario explanation"
  echo "  --revert                             Reset flags/k8s faults, clear state, reveal what was active"
  echo "  --list                               List all available scenarios"
  echo "  --list --infra-only                  List only infrastructure scenarios"
    blank
    echo -e "  ${DIM}Use --infra-only when testing AI agents: flagd failures are well-documented${NC}"
    echo -e "  ${DIM}in the OTel demo and may be known to the model. K8s-native faults are not.${NC}"
    blank
    ;;
  *)
    die "Unknown command: '${MODE}'. Run --help for usage."
    ;;
esac
