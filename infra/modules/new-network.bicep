targetScope = 'resourceGroup'

param name string
param location string

@description('Address space of the new VNet, /22 or larger. The job subnet is its first /23 and the endpoint subnet its third /24.')
param addressPrefix string

param jobSubnetName string
param tags object

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-10-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [
      {
        name: jobSubnetName
        properties: {
          addressPrefix: cidrSubnet(addressPrefix, 23, 0)
          delegations: [
            {
              name: 'container-apps'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'endpoints'
        properties: {
          addressPrefix: cidrSubnet(addressPrefix, 24, 2)
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output id string = virtualNetwork.id
output jobSubnetId string = '${virtualNetwork.id}/subnets/${jobSubnetName}'
output endpointSubnetId string = '${virtualNetwork.id}/subnets/endpoints'
