#!/usr/bin/env bash
# init-cluster.sh — Post-provisioning setup for the oteldemo cluster.
#
# Run this once after configuring kubectl access to:
#   1. Reset all flagd failure flags to off (the oteldemo template pre-activates several)
#   2. Tune the load generator to stable settings (the template defaults OOMKill the pod)
#
# Usage:
#   ./scripts/init-cluster.sh [cluster-name]
#
# If a cluster-name is provided, kubectl access is configured automatically
# via oblt-cli before running the init steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Optional: configure kubectl via oblt-cli ──────────────────────────────────
CLUSTER_NAME="${1:-}"
if [[ -n "$CLUSTER_NAME" ]]; then
  info "Configuring kubectl for cluster '${CLUSTER_NAME}'..."
  oblt-cli cluster k8s --cluster-name "${CLUSTER_NAME}" || die "Failed to configure kubectl. Check your cluster name and oblt-cli auth."
  echo ""
fi

# ── Verify kubectl can reach a live cluster ───────────────────────────────────
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
if [[ -z "$CURRENT_CONTEXT" ]]; then
  die "No kubectl context set. Run: oblt-cli cluster k8s --cluster-name <your-cluster-name>"
fi

info "Checking cluster connectivity (context: ${CURRENT_CONTEXT})..."
if ! kubectl get nodes &>/dev/null; then
  die "Cannot reach cluster '${CURRENT_CONTEXT}'. Run: oblt-cli cluster k8s --cluster-name <your-cluster-name>"
fi
success "Connected to cluster '${CURRENT_CONTEXT}'"
echo ""

NAMESPACE="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo 'default')}"

echo -e "${BOLD}OTel Demo — cluster initialisation${NC}"
echo "Namespace: ${NAMESPACE}"
echo ""

# ── 1. Sync canonical flagd config and reset all flags to off ────────────────
echo -e "${BOLD}Step 1/4 — Syncing flagd config and resetting flags${NC}"

