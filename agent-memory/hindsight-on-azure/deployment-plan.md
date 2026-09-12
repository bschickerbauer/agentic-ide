# Hindsight on Azure — Deployment Plan

**Status:** Draft v2 (September 8, 2026) — IaC written and compiled, **provisioning awaits
approval** · **Owner:** Bernd Schickerbauer (SDC)
**Goal:** Replace device-bound local Hindsight instances with one shared, Azure-hosted
Hindsight service so agents retain and recall memory **across team members and hosts**.

---

## 1. Summary

Hindsight is a self-hostable memory system (API + optional Web UI + background worker) that
stores everything in **PostgreSQL** — vectors (pgvector/DiskANN), full-text (tsvector/BM25),
relational data, JSONB, and graph queries via recursive CTEs. That makes the Azure footprint
small and boring in the best sense:

- **Azure Container Apps** runs the Hindsight API (slim image) and the Control Plane UI.
- **Azure Database for PostgreSQL Flexible Server** is the single stateful component,
  with the `vector` and `pg_diskann` extensions enabled.
- **Azure AI Foundry** serves all three model roles: extraction/reasoning LLM,
  embeddings, and reranking (Cohere Rerank, Cohere-compatible `/rerank` endpoint).
- Team members connect via the **hindsight-memory Claude Code plugin in remote mode**, the
  built-in **MCP endpoint** (`/mcp/{bank_id}/`), or the Hindsight CLI/SDKs — from any
  machine, any site.

No GPU, no vector database product, no Kubernetes cluster required.

Everything below is implemented as Bicep in [`infra/`](infra/README.md): one subscription-scope
deployment creates the resource group and all resources. `deploy.sh` previews with `what-if`
by default; `create` runs only after explicit approval.

