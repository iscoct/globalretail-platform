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
  description = "Azure region."
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

# --- Workload identity binding ----------------------------------------------

variable "sample_app_namespace" {
  description = "K8s namespace where sample-app runs."
  type        = string
  default     = "sample-app"
}

variable "sample_app_service_account" {
  description = "K8s ServiceAccount that sample-app pods use. The federated credential's subject is built from {namespace}/{serviceAccount}."
  type        = string
  default     = "sample-app"
}

# --- Demo secret -----------------------------------------------------------

variable "welcome_message_secret_name" {
  description = "Name of the Key Vault secret that sample-app mounts via the CSI Secrets Store Driver."
  type        = string
  default     = "sample-app-welcome-message"
}

variable "welcome_message_secret_value" {
  description = "Initial value of the demo secret. Real secrets do NOT live in tfvars in production — they get set out-of-band by a sealed-secrets workflow or the apps that own them. For the lab this stays inline so the demo works end-to-end with a single apply."
  type        = string
  default     = "hello-from-key-vault-via-workload-identity"
  sensitive   = true
}

# --- Layer 1 state reference -----------------------------------------------

variable "layer1_tfstate_resource_group" {
  description = "RG of the storage account that holds Layer 1's tfstate."
  type        = string
  default     = "rg-tfstate-globalretail-weu"
}

variable "layer1_tfstate_storage_account" {
  description = "Storage account holding Layer 1's tfstate. Copy this from ../../infra/backend.hcl."
  type        = string
}

variable "layer1_tfstate_container" {
  description = "Blob container holding Layer 1's tfstate."
  type        = string
  default     = "tfstate"
}

variable "layer1_tfstate_key" {
  description = "Blob key (path) for Layer 1's tfstate."
  type        = string
  default     = "infra/dev/terraform.tfstate"
}
