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

### Product Catalog Bad Database Config (`chaos-db-fail-productcatalog`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-db-fail-productcatalog` |
| **Fault folder** | `k8s-faults/scenarios/ctb-productcatalog-bad-db` |
| **What breaks** | `DB_CONNECTION_STRING` env var on `product-catalog` deployment set to a non-existent PostgreSQL hostname |
| **Realistic story** | A database migration PR updated `DB_CONNECTION_STRING` to point at the new PostgreSQL instance but the target hostname was a typo — `postgresql-broken` instead of `postgresql`. The deployment rolled out without failing (the connection string is only validated at runtime, not at deploy time), so CI was green. The app calls `pg.Connect()` at startup, DNS resolution fails for the non-existent hostname, and the process exits immediately with code 1. |
| **Symptoms** | All product browsing fails immediately with errors. The product-catalog pod is in CrashLoopBackOff — it starts, crashes within one second, and loops. It never stays up long enough to serve a single request. The frontend error rate climbs to 30–57% of all transactions because product-catalog is a critical dependency for every product listing and detail page. Unlike scale-to-zero, the pod exists and keeps restarting — a misleading signal for responders who check pod existence. |
| **Root cause** | The Go service calls `pg.Connect()` at startup. DNS resolution fails for the bad hostname, the connection times out, and the process exits with code 1. Kubernetes restarts it with exponential backoff. The pod never becomes Ready. |
| **Kibana** | APM → Services → product-catalog — zero throughput (pod never runs long enough to serve). APM → Service Map — frontend → product-catalog edge shows errors. APM → Services → frontend — error rate spike across all product-related transactions. Infrastructure → Kubernetes → Pods — product-catalog shows CrashLoopBackOff with climbing RESTARTS. |

**kubectl investigation:**

```bash
# CrashLoopBackOff immediately visible
kubectl get pods -n <namespace> -l app.kubernetes.io/component=product-catalog
# → STATUS: CrashLoopBackOff, RESTARTS: climbing

# Confirm the runtime is less than 2 seconds — it crashes immediately on startup
kubectl describe pod -n <namespace> -l app.kubernetes.io/component=product-catalog
# → Last State: Terminated, Reason: Error, Exit Code: 1
# → Started and Finished timestamps are within 1–2 seconds of each other

# Find the bad env var
kubectl get deployment product-catalog -n <namespace> -o yaml | grep DB_CONNECTION_STRING
# → DB_CONNECTION_STRING: postgres://otelu:otelp@postgresql-broken/otel?sslmode=disable
```

The tell: CrashLoopBackOff with a sub-second runtime (Started/Finished within 2 seconds in `kubectl describe`) combined with `DB_CONNECTION_STRING` pointing to an unresolvable hostname. This is a config problem, not a network problem — the pod starts, fails DNS, and exits before serving a single request.

**Verified test run (2026-05-20):**

| Phase | product-catalog: req/min | errors | error% | frontend: req/min | frontend: errors | frontend: error% |
|-------|--------------------------|--------|--------|-------------------|------------------|-----------------|
| Baseline (13:53–13:55 UTC) | 108–200 | 0 | 0% | 241–379 | 0 | 0% |
| Post-injection (13:56–14:01 UTC) | 0 | 0 | — (pod dark) | 142–279 | 47–158 | **30–57%** |
| Post-revert (14:02–14:04 UTC) | 74–108 | 0 | 0% | 261–279 | 0–4 | **0–1.5%** |

K8s observation: injection set `DB_CONNECTION_STRING=postgres://otelu:otelp@postgresql-broken/otel?sslmode=disable`; pod entered CrashLoopBackOff immediately, reaching 4 restarts within 2 minutes, with each run lasting under 1 second (exit code 1). The product-catalog service disappeared from APM within one minute of injection. Caller signal: the `frontend` service error rate climbed from 0% baseline to **57% peak** as all product gRPC calls returned unavailable. Post-revert: `kubectl set env` restored the correct hostname, pod was `1/1 Running` within 6 seconds; frontend error rate dropped from 55% → 11.5% → 1.5% → 0% within 3 minutes.

---

