# OTel Failure Scenarios

Provision the [OpenTelemetry Astronomy Shop](https://github.com/open-telemetry/opentelemetry-demo) running on a GKE Autopilot cluster and sending data to an Elastic Cloud (ESS) cluster. Trigger failure scenarios via flagd or [Chaos Mesh](https://chaos-mesh.org/), then analyse the results in Kibana.

> This project was designed based on guidance from the [Elastic Observability Test Environments — OpenTelemetry Quick Start](https://studious-disco-k66oojq.pages.github.io/user-guide/opentelemetry-quick-start/#create-a-opentelemetry-demo-cluster).

![OTel Demo Overview](assets/overview.png)

---

## Use cases

- **Replicate customer problems** — spin up a clean environment to reproduce and test solutions to real-world issues
- **Demo videos** — a stable, realistic microservices app with live telemetry flowing into Kibana, ready to record
- **Capture the Bug sessions** — inject random failures and benchmark how well Kibana (or an AI agent) can find and explain them

---

## Why this over running the OTel demo locally?

- **Cloud-hosted infrastructure** — your laptop will struggle to run a 20-service Kubernetes cluster under load; GKE Autopilot scales automatically
- **Chaos Mesh infrastructure faults** — inject failures that AI agents won't recognise out of the box; the flagd scenarios are in the OTel demo docs and likely in model training data, so agents can identify them by name without actually diagnosing anything
- **Real GCP infrastructure** — inspect nodes, pods, and networking in the GCP console or with `gcloud`, not just in a local Docker environment
- **Full `kubectl` access** — manage deployments, inspect logs, and apply manifests against a real cluster just as you would in production

---

## Table of Contents

- [Prerequisites](#prerequisites)
  - [Installing oblt-cli](#installing-oblt-cli)
- [Create the Cluster](#create-the-cluster)
- [Access the Demo](#access-the-demo)
- [Validating the Cluster in GCP](#validating-the-cluster-in-gcp)
- [Managing the Kubernetes Infrastructure](#managing-the-kubernetes-infrastructure)
- [Triggering Failure Scenarios](#triggering-failure-scenarios)
  - [Method 1: flagd — controlled failures](#method-1-flagd--controlled-failures)
  - [Method 2: Capture the Bug — random injection](#method-2-capture-the-bug--random-injection)
  - [Method 3: Chaos Mesh — infrastructure faults](#method-3-chaos-mesh--infrastructure-faults)
- [Failure Scenario Catalogue](docs/failure-scenarios.md)
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

Pass your cluster name to `init-cluster.sh` — it configures `kubectl`, resets all failure flags to off, fixes the load generator, and starts the port-forwards automatically:

```bash
./scripts/init-cluster.sh <your-cluster-name>
```

This leaves your terminal free. Port-forwards run in the background.

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

Check which flags are currently active:

```bash
./scripts/list-flags.sh              # All flags
./scripts/list-flags.sh --active-only  # Only flags that are on
```

Reset everything to off in one go:

```bash
./scripts/reset-flags.sh
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

`inject-failure.sh` is designed for **guided demo sessions** where a participant investigates a live failure in Kibana without being told what went wrong. The operator injects a random scenario from a unified pool of **flagd (application-layer)** and **Chaos Mesh (infrastructure-layer)** failures; the participant finds it.

> **GCP cost note:** Scenarios that cause sustained CPU spikes, memory leaks, or traffic floods (`emailMemoryLeak`, `loadGeneratorFloodHomepage`, `recommendationCacheFailure`, `adHighCpu`, `failedReadinessProbe`) are intentionally excluded from the random pool. Use `toggle-flag.sh` directly if you need them. Chaos Mesh scenarios auto-revert after 30 minutes if not manually reverted.

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
./scripts/inject-failure.sh --chaos-only                # Random Chaos Mesh scenario only (excludes flagd)
./scripts/inject-failure.sh --quiet --chaos-only        # Quiet + Chaos Mesh only
./scripts/inject-failure.sh --scenario=<id>             # Inject a specific scenario by ID
./scripts/inject-failure.sh --preview                   # Preview a random scenario without triggering it
./scripts/inject-failure.sh --preview --chaos-only      # Preview a random Chaos Mesh scenario
./scripts/inject-failure.sh --preview --scenario=<id>   # Preview a specific scenario
./scripts/inject-failure.sh --status                    # Show a vague symptom hint (safe to share)
./scripts/inject-failure.sh --reveal                    # Reveal the full answer + Kibana path
./scripts/inject-failure.sh --revert                    # Reset flags/chaos, clear state, reveal what was active
./scripts/inject-failure.sh --list                      # List all available scenarios
./scripts/inject-failure.sh --list --chaos-only         # List only Chaos Mesh scenarios
```

#### Testing AI agents — use `--chaos-only`

When using this demo to evaluate AI agents (e.g. Kibana AI Assistant, Elastic Agent), use `--chaos-only` to restrict the random pool to **Chaos Mesh infrastructure failures only**:

```bash
./scripts/inject-failure.sh --chaos-only
```

flagd failures are well-documented in the official OpenTelemetry Demo documentation and are likely to be in an AI model's training data — the agent may recognise symptoms by name. Chaos Mesh failures operate at the infrastructure layer (network packets, pod lifecycle, CPU scheduling) and are not described in the OTel demo docs, making them a more genuine test of the agent's diagnostic ability.

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

**Chaos Mesh — infrastructure-layer failures**

| ID | What breaks | Observable in Kibana |
|----|-------------|----------------------|
| `chaos-net-delay-checkout` | 2s network delay on checkout pod | APM → checkoutservice p99 latency spike |
| `chaos-pod-fail-cart` | Cart pod forced into failure state | Infrastructure → cart pod NotReady + APM errors |
| `chaos-cpu-stress-frontend` | 80% CPU stress on frontend pod | Infrastructure → frontend CPU spike + APM latency |
| `chaos-net-loss-payment` | 50% packet loss on payment pod | APM → paymentservice intermittent connection errors |
| `chaos-pod-fail-recommendation` | Recommendation pod forced unavailable | Infrastructure → pod NotReady + APM service map |

The active scenario is saved to `.failure-state` (gitignored) so it persists across terminal sessions. Running `--revert` always tells you what was active, even if the session was started by someone else.

---

### Method 3: Chaos Mesh — infrastructure faults

Chaos Mesh injects infrastructure-level faults — network latency, pod kills, memory pressure, IO errors — that go beyond what flagd can simulate.

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

Full details for every flagd flag (variants, affected services, Kibana paths, and toggle commands) are in **[docs/failure-scenarios.md](docs/failure-scenarios.md)**.


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