## 2. Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Subscription (**proposal, pending approval**) | The team's Claude Code subscription (AAIH) | It already hosts the team's per-person Foundry resources for Claude Code, plus a Container Apps environment, Key Vault and Log Analytics — same audience, same cost owner, same admin rights (Owner via management group). ECM Shared remains the alternative if AAIH is to stay Claude-Code-only. |
| Naming & tags | Follow the host subscription's existing convention: `<type>-weu-aaih-hindsight-prod`, RG `rg-weu-aaih-hindsight-prod`; the same nine governance tags as the neighboring resource groups | Everything in that subscription is tagged `Environment: Production` and named `-prod`/`-production`; a `-dev` island would be the odd one out. All tokens are Bicep parameters, so renaming is a parameter change. Real tag values live only in the gitignored `main.local.bicepparam` (this repo is public). |
| Compute | **Azure Container Apps** (workload-profile environment, Consumption profile, VNet-integrated) | Slim image is ~500 MB, stateless, no GPU needed. Managed identity, Key Vault refs, VNet integration, revisions. AKS + the official Helm chart is the documented alternative — only worth it if we standardize this on an existing cluster. |
| Image variant | **`hindsight-api:0.9.2-slim`** + `hindsight-control-plane:0.9.2` (pinned) | Full image is ~9 GB because it bundles local embedding/reranker models and PyTorch. On Azure we delegate all model calls to Foundry → small image, fast deploys, ~512 MB–1 GB RAM. v0.9.2 is the current release (August 25, 2026) and the version the local daemons already run. |
| Database | **Azure Database for PostgreSQL Flexible Server, PG 17**, private access (delegated subnet) | Hindsight requires PostgreSQL 14+ with a vector extension; Azure is a tested managed service in the Hindsight docs. PG 17 and `Standard_B2ms` verified available in westeurope. |
| Vector index | **Start `pgvector` (HNSW), enable `pg_diskann` from day 1** | pgvector 0.8.2 on Flexible Server — supports Hindsight's iterative index scans (needs ≥ 0.8.0). HNSW is the most-deployed path and ideal < 10 M vectors; team-scale memory is far below that. `pg_diskann` 0.6.5 is allow-listed up front so the documented switch to `HINDSIGHT_API_VECTOR_EXTENSION=pgvectorscale` (which uses DiskANN on Azure) is a config change + re-index, not a server migration. |
| Foundry account | **Dedicated AI Services account** `ais-sdc-aaih-hindsight-prod` (swedencentral) instead of reusing a personal one | A shared service must not depend on one person's key: rotating a personal Claude Code key would take the team memory down, and Hindsight's extraction load would compete with that person's interactive quota. The dedicated account costs nothing idle (pay-per-use) and gets its own key lifecycle in Key Vault. |
| LLM | **`gpt-5-mini`** (version 2025-08-07), Data Zone Standard | Hindsight's default model. Reached with `HINDSIGHT_API_LLM_PROVIDER=openai` and base URL `https://<account>.openai.azure.com/openai/v1` (the resource root and the bare deployments URL both 404 — documented Hindsight gotcha). |
| Embeddings | **`text-embedding-3-small` (1536 dims)**, Data Zone Standard, `NoAutoUpgrade` | Explicitly supported by Hindsight's `openai` embeddings provider with an Azure base URL. 1536 dims works with both HNSW (≤ 2000-dim index limit) and DiskANN. Multilingual-capable. The deployment is pinned against automatic version upgrades because the embedding dimension is locked once memories exist. |
| Reranker | **`Cohere-rerank-v4.0-fast`** on the same account, Data Zone Standard; **first deployment runs `rrf`**, then `cohere` with **failover to `rrf`** | Hindsight's `cohere` reranker POSTs to `HINDSIGHT_API_RERANKER_COHERE_BASE_URL` verbatim (verified in the source: `rerank_url == base_url`), so any URL shape incl. a query string works — but the exact invoke URL of a Cohere deployment on a Foundry account is only visible after the deployment exists. Until then recall uses fusion order (`rrf`), which is Hindsight's documented fail-open behavior anyway. |
| AuthN (phase 1) | Hindsight built-in **`ApiKeyTenantExtension`** (single shared bearer key) + HTTPS via ACA ingress; Control Plane behind an access key, optional Entra ID login (ACA built-in auth) | Smallest thing that safely works for one team. |
| AuthN (phase 2) | **APIM in front** — per-user subscription keys / Entra ID JWT validation; APIM injects the shared Hindsight key and a per-caller header (`HINDSIGHT_API_EXTENSION_PASSTHROUGH_HEADERS`) | Hindsight documents exactly this gateway pattern. Fits our APIOps estate; MCP is streamable HTTP and proxies through APIM. |
| Secrets | **Key Vault** (RBAC) + user-assigned managed identity, ACA secret references | Connection string, Foundry key1, tenant key, UI access key. No secrets in app config or parameter files: the deployment reads them from environment variables provided by the 1Password-backed shell (`secrets-management/`). |
| Memory language | `HINDSIGHT_API_LLM_OUTPUT_LANGUAGE=English` | Team ground rule: artifacts and shared knowledge in EN-US, regardless of input language. |
| Deployment path | Local `az deployment sub` via `infra/deploy.sh`, run by the owner | This repo is a public personal repo; wiring GitHub Actions OIDC from it into the corporate tenant is not appropriate. A pipeline can follow once the topic moves to an internal repo. |

## 3. Target architecture

