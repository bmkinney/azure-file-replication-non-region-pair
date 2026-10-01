data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

locals {
  subscription_id                   = coalesce(var.subscription_id, data.azurerm_client_config.current.subscription_id)
  workload_resource_group_id        = "/subscriptions/${local.subscription_id}/resourceGroups/${var.resource_group_name}"
  primary_dns_resource_group_name   = coalesce(var.primary_dns_resource_group_name, "${var.resource_group_name}-primary-dns")
  secondary_dns_resource_group_name = coalesce(var.secondary_dns_resource_group_name, "${var.resource_group_name}-secondary-dns")
  primary_token                     = substr(sha256("${local.subscription_id}/${local.workload_resource_group_id}/${var.environment_name}/${var.primary_location}"), 0, 13)
  secondary_token                   = substr(sha256("${local.subscription_id}/${local.workload_resource_group_id}/${var.environment_name}/${var.secondary_location}"), 0, 13)
  registry_token                    = local.primary_token
  monitoring_token                  = substr(sha256("${local.subscription_id}/${local.workload_resource_group_id}/${var.environment_name}"), 0, 13)
  base_tags                         = merge(var.tags, { Environment = var.environment_name, Workload = "azure-files-dr-replication", ManagedBy = "Terraform" })
  primary_tags                      = merge(local.base_tags, { RegionRole = "primary" })
  secondary_tags                    = merge(local.base_tags, { RegionRole = "secondary" })
  primary_dns_tags                  = merge(local.base_tags, { RegionRole = "primary-dns" })
  secondary_dns_tags                = merge(local.base_tags, { RegionRole = "secondary-dns" })
}

resource "azurerm_resource_group" "workload" {
  name     = var.resource_group_name
  location = var.resource_group_location
  tags     = local.base_tags
}

resource "azurerm_resource_group" "primary_dns" {
  name     = local.primary_dns_resource_group_name
  location = var.primary_location
  tags     = local.primary_dns_tags
}

resource "azurerm_resource_group" "secondary_dns" {
  name     = local.secondary_dns_resource_group_name
  location = var.secondary_location
  tags     = local.secondary_dns_tags
}

module "primary_network" {
  source              = "./modules/network"
  name                = "vnet-${var.environment_name}-primary"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.workload.name
  address_space       = "10.10.0.0/16"
  default_subnet_cidr = "10.10.0.0/23"
  storage_subnet_cidr = "10.10.2.0/24"
  tags                = local.primary_tags
}

module "secondary_network" {
  source              = "./modules/network"
  name                = "vnet-${var.environment_name}-secondary"
  location            = var.secondary_location
  resource_group_name = azurerm_resource_group.workload.name
  address_space       = "10.20.0.0/16"
  default_subnet_cidr = "10.20.0.0/23"
  storage_subnet_cidr = "10.20.2.0/24"
  tags                = local.secondary_tags
}

module "primary_dns" {
  source                  = "./modules/regional-dns"
  resource_group_name     = azurerm_resource_group.primary_dns.name
  virtual_network_id      = module.primary_network.virtual_network_id
  link_token              = local.primary_token
  storage_endpoint_suffix = var.storage_endpoint_suffix
  tags                    = local.primary_tags
}

module "secondary_dns" {
  source                  = "./modules/regional-dns"
  resource_group_name     = azurerm_resource_group.secondary_dns.name
  virtual_network_id      = module.secondary_network.virtual_network_id
  link_token              = local.secondary_token
  storage_endpoint_suffix = var.storage_endpoint_suffix
  tags                    = local.secondary_tags
}

module "storage" {
  source              = "./modules/storage"
  resource_group_name = azurerm_resource_group.workload.name
  primary_location    = var.primary_location
  secondary_location  = var.secondary_location
  primary_token       = local.primary_token
  secondary_token     = local.secondary_token
  tags                = local.base_tags
}

module "registry" {
  source                        = "./modules/registry"
  resource_group_name           = azurerm_resource_group.workload.name
  primary_location              = var.primary_location
  secondary_location            = var.secondary_location
  registry_token                = local.registry_token
  public_network_access_enabled = var.acr_public_network_access_enabled
  tags                          = local.base_tags
}

module "private_endpoint_primary_primary_file" {
  source                 = "./modules/private-endpoint"
  name                   = "pe-primary-primary-file"
  location               = var.primary_location
  resource_group_name    = azurerm_resource_group.workload.name
  subnet_id              = module.primary_network.storage_subnet_id
  private_connection_id  = module.storage.primary_file_storage_account_id
  group_id               = "file"
  private_dns_zone_id    = module.primary_dns.file_zone_id
  connection_description = "Approved by Terraform deployment"
  tags                   = local.base_tags
}

module "private_endpoint_primary_secondary_file" {
  source                 = "./modules/private-endpoint"
  name                   = "pe-primary-secondary-file"
  location               = var.primary_location
  resource_group_name    = azurerm_resource_group.workload.name
  subnet_id              = module.primary_network.storage_subnet_id
  private_connection_id  = module.storage.secondary_file_storage_account_id
  group_id               = "file"
  private_dns_zone_id    = module.primary_dns.file_zone_id
  connection_description = "Approved by Terraform deployment"
  tags                   = local.base_tags
}

module "private_endpoint_secondary_primary_file" {
  source                 = "./modules/private-endpoint"
  name                   = "pe-secondary-primary-file"
  location               = var.secondary_location
  resource_group_name    = azurerm_resource_group.workload.name
  subnet_id              = module.secondary_network.storage_subnet_id
  private_connection_id  = module.storage.primary_file_storage_account_id
  group_id               = "file"
  private_dns_zone_id    = module.secondary_dns.file_zone_id
  connection_description = "Approved by Terraform deployment"
  tags                   = local.base_tags
}

