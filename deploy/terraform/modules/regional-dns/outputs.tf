output "file_zone_id" { value = azurerm_private_dns_zone.this["file"].id }
output "blob_zone_id" { value = azurerm_private_dns_zone.this["blob"].id }
output "acr_zone_id" { value = azurerm_private_dns_zone.this["acr"].id }