```
 Team clients (any site, any host)
 ├─ Claude Code + hindsight-memory plugin (remote mode) ─┐
 ├─ Claude Code MCP (streamable HTTP)                     ├── https ──►  [Phase 2: APIM]  ──►  ACA ingress
 ├─ Hindsight CLI (~/.hindsight/config)                   │                                        │
 └─ SDKs (Python/Node) / Control Plane UI ────────────────┘                                        ▼
   Azure Container Apps environment  cae-weu-aaih-hindsight-prod  (VNet-integrated, West Europe)
   ├─ ca-weu-aaih-hindsight-api-prod   ghcr.io/vectorize-io/hindsight-api:0.9.2-slim   (internal worker, 1 replica)
   └─ ca-weu-aaih-hindsight-cp-prod    ghcr.io/vectorize-io/hindsight-control-plane:0.9.2 (0–1 replicas)
                │                                       │
                │ delegated subnet + private DNS        │ model calls (https)
                ▼                                       ▼
   psql-weu-aaih-hindsight-prod                 ais-sdc-aaih-hindsight-prod (Foundry, Sweden Central)
   PostgreSQL Flexible Server 17, B2ms          ├─ gpt-5-mini              (LLM, Data Zone Standard)
   extensions: vector 0.8.2, pg_diskann 0.6.5   ├─ text-embedding-3-small  (1536 dims, no auto-upgrade)
                                                └─ Cohere-rerank-v4.0-fast (Data Zone Standard)

   Cross-cutting: kvweuaaihhindsightprod (Key Vault, RBAC) · id-weu-aaih-hindsight-prod (UAMI)
                  log-weu-aaih-hindsight-prod · vnet-weu-aaih-hindsight-prod (10.60.0.0/23) · Bicep IaC
```

### Components

| Component | Resource | Notes |
|---|---|---|
| Resource group | `rg-weu-aaih-hindsight-prod` | Tags per host-subscription convention (placeholders in the repo). |
| ACA environment | `cae-weu-aaih-hindsight-prod` | Workload-profile environment, Consumption profile, infrastructure subnet `snet-aca` (10.60.0.0/24), external ingress. |
| API app | `ca-weu-aaih-hindsight-api-prod` | 1 vCPU / 2 GiB, **min 1 / max 1 replica** (see worker identity note), external ingress :8888, startup/liveness `/health/live`, readiness `/health/ready`. |
| Control Plane app | `ca-weu-aaih-hindsight-cp-prod` | 0.25 vCPU / 0.5 GiB, scale 0–1, external ingress :9999, protected by `HINDSIGHT_CP_ACCESS_KEY`; optional Entra ID login via ACA built-in auth (`cpEntraClientId`). Talks to the API through its public FQDN (traffic between apps of one environment stays inside the environment). |
| PostgreSQL | `psql-weu-aaih-hindsight-prod` | PG 17, `Standard_B2ms`, 32 GiB autogrow, PITR 14 days, private access via `snet-postgres` (10.60.1.0/28) + zone `hindsight.private.postgres.database.azure.com`, password auth. |
| Key Vault | `kvweuaaihhindsightprod` | RBAC mode; UAMI gets *Key Vault Secrets User*. Purge protection off during iteration (parameter). |
| Managed identity | `id-weu-aaih-hindsight-prod` | User-assigned, attached to both apps. |
| Log Analytics | `log-weu-aaih-hindsight-prod` | ACA logs; Hindsight set to `HINDSIGHT_API_LOG_FORMAT=json`. |
| Foundry | `ais-sdc-aaih-hindsight-prod` | Dedicated AI Services account, S0, key auth enabled; deployments `gpt-5-mini`, `text-embedding-3-small`, `Cohere-rerank-v4.0-fast`. |

**Container images:** pinned to `0.9.2`. Images are Cosign-signed (keyless OIDC) — verify once
before the first deployment. If org policy requires a private registry, import via
`az acr import` and pull from ACR instead of ghcr.io (open item 4).

**Worker identity (important):** Hindsight's background worker identifies itself by
hostname, which changes on every container restart — tasks claimed by a dead identity
stay parked. `HINDSIGHT_API_WORKER_ID` is fixed to `hindsight-weu-prod`. With the internal
worker and a single API replica this is one env var. If we later scale the API out, disable
the internal worker (`HINDSIGHT_API_WORKER_ENABLED=false`) and run a dedicated worker app with
its own fixed ID (the API itself is stateless and scales freely; only the worker needs a
stable identity). Before removing a worker: `hindsight-admin decommission-worker <id>`.