module "private_endpoint_secondary_secondary_file" {
  source                 = "./modules/private-endpoint"
  name                   = "pe-secondary-secondary-file"
  location               = var.secondary_location
  resource_group_name    = azurerm_resource_group.workload.name
  subnet_id              = module.secondary_network.storage_subnet_id
  private_connection_id  = module.storage.secondary_file_storage_account_id
  group_id               = "file"
  private_dns_zone_id    = module.secondary_dns.file_zone_id
  connection_description = "Approved by Terraform deployment"
  tags                   = local.base_tags
}

module "private_endpoint_primary_blob" {
  source                 = "./modules/private-endpoint"
  name                   = "pe-primary-blob"
  location               = var.primary_location
  resource_group_name    = azurerm_resource_group.workload.name
  subnet_id              = module.primary_network.storage_subnet_id
  private_connection_id  = module.storage.primary_blob_storage_account_id
  group_id               = "blob"
  private_dns_zone_id    = module.primary_dns.blob_zone_id
  connection_description = "Approved by Terraform deployment"
  tags                   = local.base_tags
}

module "private_endpoint_secondary_blob" {
  source                 = "./modules/private-endpoint"
  name                   = "pe-secondary-blob"
  location               = var.secondary_location
  resource_group_name    = azurerm_resource_group.workload.name
  subnet_id              = module.secondary_network.storage_subnet_id
  private_connection_id  = module.storage.secondary_blob_storage_account_id
  group_id               = "blob"
  private_dns_zone_id    = module.secondary_dns.blob_zone_id
  connection_description = "Approved by Terraform deployment"
  tags                   = local.base_tags
}

module "private_endpoint_primary_acr" {
  source                 = "./modules/private-endpoint"
  name                   = "pe-primary-acr"
  location               = var.primary_location
  resource_group_name    = azurerm_resource_group.workload.name
  subnet_id              = module.primary_network.storage_subnet_id
  private_connection_id  = module.registry.registry_id
  group_id               = "registry"
  private_dns_zone_id    = module.primary_dns.acr_zone_id
  connection_description = "Approved by Terraform deployment"
  tags                   = local.base_tags
}

module "private_endpoint_secondary_acr" {
  source                 = "./modules/private-endpoint"
  name                   = "pe-secondary-acr"
  location               = var.secondary_location
  resource_group_name    = azurerm_resource_group.workload.name
  subnet_id              = module.secondary_network.storage_subnet_id
  private_connection_id  = module.registry.registry_id
  group_id               = "registry"
  private_dns_zone_id    = module.secondary_dns.acr_zone_id
  connection_description = "Approved by Terraform deployment"
  tags                   = local.base_tags
}

module "replication" {
  source = "./modules/replication"

  resource_group_name         = azurerm_resource_group.workload.name
  resource_group_id           = local.workload_resource_group_id
  subscription_id             = local.subscription_id
  primary_location            = var.primary_location
  secondary_location          = var.secondary_location
  primary_token               = local.primary_token
  secondary_token             = local.secondary_token
  active_region               = var.active_region
  schedule_cron_expression    = var.schedule_cron_expression
  container_image             = var.container_image
  registry_login_server       = module.registry.registry_login_server
  registry_id                 = module.registry.registry_id
  primary_default_subnet_id   = module.primary_network.default_subnet_id
  secondary_default_subnet_id = module.secondary_network.default_subnet_id
  primary_file_account_id     = module.storage.primary_file_storage_account_id
  secondary_file_account_id   = module.storage.secondary_file_storage_account_id
  primary_file_account_name   = module.storage.primary_file_storage_account_name
  secondary_file_account_name = module.storage.secondary_file_storage_account_name
  primary_file_share_name     = module.storage.primary_file_share_name
  secondary_file_share_name   = module.storage.secondary_file_share_name
  storage_endpoint_suffix     = var.storage_endpoint_suffix
  create_role_assignments     = var.create_role_assignments
  tags                        = local.base_tags

  depends_on = [
    module.private_endpoint_primary_primary_file,
    module.private_endpoint_primary_secondary_file,
    module.private_endpoint_secondary_primary_file,
    module.private_endpoint_secondary_secondary_file,
    module.private_endpoint_primary_acr,
    module.private_endpoint_secondary_acr
  ]
}

module "monitoring" {
  source = "./modules/monitoring"

  resource_group_name               = azurerm_resource_group.workload.name
  primary_location                  = var.primary_location
  secondary_location                = var.secondary_location
  environment_name                  = var.environment_name
  monitoring_token                  = local.monitoring_token
  monitoring_enabled                = var.monitoring_enabled
  active_region                     = var.active_region
  container_image                   = var.container_image
  primary_job_id                    = module.replication.primary_job_id
  primary_job_name                  = module.replication.primary_job_name
  secondary_job_id                  = module.replication.secondary_job_id
  secondary_job_name                = module.replication.secondary_job_name
  primary_environment_name          = module.replication.primary_environment_name
  secondary_environment_name        = module.replication.secondary_environment_name
  primary_log_workspace_id          = module.replication.primary_log_workspace_id
  secondary_log_workspace_id        = module.replication.secondary_log_workspace_id
  alert_email_addresses             = var.alert_email_addresses
  replication_lag_threshold_minutes = var.replication_lag_threshold_minutes
  tags                              = local.base_tags
}
