# Input variables.
#
# `subscription_id` and `tenant_id` are required (no default) — we never want
# to accidentally target the wrong subscription with a default value.
#
# All others have sensible defaults so the typical case is just:
#   terraform apply -var-file=terraform.tfvars
# with only the two IDs in the tfvars file.

variable "subscription_id" {
  description = "Azure subscription ID where the platform is deployed."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant ID. Used by the azuread provider and for AKS Entra ID integration."
  type        = string
}

variable "workload" {
  description = "Workload name used as a prefix in resource naming. The fictional company is 'globalretail'."
  type        = string
  default     = "globalretail"
}

variable "environment" {
  description = "Deployment environment. The reference architecture only deploys 'dev'."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westeurope"
}

variable "location_short" {
  description = "Short region code used in resource names (e.g., 'weu' for westeurope)."
  type        = string
  default     = "weu"
}

variable "vnet_address_space" {
  description = "CIDR block(s) for the platform VNet."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "owner" {
  description = "Tag value identifying the person or team responsible for the platform. Set this in your terraform.tfvars."
  type        = string
  default     = "platform-team"
}

variable "kubernetes_version" {
  description = "Kubernetes minor version line. AKS picks the latest patch on this minor automatically."
  type        = string
  default     = "1.35"
}

variable "system_node_count" {
  description = "Node count for the AKS system pool (carries CriticalAddonsOnly taint)."
  type        = number
  default     = 2
}

variable "system_node_size" {
  description = "VM SKU for the AKS system pool."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "user_node_size" {
  description = "VM SKU for the AKS user pool."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "user_node_min_count" {
  description = "Minimum nodes in the autoscaling user pool."
  type        = number
  default     = 1
}

variable "user_node_max_count" {
  description = "Maximum nodes in the autoscaling user pool."
  type        = number
  default     = 3
}

variable "create_aks_admin_group" {
  description = <<-DESC
    Whether to create an Entra ID security group as the trust anchor for AKS
    cluster admins. Requires that the signed-in user has permission to create
    groups in the tenant — most tenants allow this by default, some corporate
    tenants restrict it.

    If you do not have permission, set this to false. The platform falls back
    to assigning the cluster-admin role directly to your user object ID (less
    realistic but functionally equivalent for a single-admin setup).
  DESC
  type        = bool
  default     = true
}