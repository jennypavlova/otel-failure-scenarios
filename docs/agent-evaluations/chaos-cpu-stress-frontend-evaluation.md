# Agent Response Evaluation — `chaos-cpu-stress-frontend`

**Scenario injected:** `chaos-cpu-stress-frontend` — CPU limit of `5m` added to the frontend deployment, causing kernel-level CPU throttling  
**Previous scenario reverted:** `chaos-pod-fail-productcatalog`  
**Date:** 2026-05-21  
**Cluster:** `oteldemo-rkznd`  
**Mode:** Alert-driven investigation (agent started from the Kibana alerts page)

---

## What was actually happening

The frontend deployment had a CPU limit of `5m` applied (correct value should be `500m` or higher). At normal load the frontend pod immediately hits its CPU ceiling, causing kernel-level throttling. Every frontend transaction becomes uniformly slower — no errors, no crashes, no CrashLoopBackOff. Pods show `Running/Ready`. The failure is invisible to anyone who only checks pod status or error rates.

Observable via:
```bash
kubectl get deployment frontend -o yaml | grep -A3 resources
# cpu: 5m under resources.limits

kubectl top pod -l app.kubernetes.io/component=frontend
# CPU at or near limit
```

In Kibana: **Infrastructure → Kubernetes → Pods → frontend** shows CPU pegged at limit. **APM → Services → frontend → Transactions** shows all endpoints uniformly slower — not one slow endpoint but everything degraded proportionally.

---

## What the agent got right

**The flagd alert analysis is genuinely accurate.** The agent correctly identified:

- The `GET` latency alert firing at ~10,000ms maps to `/featurelive/longpoll` — a long-poll endpoint designed to hold connections open for ~10 seconds. The 1,500ms threshold is misconfigured for this endpoint. This is a real false positive and the recommendation to raise or exclude it is correct.
- The `EventStream` gRPC calls at ~590,000ms latency are long-lived streaming connections, not slow requests. APM measuring stream duration as latency is an instrumentation artifact. These are not an incident.
- The `Flag not found` errors from cart are real but low-impact — the cart service itself is healthy.

**The alert triage methodology is sound.** For each alert the agent checked traces, confirmed HTTP 200 responses, identified the endpoint pattern, and reached a justified conclusion. This is exactly the right approach for alert triage.

---

## What the agent got wrong

**Missed the actual injected failure entirely.** `chaos-cpu-stress-frontend` was not mentioned. The agent concluded the investigation with no active incident and only recommended alert threshold tuning — which means in a real on-call scenario, the ticket would have been closed while a CPU-throttled frontend was silently degrading every user-facing transaction.

**Anchored on pre-existing alerts and stopped looking.** The flagd alerts were firing for ~1.5 hours before this scenario was injected. The agent investigated those alerts, correctly triaged them as false positives, and stopped. It did not check whether new alerts had fired for other services after the injection, or scan APM services for any that showed unusual latency patterns.

**Stayed entirely in the APM trace layer.** The CPU throttling scenario is invisible in APM error rates and traces — it shows up in infrastructure metrics (CPU utilisation, throttling percentage) and as a subtle uniform latency increase across all frontend transactions. The agent never looked at:
- Infrastructure → Kubernetes → Pods (CPU at limit)
- `kubectl top pod` for resource pressure
- APM → Services → frontend to compare per-transaction latency breadth

**Did not check if the alert list was complete.** The agent reported on the flagd GET alert (firing since 12:44 UTC) but did not surface whether frontend latency alerts had fired since the injection. A complete alert-driven investigation should confirm the full set of active alerts before closing.

---

## The core diagnostic gap: no error rate ≠ no incident

This scenario has zero application errors. Every transaction completes successfully — just slowly. The agent's investigation path relied heavily on error rates, error logs, and failing spans to find problems. CPU throttling produces none of these signals:

| Signal | CPU throttling scenario | Agent checked? |
|---|---|---|
| Pod status | Running/Ready | ❌ Not checked |
| Error rate | 0% | N/A |
| APM traces | No failing spans | N/A |
| Latency (all endpoints) | Uniformly elevated | ❌ Not checked |
| CPU utilisation | At limit | ❌ Not checked |
| Infrastructure metrics | CPU throttle rate high | ❌ Not checked |

The agent's investigation workflow appears to be: alerts → traces → error logs. For infrastructure resource exhaustion (CPU, memory), this path produces no findings. The investigation needs to branch into Infrastructure metrics whenever APM shows no errors but users report degraded service.

---

## Turn 2: "Now more alerts are appearing, can you investigate further?"

### Ground truth (verified via kubectl at time of investigation)

```
NODE CPU:
  pool-d2c7e1c0-jfqs   80%   (driven almost entirely by load-generator at 1386m cores)
  pool-d2c7e1c0-zsm4   17%

FRONTEND:
  Pod: Running/Ready, using ~10m CPU, limit: 5m → throttled
  
PRODUCT-CATALOG:
  Pod: Running/Ready (1/1), no restarts — fully healthy
```

### What the agent got right

