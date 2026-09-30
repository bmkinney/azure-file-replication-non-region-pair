output "primary_file_storage_account_id" { value = azurerm_storage_account.primary_file.id }
output "secondary_file_storage_account_id" { value = azurerm_storage_account.secondary_file.id }
output "primary_blob_storage_account_id" { value = azurerm_storage_account.primary_blob.id }
output "secondary_blob_storage_account_id" { value = azurerm_storage_account.secondary_blob.id }
output "primary_file_storage_account_name" { value = azurerm_storage_account.primary_file.name }
output "secondary_file_storage_account_name" { value = azurerm_storage_account.secondary_file.name }
output "primary_file_share_name" { value = azurerm_storage_share.primary.name }
output "secondary_file_share_name" { value = azurerm_storage_share.secondary.name }
output "security_settings" {
  value = {
    primary_file_public_network_access_enabled   = azurerm_storage_account.primary_file.public_network_access_enabled
    primary_file_shared_access_key_enabled       = azurerm_storage_account.primary_file.shared_access_key_enabled
    secondary_file_public_network_access_enabled = azurerm_storage_account.secondary_file.public_network_access_enabled
    secondary_file_shared_access_key_enabled     = azurerm_storage_account.secondary_file.shared_access_key_enabled
    primary_blob_public_network_access_enabled   = azurerm_storage_account.primary_blob.public_network_access_enabled
    primary_blob_shared_access_key_enabled       = azurerm_storage_account.primary_blob.shared_access_key_enabled
    secondary_blob_public_network_access_enabled = azurerm_storage_account.secondary_blob.public_network_access_enabled
    secondary_blob_shared_access_key_enabled     = azurerm_storage_account.secondary_blob.shared_access_key_enabled
  }
}
