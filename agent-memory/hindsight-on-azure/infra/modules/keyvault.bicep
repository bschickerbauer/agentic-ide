// Key Vault (RBAC mode) holding every secret the apps need. The apps read them through
// Container Apps secret references with the user-assigned identity; nothing lands in app config.

param name string
param location string
param tags object

@description('Principal id of the user-assigned identity that the apps run as.')
param uamiPrincipalId string

@description('Resource id of the Foundry account; its key1 is stored as foundry-api-key.')
param foundryAccountId string

param postgresFqdn string
param postgresDatabaseName string
param postgresAdminLogin string

@secure()
param postgresAdminPassword string

@secure()
param hindsightTenantKey string

@secure()
param cpAccessKey string

@secure()
param cpEntraClientSecret string = ''

@description('Purge protection cannot be switched off once enabled and blocks re-using the vault name for 90 days after deletion. Off while the service is being iterated on; switch on at hardening.')
param enablePurgeProtection bool = false

// Built-in role: Key Vault Secrets User
var keyVaultSecretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource appsCanReadSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, uamiPrincipalId, keyVaultSecretsUserRoleId)
  scope: vault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalId: uamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Password is URL-encoded so any generated value is safe in the connection string.
var connectionString = 'postgresql://${postgresAdminLogin}:${uriComponent(postgresAdminPassword)}@${postgresFqdn}:5432/${postgresDatabaseName}?sslmode=require'

resource secretConnectionString 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'psql-connection-string'
  properties: {
    value: connectionString
    contentType: 'PostgreSQL connection URL used as HINDSIGHT_API_DATABASE_URL'
  }
}

resource secretPostgresPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'psql-admin-password'
  properties: {
    value: postgresAdminPassword
    contentType: 'PostgreSQL administrator password'
  }
}

resource secretFoundryKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'foundry-api-key'
  properties: {
    value: listKeys(foundryAccountId, '2024-10-01').key1
    contentType: 'Foundry account key1 (LLM, embeddings, rerank)'
  }
}

resource secretTenantKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'hindsight-tenant-key'
  properties: {
    value: hindsightTenantKey
    contentType: 'Shared Hindsight tenant bearer key (phase 1)'
  }
}

resource secretCpAccessKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'cp-access-key'
  properties: {
    value: cpAccessKey
    contentType: 'Control Plane UI access key'
  }
}

resource secretCpEntraClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(cpEntraClientSecret)) {
  parent: vault
  name: 'cp-entra-client-secret'
  properties: {
    value: cpEntraClientSecret
    contentType: 'Entra ID app registration client secret for the Control Plane'
  }
}

output id string = vault.id
output name string = vault.name
output vaultUri string = vault.properties.vaultUri
