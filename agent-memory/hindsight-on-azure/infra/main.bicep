// Hindsight on Azure — subscription-scope entry point.
// Creates the resource group and wires the modules together.
// Deploy with ./deploy.sh (what-if first). Nothing here is deployed automatically.

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Naming and placement
// ---------------------------------------------------------------------------

@description('Environment token used in resource names. The host subscription uses the "prod" convention for all its resources.')
@allowed(['prod', 'dev'])
param environment string = 'prod'

@description('Region token used in resource names (matches the convention already used in the host subscription).')
param regionToken string = 'weu'

@description('Organization token used in resource names (matches the convention already used in the host subscription).')
param orgToken string = 'aaih'

@description('Team token used in the Foundry account name (matches the existing Foundry resources of the team).')
param teamToken string = 'sdc'

@description('Workload token used in resource names.')
param workload string = 'hindsight'

@description('Region for the resource group, networking, PostgreSQL, Key Vault, Log Analytics and Container Apps.')
param location string = 'westeurope'

@description('Region for the Azure AI Foundry (AI Services) account. Data Zone Standard EU deployments are offered in swedencentral and westeurope.')
param foundryLocation string = 'swedencentral'

@description('Governance tags. Keep the placeholders in the committed parameter file; put the real values into main.local.bicepparam (gitignored).')
param tags object = {
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

// ---------------------------------------------------------------------------
// Hindsight runtime
// ---------------------------------------------------------------------------

@description('Hindsight release to run. Pin a version; never use latest.')
param hindsightVersion string = '0.9.2'

@description('API image (slim variant: no local models, all model calls go to Foundry).')
param hindsightApiImage string = 'ghcr.io/vectorize-io/hindsight-api:${hindsightVersion}-slim'

@description('Control Plane (Web UI) image.')
param hindsightControlPlaneImage string = 'ghcr.io/vectorize-io/hindsight-control-plane:${hindsightVersion}'

@description('Stable worker identity. Hindsight parks tasks claimed by a worker id that disappears, so this must survive container restarts.')
param workerId string = 'hindsight-${regionToken}-${environment}'

@description('Shared tenant bearer key (phase 1 auth). Provide via environment variable, never in a file.')
@secure()
param hindsightTenantKey string

@description('Access key for the Control Plane UI login. Provide via environment variable, never in a file.')
@secure()
param cpAccessKey string

// ---------------------------------------------------------------------------
// PostgreSQL Flexible Server
// ---------------------------------------------------------------------------

@description('Administrator login. Hindsight connects with this role in phase 1; a least-privilege role is a hardening step.')
param postgresAdminLogin string = 'hindsight'

@description('Administrator password. Provide via environment variable, never in a file. URL-encoded automatically for the connection string.')
@secure()
param postgresAdminPassword string

param postgresVersion string = '17'
param postgresSkuName string = 'Standard_B2ms'
param postgresSkuTier string = 'Burstable'
param postgresStorageGb int = 32
param postgresBackupRetentionDays int = 14

// ---------------------------------------------------------------------------
// Network (isolated VNet, no peering; any RFC1918 range works)
// ---------------------------------------------------------------------------

param vnetAddressPrefix string = '10.60.0.0/23'
param acaSubnetPrefix string = '10.60.0.0/24'
param postgresSubnetPrefix string = '10.60.1.0/28'

// ---------------------------------------------------------------------------
// Azure AI Foundry model deployments
// ---------------------------------------------------------------------------

@description('Deployment SKU for all three models. DataZoneStandard keeps inference inside the EU data zone.')
@allowed(['DataZoneStandard', 'GlobalStandard'])
param modelDeploymentSku string = 'DataZoneStandard'

param llmModelName string = 'gpt-5-mini'
param llmModelVersion string = '2025-08-07'
param llmDeploymentName string = 'gpt-5-mini'
@description('Capacity in thousands of tokens per minute.')
param llmCapacity int = 50

param embeddingsModelName string = 'text-embedding-3-small'
param embeddingsModelVersion string = '1'
param embeddingsDeploymentName string = 'text-embedding-3-small'
@description('Capacity in thousands of tokens per minute.')
param embeddingsCapacity int = 120

param rerankModelName string = 'Cohere-rerank-v4.0-fast'
param rerankModelVersion string = '1'
param rerankDeploymentName string = 'Cohere-rerank-v4.0-fast'
@description('Capacity units for the rerank deployment (catalog default is 500).')
param rerankCapacity int = 500

@description('Full invoke URL of the Cohere rerank deployment. Hindsight POSTs to this URL verbatim. Leave empty on the first deployment: the reranker then falls back to rrf and recall keeps working. Fill in after reading the target URI from the Foundry portal (plan, open item 3).')
param rerankInvokeUrl string = ''

// ---------------------------------------------------------------------------
// Optional: Entra ID login in front of the Control Plane (ACA built-in auth)
// ---------------------------------------------------------------------------

@description('Application (client) ID of an Entra ID app registration for the Control Plane. Empty disables built-in auth; the UI is then protected by the access key only.')
param cpEntraClientId string = ''

@secure()
param cpEntraClientSecret string = ''

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

var suffix = '${regionToken}-${orgToken}-${workload}-${environment}'
var resourceGroupName = 'rg-${suffix}'
var logAnalyticsName = 'log-${suffix}'
var vnetName = 'vnet-${suffix}'
var identityName = 'id-${suffix}'
var keyVaultName = take('kv${regionToken}${orgToken}${workload}${environment}', 24)
var postgresName = 'psql-${suffix}'
var foundryName = 'ais-${teamToken}-${orgToken}-${workload}-${environment}'
var containerAppsEnvName = 'cae-${suffix}'
var apiAppName = 'ca-${regionToken}-${orgToken}-${workload}-api-${environment}'
var cpAppName = 'ca-${regionToken}-${orgToken}-${workload}-cp-${environment}'
var privateDnsZoneName = '${workload}.private.postgres.database.azure.com'

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
  }
}

