# Hindsight on Azure — Deployment Plan

**Status:** Draft v1 (September 5, 2026) · **Owner:** Bernd Schickerbauer (SDC)
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
- Team members connect via the built-in **MCP endpoint** (`/mcp/{bank_id}/`) from
  Claude Code, or via the Hindsight CLI/SDKs — from any machine, any site.

No GPU, no vector database product, no Kubernetes cluster required.

## 2. Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Compute | **Azure Container Apps** (dedicated env not required; Consumption plan) | Slim image is ~500 MB, stateless, no GPU needed. Managed identity, Key Vault refs, VNet integration, revisions. AKS + the official Helm chart is the documented alternative — only worth it if we standardize this on an existing cluster. |
| Image variant | **`hindsight-api:<version>-slim`** + external model providers | Full image is ~9 GB because it bundles local embedding/reranker models and PyTorch. On Azure we delegate all model calls to Foundry → small image, fast deploys, ~512 MB–1 GB RAM. |
| Database | **Azure Database for PostgreSQL Flexible Server, PG 17** | Hindsight requires PostgreSQL 14+ with a vector extension; Azure is a tested managed service in the Hindsight docs. |
| Vector index | **Start `pgvector` (HNSW), enable `pg_diskann` from day 1** | pgvector 0.8.2 on Flexible Server (all live PG majors) — supports Hindsight's iterative index scans (needs ≥ 0.8.0). HNSW is the most-deployed path and ideal < 10 M vectors; team-scale memory is far below that. `pg_diskann` 0.6.5 (PG 14–18) is allow-listed up front so the documented switch to `HINDSIGHT_API_VECTOR_EXTENSION=pgvectorscale` (which uses DiskANN on Azure) is a config change + re-index, not a server migration. |
| LLM | **Azure OpenAI via Foundry** — `gpt-5-mini` deployment (Hindsight default model), Data Zone Standard (EU) | Reached with `HINDSIGHT_API_LLM_PROVIDER=openai` and base URL `https://<resource>.openai.azure.com/openai/v1` (the resource root and the bare deployments URL both 404 — documented Hindsight gotcha). |
| Embeddings | **`text-embedding-3-small` (1536 dims)** via the same Foundry resource | Explicitly supported by Hindsight's `openai` embeddings provider with an Azure base URL. 1536 dims works with both HNSW (≤ 2000-dim index limit) and DiskANN. Multilingual-capable — relevant for a German/English team. |
| Reranker | **Cohere Rerank v4.0 Fast on Foundry** (Data Zone Standard EU: westeurope, germanywestcentral, swedencentral), **failover to `rrf`** | Hindsight's `cohere` reranker provider explicitly supports Azure AI Foundry via `HINDSIGHT_API_RERANKER_COHERE_BASE_URL` (full invoke URL). The indexed failover member `rrf` makes recall fail open (fusion order) instead of failing when the reranker is down. |
| AuthN (phase 1) | Hindsight built-in **`ApiKeyTenantExtension`** (single shared bearer key) + HTTPS via ACA ingress | Smallest thing that safely works for one team. |
| AuthN (phase 2) | **APIM in front** — per-user subscription keys / Entra ID JWT validation; APIM injects the shared Hindsight key and a per-caller header (`HINDSIGHT_API_EXTENSION_PASSTHROUGH_HEADERS`) | Hindsight documents exactly this gateway pattern. Fits our APIOps estate; MCP is streamable HTTP and proxies through APIM. |
| Secrets | **Key Vault** + user-assigned managed identity, ACA secret references | LLM/embedding/rerank keys, DB connection string, tenant API key. No secrets in app config. |
| Memory language | `HINDSIGHT_API_LLM_OUTPUT_LANGUAGE=English` | Team ground rule: artifacts and shared knowledge in EN-US, regardless of input language. |

## 3. Target architecture

