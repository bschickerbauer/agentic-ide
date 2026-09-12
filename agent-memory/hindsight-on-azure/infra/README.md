# Hindsight on Azure — Infrastructure as Code

Bicep templates for the shared Hindsight memory service described in
[`../deployment-plan.md`](../deployment-plan.md). One subscription-scope deployment creates
everything from the resource group to the running Container Apps.

**Nothing in this folder deploys automatically.** `deploy.sh` defaults to `what-if`; `create`
is only run after explicit approval of the preview.

## What gets deployed

| Module | Resources |
|---|---|
| `main.bicep` | Resource group, naming, wiring, outputs |
| `modules/monitoring.bicep` | Log Analytics workspace |
| `modules/network.bicep` | VNet with a Container Apps subnet and a delegated PostgreSQL subnet, private DNS zone + link |
| `modules/identity.bicep` | User-assigned managed identity for both apps |
| `modules/foundry.bicep` | Azure AI Foundry (AI Services) account with three model deployments: `gpt-5-mini`, `text-embedding-3-small`, `Cohere-rerank-v4.0-fast` |
| `modules/postgres.bicep` | PostgreSQL Flexible Server 17 (private access), `hindsight` database, `azure.extensions = VECTOR,PG_DISKANN` |
| `modules/keyvault.bicep` | Key Vault (RBAC), Secrets User role for the identity, all secrets (connection string, Foundry key1, tenant key, UI access key) |
| `modules/containerapps.bicep` | Container Apps environment (VNet-integrated, Consumption profile), Hindsight API app, Control Plane app, optional Entra ID auth on the UI |

Names follow the convention already used in the host subscription:
`<type>-<region>-<org>-hindsight-<env>`, e.g. `rg-weu-aaih-hindsight-prod`,
`ca-weu-aaih-hindsight-api-prod`, `psql-weu-aaih-hindsight-prod`. All tokens are parameters.

## Prerequisites

- Azure CLI with Bicep (`az bicep version`), signed in with an identity that has **Owner** on
  the target subscription (role assignment for the managed identity needs it).
- macOS or WSL2 with bash. The wrapper is plain bash; the Bicep is platform-neutral.
- Three secrets in the shell environment. Generate them once, store them in 1Password, and let
  the 1Password-backed loader (see `secrets-management/`) export them:

  | Variable | Used for |
  |---|---|
  | `HINDSIGHT_PG_ADMIN_PASSWORD` | PostgreSQL administrator password (any characters; URL-encoded by the template) |
  | `HINDSIGHT_TENANT_KEY` | Shared Hindsight bearer key that every client sends |
  | `HINDSIGHT_CP_ACCESS_KEY` | Login key for the Control Plane UI |
  | `HINDSIGHT_CP_ENTRA_CLIENT_SECRET` | Optional; only with `cpEntraClientId` |

  Example generator: `openssl rand -base64 48 | tr -d '/+=' | cut -c1-48`.

## Deploy

```bash
cd agent-memory/hindsight-on-azure/infra

# 1. Local parameter file with the real governance tags (gitignored)
cp main.bicepparam main.local.bicepparam
$EDITOR main.local.bicepparam

# 2. Preview (read-only)
./deploy.sh "<subscription-id>" what-if

# 3. Deploy — only after the preview has been reviewed and approved
./deploy.sh "<subscription-id>" create
```

The deployment takes roughly 15–25 minutes; PostgreSQL Flexible Server is the slow part.
Outputs (no secrets): API FQDN, Control Plane FQDN, MCP URL template, Key Vault name,
PostgreSQL FQDN, Foundry endpoint.

## After the first deployment

1. **Extensions in the database.** The allowlist is set by the template; the extensions are
   created inside the database. Hindsight creates `vector` itself on first start. Create
   `pg_diskann` now so the later DiskANN switch needs no server change:

   ```sql
   -- connect to the hindsight database (from inside the VNet, e.g. via a jump host or
   -- an Azure Cloud Shell attached to the VNet)
   CREATE EXTENSION IF NOT EXISTS vector;
   CREATE EXTENSION IF NOT EXISTS pg_diskann CASCADE;
   ```

2. **Rerank invoke URL.** The first deployment runs with `HINDSIGHT_API_RERANKER_PROVIDER=rrf`
   because the exact invoke URL of the Cohere deployment on a Foundry account is read from the
   portal after the deployment exists (deployment page → target URI). Hindsight POSTs to that
   URL verbatim (query string included). Put it into `rerankInvokeUrl` in the local parameter
   file and redeploy; the template then switches to `cohere` with `rrf` as failover member.

3. **Smoke test.**

   ```bash
   API="https://<apiFqdn>"
   curl -fsS "$API/health/ready"
   curl -fsS -H "Authorization: Bearer $HINDSIGHT_TENANT_KEY" "$API/version"
   hindsight memory retain team-ide "Smoke test: shared Hindsight on Azure is live." \
     --api-url "$API" --api-key "$HINDSIGHT_TENANT_KEY"
   hindsight memory recall team-ide "shared Hindsight on Azure" \
     --api-url "$API" --api-key "$HINDSIGHT_TENANT_KEY"
   ```

4. **Control Plane.** Open `https://<controlPlaneFqdn>`, log in with the access key. For Entra
   ID login create an app registration (web redirect
   `https://<controlPlaneFqdn>/.auth/login/aad/callback`), set `cpEntraClientId` and the
   client secret variable, redeploy.

## Client wiring (team members)

```bash
# Claude Code — hindsight-memory plugin, remote mode (recommended)
cat > ~/.hindsight/claude-code.json << 'JSON'
{ "hindsightApiUrl": "https://<apiFqdn>", "hindsightApiToken": "<tenant-key>", "bankId": "team-ide" }
JSON

# Claude Code — plain MCP (no plugin)
claude mcp add --transport http hindsight "https://<apiFqdn>/mcp/team-ide/" \
  --header "Authorization: Bearer <tenant-key>"

# Hindsight CLI
mkdir -p ~/.hindsight && printf 'api_url = "https://<apiFqdn>"\napi_key = "<tenant-key>"\n' > ~/.hindsight/config
```

## Operations notes

- **Worker identity.** The API runs one replica with the internal worker and
  `HINDSIGHT_API_WORKER_ID` fixed. Scale-out requires disabling the internal worker and adding
  a dedicated worker app (see plan, section 3).
- **Upgrades.** Change `hindsightVersion`, redeploy. Migrations run on startup; the startup
  probe allows up to five minutes.
- **Secrets rotation.** Rotate in Key Vault (or redeploy with new environment values); Container
  Apps picks up new secret versions on the next revision restart.
- **Key Vault purge protection** is off while the service is being iterated on
  (`enablePurgeProtection` parameter). Switch it on at hardening.
- **Least-privilege DB role.** Phase 1 connects as the server administrator. Creating a dedicated
  role and pointing `psql-connection-string` at it is a hardening step.

## Checks without deploying

```bash
az bicep build --file main.bicep --stdout > /dev/null
HINDSIGHT_PG_ADMIN_PASSWORD=x HINDSIGHT_TENANT_KEY=x HINDSIGHT_CP_ACCESS_KEY=x \
  az bicep build-params --file main.bicepparam --stdout > /dev/null
bash -n deploy.sh
```