## 4. PostgreSQL: the part worth getting right

### 4.1 Versions and extensions (verified against Microsoft Learn, Sep 2026)

| Item | Value |
|---|---|
| PostgreSQL | 17 (Flexible Server; Hindsight requires 14+/15+) |
| `vector` (pgvector) | **0.8.2** on PG 13–18 → satisfies Hindsight's ≥ 0.5.0 requirement *and* the ≥ 0.8.0 needed for `HINDSIGHT_API_ANN_ITERATIVE_SCAN` (on by default) |
| `pg_diskann` (DiskANN) | **0.6.5** on PG 14–18 (GA line; product quantization is preview) |
| pgvectorscale (Timescale) | Not offered on Flexible Server — irrelevant: Hindsight's `pgvectorscale` mode natively uses **`pg_diskann` on Azure** |

The Bicep sets the server allowlist (`azure.extensions = VECTOR,PG_DISKANN`) and creates the
`hindsight` database. Inside the database, Hindsight creates `vector` on first start; create
`pg_diskann` once by hand (from inside the VNet):

```sql
\c hindsight
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_diskann CASCADE;
```

Hindsight runs its own migrations on startup (`HINDSIGHT_API_RUN_MIGRATIONS_ON_STARTUP=true`,
default) and creates per-bank vector indexes automatically.

### 4.2 HNSW now, DiskANN when it earns its keep

- **Now:** `HINDSIGHT_API_VECTOR_EXTENSION=pgvector` (HNSW). Best-supported path; fast and
  exact-enough at team scale (a few 100k facts at most). Keep the default
  `HINDSIGHT_API_ANN_ITERATIVE_SCAN=true` — pgvector 0.8.2 supports it, and it prevents
  filtered recalls from silently returning fewer rows than the recall budget.
- **Later (10 M+ vectors, heavy filtering, or RAM pressure):** switch to
  `HINDSIGHT_API_VECTOR_EXTENSION=pgvectorscale` → Hindsight builds `diskann` indexes.
  With existing data Hindsight refuses to start and prints migration instructions
  (re-index); at our scale that is minutes, not hours. Since `pg_diskann` is already
  allow-listed and created, no server-side change is needed.

### 4.3 Text search

Keep `HINDSIGHT_API_TEXT_SEARCH_EXTENSION=native` (PostgreSQL tsvector/GIN, `english`
dictionary). Because extracted facts are forced to English (Section 6), the English
dictionary is correct even for German inputs. Revisit (e.g. `pgroonga`) only if we later
store raw multilingual documents at volume.

### 4.4 Server sizing & operations

| Aspect | Start | Grow to |
|---|---|---|
| SKU | `Standard_B2ms` (2 vCore, 8 GiB) ≈ fits pgvector HNSW in RAM at team scale | `Standard_D2ds_v5`+ when recall latency or CPU credits pinch |
| Storage | 32 GiB (autogrow on) | 128 GiB+ |
| HA | Off (team stage) | Zone-redundant HA for prod hardening |
| Backups | PITR **14 days** (default 7) | + geo-redundant backup if the memory estate becomes business-critical |
| Connectivity | Private access (delegated subnet + private DNS zone) + `sslmode=require` | — |
| Users | Phase 1: the administrator login `hindsight` (single-purpose server) | Dedicated least-privilege role at hardening. Entra ID DB auth is possible but Hindsight expects a static `DATABASE_URL` — token rotation doesn't fit; keep password auth for this service. |
| Pool | Defaults (`min 5 / max 100`) are fine; Flexible Server `max_connections` on 8 GiB ≈ 859 | Add PgBouncer (built-in) only with many replicas — then set `HINDSIGHT_API_MIGRATION_DATABASE_URL` to the direct port 5432, since migrations must bypass the pooler. |

## 5. Model wiring (Azure AI Foundry)

