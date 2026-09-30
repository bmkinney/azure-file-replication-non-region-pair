targetScope = 'resourceGroup'

param storageAccountName string
param principalIds array

var fileDataRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69566ab7-960f-475b-8e7c-b3118f30c6bd')

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

resource fileDataRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in principalIds: {
  name: guid(storageAccount.id, principalId, fileDataRoleDefinitionId)
  scope: storageAccount
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: fileDataRoleDefinitionId
  }
}]
