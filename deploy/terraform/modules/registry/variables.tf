variable "resource_group_name" { type = string }
variable "primary_location" { type = string }
variable "secondary_location" { type = string }
variable "registry_token" { type = string }
variable "public_network_access_enabled" { type = bool }
variable "tags" { type = map(string) }
