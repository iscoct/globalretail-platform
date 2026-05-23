variable "name_suffix" {
  description = "Naming suffix (e.g., 'globalretail-dev-weu') appended to resource names."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group where the VNet and subnets are created."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "address_space" {
  description = "VNet CIDR block(s)."
  type        = list(string)
}

variable "tags" {
  description = "Tags applied to the VNet (subnets do not support tags)."
  type        = map(string)
  default     = {}
}