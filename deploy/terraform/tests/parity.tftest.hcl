mock_provider "azurerm" {}
mock_provider "time" {}

variables {
  subscription_id       = "00000000-0000-0000-0000-000000000000"
  alert_email_addresses = ["ops@example.com"]
}

run "greenfield_parity_primary_active" {
  command = plan

  variables {
    active_region = "primary"
  }

  assert {
    condition = alltrue([
      module.private_endpoint_primary_primary_file.name == "pe-primary-primary-file",
      module.private_endpoint_primary_secondary_file.name == "pe-primary-secondary-file",
      module.private_endpoint_secondary_primary_file.name == "pe-secondary-primary-file",
      module.private_endpoint_secondary_secondary_file.name == "pe-secondary-secondary-file",
      module.private_endpoint_primary_blob.name == "pe-primary-blob",
      module.private_endpoint_secondary_blob.name == "pe-secondary-blob",
      module.private_endpoint_primary_acr.name == "pe-primary-acr",
      module.private_endpoint_secondary_acr.name == "pe-secondary-acr"
    ])
    error_message = "Expected the eight Bicep-parity private endpoints."
  }

  assert {
    condition = alltrue([
      module.storage.security_settings.primary_file_public_network_access_enabled == false,
      module.storage.security_settings.primary_file_shared_access_key_enabled == false,
      module.storage.security_settings.secondary_file_public_network_access_enabled == false,
      module.storage.security_settings.secondary_file_shared_access_key_enabled == false,
      module.storage.security_settings.primary_blob_public_network_access_enabled == false,
      module.storage.security_settings.primary_blob_shared_access_key_enabled == false,
      module.storage.security_settings.secondary_blob_public_network_access_enabled == false,
      module.storage.security_settings.secondary_blob_shared_access_key_enabled == false
    ])
    error_message = "Storage accounts must disable public access and shared keys."
  }

  assert {
    condition = alltrue([
      module.replication.primary_trigger_type == "Schedule",
      module.replication.secondary_trigger_type == "Manual"
    ])
    error_message = "active_region=primary must schedule only the primary job."
  }

  assert {
    condition     = module.replication.role_assignment_count == 6
    error_message = "create_role_assignments=true must create six role assignments."
  }

  assert {
    condition = alltrue([
      module.monitoring.primary_freshness_enabled == true,
      module.monitoring.secondary_freshness_enabled == false
    ])
    error_message = "Freshness alerts must be enabled only for the active region."
  }

  assert {
    condition = alltrue([
      length(output.job_role_assignments) == 6,
      alltrue([for assignment in output.job_role_assignments : length(setsubtract(["name", "scope", "principalId", "principalName", "roleDefinitionId", "roleName"], keys(assignment))) == 0])
    ])
    error_message = "job_role_assignments must expose the six grant-access.ps1 keys."
  }
}

run "secondary_active_no_role_assignments" {
  command = plan

  variables {
    active_region           = "secondary"
    create_role_assignments = false
  }

  assert {
    condition = alltrue([
      module.replication.primary_trigger_type == "Manual",
      module.replication.secondary_trigger_type == "Schedule"
    ])
    error_message = "active_region=secondary must schedule only the secondary job."
  }

  assert {
    condition     = module.replication.role_assignment_count == 0
    error_message = "create_role_assignments=false must create zero role assignments."
  }

  assert {
    condition = alltrue([
      module.monitoring.primary_freshness_enabled == false,
      module.monitoring.secondary_freshness_enabled == true
    ])
    error_message = "Freshness alert enablement must follow active_region."
  }
}

run "reject_invalid_active_region" {
  command = plan

  variables {
    active_region = "bogus"
  }

  expect_failures = [var.active_region]
}

run "reject_empty_alert_addresses" {
  command = plan

  variables {
    alert_email_addresses = []
  }

  expect_failures = [var.alert_email_addresses]
}
