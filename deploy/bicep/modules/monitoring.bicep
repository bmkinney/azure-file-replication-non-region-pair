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

@description('Optional names; empty values keep the generated names.')
param actionGroupName string = ''
param primaryFailureAlertName string = ''
param secondaryFailureAlertName string = ''
param primaryFreshnessAlertName string = ''
param secondaryFreshnessAlertName string = ''

@description('ISO 8601 UTC start of the freshness grace period. Defaults to the deployment time so a newly activated direction has one lag threshold to record and ingest its first success.')
param freshnessGraceStartTime string = utcNow('o')

var monitoringToken = uniqueString(subscription().id, resourceGroup().id, environmentName)
var resolvedActionGroupName = empty(actionGroupName) ? 'ag-replication-${monitoringToken}' : actionGroupName
var lagWindowSize = 'PT${replicationLagThresholdMinutes}M'
// Until one threshold after deployment, the active direction counts as fresh; activation otherwise alerts before the first run's logs arrive.
var freshnessQuery = format('''
  let graceEndsAt = datetime({1}) + {0}m;
  ContainerAppConsoleLogs_CL
  | where TimeGenerated >= ago({0}m)
  | where Log_s contains "AZURE_FILES_REPLICATION_SUCCEEDED"
  | summarize SuccessCount = count()
  | extend SuccessCount = iff(now() < graceEndsAt, max_of(SuccessCount, 1), SuccessCount)
''', replicationLagThresholdMinutes, freshnessGraceStartTime)
var emailReceivers = map(alertEmailAddresses, (emailAddress, index) => {
  name: 'replication-email-${index + 1}'
  emailAddress: emailAddress
  useCommonAlertSchema: true
})

resource replicationActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: resolvedActionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'file-repl'
    enabled: monitoringEnabled
    emailReceivers: emailReceivers
  }
}

resource primaryFailureAlert 'Microsoft.Insights/metricAlerts@2026-01-01' = {
  name: empty(primaryFailureAlertName) ? 'alert-replication-failed-primary-${monitoringToken}' : primaryFailureAlertName
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
  name: empty(secondaryFailureAlertName) ? 'alert-replication-failed-secondary-${monitoringToken}' : secondaryFailureAlertName
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
  name: empty(primaryFreshnessAlertName) ? 'alert-replication-stale-primary-${monitoringToken}' : primaryFreshnessAlertName
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
          query: freshnessQuery
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
  name: empty(secondaryFreshnessAlertName) ? 'alert-replication-stale-secondary-${monitoringToken}' : secondaryFreshnessAlertName
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
          query: freshnessQuery
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
