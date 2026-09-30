locals {
  workload_profile_name = "Consumption"
  file_role_id          = "69566ab7-960f-475b-8e7c-b3118f30c6bd"
  acr_pull_role_id      = "7f951dda-4ed3-4680-a7ca-43fe172d538d"
  file_role_definition  = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.file_role_id}"
  acr_role_definition   = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.acr_pull_role_id}"
  source_file_url       = "https://${var.primary_file_account_name}.file.${var.storage_endpoint_suffix}/${var.primary_file_share_name}"
  destination_file_url  = "https://${var.secondary_file_account_name}.file.${var.storage_endpoint_suffix}/${var.secondary_file_share_name}"
}

resource "azurerm_user_assigned_identity" "primary" {
  name                = "id-replication-primary-${var.primary_token}"
  resource_group_name = var.resource_group_name
  location            = var.primary_location
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "secondary" {
  name                = "id-replication-secondary-${var.secondary_token}"
  resource_group_name = var.resource_group_name
  location            = var.secondary_location
  tags                = var.tags
}

locals {
  job_role_targets = [
    { scope = var.primary_file_account_id, role_definition_id = local.file_role_id, role_definition_resource_id = local.file_role_definition, role_name = "Storage File Data Privileged Contributor" },
    { scope = var.secondary_file_account_id, role_definition_id = local.file_role_id, role_definition_resource_id = local.file_role_definition, role_name = "Storage File Data Privileged Contributor" },
    { scope = var.registry_id, role_definition_id = local.acr_pull_role_id, role_definition_resource_id = local.acr_role_definition, role_name = "AcrPull" }
  ]
  job_identities = [
    { id = azurerm_user_assigned_identity.primary.id, name = azurerm_user_assigned_identity.primary.name, principal_id = azurerm_user_assigned_identity.primary.principal_id },
    { id = azurerm_user_assigned_identity.secondary.id, name = azurerm_user_assigned_identity.secondary.name, principal_id = azurerm_user_assigned_identity.secondary.principal_id }
  ]
  job_role_assignments = flatten([
    for target in local.job_role_targets : [
      for identity in local.job_identities : {
        key                         = "${target.scope}|${identity.name}|${target.role_definition_id}"
        name                        = uuidv5("url", "${target.scope}/${identity.principal_id}/${target.role_definition_id}")
        scope                       = target.scope
        principal_id                = identity.principal_id
        principal_name              = identity.name
        role_definition_id          = target.role_definition_id
        role_definition_resource_id = target.role_definition_resource_id
        role_name                   = target.role_name
      }
    ]
  ])
}

resource "azurerm_role_assignment" "jobs" {
  for_each = var.create_role_assignments ? { for index, assignment in local.job_role_assignments : tostring(index) => assignment } : {}

  name                             = each.value.name
  scope                            = each.value.scope
  principal_id                     = each.value.principal_id
  principal_type                   = "ServicePrincipal"
  role_definition_id               = each.value.role_definition_resource_id
  skip_service_principal_aad_check = true
}

resource "azurerm_log_analytics_workspace" "primary" {
  name                            = "log-replication-primary-${var.primary_token}"
  resource_group_name             = var.resource_group_name
  location                        = var.primary_location
  sku                             = "PerGB2018"
  retention_in_days               = 30
  allow_resource_only_permissions = true
  tags                            = var.tags
}

resource "azurerm_log_analytics_workspace" "secondary" {
  name                            = "log-replication-secondary-${var.secondary_token}"
  resource_group_name             = var.resource_group_name
  location                        = var.secondary_location
  sku                             = "PerGB2018"
  retention_in_days               = 30
  allow_resource_only_permissions = true
  tags                            = var.tags
}

resource "azurerm_container_app_environment" "primary" {
  name                           = "cae-replication-primary-${var.primary_token}"
  resource_group_name            = var.resource_group_name
  location                       = var.primary_location
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.primary.id
  logs_destination               = "log-analytics"
  infrastructure_subnet_id       = var.primary_default_subnet_id
  internal_load_balancer_enabled = true
  zone_redundancy_enabled        = false
  tags                           = var.tags

  workload_profile {
    name                  = local.workload_profile_name
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app_environment" "secondary" {
  name                           = "cae-replication-secondary-${var.secondary_token}"
  resource_group_name            = var.resource_group_name
  location                       = var.secondary_location
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.secondary.id
  logs_destination               = "log-analytics"
  infrastructure_subnet_id       = var.secondary_default_subnet_id
  internal_load_balancer_enabled = true
  zone_redundancy_enabled        = false
  tags                           = var.tags

  workload_profile {
    name                  = local.workload_profile_name
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app_job" "primary" {
  name                         = "job-sync-primary-${var.primary_token}"
  resource_group_name          = var.resource_group_name
  location                     = var.primary_location
  container_app_environment_id = azurerm_container_app_environment.primary.id
  replica_retry_limit          = 2
  replica_timeout_in_seconds   = 3600
  workload_profile_name        = local.workload_profile_name
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.primary.id]
  }

  registry {
    server   = var.registry_login_server
    identity = azurerm_user_assigned_identity.primary.id
  }

  dynamic "manual_trigger_config" {
    for_each = var.active_region == "primary" ? [] : [1]
    content {
      parallelism              = 1
      replica_completion_count = 1
    }
  }

  dynamic "schedule_trigger_config" {
    for_each = var.active_region == "primary" ? [1] : []
    content {
      cron_expression          = var.schedule_cron_expression
      parallelism              = 1
      replica_completion_count = 1
    }
  }

  template {
    container {
      name   = "azcopy"
      image  = var.container_image
      cpu    = 1.0
      memory = "2Gi"

      env {
        name  = "SOURCE_FILE_URL"
        value = local.source_file_url
      }
      env {
        name  = "DESTINATION_FILE_URL"
        value = local.destination_file_url
      }
      env {
        name  = "AZCOPY_MSI_CLIENT_ID"
        value = azurerm_user_assigned_identity.primary.client_id
      }
      env {
        name  = "DELETE_DESTINATION"
        value = "false"
      }
    }
  }

  depends_on = [azurerm_role_assignment.jobs]
}

resource "azurerm_container_app_job" "secondary" {
  name                         = "job-sync-secondary-${var.secondary_token}"
  resource_group_name          = var.resource_group_name
  location                     = var.secondary_location
  container_app_environment_id = azurerm_container_app_environment.secondary.id
  replica_retry_limit          = 2
  replica_timeout_in_seconds   = 3600
  workload_profile_name        = local.workload_profile_name
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.secondary.id]
  }

  registry {
    server   = var.registry_login_server
    identity = azurerm_user_assigned_identity.secondary.id
  }

  dynamic "manual_trigger_config" {
    for_each = var.active_region == "secondary" ? [] : [1]
    content {
      parallelism              = 1
      replica_completion_count = 1
    }
  }

  dynamic "schedule_trigger_config" {
    for_each = var.active_region == "secondary" ? [1] : []
    content {
      cron_expression          = var.schedule_cron_expression
      parallelism              = 1
      replica_completion_count = 1
    }
  }

  template {
    container {
      name   = "azcopy"
      image  = var.container_image
      cpu    = 1.0
      memory = "2Gi"

      env {
        name  = "SOURCE_FILE_URL"
        value = local.destination_file_url
      }
      env {
        name  = "DESTINATION_FILE_URL"
        value = local.source_file_url
      }
      env {
        name  = "AZCOPY_MSI_CLIENT_ID"
        value = azurerm_user_assigned_identity.secondary.client_id
      }
      env {
        name  = "DELETE_DESTINATION"
        value = "false"
      }
    }
  }

  depends_on = [azurerm_role_assignment.jobs]
}
