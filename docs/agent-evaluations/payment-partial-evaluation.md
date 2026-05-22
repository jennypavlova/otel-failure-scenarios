# Agent Response Evaluation — `payment-partial` (paymentFailure = 50%)

**Scenario injected:** `payment-partial` — flagd flag `paymentFailure = 50%`  
**Previous scenario reverted:** `payment-down` (paymentUnreachable = off)  
**Date:** 2026-05-21  
**Cluster:** `oteldemo-rkznd`

---

## What was actually happening

- `payment-down` was cleanly reverted before this conversation started — `paymentUnreachable = off`
- `payment-partial` was then injected — `paymentFailure = 50%`, causing ~50% of all checkout attempts to fail at the payment charge step regardless of customer type
- No infrastructure changes, no flagd latency issues, no DNS problems

---

## Turn 1: "Is the issue resolved now? Are there any other issues still ongoing?"

### What the agent got right

- Correctly noticed that payment service was now receiving *some* traffic (it was receiving zero during `payment-down`), which is a real signal that something changed
- Correctly identified that checkout was still experiencing failures — because a new failure had just been injected

### What the agent got wrong

**It declared the DNS issue still unresolved.** The `payment-down` flag was off. The "DNS misconfiguration" was never a real infrastructure problem to begin with — it was a flagd flag. The agent carried over its wrong root cause from the previous incident and reported it as still active.

**It invented a "flagd severe latency" crisis.** The agent reported flagd responding at 153–414 seconds, cascading into cart, ad, recommendation, and fraud-detection with error rates of 28–75%, and 10 active latency alerts. None of this was caused by the injected scenario. This appears to be a hallucination or severe misreading of stale/noisy data. No infrastructure changes were made between incidents.

**It mischaracterised the 50% failure as gold-loyalty-specific.** The `paymentFailure = 50%` flag fails ~50% of *all* checkout attempts randomly. The agent attributed it to "gold-tier loyalty customers being rejected" with error `Invalid token. app.loyalty.level=gold`. Even if that error string appeared in some logs, the underlying cause is a blanket 50% failure rate — not a loyalty-tier targeting issue.

---

## Turn 2: "Can you check again?"

### What the agent got right

- Correctly marked Issue #1 (the "DNS" error) as resolved — consistent with the revert having completed
- Correctly identified that ~44–50% of payment attempts are still failing — directly matches `paymentFailure = 50%`
- Correctly identified flagd as involved ("almost certainly traces back to a bad feature flag value in flagd") — this is directionally right, even though the reasoning is wrong

### What the agent got wrong

**Still attributing the failure to gold-tier customers specifically.** The agent doubled down: "Gold-tier loyalty customers are being rejected at the payment step." The real failure is random 50% rejection across all customers. An engineer following this diagnosis would waste time investigating loyalty tier logic and token validation rather than the flag itself.

**The suggested fix is wrong.** It recommended:
```bash
kubectl logs -l app=flagd --tail=100 | grep -i gold
kubectl get configmap flagd-config -o yaml | grep -i gold
```
These commands will either return nothing useful or show normal config. The correct fix is:
```bash
./scripts/toggle-flag.sh paymentFailure off
# or simply visit http://localhost:8080/feature and toggle it off
```

**The 5 remaining alerts are misdiagnosed.** The agent attributes checkout/accounting/load-generator latency to downstream symptoms of the gold token issue. These are more likely residual noise from the previous incident or normal load variation — not caused by a gold-specific token bug.

---

## Summary

| Dimension | Turn 1 | Turn 2 |
|---|---|---|
| Detecting that a new failure is active | ✅ Yes | ✅ Yes |
| Correctly closing out prior incident | ❌ Said DNS still broken | ✅ Correctly marked resolved |
| Root cause of 50% failure | ❌ Gold loyalty token | ❌ Gold loyalty token |
| Flagd as the source | ❌ Missed (blamed DNS) | ✅ Directionally correct |
| Invented issues | ❌ Fabricated flagd latency cascade | ✅ No new fabrications |
| Suggested fix | ❌ Would not work | ❌ Wrong kubectl commands |
| Actual fix surfaced | ❌ Never mentioned | ❌ Never mentioned |

### Key patterns across both evaluations

1. **Carries forward wrong hypotheses.** Errors diagnosed in one incident bleed into the next. The agent never cleanly closed out the DNS theory.
2. **Never checks feature flags proactively.** In both incidents the root cause was a flagd flag. The agent never suggested checking the flag UI or the flagd API — it only mentioned flagd after being handed strong evidence pointing there.
3. **Invents corroborating signals.** In Turn 1 the agent fabricated a flagd latency cascade with specific numbers and 10 alerts. This is the most dangerous failure mode — it creates false urgency and could send an engineer chasing ghosts.
4. **Symptom → root cause jump is too fast.** The agent correctly reads APM data but jumps to infrastructure conclusions (DNS, hostname, token validation) without ruling out application-layer controls like feature flags first.
