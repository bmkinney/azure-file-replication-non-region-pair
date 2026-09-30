targetScope = 'resourceGroup'

param name string
param location string

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_GZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
param skuName string

param shareName string
param shareQuotaGiB int
param tags object

// Premium file shares require the FileStorage account kind and don't take an access tier.
var isPremium = startsWith(skuName, 'Premium')

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: skuName }
  kind: isPremium ? 'FileStorage' : 'StorageV2'
  properties: union({
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }, isPremium ? {} : { allowBlobPublicAccess: false })
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    protocolSettings: { smb: { versions: 'SMB3.0;SMB3.1.1' } }
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = {
  parent: fileService
  name: shareName
  properties: union({
    enabledProtocols: 'SMB'
    shareQuota: shareQuotaGiB
  }, isPremium ? {} : { accessTier: 'TransactionOptimized' })
}

output id string = storageAccount.id
output name string = storageAccount.name
output shareName string = share.name
