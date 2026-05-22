# Agent Response Evaluation — `chaos-pod-fail-productcatalog`

**Scenario injected:** `chaos-pod-fail-productcatalog` — product-catalog deployment scaled to 0 replicas  
**Previous scenario reverted:** `chaos-env-fail-shipping` (QUOTE_ADDR restored)  
**Date:** 2026-05-21  
**Cluster:** `oteldemo-rkznd`  
**Mode:** Quiet (scenario hidden from investigator)

---

## What was actually happening

The product-catalog deployment was scaled to 0 replicas. There are no running pods — `kubectl get pods -l app.kubernetes.io/component=product-catalog` returns nothing. Every gRPC call from frontend or checkout to product-catalog fails with `UNAVAILABLE` immediately. Frontend error rate spikes to 50–60%. The fix is a single command:
```bash
kubectl scale deployment product-catalog --replicas=1
```
All flagd flags were off. No shipping issues. No payment issues.

---

## Turn 1: Initial investigation

### What the agent got right

Nothing in this turn maps to the actual scenario.

### What the agent got wrong

**Diagnosed the previous (reverted) scenario as still active.** The shipping `→ quote-old:8080` failure was the scenario we ran immediately before this one. It was fully reverted before this injection. The agent reported it as the dominant active failure with 37 logged errors in the last 15 minutes — this is stale data from the prior incident being read as current.

**Gold loyalty / payment hallucination appeared for the fourth time.** `payment` failing 53–60% of the time for gold-tier users, with flagd involvement. No payment flag was set. This is now a confirmed recurring hallucination across every single evaluation.

**flagd latency fabricated again.** `cart → flagd` at 18s latency and 9.5% error rate. Same pattern as previous incidents.

**Missed the actual problem entirely.** product-catalog scaled to 0 replicas — the real failure — was not mentioned at all.

---

## Turn 2: Timeline and impact

### What the agent got right

None of the timeline maps to the actual scenario.

### What the agent got wrong

**Carried the wrong incidents forward with high confidence.** Shipping failure started at ~13:30 UTC, "redeployed at ~13:48 UTC but bad config persisted" — all fabricated continuity from the previous incident. The agent invented a redeployment event to explain why the reverted scenario was "still active."

**Still no mention of product-catalog.** Two full turns in, the actual failure remained undetected.

---

## Turn 3: Current state, root cause, and fix

### What the agent got right

**Finally detected product-catalog as a failing dependency.** In the third turn, the agent identified `checkout → ProductCatalogService/GetProduct gRPC` as a new active failure with ~96% error rate, with multiple product IDs failing (`LS4PSXUNUM`, `66VCHSJNUP`, `2ZYFJ3GM2N`). This is real signal.

**Correctly framed it as a misconfigured service address class of problem** — same pattern as shipping. While the specific diagnosis is wrong (see below), the instinct to look at service addressing is reasonable.

**Correctly noted the shipping issue as still active** — even though that's based on stale data from the prior incident, the structural observation that "both issues are misconfigured service addresses that started at the same time" is a coherent hypothesis, even if built on a false premise.

### What the agent got wrong

**"product-catalog itself is healthy (0% failure rate)"** — this is the critical misread. When a deployment is scaled to 0 replicas, there are no pods to generate APM data. The service appears dark: zero throughput, zero errors. The agent interpreted absence of metrics as health. The correct interpretation is the opposite: a service receiving calls from upstream but emitting no APM data is likely down or has no pods.

**Diagnosed a misconfigured gRPC address instead of scaled-to-zero.** The agent recommended checking `PRODUCT_CATALOG_SERVICE_ADDR` in the checkout config. The actual problem is visible with:
```bash
kubectl get deployment product-catalog
# READY 0/0, replicas: 0

kubectl get pods -l app.kubernetes.io/component=product-catalog
# No resources found
```
The fix is `kubectl scale deployment product-catalog --replicas=1` — not a config change.

**Declared payment resolved as if it was a real issue.** "The Invalid token errors from payment have completely stopped — this appears to have self-resolved." Payment was never failing. The agent invented a resolution for a fabricated problem.

---

## Summary

| Dimension | Score |
|---|---|
| Detecting the actual broken service (product-catalog) | ⚠️ Turn 3 only, 2 turns late |
| Root cause (scaled to 0 vs. bad address) | ❌ Wrong |
| Key kubectl command (`get deployment product-catalog`) | ❌ Never suggested |
| "No APM data = healthy" misread | ❌ Critical error |
| Shipping stale data bleed-over | ❌ Persisted all 3 turns |
| Gold loyalty hallucination | ❌ 4th consecutive appearance |
| flagd latency hallucination | ❌ 3rd consecutive appearance |
| Correct fix surfaced | ❌ Never |

---

## Patterns across all four evaluations

| Pattern | payment-down | payment-partial | chaos-env-fail-shipping | chaos-pod-fail-productcatalog |
|---|---|---|---|---|
| Correct service identified | ✅ | ✅ | ✅ | ⚠️ Turn 3 |
| Root cause correct | ❌ | ❌ | ⚠️ Near miss | ❌ |
| Gold loyalty hallucination | — | ❌ | ❌ | ❌ |
| flagd cascade hallucination | — | ❌ | ❌ | ❌ |
| Prior incident bleed-over | — | ✅ Clean | — | ❌ Severe |
| "No APM data = healthy" trap | — | — | — | ❌ |
| Feature flags checked | ❌ | ❌ | ❌ | ❌ |

### New finding: "No APM data = down, not healthy"

Scaled-to-zero deployments produce no APM spans because there are no pods to instrument. The agent consistently reads zero throughput + zero errors as a healthy service. The correct heuristic: **if a service is being called by upstream services but shows no APM data, check `kubectl get deployment <service>` for zero replicas before concluding it is healthy.**

### Confirmed systemic issues

1. **Prior incident data bleeds into new investigations.** Reverted scenarios continue to appear as active failures in subsequent conversations. The agent has no mechanism to distinguish "this error happened before the reset" from "this error is happening now."

2. **Gold loyalty + flagd cascade is a persistent hallucination.** Appeared in 3 of 4 incidents, always with specific-looking numbers (309s timeouts, 80% error rates). Never once caused by the actual injected scenario.

3. **Feature flags are never checked.** Zero out of four incidents prompted the agent to look at `http://localhost:8080/feature` or the flagd evaluation API.

4. **The agent finds the right service eventually** — but takes too long and never produces the correct kubectl fix command unprompted.
