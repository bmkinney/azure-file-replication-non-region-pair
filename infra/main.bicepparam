using './main.bicep'

param resourceGroupName = 'rg-azure-files-replication-demo'
param primaryDnsResourceGroupName = 'rg-azure-files-replication-demo-primary-dns'
param secondaryDnsResourceGroupName = 'rg-azure-files-replication-demo-secondary-dns'
param resourceGroupLocation = 'centralus'
param primaryLocation = 'southcentralus'
param secondaryLocation = 'westus'
param environmentName = 'demo'
param activeRegion = 'none'
param acrPublicNetworkAccess = 'Enabled'
param scheduleCronExpression = '*/10 * * * *'
param alertEmailAddresses = [
	'replace-with-operations@example.com'
]
param replicationLagThresholdMinutes = 30
param monitoringEnabled = true