### Product Catalog Scaled to Zero (`chaos-pod-fail-productcatalog`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-pod-fail-productcatalog` |
| **Fault folder** | `k8s-faults/scenarios/ctb-productcatalog-scaled-zero` |
| **What breaks** | `product-catalog` deployment replica count set to `0` |
| **Realistic story** | A weekend cost-reduction automation script identified the product catalog service as "low-utilization" during off-hours (European evening, low US traffic) and scaled its replicas to zero. The script compared absolute request counts against a static threshold — it failed to account for the fact that low traffic reflected time-of-day, not genuine idleness. The change was committed through GitOps automation and approved without review of the replica-count diffs. |
| **Symptoms** | All product browsing fails immediately. The frontend's gRPC calls to the product-catalog service return UNAVAILABLE. The frontend error rate spikes to ~50–60% — every product listing, product detail, and search page fails because the product catalog is a critical synchronous dependency. The `product-catalog` deployment exists but has 0 replicas. |
| **Root cause** | No product-catalog pods are running — there is nothing to serve product catalog requests. Kubernetes does not auto-recover from a manual replica scale-down. |
| **Kibana** | APM → Services → product-catalog — no recent throughput (service went dark). APM → Service Map — frontend → product-catalog edge shows errors. APM → Services → frontend — sharp error rate spike across all product-related transactions. Infrastructure → Kubernetes → Pods — no pods for product-catalog selector. |

**kubectl investigation:**

```bash
# No pods running
kubectl get deployment product-catalog -n <namespace>
# → READY shows 0/0

kubectl get pods -n <namespace> -l app.kubernetes.io/component=product-catalog
# → No resources found

# The deployment still exists — only replicas is wrong
kubectl get deployment product-catalog -n <namespace> -o yaml | grep replicas
# → replicas: 0
```

The tell: `kubectl get deployment product-catalog` shows `READY 0/0`. No pods means no traffic can be served. The fix is `kubectl scale deployment product-catalog --replicas=1`.

**Verified test run (2026-05-20):**

| Phase | product-catalog: req/min | errors | error% | p99 (ms) | frontend: error% |
|-------|--------------------------|--------|--------|----------|-----------------|
| Baseline (13:33–13:37 UTC) | 97–152 | 3–9 | 2–6% | 26–45 | 5–10% |
| Post-injection (13:39–13:43 UTC) | 0 | 0 | — (no pods) | — | **43–58%** |
| Post-revert (13:45–13:46 UTC) | 96–110 | 0 | 0% | 40–46 | **0%** |

K8s observation: injection set `replicas: 0` — `kubectl get deployment product-catalog` showed `READY 0/0` immediately; the pod selector returned no resources within 2 seconds. The `product-catalog` service disappeared from APM traces after the last in-flight requests drained (~13:38). Caller signal: the `frontend` service saw its error rate climb from a baseline of ~5–10% to **57% peak** as product catalog gRPC calls returned UNAVAILABLE. Post-revert: `kubectl scale` restored `replicas: 1`, pod was `1/1 Running` within 12 seconds; frontend error rate dropped from 55% → 21% → 0% within 2 minutes.

---

### Shipping Bad Quote Service Address (`chaos-env-fail-shipping`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-env-fail-shipping` |
| **Fault folder** | `k8s-faults/scenarios/ctb-shipping-bad-quote-addr` |
| **What breaks** | `QUOTE_ADDR` env var on `shipping` deployment set to a non-existent hostname |
| **Realistic story** | A config migration PR updated the shipping service to read its quote service endpoint from an env var (`QUOTE_ADDR`) rather than a hardcoded value. During the migration the env var was set to the old internal hostname (`quote-old:8080`) that had been renamed as part of a service reorganisation. The pod deployed and rolled out successfully — shipping only contacts the quote service per-request, not at startup — so the bad config passed CI and wasn't caught until traffic hit the new pod. Every call to `GetQuote` fails with a DNS resolution error. |
| **Symptoms** | All checkout attempts fail at the shipping step. Critically, the shipping pod is `1/1 Running` with 0 restarts — `kubectl get pods` shows nothing wrong. The fault is entirely invisible at the infrastructure layer. APM is the only place where the 100% error rate on `shipping` is visible. Checkout error rate climbs to ~25% as all order completions fail when shipping cost cannot be calculated. |
| **Root cause** | The shipping service dials `QUOTE_ADDR` on every `GetQuote` HTTP request. DNS resolution fails for `quote-old`, the HTTP call returns a connection error, and shipping returns an error to checkout. The pod starts cleanly and passes readiness checks — the bad config is only exercised at request time. |
| **Kibana** | APM → Services → shipping — 100% error rate on `GetQuote` spans. APM → Service Map — checkout → shipping edge shows errors. APM → Services → checkout — error rate spike (~25%). Infrastructure → Kubernetes → Pods — no anomalies (pod Running/Ready). |

