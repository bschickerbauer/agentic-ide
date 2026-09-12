# Agent Memory

Reusable, shared agent memory for the cross-site team.

**Problem:** Hindsight currently runs locally per machine (embedded pg0 database), so agent
memory is device-bound and cannot be shared across people or hosts.

**Goal:** Deploy Hindsight into our Azure environment so agents can retain and recall
memories across team members and machines — one shared memory service, many clients
(Claude Code via the hindsight-memory plugin or MCP, Hindsight CLI, SDKs).

## Contents

| Item | What |
|------|------|
| [`hindsight-on-azure/deployment-plan.md`](hindsight-on-azure/deployment-plan.md) | Full deployment plan: architecture decisions, PostgreSQL + vector extensions, model wiring (Azure AI Foundry), phases, configuration reference, open items |
| [`hindsight-on-azure/infra/`](hindsight-on-azure/infra/README.md) | Bicep IaC (subscription scope) + `deploy.sh` wrapper (`what-if` by default). Creates RG, VNet, PostgreSQL Flexible Server, Foundry account + model deployments, Key Vault, Container Apps |
| [`hindsight-on-azure/architecture.html`](hindsight-on-azure/architecture.html) | Architecture diagram (ANDRITZ-branded, self-contained HTML) |

## Status

- **2026-09-05** — Deployment plan and target architecture drafted.
- **2026-09-08** — Azure inventoried (nothing Hindsight-related exists yet), plan updated to
  v2, Bicep IaC written and compiled. Pinned to Hindsight 0.9.2. **Not deployed:** the
  subscription decision and the deployment approval are pending (plan, Section 10).

## Checks

```bash
az bicep build --file agent-memory/hindsight-on-azure/infra/main.bicep --stdout > /dev/null
bash -n agent-memory/hindsight-on-azure/infra/deploy.sh
```
