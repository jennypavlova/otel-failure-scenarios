# AI Agent Integration

This repo includes [Elastic Agent Skills](https://github.com/elastic/agent-skills) — the official skill library built by Elastic that gives AI coding agents (Cursor, GitHub Copilot, Windsurf, and more) native expertise across Elasticsearch, Kibana, Elastic Observability, and Elastic Security.

When you run `./scripts/init-cluster.sh <cluster-name>`, it automatically retrieves your Elastic credentials and writes them to `.env`. This means your AI agent can connect directly to the live cluster to analyse the observability data — querying latency, error rates, throughput, service dependencies, and more — without you needing to copy-paste credentials manually.

The full set of observability and Kibana skills is installed, so the agent can query and analyse the live cluster data across all dimensions:

## Observability

| Skill | Purpose |
|-------|---------|
| `observability-service-health` | Assess APM service health: latency, error rate, throughput, SLOs, ML anomalies |
| `observability-logs-search` | Search and filter logs with ES\|QL during incident investigation |
| `observability-manage-slos` | Create and manage SLOs, define SLIs and error budgets |
| `observability-llm-obs` | Monitor LLM/GenAI performance, token usage, and response quality |
| `observability-edot-java-instrument` | Instrument Java services with EDOT OpenTelemetry |
| `observability-edot-java-migrate` | Migrate Java services from the classic Elastic APM agent to EDOT |
| `observability-edot-python-instrument` | Instrument Python services with EDOT OpenTelemetry |
| `observability-edot-python-migrate` | Migrate Python services from the classic Elastic APM agent to EDOT |
| `observability-edot-dotnet-instrument` | Instrument .NET services with EDOT OpenTelemetry |
| `observability-edot-dotnet-migrate` | Migrate .NET services from the classic Elastic APM agent to EDOT |

## Kibana

| Skill | Purpose |
|-------|---------|
| `kibana-dashboards` | Create and manage dashboards and Lens visualisations |
| `kibana-alerting-rules` | Create and manage alerting rules via REST API or Terraform |
| `kibana-streams` | Inspect, enable, disable, and resync Kibana Streams |
| `kibana-connectors` | Configure Slack, PagerDuty, Jira, webhook, and other connectors |
| `kibana-vega` | Build custom Vega/Vega-Lite charts with ES\|QL data sources |
| `kibana-audit` | Enable and configure Kibana audit logging |
| `kibana-agent-builder` | Create and manage Agent Builder agents and custom tools |

To install or update the skills, follow the instructions in the [elastic/agent-skills](https://github.com/elastic/agent-skills) repository.