**kubectl investigation:**

```bash
# Pod looks completely healthy — this is the misleading signal
kubectl get pods -n <namespace> -l app.kubernetes.io/component=shipping
# → STATUS: Running, READY: 1/1, RESTARTS: 0

# Find the bad env var
kubectl get deployment shipping -n <namespace> -o yaml | grep QUOTE_ADDR
# → QUOTE_ADDR: http://quote-old:8080

# Confirm requests are failing with DNS errors
kubectl logs -n <namespace> -l app.kubernetes.io/component=shipping --tail=20
# → connection error: dial tcp: lookup quote-old: no such host
```

The tell: `QUOTE_ADDR=http://quote-old:8080` in the deployment — combined with a 100% error rate in APM on `shipping` and a fully-healthy pod in `kubectl get pods`. The pod health check passes because shipping starts without contacting the quote service; the fault is only exercised at request time.

**Verified test run (2026-05-20):**

| Phase | shipping: req/min | errors | error% | checkout: req/min | checkout: errors | checkout: error% |
|-------|-------------------|--------|--------|-------------------|------------------|-----------------|
| Baseline (14:23–14:27 UTC) | 12–18 | 0 | 0% | 52–76 | 0 | 0% |
| Post-injection (14:29–14:30 UTC) | 2–18 | 2–18 | **100%** | 8–68 | 2–18 | **25–26.5%** |
| Post-revert (14:31–14:34 UTC) | 6–18 | 0 | 0% | 24–82 | 0 | **0%** |

K8s observation: injection set `QUOTE_ADDR=http://quote-old:8080`; pod rolled out successfully in 4 seconds, `kubectl get pods` showed `1/1 Running` with `RESTARTS: 0` throughout the entire fault window — the pod never crashed. Shipping error rate reached 100% within one minute of injection. Caller signal: checkout error rate climbed from 0% to 26.5% peak. Post-revert: `kubectl set env` restored the correct address, pod rolled out in 4 seconds; both shipping and checkout returned to 0% errors within one minute.

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

**Verified test run (2026-05-20):**

| Phase | frontend → recommendation: req/min | errors | error% | avg latency (ms) |
|-------|-------------------------------------|--------|--------|-----------------|
| Baseline (09:49–10:03 UTC) | 2–8 | 0 | 0% | 10,000–17,000 |
| Injection (10:04 UTC — pod Terminating) | 2 | 1 | 50% | 7,036 |
| Post-injection (10:05–10:10 UTC) | 3–8 | 3–8 | **100%** | 639–742 |
| Revert transition (10:11 UTC) | 6 | 3 | 50% | 6,783 |
| Post-revert (10:12–10:13 UTC) | 2–7 | 0 | 0% | 12,000–12,400 |

K8s observation: injection set `replicas: 0` — `kubectl get deployment recommendation` showed `READY 0/0` immediately; pod entered `Terminating` within 1 second and the selector returned no resources. The `recommendation` service disappeared from APM traces after 10:04 (final 3 in-flight spans from the terminating pod). Caller signal: `frontend` → `grpc.oteldemo.RecommendationService/ListRecommendations` spans went from 0% errors to **100% error rate** with gRPC status code **14 (UNAVAILABLE)** and fast failures (~650ms avg, not a full timeout — K8s returns UNAVAILABLE immediately when no endpoints exist). Post-revert: `kubectl scale` restored `replicas: 1`, pod was `1/1 Running` within 8 seconds; error rate dropped from 100% → 50% → 0% within 2 minutes.

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

**Verified test run (2026-05-20):**

| Phase | frontend: req/min | p99 (ms) | avg (ms) | error% |
|-------|-------------------|----------|----------|--------|
| Baseline (08:52–09:01 UTC) | 180–380 | 19–447 | 8–35 | 2–15% |
| Throttled — 09:05 UTC | 5 | **41,368** | **36,680** | 0% |
| Throttled — 09:06 UTC | 14 | **172,060** | **26,229** | 0% |
| Post-revert (09:09–09:12 UTC) | 158–277 | 115–497 | 19–45 | 7–9% |