| Role | Deployment | Hindsight provider | Notes |
|---|---|---|---|
| LLM (fact extraction, entity resolution, reflect, consolidation) | `gpt-5-mini` 2025-08-07, Data Zone Standard, 50K TPM | `openai` | Base URL **must** be `https://<account>.openai.azure.com/openai/v1` — resource root returns 404. `HINDSIGHT_API_LLM_MODEL` = the **deployment name**. Fallback URL shape if `/openai/v1` is unavailable: `.../openai/deployments/<deployment>?api-version=<ver>`. |
| Embeddings | `text-embedding-3-small` (1536 dims), Data Zone Standard, 120K TPM, `NoAutoUpgrade` | `openai` | ⚠️ **Dimension lock:** once memories exist, the embedding dimension cannot change without wiping/re-embedding. Fix the model *before* first retain. 1536 ≤ 2000, so HNSW and DiskANN both index it. |
| Reranker | `Cohere-rerank-v4.0-fast`, Data Zone Standard, capacity 500 (catalog default) | `cohere` + custom base URL, failover `rrf` | `HINDSIGHT_API_RERANKER_COHERE_BASE_URL` = full invoke URL, used verbatim (query string allowed). Read the target URI from the deployment page after the first deployment, set `rerankInvokeUrl`, redeploy. Until then the template runs `HINDSIGHT_API_RERANKER_PROVIDER=rrf`. |

All three models are offered as Data Zone Standard in swedencentral and westeurope (verified
September 8, 2026 via the model catalog). Key-based auth on Foundry accounts is allowed in the
target subscription (the existing team resources run with it). If that policy changes, front
the model endpoints with our **APIM AI Gateway** (managed-identity backend auth) and point
Hindsight's base URLs at APIM with a subscription key — Hindsight only needs an
OpenAI-compatible/Cohere-compatible HTTPS endpoint plus a key.

## 6. Configuration reference (API app)

Implemented in [`infra/modules/containerapps.bicep`](infra/modules/containerapps.bicep);
`@kv` = Key Vault secret reference via the user-assigned identity. All variable names verified
against the Hindsight 0.9 configuration reference.

```bash
# --- Database -------------------------------------------------------------
HINDSIGHT_API_DATABASE_URL=@kv:psql-connection-string
#   postgresql://hindsight:<url-encoded-pw>@psql-weu-aaih-hindsight-prod.<zone>:5432/hindsight?sslmode=require
HINDSIGHT_API_VECTOR_EXTENSION=pgvector          # later: pgvectorscale (= pg_diskann on Azure)

# --- LLM (Azure OpenAI via Foundry) ---------------------------------------
HINDSIGHT_API_LLM_PROVIDER=openai
HINDSIGHT_API_LLM_BASE_URL=https://ais-sdc-aaih-hindsight-prod.openai.azure.com/openai/v1
HINDSIGHT_API_LLM_MODEL=gpt-5-mini               # deployment name
HINDSIGHT_API_LLM_API_KEY=@kv:foundry-api-key
HINDSIGHT_API_LLM_OUTPUT_LANGUAGE=English        # team ground rule: shared memory in EN

# --- Embeddings (Azure OpenAI via Foundry) --------------------------------
HINDSIGHT_API_EMBEDDINGS_PROVIDER=openai
HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL=https://ais-sdc-aaih-hindsight-prod.openai.azure.com/openai/v1
HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL=text-embedding-3-small   # deployment name, 1536 dims
HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY=@kv:foundry-api-key
# NOTE: embeddings env vars carry the provider segment (…_OPENAI_…) — a frequent pitfall.

# --- Reranker (first deployment: fail-open fusion order) -------------------
HINDSIGHT_API_RERANKER_PROVIDER=rrf
# --- Reranker (after rerankInvokeUrl is set) --------------------------------
# HINDSIGHT_API_RERANKER_PROVIDER=cohere
# HINDSIGHT_API_RERANKER_COHERE_BASE_URL=<full invoke URL of the Cohere deployment>
# HINDSIGHT_API_RERANKER_COHERE_MODEL=Cohere-rerank-v4.0-fast
# HINDSIGHT_API_RERANKER_COHERE_API_KEY=@kv:foundry-api-key
# HINDSIGHT_API_RERANKER_1_PROVIDER=rrf          # failover: keep fusion order, don't fail recall

# --- AuthN / server -------------------------------------------------------
HINDSIGHT_API_TENANT_EXTENSION=hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension
HINDSIGHT_API_TENANT_API_KEY=@kv:hindsight-tenant-key
HINDSIGHT_API_WORKER_ID=hindsight-weu-prod       # stable worker identity across restarts
HINDSIGHT_API_LOG_FORMAT=json                    # structured logs → Log Analytics
HINDSIGHT_API_HOST=0.0.0.0
HINDSIGHT_API_PORT=8888
# HINDSIGHT_API_MCP_ENABLED=true                 # default; MCP at /mcp/{bank_id}/
```

