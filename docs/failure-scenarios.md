# Failure Scenario Catalogue

This catalogue covers two categories:

1. **[flagd — application-layer flags](#flagd--application-layer-flags)** — toggle failure modes baked into the OTel demo app via feature flags
2. **[K8s-native — infrastructure failures](#k8s-native--infrastructure-failures)** — realistic production faults injected via `kubectl` (resource limits, NetworkPolicies, Service config)

Both categories are available via `inject-failure.sh`. K8s-native scenarios are the more realistic option for AI agent evaluation — they cannot be identified by name from training data and require genuine diagnosis.

---

## flagd — application-layer flags

All flagd flags default to `off`. See `flagd/demo.flagd.json` for the full flag definitions.

Toggle any flag with `scripts/toggle-flag.sh`:

```bash
./scripts/toggle-flag.sh <flag-name> on
./scripts/toggle-flag.sh <flag-name> off
```

---

## Payment Failures

| Flag | `paymentFailure` |
|------|-----------------|
| **Variants** | `off`, `10%`, `25%`, `50%`, `75%`, `90%`, `100%` |
| **Affected service** | `paymentservice` |
| **What it does** | Forces the `charge` method to fail at the configured rate |
| **Kibana** | APM → Services → `checkoutservice` — error rate spike. Drill into failing traces to see the `paymentservice` span erroring. |

```bash
./scripts/toggle-flag.sh paymentFailure on
```

---

## Payment Service Unreachable

| Flag | `paymentUnreachable` |
|------|---------------------|
| **Variants** | `on` / `off` |
| **Affected service** | `checkoutservice` |
| **What it does** | Uses a bad address for `paymentservice`, simulating a network outage |
| **Kibana** | APM → Service Map — `checkoutservice → paymentservice` shows as broken. Traces show connection errors. |

```bash
./scripts/toggle-flag.sh paymentUnreachable on
```

---

## Cart Service Failure

| Flag | `cartFailure` |
|------|--------------|
| **Variants** | `on` / `off` |
| **Affected service** | `cartservice` |
| **What it does** | Returns an error on every `EmptyCart` call |
| **Kibana** | APM → Services → `cartservice` — 100% error rate on `EmptyCart`. |

```bash
./scripts/toggle-flag.sh cartFailure on
```

---

## Cart Readiness Probe Failure

| Flag | `failedReadinessProbe` |
|------|------------------------|
| **Variants** | `on` / `off` |
| **Affected service** | `cartservice` pod |
| **What it does** | Forces the readiness probe to return unhealthy — pod goes `NotReady` |
| **Kibana** | Infrastructure → Kubernetes → Pods — cart pod shows `NotReady`. |

```bash
./scripts/toggle-flag.sh failedReadinessProbe on
```

---

## Product Catalog Failure

| Flag | `productCatalogFailure` |
|------|-------------------------|
| **Variants** | `on` / `off` |
| **Affected service** | `productcatalogservice` |
| **What it does** | Returns an error for `GetProduct` requests for product ID `OLJCESPC7Z` |
| **Kibana** | APM → Services → `productcatalogservice` — errors on `GetProduct`. |

```bash
./scripts/toggle-flag.sh productCatalogFailure on
```

---

## Ad Service Failure

| Flag | `adFailure` |
|------|------------|
| **Variants** | `on` / `off` |
| **Affected service** | `adservice` |
| **What it does** | Generates an error for `GetAds` ~1/10th of the time |
| **Kibana** | APM → Services → `adservice` — intermittent errors in error rate chart. |

```bash
./scripts/toggle-flag.sh adFailure on
```

---

## Ad Service High CPU

> ⚠️ **GCP cost risk** — sustained CPU spike may trigger GKE Autopilot node scale-up.

| Flag | `adHighCpu` |
|------|-------------|
| **Variants** | `on` / `off` |
| **Affected service** | `adservice` |
| **What it does** | Triggers sustained high CPU load |
| **Kibana** | Infrastructure → Kubernetes → Pods — CPU spike on the `adservice` pod. |

```bash
./scripts/toggle-flag.sh adHighCpu on
```

---

## Ad Service Manual GC

| Flag | `adManualGc` |
|------|-------------|
| **Variants** | `on` / `off` |
| **Affected service** | `adservice` (JVM) |
| **What it does** | Triggers full manual garbage collections |
| **Kibana** | APM → Services → `adservice` — JVM metrics show GC pauses. Latency spikes correlate with GC events. |

```bash
./scripts/toggle-flag.sh adManualGc on
```

---

## Recommendation Service Cache Failure (Memory Leak)

> ⚠️ **GCP cost risk** — memory growth can OOM the pod and trigger node scale-up. Let run for ~10 minutes to observe the effect, then revert.

| Flag | `recommendationCacheFailure` |
|------|------------------------------|
| **Variants** | `on` / `off` |
| **Affected service** | `recommendationservice` |
| **What it does** | Exponentially growing cache (1.4× growth, 50% of requests trigger growth) — leads to OOM |
| **Kibana** | APM → Services → `recommendationservice` — memory climbs steadily, p99 latency rises. Traces show `app.cache_hit=false` with high `app.products.count`. See the [upstream walkthrough](https://opentelemetry.io/docs/demo/feature-flags/recommendation-cache/). |

```bash
./scripts/toggle-flag.sh recommendationCacheFailure on
# Let run for ~10 minutes to observe memory growth
```

---

## Email Service Memory Leak

> ⚠️ **GCP cost risk** — high multipliers can OOM the pod and trigger node scale-up.

| Flag | `emailMemoryLeak` |
|------|------------------|
| **Variants** | `off`, `1x`, `10x`, `100x`, `1000x`, `10000x` |
| **Affected service** | `emailservice` |
| **What it does** | Simulates a memory leak at the configured multiplier |
| **Kibana** | Infrastructure → Kubernetes → Pods — RSS growth on the `emailservice` pod. |

```bash
./scripts/toggle-flag.sh emailMemoryLeak on --variant="100x"
```

---

## Kafka Queue Problems

| Flag | `kafkaQueueProblems` |
|------|---------------------|
| **Variants** | `on` / `off` |
| **Affected service** | `kafka`, `accountingservice`, `frauddetectionservice` |
| **What it does** | Overloads the Kafka queue and introduces a consumer-side delay |
| **Kibana** | APM → Services — consumer lag spike. Downstream services show increased latency. |

```bash
./scripts/toggle-flag.sh kafkaQueueProblems on
```

---

## Load Generator Homepage Flood

> ⚠️ **GCP cost risk** — high traffic volume increases LB and egress costs.

| Flag | `loadGeneratorFloodHomepage` |
|------|------------------------------|
| **Variants** | `on` / `off` |
| **Affected service** | All (via load generator) |
| **What it does** | Floods the homepage with requests |
| **Kibana** | APM → Services — throughput spike across all services. |

```bash
./scripts/toggle-flag.sh loadGeneratorFloodHomepage on
```

---

## Image Slow Load

| Flag | `imageSlowLoad` |
|------|----------------|
| **Variants** | `off`, `5sec`, `10sec` |
| **Affected service** | `frontend` (Envoy fault injection) |
| **What it does** | Injects a delay into product image loading |
| **Kibana** | APM → Services → `frontend` — page load latency increases. |

```bash
./scripts/toggle-flag.sh imageSlowLoad on --variant="5sec"
```

---

## LLM Rate Limit Error

| Flag | `llmRateLimitError` |
|------|---------------------|
| **Variants** | `on` / `off` |
| **Affected service** | `llmservice` |
| **What it does** | Intermittently returns HTTP 429 |
| **Kibana** | APM → Services → `llmservice` — intermittent 429 errors. |

```bash
./scripts/toggle-flag.sh llmRateLimitError on
```

---

## LLM Inaccurate Response

| Flag | `llmInaccurateResponse` |
|------|-------------------------|
| **Variants** | `on` / `off` |
| **Affected service** | `llmservice` |
| **What it does** | Returns an inaccurate product review summary for product ID `L9ECAV7KIM` |
| **Kibana** | APM → Traces — inspect spans on `llmservice` for the product ID. No error raised — correctness issue only. |

```bash
./scripts/toggle-flag.sh llmInaccurateResponse on
```

---

## K8s-native — infrastructure failures

These scenarios inject realistic Kubernetes-level faults that look like genuine production incidents. They are managed by `inject-failure.sh` and stored in `k8s-faults/scenarios/`. Each fault persists until `--revert` is run.

**Inject / revert via `inject-failure.sh`:**

```bash
./scripts/inject-failure.sh --scenario=<id>   # inject
./scripts/inject-failure.sh --revert          # revert
```

**Or run the scripts directly:**

```bash
NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}') \
  bash k8s-faults/scenarios/<folder>/inject.sh

NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}') \
  bash k8s-faults/scenarios/<folder>/revert.sh
```

---

### Recommendation Scaled to Zero (`chaos-pod-fail-recommendation`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-pod-fail-recommendation` |
| **Fault folder** | `k8s-faults/scenarios/ctb-recommendation-scaled-zero` |
| **What breaks** | `recommendation` deployment replica count set to `0` |
| **Realistic story** | An auto-scaling cost-review script evaluated recommendation as idle during a maintenance window and set replicas to 0. A GitOps PR was approved without noticing the replica count was being zeroed rather than reduced. |
| **Symptoms** | Product pages time out and never load. The frontend's gRPC call to the recommendation service hangs for the full gRPC timeout before the request fails. All product pages are affected. `kubectl get deployment recommendation` shows `READY 0/0`. |
| **Root cause** | No recommendation pods are running — there is nothing to serve traffic. Kubernetes does not auto-recover from a manual replica scale-down. |
| **Kibana** | APM → Services → recommendation — no recent throughput (service went dark). APM → Service Map — frontend → recommendation edge shows timeouts/errors. Infrastructure → Kubernetes → Pods — no pods for recommendation selector. |

**kubectl investigation:**

```bash
# No pods running
kubectl get deployment recommendation -n <namespace>
# → READY shows 0/0

kubectl get pods -n <namespace> -l app.kubernetes.io/component=recommendation
# → No resources found

# The deployment itself still exists — only replicas is wrong
kubectl get deployment recommendation -n <namespace> -o yaml | grep replicas
# → replicas: 0
```

The tell: `kubectl get deployment recommendation` shows `READY 0/0`. No pods means no traffic can be served. The fix is `kubectl scale deployment recommendation --replicas=1`.

---

### Cart Bad Redis Config (`chaos-pod-fail-cart`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-pod-fail-cart` |
| **Fault folder** | `k8s-faults/scenarios/ctb-cart-bad-redis` |
| **What breaks** | `VALKEY_ADDR` env var on `cart` deployment set to a non-existent Redis hostname |
| **Realistic story** | A cache-migration PR updated `VALKEY_ADDR` to point at the new Redis instance (`valkey-cart-broken:6379`) but the target hostname was wrong. The pod deployed successfully (init container checks the old Redis, not the env var), but the app crashes on startup when it tries to validate the Redis connection. |
| **Symptoms** | Cart is completely down. The cart pod is in `CrashLoopBackOff`. Logs show a fatal startup error: `Wasn't able to connect to redis`. The pod restarts repeatedly and never becomes Ready. |
| **Root cause** | The cart service (.NET) validates its Redis connection at startup and exits with a fatal error if the connection fails. The `VALKEY_ADDR=valkey-cart-broken:6379` env var points to a hostname that does not resolve. |
| **Kibana** | APM → Services → cart — no recent throughput (pod never runs long enough to handle a request). Infrastructure → Kubernetes → Pods — cart pod shows `CrashLoopBackOff`. |

**kubectl investigation:**

```bash
# CrashLoopBackOff immediately visible
kubectl get pods -n <namespace> -l app.kubernetes.io/component=cart
# → STATUS: CrashLoopBackOff, RESTARTS: climbing

# Startup crash log
kubectl logs -n <namespace> -l app.kubernetes.io/component=cart
# → "Wasn't able to connect to redis"

# Find the bad env var
kubectl get deployment cart -n <namespace> -o yaml | grep -A2 VALKEY_ADDR
# → VALKEY_ADDR: valkey-cart-broken:6379
```

The tell: `CrashLoopBackOff` + `Wasn't able to connect to redis` in logs + `VALKEY_ADDR=valkey-cart-broken:6379` in the deployment. This is a config problem, not a network problem — the pod never starts successfully.

---

### Checkout CPU Throttle (`chaos-net-delay-checkout`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-net-delay-checkout` |
| **Fault folder** | `k8s-faults/scenarios/ctb-checkout-cpu-throttle` |
| **What breaks** | A `2m` CPU limit is added to the `checkout` deployment |
| **Realistic story** | A VPA/rightsizing tool sampled CPU during a quiet maintenance window and generated a `2m` limit. The PR was approved without understanding that millicores (`2m` = 0.002 cores) is far below the service's real load requirement. |
| **Symptoms** | All checkout transactions uniformly slow. Latency spikes significantly under load with the load generator running. Error rate stays low — requests are slow, not failing. No application errors logged. The checkout pod is Running and Ready, but `kubectl top` shows CPU pinned at its limit. |
| **Root cause** | Kernel CPU throttling: checkout uses ~4m CPU under normal load but is limited to 2m. The kernel halves the pod's execution time. All downstream gRPC calls (cart, payment, shipping) are serialised slowly. |
| **Kibana** | APM → Services → checkout → Latency — p95/p99 spike, error rate flat. Infrastructure → Kubernetes → Pods → checkout — CPU usage at limit. |

**kubectl investigation:**

```bash
# CPU throttled: usage equals or exceeds limit
kubectl top pod -n <namespace> -l app.kubernetes.io/component=checkout
# → CPU shows at/near 2m limit despite higher real demand

# Bad limit in the deployment spec
kubectl get deployment checkout -n <namespace> -o yaml | grep -A5 resources
# → cpu: 2m under limits

# Pod is healthy — confirms resource constraint, not application failure
kubectl get pod -n <namespace> -l app.kubernetes.io/component=checkout
```

The tell: `resources.limits.cpu: 2m` in the deployment spec. `kubectl top` shows the pod consuming all available CPU. This should not be present — checkout has no CPU limit in the baseline config.

---

### Frontend CPU Throttle (`chaos-cpu-stress-frontend`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-cpu-stress-frontend` |
| **Fault folder** | `k8s-faults/scenarios/ctb-frontend-cpu-throttle` |
| **What breaks** | A `5m` CPU limit is added to the `frontend` deployment |
| **Realistic story** | A platform script auto-generated resource limits across all deployments but had a unit conversion bug — writing `5m` (5 millicores) instead of `500m` (0.5 cores). The PR was approved without review of the generated values. |
| **Symptoms** | All frontend service transactions show elevated latency — not one slow endpoint but everything uniformly slower. No errors. CPU metric shows throttling. The load generator drives constant traffic which amplifies the throttling effect. |
| **Root cause** | Kernel CPU throttling: the frontend (Node.js) uses ~18m CPU under normal load but is limited to 5m. The kernel throttles it to less than a third of its required execution time, slowing all server-side processing. |
| **Kibana** | APM → Services → frontend → Transactions — all transaction types show elevated latency (not isolated to one). Infrastructure → Kubernetes → Pods → frontend — CPU usage at limit. |

**kubectl investigation:**

```bash
# CPU at its limit — usage exceeds the cap
kubectl top pod -n <namespace> -l app.kubernetes.io/component=frontend
# → CPU shows at/near 5m, actual demand is ~18m

# Confirm the bad limit
kubectl get deployment frontend -n <namespace> -o yaml | grep -A5 resources
# → cpu: 5m under limits

# Pod is healthy — uniform latency, not a crash
kubectl get pod -n <namespace> -l app.kubernetes.io/component=frontend
```

The tell: `resources.limits.cpu: 5m` in the frontend deployment. Uniform latency increase across all endpoints (not a single slow one) confirms resource contention rather than a code bug or service dependency issue.

---

### Payment OOMKill Restart Loop (`chaos-net-loss-payment`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-net-loss-payment` |
| **Fault folder** | `k8s-faults/scenarios/ctb-payment-oom-restart` |
| **What breaks** | Memory limit on `payment` deployment lowered to `25Mi` |
| **Realistic story** | A memory-audit PR set an aggressive `25Mi` limit on the payment service after a period of low traffic. The Node.js runtime alone requires ~100Mi — the pod OOMKills immediately on startup. |
| **Symptoms** | Payment failures are intermittent and bursty — many successes, then a window of failures, then recovery. RESTARTS count on payment pod is elevated and growing. The pod cycles through `Running → OOMKilled → Running`. |
| **Root cause** | Node.js runtime exceeds 25Mi immediately on startup. Kernel OOMKills the pod (exit code 137). Kubernetes restarts it with exponential backoff. During each restart window in-flight payment calls fail. |
| **Kibana** | APM → Services → payment — bursty intermittent errors timed with pod restarts. Infrastructure → Kubernetes → Pods → payment — RESTARTS count climbing. |

**kubectl investigation:**

```bash
# Rising RESTARTS count
kubectl get pod -n <namespace> -l app.kubernetes.io/component=payment
# → RESTARTS: 3+ and climbing

# OOMKilled in Last State — the key diagnostic
kubectl describe pod -n <namespace> -l app.kubernetes.io/component=payment
# → Last State: Terminated, Reason: OOMKilled, Exit Code: 137

# The bad memory limit
kubectl get deployment payment -n <namespace> -o yaml | grep -A5 resources
# → memory: 25Mi under limits
```

The tell: `Last State: Terminated / Reason: OOMKilled` in `kubectl describe pod`. `resources.limits.memory: 25Mi` confirms the root cause — payment uses ~100Mi at runtime, far above the limit.
