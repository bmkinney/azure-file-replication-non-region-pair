resource "time_static" "freshness_grace_start" {
  triggers = {
    active_region   = var.active_region
    container_image = var.container_image
  }
}

locals {
  lag_window_size = "PT${var.replication_lag_threshold_minutes}M"
  # Each rule counts only its own job's successes, so both regions can share one workspace.
  freshness_queries = {
    for role, job_name in { primary = var.primary_job_name, secondary = var.secondary_job_name } : role => <<-KQL
  let graceEndsAt = datetime(${time_static.freshness_grace_start.rfc3339}) + ${var.replication_lag_threshold_minutes}m;
  ContainerAppConsoleLogs_CL
  | where TimeGenerated >= ago(${var.replication_lag_threshold_minutes}m)
  | where ContainerJobName_s == "${job_name}"
  | where Log_s contains "AZURE_FILES_REPLICATION_SUCCEEDED"
  | summarize SuccessCount = count()
  | extend SuccessCount = iff(now() < graceEndsAt, max_of(SuccessCount, 1), SuccessCount)
  KQL
  }
}

resource "azurerm_monitor_action_group" "replication" {
  name                = "ag-replication-${var.monitoring_token}"
  resource_group_name = var.resource_group_name
  short_name          = "file-repl"
  enabled             = var.monitoring_enabled
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = { for index, email in var.alert_email_addresses : index => email }
    content {
      name                    = "replication-email-${email_receiver.key + 1}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_metric_alert" "primary_failure" {
  name                     = "alert-replication-failed-primary-${var.monitoring_token}"
  resource_group_name      = var.resource_group_name
  scopes                   = [var.primary_job_id]
  description              = "Azure Files replication job ${var.primary_job_name} failed in the primary region."
  severity                 = 1
  enabled                  = var.monitoring_enabled
  frequency                = "PT1M"
  window_size              = "PT5M"
  auto_mitigate            = true
  target_resource_type     = "Microsoft.App/jobs"
  target_resource_location = var.primary_location
  tags                     = var.tags

  criteria {
    metric_namespace       = "Microsoft.App/jobs"
    metric_name            = "Executions"
    aggregation            = "Total"
    operator               = "GreaterThan"
    threshold              = 0
    skip_metric_validation = false

    dimension {
      name     = "state"
      operator = "Include"
      values   = ["Failed"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.replication.id
  }
}

resource "azurerm_monitor_metric_alert" "secondary_failure" {
  name                     = "alert-replication-failed-secondary-${var.monitoring_token}"
  resource_group_name      = var.resource_group_name
  scopes                   = [var.secondary_job_id]
  description              = "Azure Files replication job ${var.secondary_job_name} failed in the secondary region."
  severity                 = 1
  enabled                  = var.monitoring_enabled
  frequency                = "PT1M"
  window_size              = "PT5M"
  auto_mitigate            = true
  target_resource_type     = "Microsoft.App/jobs"
  target_resource_location = var.secondary_location
  tags                     = var.tags

  criteria {
    metric_namespace       = "Microsoft.App/jobs"
    metric_name            = "Executions"
    aggregation            = "Total"
    operator               = "GreaterThan"
    threshold              = 0
    skip_metric_validation = false

    dimension {
      name     = "state"
      operator = "Include"
      values   = ["Failed"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.replication.id
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "primary_freshness" {
  name                             = "alert-replication-stale-primary-${var.monitoring_token}"
  resource_group_name              = var.resource_group_name
  location                         = var.primary_location
  scopes                           = [var.primary_log_workspace_id]
  description                      = "No successful primary-to-secondary Azure Files replication was recorded within the configured lag threshold."
  severity                         = 2
  enabled                          = var.monitoring_enabled && var.active_region == "primary"
  evaluation_frequency             = "PT10M"
  window_duration                  = local.lag_window_size
  auto_mitigation_enabled          = true
  workspace_alerts_storage_enabled = false
  skip_query_validation            = true
  tags                             = var.tags

  criteria {
    query                   = local.freshness_queries["primary"]
    time_aggregation_method = "Maximum"
    metric_measure_column   = "SuccessCount"
    operator                = "LessThan"
    threshold               = 1

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.replication.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "secondary_freshness" {
  name                             = "alert-replication-stale-secondary-${var.monitoring_token}"
  resource_group_name              = var.resource_group_name
  location                         = var.secondary_location
  scopes                           = [var.secondary_log_workspace_id]
  description                      = "No successful secondary-to-primary Azure Files replication was recorded within the configured lag threshold."
  severity                         = 2
  enabled                          = var.monitoring_enabled && var.active_region == "secondary"
  evaluation_frequency             = "PT10M"
  window_duration                  = local.lag_window_size
  auto_mitigation_enabled          = true
  workspace_alerts_storage_enabled = false
  skip_query_validation            = true
  tags                             = var.tags

  criteria {
    query                   = local.freshness_queries["secondary"]
    time_aggregation_method = "Maximum"
    metric_measure_column   = "SuccessCount"
    operator                = "LessThan"
    threshold               = 1

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.replication.id]
  }
}
