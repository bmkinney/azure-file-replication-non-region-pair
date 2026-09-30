targetScope = 'resourceGroup'

// One region's replication compute: Log Analytics, the Container Apps environment, and the AzCopy job.
param environmentName string
param location string
param regionCode string

@description('Optional names; empty values generate the same names as earlier versions of this template.')
param logWorkspaceName string = ''
param managedEnvironmentName string = ''
param jobName string = ''

param infrastructureSubnetId string
param identityId string
param identityClientId string
param registryLoginServer string
param sourceFileUrl string
param destinationFileUrl string

@description('True only for the active region, which runs on scheduleCronExpression; the other region stays manual.')
param scheduled bool

param scheduleCronExpression string
param containerImage string
param tags object

var token = uniqueString(subscription().id, resourceGroup().id, environmentName, location)
// Delegated infrastructure subnets require a workload profiles environment; the Consumption profile is serverless.
var workloadProfileName = 'Consumption'
var registries = [
  {
    server: registryLoginServer
    identity: identityId
  }
]

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: empty(logWorkspaceName) ? 'log-replication-${regionCode}-${token}' : logWorkspaceName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: empty(managedEnvironmentName) ? 'cae-replication-${regionCode}-${token}' : managedEnvironmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logWorkspace.properties.customerId
        sharedKey: logWorkspace.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: true
    }
    workloadProfiles: [
      {
        name: workloadProfileName
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

var jobConfiguration = scheduled ? {
  triggerType: 'Schedule'
  replicaRetryLimit: 2
  replicaTimeout: 3600
  scheduleTriggerConfig: {
    cronExpression: scheduleCronExpression
    parallelism: 1
    replicaCompletionCount: 1
  }
  registries: registries
} : {
  triggerType: 'Manual'
  replicaRetryLimit: 2
  replicaTimeout: 3600
  manualTriggerConfig: {
    parallelism: 1
    replicaCompletionCount: 1
  }
  registries: registries
}

resource job 'Microsoft.App/jobs@2025-01-01' = {
  name: empty(jobName) ? 'job-sync-${regionCode}-${token}' : jobName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: managedEnvironment.id
    workloadProfileName: workloadProfileName
    configuration: jobConfiguration
    template: {
      containers: [{
        name: 'azcopy'
        image: containerImage
        env: [
          { name: 'SOURCE_FILE_URL', value: sourceFileUrl }
          { name: 'DESTINATION_FILE_URL', value: destinationFileUrl }
          { name: 'AZCOPY_MSI_CLIENT_ID', value: identityClientId }
          { name: 'DELETE_DESTINATION', value: 'false' }
        ]
        resources: { cpu: json('1.0'), memory: '2Gi' }
      }]
    }
  }
}

output jobId string = job.id
output jobName string = job.name
output logWorkspaceId string = logWorkspace.id
output logWorkspaceName string = logWorkspace.name
