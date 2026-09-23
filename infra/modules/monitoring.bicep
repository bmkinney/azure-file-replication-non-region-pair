targetScope = 'resourceGroup'

param environmentName string
param primaryLocation string
param secondaryLocation string

@allowed([
  'none'
  'primary'
  'secondary'
])
param activeRegion string

param primaryJobId string
param primaryJobName string
param secondaryJobId string
param secondaryJobName string
param primaryLogWorkspaceId string
param secondaryLogWorkspaceId string

@minLength(1)
@description('Email addresses that receive replication alerts through Azure Monitor.')
param alertEmailAddresses array

@allowed([
  20
  30
  60
])
@description('Minutes without a successful replication before the active direction is considered stale.')
param replicationLagThresholdMinutes int = 30

param monitoringEnabled bool = true
param tags object = {}

var monitoringToken = uniqueString(subscription().id, resourceGroup().id, environmentName)
var actionGroupName = 'ag-replication-${monitoringToken}'
var lagWindowSize = 'PT${replicationLagThresholdMinutes}M'
var emailReceivers = map(alertEmailAddresses, (emailAddress, index) => {
  name: 'replication-email-${index + 1}'
  emailAddress: emailAddress
  useCommonAlertSchema: true
})

resource replicationActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'file-repl'
    enabled: monitoringEnabled
    emailReceivers: emailReceivers
  }
}

resource primaryFailureAlert 'Microsoft.Insights/metricAlerts@2026-01-01' = {
  name: 'alert-replication-failed-primary-${monitoringToken}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Azure Files replication job ${primaryJobName} failed in the primary region.'
    severity: 1
    enabled: monitoringEnabled
    scopes: [primaryJobId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    targetResourceType: 'Microsoft.App/jobs'
    targetResourceRegion: primaryLocation
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'FailedJobExecutions'
          metricNamespace: 'Microsoft.App/jobs'
          metricName: 'Executions'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
          dimensions: [
            {
              name: 'state'
              operator: 'Include'
              values: ['Failed']
            }
          ]
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: replicationActionGroup.id
      }
    ]
  }
}

resource secondaryFailureAlert 'Microsoft.Insights/metricAlerts@2026-01-01' = {
  name: 'alert-replication-failed-secondary-${monitoringToken}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Azure Files replication job ${secondaryJobName} failed in the secondary region.'
    severity: 1
    enabled: monitoringEnabled
    scopes: [secondaryJobId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    targetResourceType: 'Microsoft.App/jobs'
    targetResourceRegion: secondaryLocation
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'FailedJobExecutions'
          metricNamespace: 'Microsoft.App/jobs'
          metricName: 'Executions'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
          dimensions: [
            {
              name: 'state'
              operator: 'Include'
              values: ['Failed']
            }
          ]
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: replicationActionGroup.id
      }
    ]
  }
}

resource primaryFreshnessAlert 'Microsoft.Insights/scheduledQueryRules@2026-03-01' = {
  name: 'alert-replication-stale-primary-${monitoringToken}'
  location: primaryLocation
  tags: tags
  properties: {
    description: 'No successful primary-to-secondary Azure Files replication was recorded within the configured lag threshold.'
    severity: 2
    enabled: monitoringEnabled && activeRegion == 'primary'
    scopes: [primaryLogWorkspaceId]
    evaluationFrequency: 'PT10M'
    windowSize: lagWindowSize
    autoMitigate: true
    checkWorkspaceAlertsStorageConfigured: false
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: '''
            ContainerAppConsoleLogs_CL
            | where TimeGenerated >= ago(${replicationLagThresholdMinutes}m)
            | where Log_s contains "AZURE_FILES_REPLICATION_SUCCEEDED"
            | summarize SuccessCount = count()
          '''
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'SuccessCount'
          operator: 'LessThan'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [replicationActionGroup.id]
    }
  }
}

resource secondaryFreshnessAlert 'Microsoft.Insights/scheduledQueryRules@2026-03-01' = {
  name: 'alert-replication-stale-secondary-${monitoringToken}'
  location: secondaryLocation
  tags: tags
  properties: {
    description: 'No successful secondary-to-primary Azure Files replication was recorded within the configured lag threshold.'
    severity: 2
    enabled: monitoringEnabled && activeRegion == 'secondary'
    scopes: [secondaryLogWorkspaceId]
    evaluationFrequency: 'PT10M'
    windowSize: lagWindowSize
    autoMitigate: true
    checkWorkspaceAlertsStorageConfigured: false
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: '''
            ContainerAppConsoleLogs_CL
            | where TimeGenerated >= ago(${replicationLagThresholdMinutes}m)
            | where Log_s contains "AZURE_FILES_REPLICATION_SUCCEEDED"
            | summarize SuccessCount = count()
          '''
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'SuccessCount'
          operator: 'LessThan'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [replicationActionGroup.id]
    }
  }
}

output actionGroupId string = replicationActionGroup.id
output primaryFailureAlertId string = primaryFailureAlert.id
output secondaryFailureAlertId string = secondaryFailureAlert.id
output primaryFreshnessAlertId string = primaryFreshnessAlert.id
output secondaryFreshnessAlertId string = secondaryFreshnessAlert.id
