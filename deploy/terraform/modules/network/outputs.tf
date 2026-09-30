output "virtual_network_id" { value = azurerm_virtual_network.this.id }
output "default_subnet_id" { value = azurerm_subnet.default.id }
output "storage_subnet_id" { value = azurerm_subnet.storage.id }
