# Elastic AI Agent — Observability Investigation Evaluation

**Cluster:** `oteldemo-rkznd` (OTel Astronomy Shop on GKE + Elastic Cloud)  
**Date:** 2026-05-21  
**Evaluator:** Jenny Pavlova  
**Scenarios tested:** 4 (2 flagd application-layer, 2 K8s infrastructure-layer)

---

## Overview

This document summarises findings from four consecutive "Capture the Bug" sessions evaluating the Elastic AI Agent's ability to diagnose injected failures in a live Kubernetes + OpenTelemetry environment. Each session used a real injected fault; the agent was given only a symptom hint and access to Kibana (APM, logs, service map, alerts).

Individual evaluation files:
- [payment-down-evaluation.md](./payment-down-evaluation.md) — `paymentUnreachable = on` (flagd)
- [payment-partial-evaluation.md](./payment-partial-evaluation.md) — `paymentFailure = 50%` (flagd)
- [chaos-env-fail-shipping-evaluation.md](./chaos-env-fail-shipping-evaluation.md) — `QUOTE_ADDR` misconfigured env var (K8s)
- [chaos-pod-fail-productcatalog-evaluation.md](./chaos-pod-fail-productcatalog-evaluation.md) — product-catalog scaled to 0 replicas (K8s)

---

## Scorecard

| Scenario | Type | Service identified | Root cause correct | Fix actionable | Hallucinations |
|---|---|---|---|---|---|
| `payment-down` | flagd | ✅ | ❌ DNS (actual: flag) | ❌ | payment/flagd |
| `payment-partial` | flagd | ✅ | ❌ Gold token (actual: flag) | ❌ | payment/flagd cascade |
| `chaos-env-fail-shipping` | K8s infra | ✅ | ⚠️ Near miss (env var listed) | ❌ Rollback suggested | payment/flagd cascade |
| `chaos-pod-fail-productcatalog` | K8s infra | ⚠️ Turn 3 only | ❌ Bad address (actual: scaled to 0) | ❌ | payment/flagd cascade + stale data |

**Summary: 0 out of 4 incidents resolved correctly. The right service was identified in 3 out of 4 (1 was 2 turns late). The correct fix was never surfaced unprompted.**

---

## What the agent does well

### APM symptom reading
The agent reliably reads APM traces, error rates, and service topology. In every session it correctly identified which upstream service was experiencing errors and mapped the failure chain from user-facing symptoms down to the failing dependency. This is genuinely useful — it gets an engineer pointed at the right service quickly.

### Pivoting on kubectl evidence
When the user provided kubectl output contradicting its hypothesis (e.g. showing the payment endpoint was healthy), the agent updated its working theory rather than doubling down. The direction of the pivot was often still wrong, but the willingness to adjust is correct behaviour.

### Business impact quantification
Incident duration, estimated failed orders, error rate percentages, and alert timelines were consistently well-reasoned and useful for incident communication. These outputs are reliable even when the root cause diagnosis is not.

---

## Failure patterns

### 1. Root cause reasoning stops one step short

The agent reliably identifies *that* something is broken and *where* in the call chain it breaks. It consistently fails to identify *why*.

| Scenario | Agent's conclusion | Actual cause |
|---|---|---|
| `payment-down` | DNS/hostname misconfiguration in checkout | `paymentUnreachable` flagd flag |
| `payment-partial` | Gold loyalty tier token rejected by payment | `paymentFailure = 50%` flagd flag |
| `chaos-env-fail-shipping` | Bad rollout, suggested pod rollback | `QUOTE_ADDR = http://quote-old:8080` env var |
| `chaos-pod-fail-productcatalog` | Misconfigured gRPC address in checkout | `product-catalog` replicas scaled to 0 |

In every case the agent reached for an infrastructure or configuration explanation that required no specific tooling knowledge — DNS, bad credentials, bad addresses — rather than checking the most direct signal first.

### 2. Feature flags are never checked

Two of the four scenarios were controlled by flagd feature flags. In neither case did the agent suggest:
- Checking the flag UI at `http://localhost:8080/feature`
- Querying the flagd evaluation API:
  ```bash
  curl -s -X POST http://localhost:8080/flagservice/flagd.evaluation.v1.Service/ResolveBoolean \
    -H "Content-Type: application/json" \
    -d '{"flagKey": "paymentUnreachable", "context": {}}'
  ```
- Running `./scripts/toggle-flag.sh --status`

