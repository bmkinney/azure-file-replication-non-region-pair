targetScope = 'resourceGroup'

// Adds a delegated job subnet to an existing VNet in this resource group.
param vnetName string
param subnetName string
param addressPrefix string

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-10-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-10-01' = {
  parent: virtualNetwork
  name: subnetName
  properties: {
    addressPrefix: addressPrefix
    delegations: [
      {
        name: 'container-apps'
        properties: { serviceName: 'Microsoft.App/environments' }
      }
    ]
  }
}

output id string = subnet.id