K8s observation: injection set `resources.limits.cpu: 5m`; `kubectl top` showed pod consuming **10–11m** CPU against a **5m** cap — throttled to ~50% of demand. Pod remained `Running/Ready` throughout (`1/1`). Revert removed the CPU limit entirely (`kubectl patch` JSON patch op `remove`), rollout completed in ~4 seconds. Post-revert throughput and p99 recovered to baseline within one per-minute bucket.

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

**Verified test run (2026-05-20):**

| Phase | payment (total / errors / error%) | checkout (total / errors / error%) |
|-------|-----------------------------------|-------------------------------------|
| Baseline (last 15 min pre-injection) | 62 / 0 / 0% — p99 53 ms | 490 / 30 / 6.1% — p99 134 ms |
| Post-injection peak (08:48 UTC) | ~1–2 spans/min (pod cycling) | 28 / 8 / **28.6%** — p99 746 ms |
| Post-injection (08:49 UTC) | near-zero | 18 / 4 / **22.2%** |
| Post-revert (08:54 UTC) | 5 / 0 / 0% — normal volume | 12 / 0 / **0%** |

K8s observation: pod reached `OOMKilled` state 4 times within the first 2 minutes after injection (exit code 137). `kubectl rollout status` confirmed clean recovery within 4 seconds of revert.

---

### Dual Fault: Cart CrashLoopBackOff + Payment OOMKill (`chaos-dual-cart-payment`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-dual-cart-payment` |
| **Fault folder** | `k8s-faults/scenarios/ctb-dual-cart-payment` |
| **What breaks** | Two independent faults simultaneously: (1) `cart` `VALKEY_ADDR` set to a non-existent Redis hostname; (2) `payment` memory limit lowered to `25Mi` |
| **Realistic story** | Two unrelated PRs landed in the same release window. A cache-migration PR set `VALKEY_ADDR=valkey-cart-broken:6379` on the cart service. A memory-audit PR set an aggressive `25Mi` limit on the payment service. Neither author knew about the other. Both passed CI. |
| **Symptoms** | Checkout is completely broken and users cannot add items to their cart. Two separate things appear to be wrong at the same time — this looks like a single systemic outage but has two independent root causes with different failure modes, different fix procedures, and different investigation paths. |
| **Root cause** | **(1) Cart:** The cart service (.NET) validates its Redis connection at startup and exits fatally if it fails. `VALKEY_ADDR=valkey-cart-broken:6379` resolves to nothing — the pod crashes immediately on every restart, entering `CrashLoopBackOff`. **(2) Payment:** The Node.js runtime exceeds `25Mi` immediately on startup. Kernel OOMKills the pod (exit code 137). Kubernetes restarts it with exponential backoff, causing bursty payment failures during each restart window. |
| **Kibana** | APM → Services → cart — no throughput (pod never reaches ready). APM → Services → payment — intermittent bursty errors timed with pod restarts. Infrastructure → Kubernetes → Pods — cart in `CrashLoopBackOff`, payment in `OOMKilled/Restarting`. |

**Design intent:**

This scenario is specifically designed to test whether an agent (or human investigator) can distinguish between two simultaneous unrelated faults rather than inferring a single systemic root cause. The shared blast radius (checkout failures) creates a false signal of one incident. Key divergence points:

- Cart fails **deterministically** and **immediately** — `CrashLoopBackOff` with a clear startup error log.
- Payment fails **intermittently** and **bursty** — `OOMKilled` with rising RESTARTS but visible recovery windows.
- The fixes are completely independent: cart needs an env var corrected; payment needs its memory limit removed.

**kubectl investigation:**

```bash
# Overview — spot both failing pods at once
kubectl get pods -n <namespace> | grep -E 'cart|payment'
# → cart:    STATUS CrashLoopBackOff, RESTARTS climbing
# → payment: STATUS OOMKilled/Running cycling, RESTARTS climbing

# --- Cart fault ---
kubectl logs -n <namespace> -l app.kubernetes.io/component=cart
# → "Wasn't able to connect to redis"

kubectl get deployment cart -n <namespace> -o yaml | grep -A2 VALKEY_ADDR
# → VALKEY_ADDR: valkey-cart-broken:6379

# --- Payment fault ---
kubectl describe pod -n <namespace> -l app.kubernetes.io/component=payment
# → Last State: Terminated, Reason: OOMKilled, Exit Code: 137

kubectl get deployment payment -n <namespace> -o yaml | grep -A5 resources
# → memory: 25Mi under limits
```

