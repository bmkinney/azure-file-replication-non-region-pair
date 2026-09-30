resource "azurerm_container_registry" "this" {
  name                          = "acr${var.registry_token}"
  resource_group_name           = var.resource_group_name
  location                      = var.primary_location
  sku                           = "Premium"
  admin_enabled                 = false
  data_endpoint_enabled         = true
  zone_redundancy_enabled       = true
  public_network_access_enabled = var.public_network_access_enabled
  tags                          = var.tags

  georeplications {
    location                        = var.secondary_location
    zone_redundancy_enabled         = false
    global_endpoint_routing_enabled = true
    tags                            = var.tags
  }
}
