targetScope = 'resourceGroup'

// One region's replication compute: Log Analytics, the Container Apps environment, and the AzCopy job.
param environmentName string
param location string
param regionCode string

@description('Optional names; empty values generate the same names as earlier versions of this template.')
param logWorkspaceName string = ''
param managedEnvironmentName string = ''
param jobName string = ''

@description('Resource ID of an existing Log Analytics workspace to send the job logs to, in any resource group or subscription. Empty creates a workspace in this resource group.')
param existingLogWorkspaceId string = ''

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
var reusesLogWorkspace = !empty(existingLogWorkspaceId)
// /subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.OperationalInsights/workspaces/<name>; the
// placeholder keeps the reference well formed when no workspace is reused.
var existingLogWorkspaceSegments = split(reusesLogWorkspace ? existingLogWorkspaceId : '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.OperationalInsights/workspaces/unused', '/')

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = if (!reusesLogWorkspace) {
  name: empty(logWorkspaceName) ? 'log-replication-${regionCode}-${token}' : logWorkspaceName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource existingLogWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = if (reusesLogWorkspace) {
  name: existingLogWorkspaceSegments[8]
  scope: resourceGroup(existingLogWorkspaceSegments[2], existingLogWorkspaceSegments[4])
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: empty(managedEnvironmentName) ? 'cae-replication-${regionCode}-${token}' : managedEnvironmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        // Resource Manager evaluates only the taken branch of a condition, so only one workspace's keys are read.
        customerId: reusesLogWorkspace ? existingLogWorkspace!.properties.customerId : logWorkspace!.properties.customerId
        sharedKey: reusesLogWorkspace ? existingLogWorkspace!.listKeys().primarySharedKey : logWorkspace!.listKeys().primarySharedKey
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
output environmentName string = managedEnvironment.name
output logWorkspaceId string = reusesLogWorkspace ? existingLogWorkspaceId : logWorkspace.id
output logWorkspaceName string = reusesLogWorkspace ? existingLogWorkspaceSegments[8] : logWorkspace.name
output logWorkspaceLocation string = reusesLogWorkspace ? existingLogWorkspace!.location : location
output logWorkspaceCreated bool = !reusesLogWorkspace
