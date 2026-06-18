variable "subscription_id" {
  description = "Target Azure subscription ID."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant ID."
  type        = string
}

variable "workload" {
  description = "Workload prefix used in resource names. Must match Layer 1."
  type        = string
  default     = "globalretail"
}

variable "environment" {
  description = "Environment label."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region. Note: Managed Grafana is available only in a subset of regions."
  type        = string
  default     = "westeurope"
}

variable "location_short" {
  description = "Short region code."
  type        = string
  default     = "weu"
}

variable "owner" {
  description = "Resource owner tag."
  type        = string
  default     = "platform-team"
}

variable "managed_grafana_sku" {
  description = "Managed Grafana SKU. As of late 2024, only 'Standard' is accepted by the API — the 'Essential' SKU was deprecated and removed. Standard is the only valid value today."
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Standard"], var.managed_grafana_sku)
    error_message = "managed_grafana_sku must be 'Standard' (Essential was deprecated)."
  }
}

# --- Layer 1 state reference -----------------------------------------------

variable "layer1_tfstate_resource_group" {
  description = "RG of the storage account that holds Layer 1's tfstate."
  type        = string
  default     = "rg-tfstate-globalretail-weu"
}

variable "layer1_tfstate_storage_account" {
  description = "Storage account holding Layer 1's tfstate. Copy from ../../../infra/backend.hcl."
  type        = string
}

variable "layer1_tfstate_container" {
  description = "Blob container holding Layer 1's tfstate."
  type        = string
  default     = "tfstate"
}

variable "layer1_tfstate_key" {
  description = "Blob key for Layer 1's tfstate."
  type        = string
  default     = "infra/dev/terraform.tfstate"
}

# --- Grafana admin --------------------------------------------------------

variable "grafana_admin_user_object_id" {
  description = "Entra ID object ID of the user who will get the 'Grafana Admin' role on the Managed Grafana instance. Leave empty to skip (and assign via portal)."
  type        = string
  default     = ""
}
