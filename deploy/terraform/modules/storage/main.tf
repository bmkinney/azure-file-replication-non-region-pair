locals {
  primary_tags   = merge(var.tags, { RegionRole = "primary" })
  secondary_tags = merge(var.tags, { RegionRole = "secondary" })
  file_tags      = { DataRole = "files" }
  blob_tags      = { DataRole = "blob" }
}

resource "azurerm_storage_account" "primary_file" {
  name                            = "stfile${var.primary_token}"
  resource_group_name             = var.resource_group_name
  location                        = var.primary_location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  account_kind                    = "StorageV2"
  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = merge(local.primary_tags, local.file_tags)

  share_properties {
    retention_policy {
      days = 14
    }

    smb {
      versions = ["SMB3.0", "SMB3.1.1"]
    }
  }
}

resource "azurerm_storage_account" "secondary_file" {
  name                            = "stfile${var.secondary_token}"
  resource_group_name             = var.resource_group_name
  location                        = var.secondary_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = merge(local.secondary_tags, local.file_tags)

  share_properties {
    retention_policy {
      days = 14
    }

    smb {
      versions = ["SMB3.0", "SMB3.1.1"]
    }
  }
}

resource "azurerm_storage_share" "primary" {
  name               = "files-primary"
  storage_account_id = azurerm_storage_account.primary_file.id
  quota              = 1024
  access_tier        = "TransactionOptimized"
  enabled_protocol   = "SMB"
}

resource "azurerm_storage_share" "secondary" {
  name               = "files-secondary"
  storage_account_id = azurerm_storage_account.secondary_file.id
  quota              = 1024
  access_tier        = "TransactionOptimized"
  enabled_protocol   = "SMB"
}

resource "azurerm_storage_account" "primary_blob" {
  name                            = "stblob${var.primary_token}"
  resource_group_name             = var.resource_group_name
  location                        = var.primary_location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  account_kind                    = "StorageV2"
  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  is_hns_enabled                  = false
  tags                            = merge(local.primary_tags, local.blob_tags)

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 14
    }

    container_delete_retention_policy {
      days = 14
    }
  }
}

resource "azurerm_storage_account" "secondary_blob" {
  name                            = "stblob${var.secondary_token}"
  resource_group_name             = var.resource_group_name
  location                        = var.secondary_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  is_hns_enabled                  = false
  tags                            = merge(local.secondary_tags, local.blob_tags)

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 14
    }

    container_delete_retention_policy {
      days = 14
    }
  }
}

resource "azurerm_storage_container" "primary" {
  name                  = "replication"
  storage_account_id    = azurerm_storage_account.primary_blob.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "secondary" {
  name                  = "replication"
  storage_account_id    = azurerm_storage_account.secondary_blob.id
  container_access_type = "private"
}
