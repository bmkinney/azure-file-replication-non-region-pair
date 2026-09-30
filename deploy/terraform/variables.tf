variable "subscription_id" {
  type        = string
  default     = null
  description = "Azure subscription ID. Leave null to use ARM_SUBSCRIPTION_ID or the current Azure CLI context."

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID when set."
  }
}

variable "resource_group_name" {
  type        = string
  default     = "rg-azure-files-replication-demo"
  description = "Resource group for the replication workload."

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "primary_dns_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group for primary-region private DNS zones. Defaults to <resource_group_name>-primary-dns."
}

variable "secondary_dns_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group for secondary-region private DNS zones. Defaults to <resource_group_name>-secondary-dns."
}

variable "resource_group_location" {
  type        = string
  default     = "centralus"
  description = "Resource group metadata location. Keep unchanged because resource group locations are immutable."
}

variable "primary_location" {
  type        = string
  default     = "southcentralus"
  description = "Primary Azure region."
}

variable "secondary_location" {
  type        = string
  default     = "westus"
  description = "Secondary Azure region."
}

variable "environment_name" {
  type        = string
  default     = "demo"
  description = "Short environment name used in resource names and deterministic hashes."

  validation {
    condition     = can(regex("^[a-z0-9-]{1,16}$", var.environment_name))
    error_message = "environment_name must be 1-16 lowercase letters, numbers, or hyphens."
  }
}

variable "active_region" {
  type        = string
  default     = "none"
  description = "The only region with an enabled schedule. Use none while bootstrapping the image."

  validation {
    condition     = contains(["none", "primary", "secondary"], var.active_region)
    error_message = "active_region must be one of: none, primary, secondary."
  }
}

variable "container_image" {
  type        = string
  default     = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
  description = "Container image for the AzCopy job. Production deployments should use a digest-pinned image."
}

variable "acr_public_network_access_enabled" {
  type        = bool
  default     = true
  description = "Whether the created Azure Container Registry allows public network access. The deploy script opens it only for the image build."
}

variable "schedule_cron_expression" {
  type        = string
  default     = "*/10 * * * *"
  description = "Cron expression for the active Container Apps job schedule."
}

variable "alert_email_addresses" {
  type        = list(string)
  description = "Email addresses that receive Azure Monitor replication alerts."

  validation {
    condition     = length(var.alert_email_addresses) >= 1 && alltrue([for email in var.alert_email_addresses : length(trimspace(email)) > 0])
    error_message = "alert_email_addresses must contain at least one non-empty address."
  }
}

variable "replication_lag_threshold_minutes" {
  type        = number
  default     = 30
  description = "Minutes without a successful active-direction replication before an alert is raised."

  validation {
    condition     = contains([20, 30, 60], var.replication_lag_threshold_minutes)
    error_message = "replication_lag_threshold_minutes must be 20, 30, or 60."
  }
}

variable "monitoring_enabled" {
  type        = bool
  default     = true
  description = "Creates and enables Azure Monitor alerting resources when true."
}

variable "create_role_assignments" {
  type        = bool
  default     = true
  description = "Assigns job identities their roles. Set false when an administrator grants them with scripts/grant-access.ps1."
}

variable "storage_endpoint_suffix" {
  type        = string
  default     = "core.windows.net"
  description = "Azure Storage endpoint suffix for file share URLs and private DNS zone names."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to resources. Keep Workload for scripts that discover the replication jobs."
  default = {
    Environment = "demo"
    Workload    = "azure-files-dr-replication"
    ManagedBy   = "Terraform"
  }

  validation {
    condition     = lookup(var.tags, "Workload", "") == "azure-files-dr-replication"
    error_message = "tags.Workload must be azure-files-dr-replication because scripts use it to discover jobs."
  }
}
