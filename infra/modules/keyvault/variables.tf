variable "workload" {
  description = <<-DESC
    Workload name embedded in the KV name. KV names are 3-24 chars, alphanumeric + dashes,
    globally unique. Budget breakdown: 'kv-' (3) + workload (≤16) + '-' (1) + 4-hex suffix = ≤24.
    Env + region are NOT included in the name because the resource group already encodes them.
  DESC
  type        = string
  validation {
    condition     = length(var.workload) <= 16
    error_message = "workload must be 16 chars or fewer (KV name budget: 'kv-' + workload + '-' + 4 hex chars must fit in 24)."
  }
}

variable "resource_group_name" {
  description = "Resource group where the vault lives."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant — required by Key Vault even in RBAC mode."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace receiving vault audit logs."
  type        = string
}

variable "admin_object_ids" {
  description = <<-DESC
    Map of { static_label = object_id } for principals granted 'Key Vault Administrator'.
    Map keys must be known at plan time (static strings); values can be known-after-apply.
    This map shape is required (instead of a plain list) because for_each cannot tolerate
    unknown values in its key set — and at least one of our principal IDs (the AKS admin
    group) is created in the same plan that consumes it.
  DESC
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to the vault."
  type        = map(string)
  default     = {}
}