variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "address_space" { type = string }
variable "default_subnet_cidr" { type = string }
variable "storage_subnet_cidr" { type = string }
variable "tags" { type = map(string) }
