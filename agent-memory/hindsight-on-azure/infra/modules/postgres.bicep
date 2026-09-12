// Azure Database for PostgreSQL Flexible Server — the only stateful component.
// Private access via delegated subnet; vector and pg_diskann allow-listed from day 1.

param name string
param location string
param tags object
param postgresVersion string
param skuName string
param skuTier string
param storageGb int
param backupRetentionDays int
param administratorLogin string

@secure()
param administratorLoginPassword string

param delegatedSubnetId string
param privateDnsZoneId string
param databaseName string = 'hindsight'

@description('Server-level extension allowlist. pg_diskann is included now so the later switch to DiskANN is a config change, not a server change.')
param allowedExtensions string = 'VECTOR,PG_DISKANN'

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: postgresVersion
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    storage: {
      storageSizeGB: storageGb
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
      publicNetworkAccess: 'Disabled'
    }
    authConfig: {
      // Hindsight expects a static DATABASE_URL; Entra token rotation does not fit.
      passwordAuth: 'Enabled'
      activeDirectoryAuth: 'Disabled'
    }
  }
}

resource extensionAllowlist 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'azure.extensions'
  properties: {
    value: allowedExtensions
    source: 'user-override'
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  // Serialize server-level operations.
  dependsOn: [extensionAllowlist]
}

output serverName string = server.name
output fqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
