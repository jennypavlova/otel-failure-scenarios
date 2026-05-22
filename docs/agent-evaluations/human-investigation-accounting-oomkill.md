# Human Investigation Evaluation — Accounting OOMKill + payment-partial

**Investigator:** Jenny Pavlova  
**Injected scenario:** `payment-partial` — `paymentFailure = 50%` (flagd)  
**What was found first:** Pre-existing accounting OOMKill (memory limit 120Mi)  
**What was confirmed later:** payment-partial via manual store testing  
**Date:** 2026-05-21  
**Cluster:** `oteldemo-rkznd`

---

## The twist

The injected scenario was `payment-partial` — a flagd flag causing ~50% of checkout attempts to fail at the payment charge step. All pods healthy, no crashes, no K8s changes.

What the investigator found first was a **separate, pre-existing problem**: the accounting service OOMKilling in a crash loop due to a memory limit of 120Mi being too tight under current throughput. This was a real issue — not a hallucination, not noise — but it was not the injected scenario.

The payment-partial failure was ultimately confirmed through **manual store testing** — placing orders directly in the UI and observing intermittent failures, then tracing them back to APM errors on the payment service. This surfaced a second important finding: **no alert fired for the payment failure**, exposing a gap in the alert ruleset.

---

## Investigation steps — what you did

### Step 1 — Latency alert on accounting → no APM service data
**Starting point: Kibana Alerts page**

Correctly noticed that accounting had a latency alert firing and that the APM service view showed no data. This was a valid and important observation — the absence of APM data pointed to a crashing service rather than a slow one. Good first instinct.

### Step 2 — APM Errors: `23505 duplicate key value violates unique constraint "order_pkey"`
**APM → Services → accounting → Errors**

Found the PostgreSQL duplicate key violation. The culprit being `N/A` and the error message being a DB constraint violation were correctly noted. You were right to dig further rather than stopping here — this didn't look like a root cause, it looked like a symptom.

### Step 3 — Investigated recommendation (Culprit N/A) and ad service (no metrics)
**APM → Services**

You noticed a recommendation error and the ad service appearing disconnected. You then checked the infra tab to investigate further. This was good instinct — checking multiple services to see if the blast radius is wider. In this case both were red herrings (both pods `Running/Ready` with 0 restarts and no injected fault), but the methodology of checking breadth before depth is correct.

**Note from evaluator:** At this point I confirmed the pods were healthy and steered you back to accounting. In hindsight I could have let you make that call yourself from the kubectl output — I nudged slightly too early here.

### Step 4 — PostgreSQL dependency: 36% failed transaction rate with timing correlation
**APM → Services → accounting → Dependencies**

This was the strongest piece of evidence you found. Seeing the PostgreSQL dependency failure rate spike at the same time as the accounting incident confirmed cause and effect — the DB errors were not pre-existing noise, they correlated with the start of the crash loop. This is exactly the kind of cross-signal correlation that separates a good investigation from a shallow one.

### Step 5 — Throughput increase on accounting
**APM → Services → accounting → Transactions**

Noticing that accounting throughput increased before the crash was a sharp observation. Under normal conditions higher throughput = higher memory pressure, which explains why a 120Mi limit that wasn't being breached before suddenly became the ceiling.

### Step 6 — Discover: memory metrics via ES|QL time series
**Discover → ES|QL**

```
TS "metrics-*,metricbeat-*"
| WHERE k8s.pod.uid == "30cea8d8-7dc1-48c6-ac13-c4c299ddf7cf"
```