module network 'modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: {
    vnetName: vnetName
    location: location
    tags: tags
    vnetAddressPrefix: vnetAddressPrefix
    acaSubnetPrefix: acaSubnetPrefix
    postgresSubnetPrefix: postgresSubnetPrefix
    privateDnsZoneName: privateDnsZoneName
  }
}

module identity 'modules/identity.bicep' = {
  scope: rg
  name: 'identity'
  params: {
    name: identityName
    location: location
    tags: tags
  }
}

module foundry 'modules/foundry.bicep' = {
  scope: rg
  name: 'foundry'
  params: {
    name: foundryName
    location: foundryLocation
    tags: tags
    modelDeploymentSku: modelDeploymentSku
    llmModelName: llmModelName
    llmModelVersion: llmModelVersion
    llmDeploymentName: llmDeploymentName
    llmCapacity: llmCapacity
    embeddingsModelName: embeddingsModelName
    embeddingsModelVersion: embeddingsModelVersion
    embeddingsDeploymentName: embeddingsDeploymentName
    embeddingsCapacity: embeddingsCapacity
    rerankModelName: rerankModelName
    rerankModelVersion: rerankModelVersion
    rerankDeploymentName: rerankDeploymentName
    rerankCapacity: rerankCapacity
  }
}

module postgres 'modules/postgres.bicep' = {
  scope: rg
  name: 'postgres'
  params: {
    name: postgresName
    location: location
    tags: tags
    postgresVersion: postgresVersion
    skuName: postgresSkuName
    skuTier: postgresSkuTier
    storageGb: postgresStorageGb
    backupRetentionDays: postgresBackupRetentionDays
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    delegatedSubnetId: network.outputs.postgresSubnetId
    privateDnsZoneId: network.outputs.privateDnsZoneId
  }
}

module keyvault 'modules/keyvault.bicep' = {
  scope: rg
  name: 'keyvault'
  params: {
    name: keyVaultName
    location: location
    tags: tags
    uamiPrincipalId: identity.outputs.principalId
    foundryAccountId: foundry.outputs.id
    postgresFqdn: postgres.outputs.fqdn
    postgresDatabaseName: postgres.outputs.databaseName
    postgresAdminLogin: postgresAdminLogin
    postgresAdminPassword: postgresAdminPassword
    hindsightTenantKey: hindsightTenantKey
    cpAccessKey: cpAccessKey
    cpEntraClientSecret: cpEntraClientSecret
  }
}

module containerApps 'modules/containerapps.bicep' = {
  scope: rg
  name: 'containerapps'
  params: {
    environmentName: containerAppsEnvName
    apiAppName: apiAppName
    cpAppName: cpAppName
    location: location
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.id
    logAnalyticsCustomerId: monitoring.outputs.customerId
    infrastructureSubnetId: network.outputs.acaSubnetId
    uamiId: identity.outputs.id
    keyVaultUri: keyvault.outputs.vaultUri
    apiImage: hindsightApiImage
    cpImage: hindsightControlPlaneImage
    workerId: workerId
    llmBaseUrl: foundry.outputs.openAiV1BaseUrl
    llmDeploymentName: llmDeploymentName
    embeddingsBaseUrl: foundry.outputs.openAiV1BaseUrl
    embeddingsDeploymentName: embeddingsDeploymentName
    rerankInvokeUrl: rerankInvokeUrl
    rerankDeploymentName: rerankDeploymentName
    cpEntraClientId: cpEntraClientId
  }
}

// ---------------------------------------------------------------------------
// Outputs (no secrets)
// ---------------------------------------------------------------------------

output resourceGroupName string = rg.name
output apiFqdn string = containerApps.outputs.apiFqdn
output controlPlaneFqdn string = containerApps.outputs.cpFqdn
output mcpUrlTemplate string = 'https://${containerApps.outputs.apiFqdn}/mcp/{bank_id}/'
output keyVaultName string = keyvault.outputs.name
output postgresFqdn string = postgres.outputs.fqdn
output foundryEndpoint string = foundry.outputs.endpoint
output foundryAccountName string = foundry.outputs.name