Feature flag state should be the first thing checked in an environment that uses them — before DNS, before env vars, before pod restarts.

### 3. Persistent gold loyalty + flagd cascade hallucination

In 3 out of 4 sessions the agent reported:
- Payment failing 44–60% of the time with `Invalid token. app.loyalty.level=gold`
- flagd EventStream latency of 153–15,716ms (varying by session)
- Cascading 28–75% error rates across cart, ad, recommendation, fraud-detection, product-reviews
- 5–10 active latency threshold alerts

**None of this happened in any session.** All payment flags were off. No flagd configuration was changed. The numbers vary between sessions but the structure is identical every time. This is a systematic hallucination, not noise.

This is the most dangerous failure mode evaluated: it generates false urgency with convincing specifics, creating ghost incidents that consume engineering time during a real outage. Any evaluation of the agent should treat gold loyalty / flagd cascade reports as a known false positive until independently verified.

### 4. Prior incident data bleeds into new investigations

In the final session (`chaos-pod-fail-productcatalog`), the reverted shipping scenario (`QUOTE_ADDR = http://quote-old:8080`) continued to appear as the dominant active failure across all three turns, including a fabricated redeployment event ("shipping was redeployed at 13:48 UTC but picked up the same bad config"). The scenario had been fully reverted before the new injection.

The agent has no mechanism to distinguish pre-reset errors from current errors. In a real environment with multiple incidents and rollbacks in a rolling time window, this could cause the agent to anchor on resolved incidents rather than the active one.

### 5. "No APM data = healthy" misread

When `product-catalog` was scaled to 0 replicas, it produced no APM spans — no pods, no instrumentation. The agent read zero throughput + zero errors as a healthy service: *"product-catalog itself is healthy (0% failure rate)"*.

The correct heuristic is the opposite: **a service receiving upstream calls but emitting no APM data is likely down**. The immediate check should be:
```bash
kubectl get deployment product-catalog
# READY 0/0 → scaled to zero

kubectl get pods -l app.kubernetes.io/component=product-catalog
# No resources found → confirmed
```

This misread caused the agent to miss the actual root cause for two full turns and diagnose a secondary symptom (checkout's gRPC call failing) as a misconfigured address.

---

## Recommended improvements

### For the agent

| Priority | Recommendation |
|---|---|
| High | Add feature flag state as a first-pass check when application-layer errors appear — query flagd before investigating DNS or credentials |
| High | Treat "service receives upstream calls but emits zero APM data" as a scaled-to-zero signal, not a health signal — follow up with `kubectl get deployment` |
| High | Validate claimed active issues against a narrow recent time window (last 5 minutes) to avoid bleed-over from prior incidents or resolved faults |
| Medium | When suggesting a fix (pod rollback, env var change), first confirm the hypothesis with a kubectl read before recommending a write |
| Medium | Suppress or flag the gold loyalty / flagd cascade pattern for internal review — it is appearing as a false positive in every session |
| Low | After issuing a fix recommendation, suggest a verification step (e.g. `kubectl get pods`, re-check error rate in APM) |

### For evaluation methodology

- **Use `--infra-only`** when evaluating AI agents on investigation quality. flagd scenarios are documented in the OTel demo docs and may be pattern-matched from training data. K8s-native faults require genuine diagnosis.
- **Run sessions back-to-back** to expose prior-incident bleed-over — this is a realistic production condition and the agent handles it poorly.
- **Always verify agent claims with kubectl** before scoring. The agent produces specific-looking metrics (309s timeouts, exact error counts) that are not always grounded in real data.

---

## Quick reference: correct diagnostic path by scenario type

### flagd application-layer failure
```
1. kubectl get pods              → all Running? → likely not infra
2. toggle-flag.sh --status       → any flag on?
3. curl flagd evaluation API     → confirm flag value
4. toggle-flag.sh <flag> off     → fix
```

### K8s env var misconfiguration
```
1. kubectl get pods              → Running but errors? → check config
2. kubectl get deployment <svc> -o yaml | grep -i addr
3. kubectl logs -l app=<svc>    → DNS resolution error?
4. kubectl set env deployment/<svc> VAR=correct-value
```

### Scaled-to-zero deployment
```
1. APM shows service dark (zero throughput, zero errors)?
2. kubectl get deployment <svc>  → READY 0/0?
3. kubectl get pods -l app=<svc> → No resources found?
4. kubectl scale deployment <svc> --replicas=1
```