**What this query does:**
- `TS` is the ES|QL Time Series command (available since 8.15). Unlike a standard `FROM`, `TS` is optimised for metric data — it understands timestamp ordering, fills gaps, and renders as a time series chart rather than a flat table.
- `"metrics-*,metricbeat-*"` targets both the OTel metrics index and any metricbeat indices — casting a wide net across infrastructure metric sources.
- `k8s.pod.uid` is the stable Kubernetes pod identifier (doesn't change on restart within the same pod lifecycle). Filtering by UID rather than pod name means you get metrics scoped to exactly that pod, not any other pods sharing the same deployment name.
- `hideChart:!f, hideTable:!t` in the URL means chart visible, table hidden — you were in pure visualisation mode, which is the right choice for spotting spike + drop patterns.
- The 15-minute time window (15:28–15:43 UTC) was tight around the incident, which made the memory climb and OOMKill crash visible as a clean pattern rather than lost in hours of data.

The memory spike followed immediately by a sharp drop to zero (pod killed) is the definitive OOMKill signature. This was excellent use of Discover as a metrics investigation tool — most people only use Discover for logs.

---

## What was missed

### The actual injected scenario: `payment-partial`

`paymentFailure = 50%` was active the entire time. 50% of all checkout attempts were failing at the payment charge step. This would be visible in:

- **APM → Services → checkoutservice** — error rate spike on `PlaceOrder`
- **APM → Services → paymentservice** — explicit error responses (not connection failures)
- **APM → Service Map** — checkout → payment edge showing errors
- **Kibana Alerts** — the alert page you started from may have had checkout/payment alerts alongside the accounting one

The accounting investigation was thorough and correct — but it consumed the full investigation window. The payment failure, which was the actual injected fault, was never looked at.

### Feature flags were not checked

Neither the flagd UI (`http://localhost:8080/feature`) nor the `toggle-flag.sh --status` command was checked. This is the same gap identified in the AI agent evaluations. In this environment, feature flags are the primary failure injection mechanism and should be part of every investigation checklist.

---

## Evaluation summary

| Step | Quality | Notes |
|---|---|---|
| Alert → no APM data → service down hypothesis | ✅ Excellent | Correct inference from absence of data |
| DB error found, treated as symptom not root cause | ✅ Excellent | Didn't anchor on the first error found |
| Checking recommendation + ad as blast radius | ✅ Good | Right methodology, correctly identified as red herrings |
| PostgreSQL timing correlation | ✅ Excellent | Best piece of evidence — cross-signal confirmation |
| Throughput increase as contributing factor | ✅ Strong | Connected workload change to resource exhaustion |
| Discover ES|QL memory time series | ✅ Excellent | Sophisticated and effective use of the tool |
| Checking feature flags | ❌ Not done | Would have immediately surfaced payment-partial |
| Checking checkout / payment service | ❌ Not done | Actual injected failure not found |
| Root cause conclusion | ⚠️ Real but wrong incident | Correctly diagnosed accounting OOMKill, missed payment-partial |

---

## Key takeaway

You diagnosed a real production issue with rigorous methodology. The accounting OOMKill is a genuine problem that would affect any real cluster running this workload — the memory limit is too tight. But the injected fault (payment-partial) remained invisible because the investigation anchored on the first signal found (accounting alert) and followed it to completion without broadening back out.

**Recommended addition to investigation checklist:**
1. When an alert fires, note the service — but scan all other services for anomalies before diving deep
2. Check feature flag state early (`http://localhost:8080/feature` or `toggle-flag.sh --status`)
3. After diagnosing one issue, always do a final pass: "are there other independent failures active right now?"

---

## Phase 2 — Manual store testing confirms payment-partial

After the accounting investigation, the investigator went directly to **http://localhost:8080** and placed multiple orders. Roughly every other checkout failed — consistent with `paymentFailure = 50%`. The failure was then traced in **APM → Services → payment → Errors**, confirming the error was an explicit payment rejection, not a connection failure.

This is a meaningful finding in itself: the payment failure was only discovered through **user-experience testing**, not through any monitoring or alerting signal.

### Alert gap discovered

Checking the three configured alert rules against the failure pattern:

| Rule | Threshold | Why it didn't fire |
|---|---|---|
| Error count threshold | >5 errors / 5 min | Load generator at 10 users produces ~1–2 payment errors/min — under the threshold |
| Latency threshold | avg >1500ms / 5 min | Failed payments return fast (immediate rejection), so avg latency drops not rises |
| APM Anomaly | Critical severity / 30 min | Too slow for this failure type; may eventually fire but not actionable |

**Missing rule:** a transaction failure rate alert (e.g. >20% of `PlaceOrder` transactions failing over 5 minutes) would have fired within minutes of injection. The current ruleset is latency-biased and has a blind spot for fast, intermittent application-layer rejections.

---

## Evaluator note

I confirmed pod health data one step too early during the recommendation/ad investigation — before the investigator had a chance to reach that conclusion independently. In future sessions I'll hold kubectl confirmations until explicitly asked or until a hypothesis has been stated.

---

## Human vs AI Agent — summary comparison

Across all five AI agent sessions and this human session, a clear picture emerges of where each approach succeeds and where it fails.

The **human investigator** followed evidence methodically through multiple layers (alerts → APM errors → dependencies → infrastructure metrics → UI testing), correctly diagnosed a real pre-existing infrastructure issue end-to-end, and discovered an alert coverage gap that no agent session surfaced — but anchored on the first signal found and didn't broaden back out to catch the injected fault running in parallel.

The **AI agent** consistently identified the right failing service from APM data quickly, but repeatedly stopped one step short of the correct root cause, never checked feature flags proactively across five sessions, and fabricated the same gold loyalty / flagd cascade hallucination in three of five sessions with convincing-looking specifics — the most dangerous failure mode in a real incident.

The human's key advantage is **real-world validation** — placing an order and watching it fail is something no agent did unprompted. The agent's key advantage is **breadth and speed** — it scans more services and signals faster than a human working through a UI, which matters in the first minutes of an incident. The shared gap across both is the same: neither consistently checked feature flags first, which would have resolved two of the five AI sessions and this human session immediately. The most significant concern with the agent is not what it misses but what it invents — fabricated cascades with specific numbers erode trust and create false work, which is harder to recover from than a simple miss.

| Dimension | Human | AI Agent |
|---|---|---|
| APM symptom reading | ✅ Thorough | ✅ Fast |
| Infrastructure metrics (kubectl, CPU/memory) | ✅ Used effectively | ⚠️ Checked but misread |
| Feature flags checked | ❌ Never | ❌ Never |
| UI / real-world validation | ✅ Placed real orders | ❌ Never done |
| Alert gap identification | ✅ Found and explained | ❌ Never surfaced |
| Root cause accuracy | ⚠️ Right issue, wrong incident | ❌ 0/5 fully correct |
| Hallucinated signals | ✅ None | ❌ Persistent (3/5 sessions) |
| Prior incident bleed-over | ✅ Clean | ❌ Affected 2/5 sessions |
| Speed to first hypothesis | 🐢 Slower | ⚡ Faster |
