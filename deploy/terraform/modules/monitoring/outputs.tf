output "action_group_id" { value = azurerm_monitor_action_group.replication.id }
output "primary_failure_alert_id" { value = azurerm_monitor_metric_alert.primary_failure.id }
output "secondary_failure_alert_id" { value = azurerm_monitor_metric_alert.secondary_failure.id }
output "primary_freshness_alert_id" { value = azurerm_monitor_scheduled_query_rules_alert_v2.primary_freshness.id }
output "secondary_freshness_alert_id" { value = azurerm_monitor_scheduled_query_rules_alert_v2.secondary_freshness.id }
output "primary_freshness_enabled" { value = azurerm_monitor_scheduled_query_rules_alert_v2.primary_freshness.enabled }
output "secondary_freshness_enabled" { value = azurerm_monitor_scheduled_query_rules_alert_v2.secondary_freshness.enabled }
