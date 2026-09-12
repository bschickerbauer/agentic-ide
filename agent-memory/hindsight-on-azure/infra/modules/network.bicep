// Isolated VNet for the Container Apps environment and the PostgreSQL Flexible Server
// (VNet-integrated, private access only). No peering to corporate networks.

param vnetName string
param location string
param tags object
param vnetAddressPrefix string

@description('Container Apps infrastructure subnet. Workload-profile environments need at least a /27.')
param acaSubnetPrefix string

@description('Delegated subnet for PostgreSQL Flexible Server.')
param postgresSubnetPrefix string

@description('Private DNS zone for the Flexible Server. Must end with postgres.database.azure.com.')
param privateDnsZoneName string

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: acaSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'snet-postgres'
        properties: {
          addressPrefix: postgresSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.DBforPostgreSQL.flexibleServers'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

output vnetId string = vnet.id
output acaSubnetId string = vnet.properties.subnets[0].id
output postgresSubnetId string = vnet.properties.subnets[1].id
// The module only completes after the zone link exists, so PostgreSQL (which depends on this
// module's outputs) is created with working private DNS.
output privateDnsZoneId string = privateDnsZone.id
