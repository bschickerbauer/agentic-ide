// Committed parameter file with placeholders. For a real deployment:
//   cp main.bicepparam main.local.bicepparam   (gitignored)
// and fill in the governance tags there. Secrets are read from environment variables that
// the 1Password-backed shell provides (see secrets-management/); they never live in a file.

using './main.bicep'

param environment = 'prod'
param location = 'westeurope'
param foundryLocation = 'swedencentral'

param tags = {
  Application_Owner: '<owner>'
  Company_Code: '<company-code>'
  Company_Name: '<company-name>'
  Customer_Cost_Collector: '<cost-collector>'
  Description: 'Shared agent memory (Hindsight) for the SDC team'
  Environment: 'Production'
  Service_Name: 'hindsight'
  Service_Provider: '<service-provider>'
  Technical_Contact: '<technical-contact>'
}

// Hindsight release (pinned)
param hindsightVersion = '0.9.2'

// Secrets — provided by the environment, never typed into this file.
param postgresAdminPassword = readEnvironmentVariable('HINDSIGHT_PG_ADMIN_PASSWORD')
param hindsightTenantKey = readEnvironmentVariable('HINDSIGHT_TENANT_KEY')
param cpAccessKey = readEnvironmentVariable('HINDSIGHT_CP_ACCESS_KEY')

// Set after the first deployment, once the Cohere rerank invoke URL is known
// (deployment-plan.md, open item 3). Empty = reranker falls back to rrf.
param rerankInvokeUrl = ''

// Optional Entra ID login for the Control Plane UI (leave empty to rely on the access key).
param cpEntraClientId = ''
param cpEntraClientSecret = readEnvironmentVariable('HINDSIGHT_CP_ENTRA_CLIENT_SECRET', '')
