locals {
  zones = {
    file = "privatelink.file.${var.storage_endpoint_suffix}"
    blob = "privatelink.blob.${var.storage_endpoint_suffix}"
    acr  = "privatelink.azurecr.io"
  }
}

resource "azurerm_private_dns_zone" "this" {
  for_each            = local.zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each             = azurerm_private_dns_zone.this
  name                 = "link-${var.link_token}"
  private_dns_zone_id  = each.value.id
  virtual_network_id   = var.virtual_network_id
  registration_enabled = false
  tags                 = var.tags
}