FLAGD_POD=$(kubectl get po -l app.kubernetes.io/component=flagd \
  -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$FLAGD_POD" ]] && die "flagd pod not found. Is kubectl configured correctly?"

CANONICAL_FILE="${SCRIPT_DIR}/../flagd/demo.flagd.json"
[[ -f "$CANONICAL_FILE" ]] || die "Canonical flagd config not found: ${CANONICAL_FILE}"

# Check what's live vs what should be there
LIVE_FLAGS=$(kubectl exec "$FLAGD_POD" -c flagd-ui -n "$NAMESPACE" -- \
  cat /app/data/demo.flagd.json | jq -r '.flags | keys | sort | @csv' 2>/dev/null)
CANONICAL_FLAGS=$(jq -r '.flags | keys | sort | @csv' "$CANONICAL_FILE")

ACTIVE=$(kubectl exec "$FLAGD_POD" -c flagd-ui -n "$NAMESPACE" -- \
  cat /app/data/demo.flagd.json | jq -r '
    .flags | to_entries[]
    | select(.value.defaultVariant != "off")
    | "  \(.key): \(.value.defaultVariant)"
  ')

NEEDS_SYNC=false
if [[ "$LIVE_FLAGS" != "$CANONICAL_FLAGS" ]]; then
  warn "Live flagd config is missing flags — syncing canonical config from flagd/demo.flagd.json..."
  NEEDS_SYNC=true
fi

if [[ -n "$ACTIVE" ]]; then
  echo "Turning off:"
  echo "$ACTIVE"
  NEEDS_SYNC=true
fi

if [[ "$NEEDS_SYNC" == true ]]; then
  # Always write the full canonical config (all flags present, all set to off)
  CANONICAL_JSON=$(jq '.flags |= with_entries(.value.defaultVariant = "off")' "$CANONICAL_FILE")
  PATCH_PAYLOAD=$(jq -n --arg json "$CANONICAL_JSON" '{"data": {"demo.flagd.json": $json}}')
  kubectl patch configmap flagd-config -n "$NAMESPACE" --type merge --patch "$PATCH_PAYLOAD" &>/dev/null
  kubectl rollout restart deployment/flagd -n "$NAMESPACE" &>/dev/null
  kubectl rollout status deployment/flagd -n "$NAMESPACE" --timeout=120s &>/dev/null
  success "flagd config synced and all flags reset to off"
else
  success "All flags already correct"
fi

echo ""

# ── 2. Tune load generator ────────────────────────────────────────────────────
echo -e "${BOLD}Step 2/4 — Tuning load generator${NC}"

# The oteldemo template sets LOCUST_USERS=50, which consistently OOMKills the
# pod under GKE Autopilot's default memory limits. Drop to 10 users, which
# keeps the pod stable and still generates meaningful load.
CURRENT_USERS=$(kubectl get deployment load-generator -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LOCUST_USERS")].value}' 2>/dev/null || echo "")

TARGET_USERS=10

if [[ "$CURRENT_USERS" == "$TARGET_USERS" ]]; then
  success "Load generator already set to ${TARGET_USERS} users"
else
  info "Setting LOCUST_USERS from ${CURRENT_USERS:-unknown} → ${TARGET_USERS}..."
  kubectl set env deployment/load-generator LOCUST_USERS="${TARGET_USERS}" -n "$NAMESPACE"
  kubectl rollout status deployment/load-generator -n "$NAMESPACE" --timeout=120s
  success "Load generator stable at ${TARGET_USERS} users"
fi

echo ""

# ── 3. Patch OTel collector pipelines ────────────────────────────────────────
# Three upstream template defects are fixed here, all idempotent.
echo -e "${BOLD}Step 3/4 — Patching OTel collector pipelines${NC}"

DAEMON_CRD="opentelemetry-kube-stack-daemon"
GATEWAY_CRD="opentelemetry-kube-stack-gateway"

if kubectl get opentelemetrycollector "$DAEMON_CRD" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -e '.spec.config.processors["k8sattributes/apm"]' > /dev/null 2>&1; then
  success "OTel daemon collector already has k8sattributes/apm processor"
else
  warn "k8sattributes/apm missing from upstream template — patching now..."

  CURRENT=$(kubectl get opentelemetrycollector "$DAEMON_CRD" -n "$NAMESPACE" -o json)

  TRACES_APM_PROCS=$(echo "$CURRENT" | jq '.spec.config.service.pipelines["traces/apm"].processors')
  LOGS_APM_PROCS=$(echo "$CURRENT"   | jq '.spec.config.service.pipelines["logs/apm"].processors')

  NEW_TRACES_APM=$(echo "$TRACES_APM_PROCS" | jq '["k8sattributes/apm"] + .')
  NEW_LOGS_APM=$(echo "$LOGS_APM_PROCS"     | jq '["k8sattributes/apm"] + .')

  PATCH=$(jq -n \
    --argjson traces_apm "$NEW_TRACES_APM" \
    --argjson logs_apm   "$NEW_LOGS_APM" \
    '{
      "spec": {
        "config": {
          "processors": {
            "k8sattributes/apm": {
              "passthrough": false,
              "extract": {
                "metadata": [
                  "k8s.namespace.name",
                  "k8s.pod.name",
                  "k8s.pod.uid",
                  "k8s.deployment.name",
                  "k8s.statefulset.name",
                  "k8s.daemonset.name",
                  "k8s.replicaset.name",
                  "k8s.node.name",
                  "container.id"
                ],
                "labels": [
                  {"from": "node", "key": "cloud.google.com/gke-nodepool",     "tag_name": "cloud.google.com/gke-nodepool"},
                  {"from": "node", "key": "topology.kubernetes.io/zone",       "tag_name": "topology.kubernetes.io/zone"},
                  {"from": "node", "key": "topology.kubernetes.io/region",     "tag_name": "topology.kubernetes.io/region"}
                ]
              },
              "pod_association": [
                {"sources": [{"from": "resource_attribute", "name": "k8s.pod.ip"}]},
                {"sources": [{"from": "resource_attribute", "name": "k8s.pod.uid"}]},
                {"sources": [{"from": "connection"}]}
              ]
            }
          },
          "service": {
            "pipelines": {
              "traces/apm": {"processors": $traces_apm},
              "logs/apm":   {"processors": $logs_apm}
            }
          }
        }
      }
    }')

  kubectl patch opentelemetrycollector "$DAEMON_CRD" \
    -n "$NAMESPACE" --type=merge -p "$PATCH"

  kubectl rollout status "daemonset/${DAEMON_CRD}-collector" \
    -n "$NAMESPACE" --timeout=120s

  success "k8sattributes/apm processor added — k8s.pod.name, container.id, and k8s.node.name will now appear in traces"
fi

# ── 3b. Fix daemon metrics pipeline: remove kubeletstats/hostmetrics duplicate ─
# The upstream template puts kubeletstats and hostmetrics in BOTH the "metrics"
# pipeline (no resource detection) and the "metrics/node/otel" pipeline (full
# resource detection). OTel fan-outs shared receivers — each metric is sent to
# the gateway twice. The copy from "metrics" has no host.name set (no
# resource/hostname processor), and the gateway's two exporters both target the
# same index, producing continuous 409 version_conflict errors in Elasticsearch.
#
# Fix: keep only k8s_cluster in the "metrics" pipeline receivers. kubeletstats
# and hostmetrics then flow exclusively through "metrics/node/otel", which runs
# resourcedetection/gcp and resource/hostname to set host.name correctly.
DAEMON_METRICS_RECEIVERS=$(kubectl get opentelemetrycollector "$DAEMON_CRD" \
  -n "$NAMESPACE" -o json 2>/dev/null \
  | jq -r '.spec.config.service.pipelines.metrics.receivers | @csv' 2>/dev/null || echo "")

if echo "$DAEMON_METRICS_RECEIVERS" | grep -q 'kubeletstats\|hostmetrics'; then
  warn "Daemon metrics pipeline has duplicate kubeletstats/hostmetrics receivers — removing..."
  kubectl patch opentelemetrycollector "$DAEMON_CRD" \
    -n "$NAMESPACE" --type=merge \
    -p '{"spec":{"config":{"service":{"pipelines":{"metrics":{"receivers":["k8s_cluster"]}}}}}}'
  kubectl rollout status "daemonset/${DAEMON_CRD}-collector" \
    -n "$NAMESPACE" --timeout=120s
  success "Daemon metrics pipeline fixed — host metrics flow through metrics/node/otel only (host.name now set)"
else
  success "Daemon metrics pipeline already correct (no duplicate receivers)"
fi

# ── 3c. Fix gateway routing: remove metrics/infra/ecs from hostmetrics route ──
# The gateway routing connector sends host metrics to both metrics/infra/ecs
# (elasticsearch/ecs exporter) and metrics/otel (elasticsearch/otel exporter).
# The ECS exporter falls back to OTel index naming for hostmetrics, so both
# exporters target the same index and produce 409 version_conflict errors.
#
# Fix: route hostmetrics only to metrics/otel. The OTel-format index
# (metrics-hostmetricsreceiver.otel-default) is the correct destination and
# Kibana's Infrastructure view can query it directly.
GATEWAY_ROUTING_PIPELINES=$(kubectl get opentelemetrycollector "$GATEWAY_CRD" \
  -n "$NAMESPACE" -o json 2>/dev/null \
  | jq -r '.spec.config.connectors.routing.table[0].pipelines | @csv' 2>/dev/null || echo "")

if echo "$GATEWAY_ROUTING_PIPELINES" | grep -q 'metrics/infra/ecs'; then
  warn "Gateway hostmetrics routing includes metrics/infra/ecs — removing to stop 409 conflicts..."
  kubectl patch opentelemetrycollector "$GATEWAY_CRD" \
    -n "$NAMESPACE" --type=merge \
    -p '{
      "spec": {
        "config": {
          "connectors": {
            "routing": {
              "default_pipelines": ["metrics/otel"],
              "table": [
                {
                  "context": "metric",
                  "pipelines": ["metrics/otel"],
                  "statement": "route() where IsMatch(instrumentation_scope.name, \"github.com/open-telemetry/opentelemetry-collector-contrib/receiver/hostmetricsreceiver/internal/scraper/*\")"
                }
              ]
            }
          }
        }
      }
    }'
  kubectl rollout status "deployment/${GATEWAY_CRD}-collector" \
    -n "$NAMESPACE" --timeout=120s
  success "Gateway routing fixed — hostmetrics routed to metrics/otel only (no more 409 conflicts)"
else
  success "Gateway hostmetrics routing already correct"
fi

# ── 3d. Enable opt-in hostmetrics for Kibana Infrastructure view ──────────────
# The upstream template leaves the cpu, memory, and filesystem scrapers at their
# defaults (null config), which omits the utilization metrics Kibana's
# Infrastructure Hosts view requires:
#   - system.cpu.utilization        → CPU Usage (%)
#   - system.cpu.logical.count      → Normalized Load denominator
#   - system.memory.utilization     → Memory Usage (%)
#   - system.filesystem.utilization → Disk Usage - Max (%)
# Without these, CPU Usage, Memory Usage, and Normalized Load all show N/A.
# Disk Usage shows correctly because it falls back to system.filesystem.usage.
#
# The filesystem scraper also needs exclude_mount_points and exclude_fs_types
# (per the EDOT reference values.yaml) to avoid scraping hundreds of virtual
# filesystems (overlay, proc, sysfs, cgroup, etc.) which create junk TSDB
# time series and slow down Kibana's Disk view.
#
# Fix: explicitly enable the opt-in metrics and add filesystem excludes.
DAEMON_CPU_UTILIZATION=$(kubectl get opentelemetrycollector "$DAEMON_CRD" \
  -n "$NAMESPACE" -o json 2>/dev/null \
  | jq -r '.spec.config.receivers.hostmetrics.scrapers.cpu.metrics["system.cpu.utilization"].enabled // false' \
  2>/dev/null || echo "false")

if [[ "$DAEMON_CPU_UTILIZATION" != "true" ]]; then
  warn "Hostmetrics opt-in utilization metrics not enabled — patching cpu/memory/filesystem scrapers..."
  kubectl patch opentelemetrycollector "$DAEMON_CRD" \
    -n "$NAMESPACE" --type=merge \
    -p '{
      "spec": {
        "config": {
          "receivers": {
            "hostmetrics": {
              "scrapers": {
                "cpu": {
                  "metrics": {
                    "system.cpu.utilization": {"enabled": true},
                    "system.cpu.logical.count": {"enabled": true}
                  }
                },
                "memory": {
                  "metrics": {
                    "system.memory.utilization": {"enabled": true}
                  }
                },
                "filesystem": {
                  "metrics": {
                    "system.filesystem.utilization": {"enabled": true}
                  },
                  "exclude_mount_points": {
                    "mount_points": ["/dev/*","/proc/*","/sys/*","/run/k3s/containerd/*","/var/lib/docker/*","/var/lib/kubelet/*","/snap/*"],
                    "match_type": "regexp"
                  },
                  "exclude_fs_types": {
                    "fs_types": ["autofs","binfmt_misc","bpf","cgroup2","configfs","debugfs","devpts","devtmpfs","fusectl","hugetlbfs","iso9660","mqueue","nsfs","overlay","proc","procfs","pstore","rpc_pipefs","securityfs","selinuxfs","squashfs","sysfs","tracefs"],
                    "match_type": "strict"
                  }
                }
              }
            }
          }
        }
      }
    }'
  kubectl rollout status "daemonset/${DAEMON_CRD}-collector" \
    -n "$NAMESPACE" --timeout=120s
  success "Hostmetrics utilization metrics enabled — CPU Usage, Memory Usage, Normalized Load will now show in Kibana"
else
  success "Hostmetrics utilization metrics already enabled"
fi

echo ""

# ── 4. Retrieve and store Elastic credentials in .env ────────────────────────
if [[ -n "$CLUSTER_NAME" ]]; then
  echo -e "${BOLD}Step 4/4 — Retrieving Elastic credentials${NC}"

  CREDS_OUTPUT=$(oblt-cli cluster secrets credentials --cluster-name "${CLUSTER_NAME}" 2>/dev/null)

  KIBANA_URL=$(echo "$CREDS_OUTPUT"    | grep "^* Kibana:"         | head -1 | awk '{print $3}')
  ES_URL=$(echo "$CREDS_OUTPUT"        | grep "^* Elasticsearch:"  | head -1 | awk '{print $3}')
  ES_PASSWORD=$(echo "$CREDS_OUTPUT"   | grep "^  password:"       | head -1 | awk '{print $2}')
  KIBANA_API_KEY=$(echo "$CREDS_OUTPUT" | grep "^  api_key:"       | head -1 | awk '{print $2}')

  ENV_FILE="${SCRIPT_DIR}/../.env"

  if [[ -n "$KIBANA_URL" && -n "$ES_PASSWORD" ]]; then
    # Preserve existing lines that aren't credential keys or the auto-generated comment block
    PRESERVED=$(grep -v -E \
      "^KIBANA_URL=|^KIBANA_USERNAME=|^KIBANA_PASSWORD=|^KIBANA_API_KEY=|^ELASTICSEARCH_URL=|^ELASTICSEARCH_USERNAME=|^ELASTICSEARCH_PASSWORD=|^# Elastic cluster credentials" \
      "$ENV_FILE" 2>/dev/null | sed '/^$/N;/^\n$/d' | sed -e 's/[[:space:]]*$//' || true)

    {
      echo "$PRESERVED"
      echo ""
      echo "# Elastic cluster credentials (auto-populated by init-cluster.sh)"
      echo "KIBANA_URL=${KIBANA_URL}"
      echo "KIBANA_USERNAME=elastic"
      echo "KIBANA_PASSWORD=${ES_PASSWORD}"
      [[ -n "$KIBANA_API_KEY" ]] && echo "KIBANA_API_KEY=${KIBANA_API_KEY}"
      echo "ELASTICSEARCH_URL=${ES_URL}"
      echo "ELASTICSEARCH_USERNAME=elastic"
      echo "ELASTICSEARCH_PASSWORD=${ES_PASSWORD}"
    } > "$ENV_FILE"

    success "Credentials written to .env"
    echo -e "  ${BOLD}Kibana:${NC}        ${KIBANA_URL}"
    echo -e "  ${BOLD}Elasticsearch:${NC} ${ES_URL}"
    echo -e "  ${BOLD}Username:${NC}      elastic"
    echo -e "  ${DIM}Source credentials with: source .env${NC}"
  else
    warn "Could not parse credentials from oblt-cli output — skipping .env update"
    warn "Run manually: oblt-cli cluster secrets credentials --cluster-name ${CLUSTER_NAME}"
  fi

  echo ""
else
  info "No cluster name provided — skipping credential retrieval"
  info "Re-run with your cluster name to populate .env: ./scripts/init-cluster.sh <cluster-name>"
  echo ""
fi

echo -e "${GREEN}${BOLD}Cluster ready.${NC} Starting port-forwards..."
echo ""

"${SCRIPT_DIR}/start-demo.sh"
