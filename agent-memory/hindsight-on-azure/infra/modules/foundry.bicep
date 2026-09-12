// Azure AI Foundry (AI Services) account dedicated to Hindsight, with the three model roles:
// LLM (fact extraction / reflect), embeddings (frozen at 1536 dims) and Cohere rerank.
// Model deployments are chained so they are created one after another (the account
// rejects concurrent deployment operations).

param name string
param location string
param tags object

@allowed(['DataZoneStandard', 'GlobalStandard'])
param modelDeploymentSku string

param llmModelName string
param llmModelVersion string
param llmDeploymentName string
param llmCapacity int

param embeddingsModelName string
param embeddingsModelVersion string
param embeddingsDeploymentName string
param embeddingsCapacity int

param rerankModelName string
param rerankModelVersion string
param rerankDeploymentName string
param rerankCapacity int

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: toLower(name)
    publicNetworkAccess: 'Enabled'
    // Hindsight authenticates with a static key (rotated via Key Vault). Entra-only auth
    // would require the APIM AI Gateway in between — see plan, section 5.
    disableLocalAuth: false
  }
}

resource llm 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: account
  name: llmDeploymentName
  sku: {
    name: modelDeploymentSku
    capacity: llmCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: llmModelName
      version: llmModelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

resource embeddings 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: account
  name: embeddingsDeploymentName
  sku: {
    name: modelDeploymentSku
    capacity: embeddingsCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingsModelName
      version: embeddingsModelVersion
    }
    // Embedding dimension lock: never auto-upgrade the embedding model once memories exist.
    versionUpgradeOption: 'NoAutoUpgrade'
  }
  dependsOn: [llm]
}

resource rerank 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: account
  name: rerankDeploymentName
  sku: {
    name: modelDeploymentSku
    capacity: rerankCapacity
  }
  properties: {
    model: {
      format: 'Cohere'
      name: rerankModelName
      version: rerankModelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
  dependsOn: [embeddings]
}

output id string = account.id
output name string = account.name
output endpoint string = account.properties.endpoint
// Hindsight needs the OpenAI v1 surface; the resource root returns 404 (documented gotcha).
output openAiV1BaseUrl string = 'https://${toLower(name)}.openai.azure.com/openai/v1'
output rerankDeploymentName string = rerank.name
