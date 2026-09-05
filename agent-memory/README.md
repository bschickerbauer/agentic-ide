# Agent Memory

Reusable, shared agent memory for the cross-site team.

**Problem:** Hindsight currently runs locally per machine (embedded pg0 database), so agent
memory is device-bound and cannot be shared across people or hosts.

**Goal:** Deploy Hindsight into our Azure environment so agents can retain and recall
memories across team members and machines — one shared memory service, many clients
(Claude Code via MCP, Hindsight CLI, SDKs).

## Contents

| Item | What |
|------|------|
| [`hindsight-on-azure/deployment-plan.md`](hindsight-on-azure/deployment-plan.md) | Full deployment plan: architecture decisions, PostgreSQL + vector extensions, model wiring (Azure AI Foundry), phases, configuration reference |
| [`hindsight-on-azure/architecture.html`](hindsight-on-azure/architecture.html) | Architecture diagram (ANDRITZ-branded, self-contained HTML) |

## Status

- **2026-09-05** — Deployment plan and target architecture drafted. Azure subscription and
  resource group not yet created; provisioning is the next step (see plan, Phase 0).
