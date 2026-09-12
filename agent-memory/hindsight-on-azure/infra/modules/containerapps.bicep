// Container Apps environment (VNet-integrated, Consumption workload profile) with the
// Hindsight API (slim image, internal worker, one replica) and the Control Plane UI.

param environmentName string
param apiAppName string
param cpAppName string
param location string
param tags object

param logAnalyticsWorkspaceId string
param logAnalyticsCustomerId string
param infrastructureSubnetId string

@description('Resource id of the user-assigned identity used for Key Vault secret references.')
param uamiId string

@description('Key Vault URI including the trailing slash (the vaultUri property of the vault).')
param keyVaultUri string

param apiImage string
param cpImage string

@description('Port the Control Plane image listens on (image exposes 9999).')
param cpPort int = 9999

param workerId string
param llmBaseUrl string
param llmDeploymentName string
param embeddingsBaseUrl string
param embeddingsDeploymentName string

@description('Full invoke URL of the Cohere rerank deployment. Empty = reranker falls back to rrf.')
param rerankInvokeUrl string
param rerankDeploymentName string

param cpEntraClientId string = ''
param entraTenantId string = tenant().tenantId

var apiPort = 8888
var rerankEnabled = !empty(rerankInvokeUrl)
var cpEntraEnabled = !empty(cpEntraClientId)

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: listKeys(logAnalyticsWorkspaceId, '2023-09-01').primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: false
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

// --- API -------------------------------------------------------------------

var apiEnvBase = [
  // Database
  { name: 'HINDSIGHT_API_DATABASE_URL', secretRef: 'database-url' }
  { name: 'HINDSIGHT_API_VECTOR_EXTENSION', value: 'pgvector' } // later: pgvectorscale (= pg_diskann on Azure)
  // LLM (Azure OpenAI via Foundry, /openai/v1 surface)
  { name: 'HINDSIGHT_API_LLM_PROVIDER', value: 'openai' }
  { name: 'HINDSIGHT_API_LLM_BASE_URL', value: llmBaseUrl }
  { name: 'HINDSIGHT_API_LLM_MODEL', value: llmDeploymentName }
  { name: 'HINDSIGHT_API_LLM_API_KEY', secretRef: 'foundry-api-key' }
  { name: 'HINDSIGHT_API_LLM_OUTPUT_LANGUAGE', value: 'English' }
  // Embeddings (provider segment in the variable names is required)
  { name: 'HINDSIGHT_API_EMBEDDINGS_PROVIDER', value: 'openai' }
  { name: 'HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL', value: embeddingsBaseUrl }
  { name: 'HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL', value: embeddingsDeploymentName }
  { name: 'HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY', secretRef: 'foundry-api-key' }
  // AuthN and server
  { name: 'HINDSIGHT_API_TENANT_EXTENSION', value: 'hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension' }
  { name: 'HINDSIGHT_API_TENANT_API_KEY', secretRef: 'hindsight-tenant-key' }
  { name: 'HINDSIGHT_API_WORKER_ID', value: workerId }
  { name: 'HINDSIGHT_API_LOG_FORMAT', value: 'json' }
  { name: 'HINDSIGHT_API_HOST', value: '0.0.0.0' }
  { name: 'HINDSIGHT_API_PORT', value: string(apiPort) }
]

var apiEnvReranker = rerankEnabled
  ? [
      { name: 'HINDSIGHT_API_RERANKER_PROVIDER', value: 'cohere' }
      { name: 'HINDSIGHT_API_RERANKER_COHERE_BASE_URL', value: rerankInvokeUrl }
      { name: 'HINDSIGHT_API_RERANKER_COHERE_MODEL', value: rerankDeploymentName }
      { name: 'HINDSIGHT_API_RERANKER_COHERE_API_KEY', secretRef: 'foundry-api-key' }
      { name: 'HINDSIGHT_API_RERANKER_1_PROVIDER', value: 'rrf' } // fail open: keep fusion order
    ]
  : [
      { name: 'HINDSIGHT_API_RERANKER_PROVIDER', value: 'rrf' }
    ]

resource api 'Microsoft.App/containerApps@2024-03-01' = {
  name: apiAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiId}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: apiPort
        transport: 'auto'
        allowInsecure: false
      }
      secrets: [
        { name: 'database-url', keyVaultUrl: '${keyVaultUri}secrets/psql-connection-string', identity: uamiId }
        { name: 'foundry-api-key', keyVaultUrl: '${keyVaultUri}secrets/foundry-api-key', identity: uamiId }
        { name: 'hindsight-tenant-key', keyVaultUrl: '${keyVaultUri}secrets/hindsight-tenant-key', identity: uamiId }
      ]
    }
    template: {
      containers: [
        {
          name: 'hindsight-api'
          image: apiImage
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: concat(apiEnvBase, apiEnvReranker)
          probes: [
            {
              type: 'Startup'
              httpGet: { path: '/health/live', port: apiPort }
              periodSeconds: 10
              failureThreshold: 30 // migrations run on startup
            }
            {
              type: 'Liveness'
              httpGet: { path: '/health/live', port: apiPort }
              periodSeconds: 30
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: '/health/ready', port: apiPort }
              periodSeconds: 10
              failureThreshold: 6
            }
          ]
        }
      ]
      scale: {
        // One replica: the internal worker needs a single stable identity (HINDSIGHT_API_WORKER_ID).
        // Scale-out = disable the internal worker and add a dedicated worker app.
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// --- Control Plane ---------------------------------------------------------

var cpSecretsBase = [
  { name: 'hindsight-tenant-key', keyVaultUrl: '${keyVaultUri}secrets/hindsight-tenant-key', identity: uamiId }
  { name: 'cp-access-key', keyVaultUrl: '${keyVaultUri}secrets/cp-access-key', identity: uamiId }
]

var cpSecretsEntra = cpEntraEnabled
  ? [
      { name: 'cp-entra-client-secret', keyVaultUrl: '${keyVaultUri}secrets/cp-entra-client-secret', identity: uamiId }
    ]
  : []

resource controlPlane 'Microsoft.App/containerApps@2024-03-01' = {
  name: cpAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiId}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: cpPort
        transport: 'auto'
        allowInsecure: false
      }
      secrets: concat(cpSecretsBase, cpSecretsEntra)
    }
    template: {
      containers: [
        {
          name: 'hindsight-control-plane'
          image: cpImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'PORT', value: string(cpPort) }
            { name: 'HINDSIGHT_CP_DATAPLANE_API_URL', value: 'https://${api.properties.configuration.ingress.fqdn}' }
            { name: 'HINDSIGHT_CP_DATAPLANE_API_KEY', secretRef: 'hindsight-tenant-key' }
            { name: 'HINDSIGHT_CP_ACCESS_KEY', secretRef: 'cp-access-key' }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

// Optional Entra ID login in front of the UI (Container Apps built-in authentication).
resource controlPlaneAuth 'Microsoft.App/containerApps/authConfigs@2024-03-01' = if (cpEntraEnabled) {
  parent: controlPlane
  name: 'current'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: cpEntraClientId
          clientSecretSettingName: 'cp-entra-client-secret'
          openIdIssuer: '${environment().authentication.loginEndpoint}${entraTenantId}/v2.0'
        }
        validation: {
          allowedAudiences: ['api://${cpEntraClientId}']
        }
      }
    }
  }
}

output environmentId string = managedEnvironment.id
output apiFqdn string = api.properties.configuration.ingress.fqdn
output cpFqdn string = controlPlane.properties.configuration.ingress.fqdn
