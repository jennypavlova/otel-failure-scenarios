# Agent Response Evaluation — `payment-down` (paymentUnreachable = on)

**Scenario injected:** `payment-down` — flagd flag `paymentUnreachable = on`  
**Date:** 2026-05-21  
**Cluster:** `oteldemo-rkznd`

---

## What the agent got right

**Symptom identification — excellent.** It correctly pinpointed the 100% error rate on the Charge gRPC call, quoted the exact error (`name resolver error: produced zero addresses`), and mapped the failure chain accurately: the problem is isolated to the `checkout → payment` edge, with all other services healthy.

**Pivoting on new evidence — good.** When the user ran `kubectl get endpoints payment` and showed a healthy IP (`10.1.149.34:8080`), the agent correctly abandoned the "pod is down" hypothesis and shifted to a misconfigured hostname theory. That's the right instinct given the evidence.

**Business impact quantification — solid.** First occurrence at 10:07 UTC, ~3h duration, ~121 failed orders, 26.5% checkout failure rate — this is well-reasoned and useful for incident communication.

---

## Where the agent went wrong

**It diagnosed the wrong root cause.** The actual failure is a **flagd feature flag** (`paymentUnreachable = on`) that makes the checkout service simulate an unreachable payment endpoint at the application layer. The payment pod is perfectly healthy and DNS is fine. The agent concluded this was a Kubernetes hostname misconfiguration and sent the user down a dead end:

- Checking `PAYMENT_SERVICE_ADDR` env vars in the checkout deployment
- Testing DNS resolution with `nslookup` from a debug pod
- Suggesting a deployment config change as the fix

None of that would have fixed it. The actual fix is a single command:
```bash
./scripts/toggle-flag.sh paymentUnreachable off
```

**It never checked the feature flag system.** This environment runs flagd — a feature flag service that ships with the OTel demo and is a primary mechanism for injecting failures. The agent never suggested:
```bash
curl -s -X POST http://localhost:8080/flagservice/flagd.evaluation.v1.Service/ResolveBoolean \
  -H "Content-Type: application/json" \
  -d '{"flagKey": "paymentUnreachable", "context": {}}'
```
or simply checking the flag UI at `http://localhost:8080/feature`. A production-grade investigation of "payment is unreachable but the pod has a healthy endpoint" should include checking whether any chaos/feature flag tooling is active.

**The "produced zero addresses" error was taken at face value.** This error typically means DNS can't resolve the hostname — but in this case it's being generated synthetically by the application when the `paymentUnreachable` flag is on. The agent didn't consider that the error itself could be fabricated by application logic rather than reflecting real infrastructure state.

---

## Summary

| Dimension | Score |
|---|---|
| Symptom identification | ✅ Strong |
| Log & APM analysis | ✅ Strong |
| Hypothesis adjustment | ✅ Good |
| Business impact | ✅ Good |
| Root cause (actual) | ❌ Wrong — flagd flag, not DNS/config |
| Time-to-fix | ❌ Would have wasted significant time on env vars and DNS |
| Feature flag awareness | ❌ Never surfaced |

The agent would have kept a real engineer busy for 30–60 minutes before realising the deployment config was clean and circling back to look elsewhere. The missing step was awareness that the environment uses flagd for failure injection — once that's on the checklist, the diagnosis is immediate.
