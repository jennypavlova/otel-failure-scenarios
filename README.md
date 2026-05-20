# OTel Failure Scenarios

Provision the [OpenTelemetry Astronomy Shop](https://github.com/open-telemetry/opentelemetry-demo) running on a GKE Autopilot cluster and sending data to an Elastic Cloud (ESS) cluster. Trigger failure scenarios via flagd (application-layer flags), realistic K8s-native faults (bad deployments, config changes, resource limits), or [Chaos Mesh](https://chaos-mesh.org/) (scheduled infrastructure experiments) — then analyse the results in Kibana.

> This project was designed based on guidance from the [Elastic Observability Test Environments — OpenTelemetry Quick Start](https://studious-disco-k66oojq.pages.github.io/user-guide/opentelemetry-quick-start/#create-a-opentelemetry-demo-cluster).

![OTel Demo Overview](assets/overview.png)

---

## Use cases

- **Replicate customer problems** — spin up a clean environment to reproduce and test solutions to real-world issues
- **Demo videos** — a stable, realistic microservices app with live telemetry flowing into Kibana, ready to record
- **Capture the Bug sessions** — inject random failures and benchmark how well Kibana (or an AI agent) can find and explain them

---

## Architecture

```mermaid
flowchart LR
  subgraph local [Local Machine]
    Browser
    kubectl
    gcloud
    Agent["AI Agent"]
  end

  subgraph gcp [GCP / us-central1]
    subgraph gke [GKE Autopilot Cluster]
      Shop["OTel Astronomy Shop\n17 microservices"]
      Flagd["flagd"]
      ChaosMesh["Chaos Mesh"]
      OtelCol["OTel Collectors"]
    end

    subgraph elasticcloud ["Elastic Cloud (managed by Elastic)"]
      ES["Elasticsearch"]
      Kibana["Kibana"]
      Kibana --- ES
    end
  end

  Shop -->|OTLP| OtelCol
  Flagd -->|OTLP| OtelCol
  OtelCol -->|"traces, metrics, logs"| ES

  Browser -->|"localhost:8080 (port-forward)"| Shop
  Browser -->|"localhost:8080/feature (port-forward)"| Flagd
  Browser -->|"localhost:2333 (port-forward)"| ChaosMesh
  Browser -->|"direct URL"| Kibana
  kubectl -->|"get / logs / apply"| gke
  gcloud -->|"clusters / nodes"| gcp
  Agent -->|"ES QL / REST"| ES
  Agent -->|"Kibana API"| Kibana
```

---

## AI Agent Integration

This repo includes [Elastic Agent Skills](https://github.com/elastic/agent-skills) for AI coding agents (Cursor, GitHub Copilot, Windsurf, and more). When you run `./scripts/init-cluster.sh`, your agent can query the live cluster directly — no manual credential setup needed. See [docs/ai-agent-integration.md](docs/ai-agent-integration.md) for the full list of installed skills.

---

## Why this over running the OTel demo locally?

- **Cloud-hosted infrastructure** — your laptop will struggle to run a 20-service Kubernetes cluster under load; GKE Autopilot scales automatically
- **Realistic K8s-native infrastructure faults** — inject failures that look like real production incidents (misconfigured resource limits, NetworkPolicy mistakes, Service selector mismatches); the flagd scenarios are in the OTel demo docs and likely in model training data, so agents can identify them by name without actually diagnosing anything
- **Real GCP infrastructure** — inspect nodes, pods, and networking in the GCP console or with `gcloud`, not just in a local Docker environment
- **Full `kubectl` access** — manage deployments, inspect logs, and apply manifests against a real cluster just as you would in production

---

## Table of Contents

- [Use cases](#use-cases)
- [Architecture](#architecture)
- [AI Agent Integration](docs/ai-agent-integration.md)
- [Prerequisites](#prerequisites)
  - [Installing oblt-cli](#installing-oblt-cli)
- [Create the Cluster](#create-the-cluster)
- [Access the Demo](#access-the-demo)
- [Validating the Cluster in GCP](#validating-the-cluster-in-gcp)
- [Managing the Kubernetes Infrastructure](#managing-the-kubernetes-infrastructure)
- [Triggering Failure Scenarios](#triggering-failure-scenarios)
  - [Method 1: flagd — controlled failures](#method-1-flagd--controlled-failures)
  - [Method 2: Capture the Bug — random injection](#method-2-capture-the-bug--random-injection)
  - [Method 3: Chaos Mesh — scheduled infrastructure experiments](#method-3-chaos-mesh--scheduled-infrastructure-experiments)
- [Failure Scenario Catalogue](docs/failure-scenarios.md)
- [FAQ](#faq)
- [Cluster Management](#cluster-management)

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| [`gh`](https://cli.github.com/) | GitHub CLI — required for oblt-cli authentication |
| [`oblt-cli`](#installing-oblt-cli) | Provisions clusters and retrieves credentials |
| [`kubectl`](https://kubernetes.io/docs/tasks/tools/) | Manage the GKE cluster |
| [`jq`](https://jqlang.org/download/) | Used by `scripts/toggle-flag.sh` |

---

### Installing oblt-cli

#### Step 1 — Install GitHub CLI and authenticate

```bash
brew install gh
gh auth login
gh auth status
```

#### Step 2 — Tap and install

```bash
export HOMEBREW_GITHUB_API_TOKEN=$(gh auth token)
brew tap elastic/oblt-cli
brew install elastic/oblt-cli/oblt-cli
```

Verify:

```bash
oblt-cli --help
```

#### Step 3 — Configure (HTTP mode)

```bash
oblt-cli configure --slack-channel=@<slack_member_id> --username=<github_username> --git-http-mode
```

> **Finding your Slack member ID:** Slack profile → `⋮` menu → **Copy member ID**. It looks like `UJZTUC4HZ` — not your display name.

---

## Create the Cluster

One command creates everything:
- An ESS cluster with **Elasticsearch and Kibana**
- A **GKE Autopilot Kubernetes cluster** with the OpenTelemetry demo pre-deployed and sending telemetry to that ESS cluster

Copy the example config and set your stack version:

```bash
cp .env.example .env
# edit .env to change STACK_VERSION if needed
```

Then create the cluster:

```bash
source .env
oblt-cli cluster create custom \
  --template oteldemo \
  --parameter StackVersion=${STACK_VERSION} \
  --parameter Template=observability
```

> The `observability` template deploys both Elasticsearch and Kibana. If you only need an Elasticsearch cluster without Kibana, use `--parameter Template=elasticsearch` instead.

A CI job runs (~5 minutes). When complete, **`oblt-robot-ci` sends you a Slack DM** containing:

- **Kibana URL** — open this directly in your browser to start analysing data
- **Elasticsearch URL**
- **Username and password** for Kibana login
- Your cluster name (e.g. `oteldemo-ullxj`)

### Once you have your cluster name — run these steps in order

**1. Initialise the cluster**

Pass your cluster name to `init-cluster.sh` — it configures `kubectl`, resets all failure flags to off, fixes the load generator, patches the OTel Collector to add Kubernetes resource attributes to traces, retrieves your Elastic credentials into `.env`, and starts the port-forwards automatically:

```bash
./scripts/init-cluster.sh <your-cluster-name>
```

This leaves your terminal free. Port-forwards run in the background.

> The credentials saved to `.env` (Kibana URL, Elasticsearch URL, username, password, API key) are picked up automatically by the [Elastic Agent Skills](#ai-agent-integration), so your AI agent can query latency, error rates, logs, and service health directly against the live cluster.

> **OTel Collector patch:** The upstream `oteldemo` template omits `k8sattributes` from the daemon collector's APM pipelines, so `k8s.pod.name`, `k8s.node.name`, `k8s.namespace.name`, and `container.id` are absent from all trace documents — breaking infrastructure correlation in Kibana. `init-cluster.sh` detects this and patches the `opentelemetry-kube-stack-daemon` CRD automatically. Once the upstream template is fixed, the check becomes a no-op.

**2. Open the demo**

| URL | Description |
|-----|-------------|
| [http://localhost:8080](http://localhost:8080) | Astronomy Shop web store |
| [http://localhost:8080/feature](http://localhost:8080/feature) | flagd feature flag UI |
| [http://localhost:8080/loadgen](http://localhost:8080/loadgen) | Load generator UI |
| [http://localhost:8080/jaeger/ui](http://localhost:8080/jaeger/ui) | Jaeger trace UI |
| [http://localhost:2333](http://localhost:2333) | Chaos Mesh dashboard |

> If you ever lose access (e.g. after a laptop sleep), restart the port-forwards:
> ```bash
> ./scripts/start-demo.sh
> ```

You can retrieve credentials at any time with:

```bash
oblt-cli cluster secrets credentials --cluster-name <your-cluster-name>
```

### Destroy the cluster

When you're done, tear everything down (GKE cluster + ESS deployment) with:

```bash
oblt-cli cluster destroy --cluster-name <your-cluster-name>
```

> This requires an interactive terminal — type `yes` when prompted. You'll get a Slack DM when teardown is complete (~5 minutes). See [Cluster Management](#cluster-management) for more cluster commands.

---

## Access the Demo

### Kibana — direct URL from Slack

Open the Kibana URL from the Slack message directly in your browser. No port-forwarding needed. Log in with the credentials provided.

Go to **Observability** to see traces, metrics, and logs from the OTel demo flowing in.

### OTel Astronomy Shop — localhost via port-forward

The demo web app has no external IP. `init-cluster.sh` starts the port-forward automatically. If you need to manage it manually:

```bash
./scripts/start-demo.sh           # Start all port-forwards (idempotent)
./scripts/start-demo.sh --status  # Check whether they are running
./scripts/start-demo.sh --stop    # Stop all demo port-forwards
```

---

## Validating the Cluster in GCP

The `oteldemo` clusters run on GKE Autopilot in the `elastic-observability` GCP project. You can use the `gcloud` CLI to confirm your cluster exists and inspect its GCP-level configuration.

### Prerequisites

```bash
# Install gcloud if needed
brew install --cask google-cloud-sdk

# Switch to your Elastic account
gcloud config set account <your-email>@elastic.co
```

### Find your cluster

```bash
gcloud container clusters list --project elastic-observability | grep oteldemo
```

You'll see your cluster alongside any others currently running in the shared project:

```
NAME                   LOCATION     MASTER_VERSION       STATUS
oteldemo-ullxj         us-central1  1.34.4-gke.1193000   RUNNING
```

### Inspect cluster details

```bash
gcloud container clusters describe <cluster-name> \
  --project elastic-observability \
  --region us-central1
```

This shows node pool configuration, machine types, autoscaling settings, and GCP-level networking — things not visible via `kubectl`.

---

## Managing the Kubernetes Infrastructure

Once `kubectl` is configured (via `oblt-cli cluster k8s`), you have full access to inspect and modify every workload in the cluster.

![kubectl get deployments](assets/kubectl-deployments.png)

### Useful commands

```bash
# List all deployments and their status
kubectl get deployments

# List all running pods
kubectl get pods

# Describe a specific deployment (resource limits, env vars, events)
kubectl describe deployment frontend

# Scale a deployment up or down
kubectl scale deployment recommendation --replicas=0

# Restart a deployment (triggers a rolling restart)
kubectl rollout restart deployment/payment

# Edit a deployment's environment variables inline
kubectl set env deployment/load-generator LOCUST_USERS=5

# View logs for a service
kubectl logs -l app.kubernetes.io/component=checkout --tail=50 -f

# Get a shell inside a running container
kubectl exec -it deploy/frontend -- sh
```

> All commands operate against the namespace set in your current `kubectl` context. Run `kubectl config view --minify -o jsonpath='{..namespace}'` to confirm which namespace you're targeting.

---

## Triggering Failure Scenarios

There are two main ways to trigger failures, plus an optional infrastructure-level layer via Chaos Mesh.

---

### Checking and resetting the environment

Before injecting anything — or if the demo looks unhealthy — run this to see the full picture:

```bash
./scripts/inject-failure.sh --check
```

This checks both K8s-native faults and flagd flags in one shot, regardless of whether they were set via script or the browser UI.

To clear everything and return to a clean state:

```bash
./scripts/inject-failure.sh --reset-all
```

---

### Method 1: flagd — controlled failures

The OpenTelemetry demo ships with [flagd](https://flagd.dev), a feature flagging system that lets you toggle failure scenarios on and off in real time. This is the primary mechanism for injecting application-level faults — things like payment errors, cart failures, memory leaks, and latency injections.

#### Option A — Browser UI

The easiest way to toggle flags manually. No terminal needed.

1. Ensure the port-forward is running (`./scripts/start-demo.sh`)
2. Open [http://localhost:8080/feature](http://localhost:8080/feature)
3. Toggle flags using **Basic View** (on/off) or **Advanced View** (raw JSON)
4. Changes take effect immediately — no restart needed

#### Option B — Command line (`toggle-flag.sh`)

Use `toggle-flag.sh` to set a specific flag from the terminal. It patches the flagd ConfigMap and restarts the pod automatically.

```bash
# Turn a flag on
./scripts/toggle-flag.sh paymentFailure on

# Turn it off
./scripts/toggle-flag.sh paymentFailure off

# Set a specific variant (for flags with multiple levels)
./scripts/toggle-flag.sh paymentFailure on --variant="50%"
./scripts/toggle-flag.sh emailMemoryLeak on --variant="100x"
./scripts/toggle-flag.sh imageSlowLoad on --variant="5sec"
```

Check which flags are currently active (catches flags set via the UI too):

```bash
./scripts/toggle-flag.sh --status
```

> **Note:** flagd copies its ConfigMap to a local volume on startup and doesn't watch for changes — a pod restart is required after each change. `toggle-flag.sh` handles this automatically. See [upstream issue #1953](https://github.com/open-telemetry/opentelemetry-demo/issues/1953).

You can also verify the live state of any flag directly via the flagd API:

```bash
curl -s -X POST http://localhost:8080/flagservice/flagd.evaluation.v1.Service/ResolveBoolean \
  -H "Content-Type: application/json" \
  -d '{"flagKey": "productCatalogFailure", "context": {}}'
```

---

### Method 2: Capture the Bug — random injection

`inject-failure.sh` is designed for **guided demo sessions** where a participant investigates a live failure in Kibana without being told what went wrong. The operator injects a random scenario from a unified pool of **flagd (application-layer)** and **K8s-native (infrastructure-layer)** failures; the participant finds it.

> **GCP cost note:** Scenarios that cause sustained CPU spikes, memory leaks, or traffic floods (`emailMemoryLeak`, `loadGeneratorFloodHomepage`, `recommendationCacheFailure`, `adHighCpu`, `failedReadinessProbe`) are intentionally excluded from the random pool. Use `toggle-flag.sh` directly if you need them. K8s-native faults persist until explicitly reverted with `--revert`.

#### Typical session flow

```bash
./scripts/inject-failure.sh          # 1. inject a random failure (operator sees which one)
./scripts/inject-failure.sh --status # 2. check the symptom hint (safe to share with participant)
./scripts/inject-failure.sh --reveal # 3. reveal the full answer + Kibana path
./scripts/inject-failure.sh --revert # 4. reset the demo (always shows what was active)
```

Use `--quiet` to hide which scenario was triggered from everyone, including yourself:

```bash
./scripts/inject-failure.sh --quiet
```

---

#### All commands

```bash
./scripts/inject-failure.sh                             # Random injection (operator sees the scenario)
./scripts/inject-failure.sh --quiet                     # Random injection, scenario hidden from everyone
./scripts/inject-failure.sh --infra-only                # Random infrastructure scenario only (excludes flagd)
./scripts/inject-failure.sh --quiet --infra-only        # Quiet + infrastructure only
./scripts/inject-failure.sh --scenario=<id>             # Inject a specific scenario by ID
./scripts/inject-failure.sh --preview                   # Preview a random scenario without triggering it
./scripts/inject-failure.sh --preview --infra-only      # Preview a random infrastructure scenario
./scripts/inject-failure.sh --preview --scenario=<id>   # Preview a specific scenario
./scripts/inject-failure.sh --status                    # Show a vague symptom hint (safe to share)
./scripts/inject-failure.sh --check                     # Full health check: k8s state + all live flagd flags
./scripts/inject-failure.sh --reveal                    # Reveal the full answer + Kibana path
./scripts/inject-failure.sh --revert                    # Reset the active k8s/flagd fault, reveal what was active
./scripts/inject-failure.sh --reset-all                 # Clear everything — k8s fault + all non-off flagd flags
./scripts/inject-failure.sh --list                      # List all available scenarios
./scripts/inject-failure.sh --list --infra-only         # List only infrastructure scenarios
```

#### Testing AI agents — use `--infra-only`

When using this demo to evaluate AI agents (e.g. Kibana AI Assistant, Elastic Agent), use `--infra-only` to restrict the random pool to **K8s-native infrastructure failures only**:

```bash
./scripts/inject-failure.sh --infra-only
```

flagd failures are well-documented in the official OpenTelemetry Demo documentation and are likely to be in an AI model's training data — the agent may recognise symptoms by name. K8s-native faults (misconfigured resource limits, NetworkPolicy blocks, Service selector mismatches) look like real production incidents and require genuine diagnosis using `kubectl`, APM, and Infrastructure metrics — not pattern matching against documentation.

#### Available scenarios

**flagd — application-layer failures**

| ID | What breaks | Observable in Kibana |
|----|-------------|----------------------|
| `payment-partial` | ~50% of checkouts fail | APM → checkoutservice error rate spike |
| `payment-down` | Checkout cannot reach payment service | APM → Service Map broken edge |
| `cart-errors` | Cart empty fails on every checkout | APM → cartservice 100% error rate |
| `product-missing` | One product returns errors | APM → productcatalogservice GetProduct errors |
| `ad-errors` | Intermittent ad service errors | APM → adservice error rate |
| `llm-rate-limit` | AI reviews intermittently fail with 429 | APM → llmservice errors |
| `image-slow` | Product images take 5s to load | APM → frontend latency increase |
| `kafka-lag` | Backend processing falls behind | APM → consumer lag, downstream latency |

**K8s-native — realistic infrastructure failures**

| ID | Root cause | Realistic story | Observable in Kibana |
|----|------------|-----------------|----------------------|
| `chaos-pod-fail-recommendation` | `recommendation` deployment scaled to 0 replicas | Auto-scaling cost-review script zeroed replicas; GitOps PR approved without noticing | APM → recommendation dark (no throughput), product pages timeout |
| `chaos-pod-fail-cart` | `VALKEY_ADDR` env var set to wrong Redis hostname | Cache-migration PR pointed cart at a non-existent Redis instance | kubectl → cart in CrashLoopBackOff, startup crash: "Wasn't able to connect to redis" |
| `chaos-net-delay-checkout` | CPU limit `2m` added to checkout | VPA rightsizing tool sampled during quiet window; PR approved without understanding millicores | APM → checkout latency spike, error rate flat; `kubectl top` shows CPU throttled |
| `chaos-net-loss-payment` | Memory limit lowered to `25Mi` | Memory-audit PR set limit below Node.js runtime overhead | kubectl → payment pod OOMKilled repeatedly, bursty payment errors in APM |
| `chaos-cpu-stress-frontend` | CPU limit `5m` added to frontend | Platform script had unit conversion bug — wrote `5m` instead of `500m` | APM → all frontend transactions uniformly slower; `kubectl top` shows CPU at limit |

The active scenario is saved to `.failure-state` (gitignored) so it persists across terminal sessions. Running `--revert` always tells you what was active, even if the session was started by someone else.

---

#### Checking for active failures and clearing everything

Use these two commands any time — they cover **both** K8s-native faults and flagd flags, regardless of whether they were set via the script, the browser UI, or `toggle-flag.sh` directly:

```bash
# See exactly what's active right now
./scripts/inject-failure.sh --check

# Clear everything in one shot (k8s fault + all non-off flagd flags)
./scripts/inject-failure.sh --reset-all
```

`--check` shows the K8s state file and all live flagd flag variants side by side. `--reset-all` is safe to run at any time — it tells you what it cleared, or confirms nothing needed clearing.

---

### Method 3: Chaos Mesh — scheduled infrastructure experiments

Chaos Mesh injects infrastructure-level faults — network latency, pod kills, memory pressure, IO errors — on a repeating schedule. These are separate from the Capture the Bug pool and are applied manually.

#### Access the Chaos Mesh UI

`start-demo.sh` starts the Chaos Mesh port-forward automatically alongside the shop. If you need to start it manually:

```bash
./scripts/start-demo.sh           # starts both forwards (idempotent)
./scripts/start-demo.sh --status  # check if they are running
```

Open [http://localhost:2333](http://localhost:2333) and create experiments via the UI.

Get your current namespace if you need it for manual `kubectl` commands:

```bash
kubectl config view --minify -o jsonpath='{..namespace}'
```

> **Warning:** Some experiments can destabilise the cluster. Target only the specific pods you intend to affect.

#### Apply a pre-built manifest

Pre-built experiment manifests are in `chaos-mesh/`. Replace `MY_NAMESPACE` with your cluster namespace before applying.

| Manifest | Effect |
|----------|--------|
| `chaos-mesh/network-delay-frontend.yaml` | 60ms latency on frontend every 5 min for 90s |
| `chaos-mesh/pod-kill-frontend.yaml` | Kill frontend pod every 5 min |
| `chaos-mesh/memory-stress-adservice.yaml` | Memory pressure on adservice every 5 min for 90s |
| `chaos-mesh/io-error-frontend.yaml` | 99% IO fault rate on frontend every 2 min for 90s |

```bash
# Apply
kubectl apply -f chaos-mesh/network-delay-frontend.yaml

# Remove
kubectl delete -f chaos-mesh/network-delay-frontend.yaml
```

---

## Failure Scenario Catalogue

Full details for every scenario — flagd flags (variants, affected services, Kibana paths, toggle commands) and K8s-native faults (kubectl investigation steps, root cause, revert procedure) — are in **[docs/failure-scenarios.md](docs/failure-scenarios.md)**.


## FAQ

**Q: How do I check if any failures are currently active?**

Run this one command — it checks both K8s-native faults and flagd flags in one shot, regardless of how they were triggered (script, browser UI, or direct `kubectl`):

```bash
./scripts/inject-failure.sh --check
```

---

**Q: Something looks broken in the demo. How do I reset everything to a clean state?**

```bash
./scripts/inject-failure.sh --reset-all
```

This reverts any active K8s fault (scaled deployments, bad env vars, CPU/memory limits) and resets every flagd flag back to `off`. Safe to run at any time — it reports what it cleared, or confirms nothing needed clearing.

---

**Q: I turned on a flagd flag via the browser UI at `localhost:8080/feature`. How do I turn it off?**

Either toggle it off in the same UI, or run:

```bash
./scripts/toggle-flag.sh --status          # see what's on
./scripts/toggle-flag.sh paymentFailure off  # turn off a specific flag
./scripts/inject-failure.sh --reset-all    # turn off everything at once
```

The browser UI and the scripts both write to the same ConfigMap — they are interchangeable.

---

**Q: The demo website (`localhost:8080`) isn't loading or is behaving strangely. Where do I start?**

First check whether a failure was left active:

```bash
./scripts/inject-failure.sh --check
```

If something is active, clear it:

```bash
./scripts/inject-failure.sh --reset-all
```

If the site is still broken after a reset, the port-forward may have dropped. Restart it:

```bash
./scripts/start-demo.sh
```

If pods are crashing, check overall cluster health:

```bash
kubectl get pods          # look for CrashLoopBackOff, Error, OOMKilled
kubectl get deployments   # look for 0/1 READY
```

---

**Q: What's the difference between `--revert` and `--reset-all`?**

| Command | What it does |
|---------|-------------|
| `--revert` | Reverts the single scenario that was injected via `inject-failure.sh`, then reveals what it was. Won't touch flags set via the browser UI or `toggle-flag.sh` directly. |
| `--reset-all` | Clears everything — the k8s state file AND every non-off flagd flag, regardless of how they were set. Use this when you're not sure what's active. |

---

**Q: I injected a scenario but I've forgotten which one. How do I find out?**

```bash
./scripts/inject-failure.sh --status   # vague symptom hint (safe to share with a participant)
./scripts/inject-failure.sh --reveal   # full answer + root cause + Kibana path
```

---

**Q: Can I inject a specific failure rather than a random one?**

Yes. List the available scenarios and pick one by ID:

```bash
./scripts/inject-failure.sh --list
./scripts/inject-failure.sh --scenario=chaos-net-loss-payment
```

---

**Q: The demo was working yesterday but now `localhost:8080` is timing out. Nothing is shown as active.**

The port-forward process dies when your laptop sleeps or the terminal is closed. Restart it:

```bash
./scripts/start-demo.sh
```

Check it's running:

```bash
./scripts/start-demo.sh --status
```

---

**Q: How do I tell whether I'm looking at a flagd failure or a K8s infrastructure failure?**

- **flagd failures** are application-layer — the pods are all Running/Ready, errors come from the app logic. Check with `./scripts/toggle-flag.sh --status`.
- **K8s failures** affect infrastructure — pods may be in `CrashLoopBackOff`, `OOMKilled`, or scaled to 0. Check with `kubectl get pods` and `kubectl get deployments`.
- Run `./scripts/inject-failure.sh --check` to see both at once.

---

## Cluster Management

### Retrieve credentials

If you need to log back into Kibana or Elasticsearch, fetch your credentials at any time:

```bash
oblt-cli cluster secrets credentials --cluster-name <cluster-name>
```

### Retrieve Kibana config

Downloads a sample `kibana.yml` pre-configured for your cluster — useful if you want to run a local Kibana instance pointing at the ESS deployment:

```bash
oblt-cli cluster secrets kibana-config --cluster-name <cluster-name>
```

### Destroy the cluster

Tears down both the GKE Kubernetes cluster and the ESS (Elasticsearch + Kibana) deployment. You'll get a Slack DM when it's done (~5 minutes).

```bash
oblt-cli cluster destroy --cluster-name <cluster-name>
```

> `oblt-cli` requires an interactive terminal for the confirmation prompt — it cannot be piped. Type `yes` when asked.

You can also use the helper script (which prompts for confirmation first):

```bash
./scripts/teardown.sh <cluster-name>
```

---

## Reference

- [OpenTelemetry Demo documentation](https://opentelemetry.io/docs/demo/)
- [Feature flag reference](https://opentelemetry.io/docs/demo/feature-flags/)
- [Recommendation cache failure walkthrough](https://opentelemetry.io/docs/demo/feature-flags/recommendation-cache/)
- [oblt-cli internal docs](https://studious-disco-k66oojq.pages.github.io/tools/oblt-cli/)
- [oblt failure scenarios internal docs](https://studious-disco-k66oojq.pages.github.io/opentelemetry/failure-scenarios/)
- [Chaos Mesh documentation](https://chaos-mesh.org/docs/)