Control Plane app:

```bash
PORT=9999
HINDSIGHT_CP_DATAPLANE_API_URL=https://<api-fqdn>
HINDSIGHT_CP_DATAPLANE_API_KEY=@kv:hindsight-tenant-key
HINDSIGHT_CP_ACCESS_KEY=@kv:cp-access-key        # plus optional ACA built-in Entra ID auth on ingress
```

## 7. Team access (the actual point)

One server, one shared tenant key (phase 1), memory organized in **banks**:

| Bank | Purpose |
|---|---|
| `team-ide` | Shared knowledge for this repo's topics (IDE, agent tooling, conventions) |
| `team-<project>` | One shared bank per ongoing project (e.g. `team-apiops`, `team-datamesh`) |
| `user-<alias>` | Optional personal banks (preferences, private working notes) |

Client wiring per team member:

```bash
# Claude Code — hindsight-memory plugin in remote mode (recommended: auto-recall/retain,
# knowledge tools; the plugin skips the local daemon when hindsightApiUrl is set)
cat > ~/.hindsight/claude-code.json << 'JSON'
{ "hindsightApiUrl": "https://<api-fqdn>", "hindsightApiToken": "<tenant-key>", "bankId": "team-ide" }
JSON

# Claude Code — plain MCP (retain/recall/reflect become native tools)
claude mcp add --transport http hindsight https://<api-fqdn>/mcp/team-ide/ \
  --header "Authorization: Bearer <tenant-key>"

# Hindsight CLI (used by the hindsight-self-hosted skill)
mkdir -p ~/.hindsight && cat > ~/.hindsight/config << 'EOF'
api_url = "https://<api-fqdn>"
api_key = "<tenant-key>"
EOF
```

The tenant key is distributed through a shared 1Password vault and loaded by the
`secrets-management/` loader, never pasted into repo files. The repo-local
`hindsight-self-hosted` skill then gives every Claude Code instance the same retain/recall
workflow against the shared server. Bank/tag design (mission statements, tag schema,
dispositions) is a follow-up workstream — run the `hindsight-architect` skill once the
service is up. Valuable local memories can move over with the document export/import API
(present in 0.9.2).

## 8. Rollout phases

