# Agent Response Evaluation — `chaos-dual-ad-recommendation`

**Scenario injected:** `chaos-dual-ad-recommendation` — two independent non-critical-path faults: (1) ad service CPU limit set to `20m` (JVM latency spike on GetAds); (2) recommendation service scaled to `0` replicas (gRPC UNAVAILABLE)  
**Previous scenario reverted:** `chaos-dual-cart-payment`  
**Date:** 2026-05-22  
**Cluster:** `oteldemo-wacts`  
**Mode:** Open-ended investigation (no specific alert, user-driven prompt)

---

## What was actually happening

Two independent faults were active simultaneously, both confined to non-critical product-page decoration services. Checkout and cart were fully working throughout.

**Fault 1 — ad service CPU throttle:**  
`resources.limits.cpu: 20m` was applied to the ad deployment. The JVM cannot process GetAds requests fast enough at this CPU cap — kernel-level throttling causes GetAds call latency to spike from ~10ms to multi-second values. The pod stays `Running` and `Ready`; there are no crashes, no errors in application logs. Only observable via infrastructure CPU metrics and APM latency on the `oteldemo.AdService/GetAds` transaction.

**Fault 2 — recommendation scaled to zero:**  
`replicas: 0` was set on the recommendation deployment. No pods are scheduled. Frontend gRPC calls to `ListRecommendations` hit a service endpoint with no backing pods and fail immediately with `ECONNREFUSED` (gRPC status 14 = UNAVAILABLE). `kubectl get pods -l app.kubernetes.io/component=recommendation` returns nothing.

---

## Session summary

The agent was run twice — once as an open investigation, and once when the user asked specifically about other issues after the initial root cause was declared. This is an important distinction.

**Turn 1 (unprompted investigation):** The agent found the recommendation fault, correctly traced the failure chain, and declared root cause — stopping before finding the ad service fault.

**Turn 2 (user prompted: "any other issues?"):** The agent then found the ad service high latency, correctly attributed it to CPU pressure, and identified it as a separate independent issue.

---

## What the agent got right

**Recommendation fault — strongest evidence quality seen across all sessions:**

- Correctly identified gRPC status 14 = UNAVAILABLE and `ECONNREFUSED` on two distinct pod IPs
- Noted that the two failing IPs (`10.2.89.239`, `10.2.222.121`) correspond to recommendation pod IPs — meaning multiple pods are down
- Compared a successful trace (`f70de9d83027f31cc1db2d65c748678a`: full chain completes) against a failing trace (`ef3f3abf5b69c56cd898e9c27bbc2e5b`: ECONNREFUSED before the pod receives the request)
- Observed that error timestamps were minutes stale — correctly concluded this is a sustained failure, not a transient blip
- Quantified the failure rate: 70% error rate on the frontend → recommendation link, 6.2 rpm attempts vs 1.75 rpm successes

**Ad service fault (after prompting):**

- Correctly identified GetAds latency spike as the signal
- Attributed it to CPU pressure / throttling — the right failure mode
- Correctly noted it as independent from the recommendation issue

**No prior scenario bleed-over** — unlike earlier sessions, no signals from the previous `chaos-dual-cart-payment` scenario contaminated the analysis.

---

## What the agent got wrong

**1. Found one fault, stopped — the scenario's core test**

The agent declared root cause after finding recommendation and did not proactively look for a second independent fault. Only after the user explicitly asked "any other issues?" did it find the ad service problem. In a real on-call scenario with no human prompt, the ad service CPU throttle would have been missed entirely.

**2. Wrong root cause hypothesis for recommendation**

> *"likely in CrashLoopBackOff or being evicted"*

The actual cause is `replicas: 0` — the deployment was intentionally scaled down to zero. No pods exist to crash. The agent's recommended remediation (`kubectl get pods`, `kubectl logs --previous`, `kubectl rollout restart`) would either return empty results or do nothing useful against a zeroed deployment.

The correct investigation path: `kubectl get deployment recommendation` → sees `READY 0/0` → checks `spec.replicas` → finds `0` → `kubectl scale --replicas=1`.  
The incorrect path the agent followed: assumes crash, looks for logs from crashing pods that do not exist.

**3. Breadth check was never run unprompted**

A `kubectl get pods | grep -v Running` across all deployments at the start of the investigation would have surfaced both faults simultaneously — recommendation with no pods and ad pod with CPU at limit (via `kubectl top`). The agent went deep on one APM signal without first establishing the full blast radius.

---

## Scorecard

| Dimension | Result |
|-----------|--------|
| Recommendation fault identified | ✅ |
| Recommendation failure chain traced | ✅ strong — trace-level evidence |
| Recommendation root cause (replicas: 0) | ❌ assumed CrashLoopBackOff |
| Fix for recommendation would work | ❌ rollout restart on 0 replicas does nothing |
| Ad service fault identified unprompted | ❌ |
| Ad service fault identified when asked | ✅ |
| Ad service root cause (CPU throttle) | ✅ |
| Prior scenario bleed-over | ✅ clean |
| Broad pod health sweep before diving into APM | ❌ |

---

## Comparison to previous dual-fault session (`chaos-dual-cart-payment`)

| Dimension | cart+payment | ad+recommendation |
|-----------|-------------|-------------------|
| Failure chain traced | ✅ | ✅ better (trace-level) |
| Fault 1 symptom identified | ✅ | ✅ |
| Fault 1 root cause correct | ❌ | ❌ |
| Fault 1 fix would work | ❌ | ❌ |
| Fault 2 identified unprompted | ❌ | ❌ |
| Fault 2 identified when prompted | n/a | ✅ |
| No bleed-over from prior scenario | ❌ (kafka noise) | ✅ |
| Evidence quality | medium | high |

**Improvement:** Evidence quality and trace analysis are significantly better. Bleed-over eliminated. The agent is getting better at reading the APM data it finds.  
**Persistent gap:** The agent still does not proactively scan for multiple independent faults. It finds the loudest signal and declares root cause. The breadth-first pod health sweep remains missing from the unprompted investigation path.

---

## Key takeaway

The "find one thing and stop" pattern has now appeared in every dual-fault session. The agent is capable of finding the second fault when prompted — which means the signal is there in the data and the agent can read it. The missing behaviour is the habit of asking "is there anything else broken?" before closing the investigation. A structured runbook step ("scan all services for anomalies before declaring root cause") would likely fix this across the board.
