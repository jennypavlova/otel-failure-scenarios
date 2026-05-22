# Agent Response Evaluation — `chaos-env-fail-shipping`

**Scenario injected:** `chaos-env-fail-shipping` — `QUOTE_ADDR` env var set to `http://quote-old:8080` (decommissioned hostname) in the shipping deployment  
**Previous scenario reverted:** `payment-partial` (paymentFailure = off)  
**Date:** 2026-05-21  
**Cluster:** `oteldemo-rkznd`

---

## What was actually happening

The shipping deployment had its `QUOTE_ADDR` env var patched to `http://quote-old:8080` — a hostname that doesn't exist. Patching an env var triggers a rolling restart, so a new shipping pod (`shipping-d9cbc4c95-ljcfj`) came up `Running/Ready` (health checks pass) but every `/get-quote` request fails because the address is unreachable. The old pod is replaced — there is no "healthy old pod" alongside a "broken new pod." All flagd flags were off. No payment failures. No infrastructure cascade.

Ground truth confirmed via `kubectl`:
```
NAME                       READY   STATUS    RESTARTS
shipping-d9cbc4c95-ljcfj   1/1     Running   0

QUOTE_ADDR = http://quote-old:8080
```

---

## What the agent got right

**Identified the right service.** Shipping is the root cause. The agent correctly mapped the failure chain:
```
checkout → shipping /get-quote → HTTP 400 → PlaceOrder INTERNAL error → HTTP 500
```

**Identified the key insight for this scenario.** "The shipping pod passes Kubernetes health checks, but the application logic is broken" — this is exactly why the scenario is hard: `kubectl get pods` shows `Running/Ready`, misleading anyone who only checks pod status.

**Mentioned the correct root cause as a possibility.** The agent listed "wrong environment variable, missing config, or a broken image" as probable causes. `QUOTE_ADDR = http://quote-old:8080` is a wrong environment variable — so the agent was one step away from the correct diagnosis.

---

## What the agent got wrong

**Framed the scenario as a bad rollout, not a misconfigured env var.** The agent concluded this was "a bad rollout or misconfigured new pod" and recommended rolling back the pod. Rolling back would reintroduce the same broken env var — the rollout itself is not the problem. The correct fix is patching `QUOTE_ADDR` to the right value:
```bash
kubectl set env deployment/shipping QUOTE_ADDR=http://quote-service:8080
```
The agent surfaced the right hypothesis (wrong env var) but didn't commit to it or validate it with:
```bash
kubectl get deployment shipping -o yaml | grep QUOTE_ADDR
```

**Invented the gold loyalty / payment failure — again.** For the third incident in a row, the agent reported `paymentFailure` errors attributed to gold-tier loyalty customers (~19 errors, 50% payment failure rate). The `paymentFailure` flag was explicitly turned off before this scenario was injected. This is the same hallucination appearing across all three evaluations — it is a persistent and systematic false positive.

**Invented the flagd latency cascade — again.** The agent reported flagd at 15,716ms average latency, with EventStream timeouts of 309 seconds across cart, ad, recommendation, fraud-detection, and product-reviews. This did not happen. No flagd changes were made. This is identical to the fabricated cascade in the `payment-partial` evaluation (Turn 1), down to the same 309-second figure.

---

## Summary

| Dimension | Score |
|---|---|
| Identifying the broken service (shipping) | ✅ Correct |
| Failure chain mapping | ✅ Correct |
| Key insight (healthy pod, broken app logic) | ✅ Correct |
| Root cause (bad env var vs. bad rollout) | ⚠️ Close but wrong direction |
| Suggested fix | ❌ Rollback won't work; env var patch needed |
| Payment / gold loyalty errors | ❌ Fabricated — flags were off |
| flagd latency cascade | ❌ Fabricated — same hallucination as prior run |

---

## Patterns across all three evaluations

| Pattern | payment-down | payment-partial | chaos-env-fail-shipping |
|---|---|---|---|
| Correct service identified | ✅ | ✅ | ✅ |
| Root cause correct | ❌ DNS | ❌ Gold token | ⚠️ Near miss (env var mentioned) |
| Fabricated gold loyalty errors | — | ❌ | ❌ |
| Fabricated flagd cascade | — | ❌ | ❌ |
| Feature flags checked proactively | ❌ | ❌ | ❌ |

### Conclusions

1. **APM symptom reading is reliable.** The agent consistently identifies the right failing service and failure chain from traces and logs.

2. **Root cause reasoning is unreliable.** It stops one step short of the actual fix — close enough to point an engineer in the right direction, but not close enough to resolve the incident without further manual investigation.

3. **The gold loyalty + flagd cascade is a recurring hallucination.** It appeared in two of three incidents with specific metrics (309s timeouts, 80% error rates) despite neither being caused by flagd. This is the highest-risk failure mode: fabricated urgency with convincing numbers that could trigger unnecessary escalations or mask the real issue.

4. **Feature flags are never checked proactively.** Two of three incidents were flagd-controlled. The agent found the right answer for the infra scenario by accident (env var listed as a possible cause) — but it has never once suggested checking the flagd UI or API as a first step.