| Phase | Scope | Status |
|---|---|---|
| **0 — Foundation** | Subscription decision, naming, tags, Bicep for RG, VNet + subnets, Key Vault, Log Analytics, UAMI. | IaC written and compiled (Sep 8, 2026). **Subscription decision pending.** |
| **1 — Data layer** | PG Flexible Server (PG 17, private access), allowlist `VECTOR,PG_DISKANN`, database, secrets to KV. | In the same Bicep deployment. |
| **2 — Models** | Dedicated Foundry account with `gpt-5-mini`, `text-embedding-3-small`, `Cohere-rerank-v4.0-fast` (Data Zone Standard); key1 to KV. **Freeze the embedding model here.** | In the same Bicep deployment. |
| **3 — Runtime** | ACA env + API app (slim, env block above) + Control Plane app. `what-if`, approval, `create`, then: `pg_diskann`, rerank URL, smoke test (create bank, retain, recall, reflect), check `/metrics` and logs. | Ready to preview. ~1 hour incl. PostgreSQL provisioning. |
| **4 — Team onboarding** | Distribute API host + key (1PW shared vault), plugin remote mode / MCP / CLI setup per member, bank conventions, short runbook. Migrate/export valuable local memories where worth it. | ~0.5 day, after phase 3. |
| **5 — Hardening** | APIM front door (per-user subscriptions, Entra JWT, passthrough header for per-caller identity), private endpoints for Foundry/KV, KV purge protection, least-privilege DB role, PG HA + tuned backups, OTel traces → App Insights (`HINDSIGHT_API_OTEL_TRACES_ENABLED=true`), alerting. | On demand. |

## 9. Cost (rough, monthly, team stage)

| Item | Estimate |
|---|---|
| ACA API app (1 vCPU/2 GiB, always-on) + CP (scale-to-zero) | ~€50–75 |
| PostgreSQL Flexible `B2ms` + 32 GiB + 14 d PITR | ~€60–80 |
| Foundry usage (gpt-5-mini extraction, embeddings, rerank) at team volume | ~€10–40 |
| Key Vault, Log Analytics, networking | ~€10–20 |
| **Total** | **~€130–215 / month** |

Reserved capacity / prod HA excluded; numbers are order-of-magnitude for sizing the
conversation, not a quote.

## 10. Open items

1. **Subscription & governance — decision needed.** Proposal: the team's Claude Code
   subscription (AAIH), naming and tags per its convention (Section 2). Alternative: ECM
   Shared. Real tag values go into the gitignored parameter file.
2. ~~Key-auth policy on Foundry~~ — verified allowed in the proposed subscription (existing
   team resources run with key auth). Re-check only if the subscription changes.
3. **Rerank invoke URL** — read from the Foundry deployment page after the first deployment,
   set `rerankInvokeUrl`, redeploy. Until then recall runs with `rrf`.
4. **ghcr.io egress** — confirm pulls from ghcr.io are acceptable or import images to ACR.
5. **Data classification** — shared memory will contain internal engineering knowledge;
   confirm internal-only classification and retention expectations before onboarding.
6. **Least-privilege DB role** — phase 1 uses the administrator login; create a dedicated role
   and re-point the connection string at hardening.
7. **Pipeline** — no GitHub Actions from this public repo into the corporate tenant; revisit
   when the topic moves to an internal repo.

## 11. Sources

- Hindsight docs (local skill `hindsight-docs`, 0.9 line): installation, configuration
  (every variable in Section 6 checked), storage, services, MCP server, monitoring — including
  the Azure-specific notes on `pg_diskann`, Azure OpenAI URL shapes, and the Cohere-compatible
  rerank endpoint; `cross_encoder.py` in the Hindsight repo for the verbatim base-URL behavior.
- ghcr.io image configs (September 8, 2026): `hindsight-api:0.9.2-slim` exposes 8888,
  `hindsight-control-plane:0.9.2` exposes 9999.
- hindsight-memory Claude Code plugin 0.7.2 README: remote mode via `hindsightApiUrl` /
  `hindsightApiToken`.
- Microsoft Learn (verified Sep 2026): pg_diskann 0.6.5 / vector 0.8.2 extension matrix
  per PG version; `azure.extensions` allowlist procedure; Cohere-rerank-v4.0 Data Zone
  Standard availability.
- Azure inventory (September 8, 2026, read-only): Resource Graph across all subscriptions,
  model catalog for swedencentral/westeurope, Flexible Server capabilities for westeurope,
  existing naming/tag convention in the proposed subscription.