```
 Team clients (any site, any host)
 ├─ Claude Code  ── MCP (streamable HTTP)  ─┐
 ├─ Hindsight CLI (~/.hindsight/config)     ├── https ──►  [Phase 2: APIM]  ──►  ACA ingress
 └─ SDKs (Python/Node) / Control Plane UI  ─┘                                        │
                                                                                     ▼
   Azure Container Apps environment (VNet-integrated, West Europe)
   ├─ ca-hindsight-api   ghcr.io/vectorize-io/hindsight-api:<ver>-slim   (internal worker on)
   └─ ca-hindsight-cp    ghcr.io/vectorize-io/hindsight-control-plane    (internal ingress)
                │                                       │
                │ private endpoint / VNet               │ model calls (https)
                ▼                                       ▼
   Azure Database for PostgreSQL                Azure AI Foundry (AAIH resource)
   Flexible Server PG17                         ├─ gpt-5-mini            (LLM, DZ-EU)
   extensions: vector 0.8.2,                    ├─ text-embedding-3-small (1536 dims)
               pg_diskann 0.6.5                 └─ Cohere-rerank-v4.0-fast (DZ-EU)

   Cross-cutting: Key Vault + UAMI · Log Analytics (+ optional OTel→App Insights) · Bicep IaC
```

### Components

| Component | Resource (proposal) | Notes |
|---|---|---|
| Resource group | `RG-WEU-HINDSIGHT-DEV` | Align final name with CAF/ANDRITZ convention; subscription TBD. |
| ACA environment | `cae-weu-hindsight-dev` | VNet-integrated; Consumption workload profile. |
| API app | `ca-weu-hindsight-api-dev` | 1 vCPU / 2 GiB, **min 1 / max 1 replica** initially (see worker identity note), external ingress :8888. |
| Control Plane app | `ca-weu-hindsight-cp-dev` | 0.25 vCPU / 0.5 GiB, scale 0–1, ingress external, protected by ACA built-in Entra ID auth + `HINDSIGHT_CP_ACCESS_KEY`. Talks to the API server-side (`HINDSIGHT_CP_DATAPLANE_API_URL` + `..._API_KEY`), so the API's internal FQDN suffices. |
| PostgreSQL | `psql-weu-hindsight-dev` | PG 17, `Standard_B2ms` to start (General Purpose `D2ds_v5` if latency matters), 32–128 GiB storage, private access. |
| Key Vault | `kv-weu-hindsight-dev` | RBAC mode; UAMI gets *Key Vault Secrets User*. |
| Managed identity | `id-weu-hindsight-dev` | User-assigned, attached to both apps. |
| Log Analytics | `log-weu-hindsight-dev` | ACA logs; Hindsight set to `HINDSIGHT_API_LOG_FORMAT=json`. |
| Foundry | reuse **AAIH** Foundry resource | New deployments: `gpt-5-mini`, `text-embedding-3-small`, `Cohere-rerank-v4.0-fast`. |

**Container images:** pin a version tag (and ideally the digest) of
`ghcr.io/vectorize-io/hindsight-api:<version>-slim` and
`ghcr.io/vectorize-io/hindsight-control-plane:<version>`. Images are Cosign-signed
(keyless OIDC) — verify once in CI. If org policy requires a private registry, import via
`az acr import` and pull from ACR instead of ghcr.io.

**Worker identity (important):** Hindsight's background worker identifies itself by
hostname, which changes on every container restart — tasks claimed by a dead identity
stay parked. Set `HINDSIGHT_API_WORKER_ID` to a stable value. With the internal worker and
a single API replica this is one env var. If we later scale the API out, disable the
internal worker (`HINDSIGHT_API_WORKER_ENABLED=false`) and run a dedicated worker app with
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

Enable both extensions at the server level (allowlist) and in the database:

```bash
az postgres flexible-server parameter set \
  --resource-group RG-WEU-HINDSIGHT-DEV --server-name psql-weu-hindsight-dev \
  --name azure.extensions --value "VECTOR,PG_DISKANN"
```