**Broadened scope beyond flagd.** In Turn 1 the agent stopped at the pre-existing alerts. In Turn 2 it looked at Infrastructure metrics and service-level failure rates — the right direction.

**Correctly identified frontend-proxy and frontend as showing elevated failure rates.** These are real signals consistent with CPU-throttled frontend transactions timing out or being slow under load.

**Correctly flagged the EventStream flapping as background noise**, consistent with the Turn 1 analysis.

**Correctly recommended tuning the flagd alert thresholds** — this remains valid housekeeping.

### What the agent got wrong

**"Both GKE nodes at 100% CPU" — fabricated.** Actual node CPU at time of investigation: **jfqs at 80%, zsm4 at 17%**. Neither node was at 100%. The jfqs figure is high, but it's driven by the load-generator pod (1386m cores) running normal synthetic traffic — not a symptom of the incident. The agent invented node saturation as a root cause.

**Wrong root cause → wrong fix.** Node CPU saturation and pod CPU throttling are completely different problems:

| | Agent's diagnosis | Actual problem |
|---|---|---|
| What's limited | Both GKE nodes | Single frontend pod |
| Mechanism | Nodes out of capacity | Kernel throttles pod at `5m` limit |
| Fix | Scale up node pool | Remove/raise the `5m` CPU limit |
| kubectl signal | `kubectl top nodes` high | `kubectl get deployment frontend -o yaml` shows `cpu: 5m` |

Scaling up the node pool would have done nothing. The frontend pod would still be capped at 5 millicores regardless of how much node capacity was available.

**product-catalog "going dark" is stale bleed-over — again.** The agent reported product-catalog went dark between 14:10–14:47 UTC and that checkout was failing with `GetProduct` gRPC errors. product-catalog was scaled back to 1 replica and verified healthy before this scenario was injected (`kubectl get pods` confirms `1/1 Running`). This is the same prior-incident bleed-over pattern seen in the previous evaluation session.

**Fabricated Kafka/accounting cascade.** The agent reported 129s Kafka publish latency causing a 43s accounting consumer delay. No Kafka configuration was changed. This appears to be noise data amplified by the same pattern of reading stale or unrelated metrics as causally connected to the incident.

**Alert count inflated.** The agent reported 20 active alerts. Pre-injection there were 6 confirmed flagd alerts. Some new frontend/load-generator latency alerts may have legitimately fired, but the agent's table includes entries (accounting, product-reviews, recommendation, ad, fraud-detection) that are pre-existing or fabricated.

---

## Summary

| Dimension | Turn 1 | Turn 2 |
|---|---|---|
| Flagd false positive identification | ✅ Excellent | ✅ Consistent |
| Alert triage methodology | ✅ Sound | ✅ Improved scope |
| Detecting the actual injected failure | ❌ Missed | ❌ Missed |
| Root cause (pod throttle vs. node saturation) | ❌ | ❌ Wrong layer |
| Correct fix surfaced | ❌ | ❌ Scale-up won't work |
| product-catalog bleed-over | — | ❌ Again |
| Fabricated cascades (Kafka, accounting) | ❌ | ❌ |
| Infrastructure metrics checked | ❌ | ⚠️ Checked but misread |

The agent did improve in Turn 2 by broadening into infrastructure metrics — the right instinct. But it misread node CPU as saturated (80% → "100%") and used that to construct a plausible-sounding but wrong causal chain. The actual signal — a single line in `kubectl get deployment frontend -o yaml` showing `cpu: 5m` — was never checked.

---

## Updated master pattern table

| Pattern | payment-down | payment-partial | chaos-env-fail-shipping | chaos-pod-fail-productcatalog | chaos-cpu-stress-frontend |
|---|---|---|---|---|---|
| Correct service identified | ✅ | ✅ | ✅ | ⚠️ Turn 3 | ⚠️ Turn 2 (wrong layer) |
| Root cause correct | ❌ | ❌ | ⚠️ Near miss | ❌ | ❌ |
| Infrastructure metrics checked | — | — | — | ❌ | ⚠️ Checked, misread |
| Alert false positive identified | — | — | — | — | ✅ |
| Gold loyalty hallucination | — | ❌ | ❌ | ❌ | — |
| Prior incident bleed-over | — | — | — | ❌ | ❌ |
| Fabricated cascades | — | ❌ | ❌ | ❌ | ❌ |

### Findings from this session

**Alert anchoring:** When pre-existing alerts dominate, the agent investigates those and stops — then broadens only when prompted. A proactive scan of all services (not just alerted ones) should happen at investigation start.

**Node vs. pod CPU confusion:** The agent reached for infrastructure metrics (good) but diagnosed at the wrong granularity. Node CPU % and pod CPU throttling require different kubectl commands and have different fixes. Whenever a latency-only incident (no error rate increase) appears, the first infrastructure check should be `kubectl get deployment <service> -o yaml | grep -A5 resources` — not `kubectl top nodes`.

**Bleed-over persists across sessions.** Prior incident data continues to contaminate new investigations even after explicit reverts. The agent needs a way to anchor to a specific time window that excludes pre-reset data.