The first tell: `kubectl get pods` shows **two** unhealthy pods in unrelated components. The investigator must resist the temptation to declare a single root cause — cart and payment have different failure modes, different logs, and require different fixes.

**Fixes (both required to restore checkout):**

```bash
# Fix cart: restore correct Redis address
kubectl set env deployment/cart -n <namespace> VALKEY_ADDR=valkey-cart:6379
kubectl rollout status deployment/cart -n <namespace> --timeout=120s

# Fix payment: remove the aggressive memory limit
kubectl set resources deployment payment -n <namespace> \
  -c payment --limits=memory=''
```

---

### Dual Fault: Ad CPU Throttle + Recommendation Scaled to Zero (`chaos-dual-ad-recommendation`)

| Field | Value |
|-------|-------|
| **Scenario ID** | `chaos-dual-ad-recommendation` |
| **Fault folder** | `k8s-faults/scenarios/ctb-dual-ad-recommendation` |
| **What breaks** | Two independent non-critical-path faults: (1) `ad` deployment CPU limit set to `20m`; (2) `recommendation` deployment scaled to `0` replicas |
| **Realistic story** | Two unrelated infrastructure changes landed in the same release window. An automated rightsizing tool sampled CPU during a quiet overnight window and wrote a `20m` limit for the ad service (Java/JVM). A separate cost-optimisation script evaluated recommendation as idle based on a 24h window that missed peak hours and submitted a PR setting replicas to 0. Neither team knew about the other. |
| **Symptoms** | Product pages are degraded in two distinct ways — ads load slowly or not at all, and recommendation widgets fail. Checkout and cart work normally throughout. The outage looks like a "product page issue" but has two completely independent causes with different fixes. |
| **Root cause** | **(1) Ad service:** The JVM cannot process GetAds requests fast enough with a `20m` CPU cap; kernel CPU throttling causes latency to spike from ~10ms to multi-second values while the pod stays `Running`. **(2) Recommendation:** No pods are running — `replicas: 0` means Kubernetes has nothing to schedule; frontend gRPC calls to `ListRecommendations` fail immediately with `UNAVAILABLE`. |
| **Kibana** | APM → Services → ad — GetAds transaction latency spike (service stays alive, just slow). APM → Services → recommendation — no recent throughput (service went dark). Infrastructure → Kubernetes → Pods → ad — CPU usage at `20m` limit. `kubectl get deployment recommendation` shows `READY 0/0`. |

**Design intent:**

This scenario differs from `chaos-dual-cart-payment` in a key way: **checkout is unaffected**. Both faults are confined to non-critical product-page decorations. The investigation trap is different — the investigator cannot use "checkout broken" as a triage signal. Instead, they must separately discover two different degradation patterns on what looks like a single surface (product pages). Ad service has a *latency* failure mode (slow but alive); recommendation has an *availability* failure mode (completely gone). Neither fault explains the other, and they require completely different fixes.

**kubectl investigation:**

```bash
# Overview — one pod throttled (CPU), one missing entirely
kubectl get pods -n <namespace> | grep -E '^ad|^recommendation'
# → ad:             Running (but CPU at limit)
# → recommendation: No resources found

kubectl get deployment recommendation -n <namespace>
# → READY 0/0

# --- Ad fault ---
kubectl top pod -n <namespace> -l app.kubernetes.io/component=ad
# → CPU shows at/near 20m despite higher real demand

kubectl get deployment ad -n <namespace> -o yaml | grep -A5 resources
# → cpu: 20m under limits

# --- Recommendation fault ---
kubectl get deployment recommendation -n <namespace> -o yaml | grep replicas
# → replicas: 0
```

The first tell is asymmetric: `kubectl get pods` shows ad running (not crashing) while recommendation has no pods at all. These are different failure classes — a resource-constrained slow service vs a zeroed deployment.

**Fixes (both required to restore full product page experience):**

```bash
# Fix ad service: remove the CPU limit
kubectl set resources deployment ad -n <namespace> \
  -c ad --limits=cpu=''
kubectl rollout status deployment/ad -n <namespace> --timeout=120s

# Fix recommendation: restore replicas
kubectl scale deployment recommendation -n <namespace> --replicas=1
```
