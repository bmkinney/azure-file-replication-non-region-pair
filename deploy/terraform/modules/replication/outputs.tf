output "primary_job_name" { value = azurerm_container_app_job.primary.name }
output "secondary_job_name" { value = azurerm_container_app_job.secondary.name }
output "primary_environment_name" { value = azurerm_container_app_environment.primary.name }
output "secondary_environment_name" { value = azurerm_container_app_environment.secondary.name }
output "primary_job_id" { value = azurerm_container_app_job.primary.id }
output "secondary_job_id" { value = azurerm_container_app_job.secondary.id }
output "primary_log_workspace_id" { value = azurerm_log_analytics_workspace.primary.id }
output "secondary_log_workspace_id" { value = azurerm_log_analytics_workspace.secondary.id }
output "primary_log_workspace_name" { value = azurerm_log_analytics_workspace.primary.name }
output "secondary_log_workspace_name" { value = azurerm_log_analytics_workspace.secondary.name }
output "primary_trigger_type" { value = var.active_region == "primary" ? "Schedule" : "Manual" }
output "secondary_trigger_type" { value = var.active_region == "secondary" ? "Schedule" : "Manual" }
output "role_assignment_count" { value = length(azurerm_role_assignment.jobs) }
output "job_role_assignments" {
  value = [
    for assignment in local.job_role_assignments : {
      name             = assignment.name
      scope            = assignment.scope
      principalId      = assignment.principal_id
      principalName    = assignment.principal_name
      roleDefinitionId = assignment.role_definition_id
      roleName         = assignment.role_name
    }
  ]
}