```sql
CREATE DATABASE hindsight;
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
| HA | Off (dev/team stage) | Zone-redundant HA for prod hardening |
| Backups | PITR **14 days** (default 7) | + geo-redundant backup if the memory estate becomes business-critical |
| Connectivity | Private access (VNet integration or private endpoint) + `sslmode=require` | — |
| Users | Dedicated `hindsight` DB role (no server admin); password in Key Vault | Entra ID DB auth is possible but Hindsight expects a static `DATABASE_URL` — token rotation doesn't fit; keep password auth for this service. |
| Pool | Defaults (`min 5 / max 100`) are fine; Flexible Server `max_connections` on 8 GiB ≈ 859 | Add PgBouncer (built-in) only with many replicas — then set `HINDSIGHT_API_MIGRATION_DATABASE_URL` to the direct port 5432, since migrations must bypass the pooler. |

## 5. Model wiring (Azure AI Foundry)

| Role | Deployment | Hindsight provider | Notes |
|---|---|---|---|
| LLM (fact extraction, entity resolution, reflect, consolidation) | `gpt-5-mini` (Data Zone Standard EU) | `openai` | Base URL **must** be `https://<resource>.openai.azure.com/openai/v1` — resource root returns 404. `HINDSIGHT_API_LLM_MODEL` = the **deployment name**. Fallback URL shape if `/openai/v1` is unavailable: `.../openai/deployments/<deployment>?api-version=<ver>`. |
| Embeddings | `text-embedding-3-small` (1536 dims) | `openai` | ⚠️ **Dimension lock:** once memories exist, the embedding dimension cannot change without wiping/re-embedding. Fix the model *before* first retain. 1536 ≤ 2000, so HNSW and DiskANN both index it. |
| Reranker | `Cohere-rerank-v4.0-fast` (Data Zone Standard EU) | `cohere` + custom base URL | `HINDSIGHT_API_RERANKER_COHERE_BASE_URL` = full invoke URL (e.g. `https://<deployment>.<region>.models.ai.azure.com/v2/rerank`). Configure failover member 1 = `rrf` so recall degrades gracefully instead of failing. |

If ANDRITZ policy disables key-based auth on AI resources, front the model endpoints with
our **APIM AI Gateway** (managed-identity backend auth) and point Hindsight's base URLs at
APIM with a subscription key — Hindsight only needs an OpenAI-compatible/Cohere-compatible
HTTPS endpoint plus a key.

## 6. Configuration reference (API app)

Secrets (`@kv` = Key Vault reference via managed identity) — everything else is plain env.

```bash
# --- Database -------------------------------------------------------------
HINDSIGHT_API_DATABASE_URL=@kv:psql-connection-string
#   postgresql://hindsight:<pw>@psql-weu-hindsight-dev.postgres.database.azure.com:5432/hindsight?sslmode=require
HINDSIGHT_API_VECTOR_EXTENSION=pgvector          # later: pgvectorscale (= pg_diskann on Azure)

# --- LLM (Azure OpenAI via Foundry) ---------------------------------------
HINDSIGHT_API_LLM_PROVIDER=openai
HINDSIGHT_API_LLM_BASE_URL=https://<aoai-resource>.openai.azure.com/openai/v1
HINDSIGHT_API_LLM_MODEL=gpt-5-mini               # deployment name
HINDSIGHT_API_LLM_API_KEY=@kv:aoai-api-key
HINDSIGHT_API_LLM_OUTPUT_LANGUAGE=English        # team ground rule: shared memory in EN

# --- Embeddings (Azure OpenAI via Foundry) --------------------------------
HINDSIGHT_API_EMBEDDINGS_PROVIDER=openai
HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL=https://<aoai-resource>.openai.azure.com/openai/v1
HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL=text-embedding-3-small   # deployment name, 1536 dims
HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY=@kv:aoai-api-key
# NOTE: embeddings env vars carry the provider segment (…_OPENAI_…) — a frequent pitfall.

# --- Reranker (Cohere Rerank on Foundry, fail-open) ------------------------
HINDSIGHT_API_RERANKER_PROVIDER=cohere
HINDSIGHT_API_RERANKER_COHERE_BASE_URL=https://<rerank-deployment>.<region>.models.ai.azure.com/v2/rerank
HINDSIGHT_API_RERANKER_COHERE_MODEL=Cohere-rerank-v4.0-fast
HINDSIGHT_API_RERANKER_COHERE_API_KEY=@kv:rerank-api-key
HINDSIGHT_API_RERANKER_1_PROVIDER=rrf            # failover: keep fusion order, don't fail recall

# --- AuthN / server -------------------------------------------------------
HINDSIGHT_API_TENANT_EXTENSION=hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension
HINDSIGHT_API_TENANT_API_KEY=@kv:hindsight-tenant-key
HINDSIGHT_API_WORKER_ID=hindsight-weu-dev        # stable worker identity across restarts
HINDSIGHT_API_LOG_FORMAT=json                    # structured logs → Log Analytics
# HINDSIGHT_API_MCP_ENABLED=true                 # default; MCP at /mcp/{bank_id}/
```

