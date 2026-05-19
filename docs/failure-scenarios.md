# Failure Scenario Catalogue

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
