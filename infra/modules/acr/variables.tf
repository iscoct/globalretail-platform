variable "name_suffix" {
  description = "Naming suffix (e.g., 'globalretail-dev-weu'). Dashes are stripped to satisfy the ACR alphanumeric-only rule."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group where the ACR lives."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace receiving ACR diagnostic logs."
  type        = string
}

variable "kubelet_identity_object_id" {
  description = "Object (principal) ID of the AKS kubelet UAMI — granted AcrPull on this registry."
  type        = string
}

variable "tags" {
  description = "Tags applied to the ACR."
  type        = map(string)
  default     = {}
}