Control Plane app:

```bash
HINDSIGHT_CP_DATAPLANE_API_URL=https://ca-weu-hindsight-api-dev.internal.<env>.azurecontainerapps.io
HINDSIGHT_CP_DATAPLANE_API_KEY=@kv:hindsight-tenant-key
HINDSIGHT_CP_ACCESS_KEY=@kv:cp-access-key        # plus ACA built-in Entra ID auth on ingress
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
# Claude Code — MCP (recommended; retain/recall/reflect become native tools)
claude mcp add --transport http hindsight https://<api-host>/mcp/team-ide/ \
  --header "Authorization: Bearer <tenant-key>"

# Hindsight CLI (used by the hindsight-self-hosted skill)
mkdir -p ~/.hindsight && cat > ~/.hindsight/config << 'EOF'
api_url = "https://<api-host>"
api_key = "<tenant-key>"
EOF
```

The repo-local `hindsight-self-hosted` skill then gives every Claude Code instance the same
retain/recall workflow against the shared server. Bank/tag design (mission statements, tag
schema, dispositions) is a follow-up workstream — run the `hindsight-architect` skill once
the service is up.

## 8. Rollout phases

| Phase | Scope | Effort |
|---|---|---|
| **0 — Foundation** | Subscription decision, RG, VNet (+ subnets: ACA, PG), Key Vault, Log Analytics, UAMI. Bicep from the start (`infra/` in this repo, deployed via GitHub Actions like APIOps). | ~0.5 day |
| **1 — Data layer** | PG Flexible Server (PG 17, private access), allowlist `VECTOR,PG_DISKANN`, create DB + role + extensions, secrets to KV. | ~0.5 day |
| **2 — Models** | Foundry deployments: `gpt-5-mini`, `text-embedding-3-small`, `Cohere-rerank-v4.0-fast` (DZ-EU); keys/quotas to KV. **Freeze the embedding model here.** | ~0.5 day |
| **3 — Runtime** | ACA env + API app (slim, env block above) + Control Plane app (Entra auth). Smoke test: create bank, retain, recall, reflect via `curl`/CLI; check `/metrics`, logs. | ~0.5–1 day |
| **4 — Team onboarding** | Distribute API host + key (1PW shared vault), MCP + CLI setup per member, bank conventions, short runbook. Migrate/export valuable local memories where worth it. | ~0.5 day |
| **5 — Hardening** | APIM front door (per-user subscriptions, Entra JWT, passthrough header for per-caller identity), private endpoints for Foundry/KV, PG HA + tuned backups, OTel traces → App Insights (`HINDSIGHT_API_OTEL_TRACES_ENABLED=true`), alerting. | on demand |

## 9. Cost (rough, monthly, dev/team stage)

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

1. **Subscription & governance** — which subscription hosts this (ECM Shared vs. AAIH)?
   Final naming per ANDRITZ convention.
2. **Key-auth policy on Foundry** — if disabled, route models through APIM AI Gateway
   (managed identity) instead of direct keys.
3. **Rerank endpoint URL shape** — confirm the exact invoke URL (`/v1` vs `/v2/rerank`)
   after deploying the Cohere model; set `HINDSIGHT_API_RERANKER_COHERE_BASE_URL` accordingly.
4. **ghcr.io egress** — confirm pulls from ghcr.io are acceptable or import images to ACR.
5. **Data classification** — shared memory will contain internal engineering knowledge;
   confirm internal-only classification and retention expectations before onboarding.

## 11. Sources

- Hindsight docs (local skill `hindsight-docs`): installation, configuration, storage,
  services, MCP server, monitoring — including the Azure-specific notes on
  `pg_diskann`, Azure OpenAI URL shapes, and the Foundry-compatible rerank endpoint.
- Microsoft Learn (verified Sep 2026): pg_diskann 0.6.5 / vector 0.8.2 extension matrix
  per PG version; `azure.extensions` allowlist procedure; Cohere-rerank-v4.0 Data Zone
  Standard EU availability.
