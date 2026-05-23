# Root input variables for Layer 2 (CI/CD identity).
#
# Most defaults mirror Layer 1 so the same `terraform.tfvars` could in theory
# drive both — in practice each layer has its own tfvars to keep the state
# files and lifecycles separated.

variable "subscription_id" {
  description = "Target Azure subscription ID."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant ID."
  type        = string
}

variable "workload" {
  description = "Workload prefix used in resource names. Must match Layer 1 so RBAC scopes line up."
  type        = string
  default     = "globalretail"
  validation {
    condition     = length(var.workload) <= 16
    error_message = "Workload must be <= 16 chars to keep derived names within Azure limits."
  }
}

variable "environment" {
  description = "Environment label (dev/staging/prod). Single env in this reference architecture."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region. Should match Layer 1."
  type        = string
  default     = "westeurope"
}

variable "location_short" {
  description = "Short region code (used in resource names)."
  type        = string
  default     = "weu"
}

variable "owner" {
  description = "Resource owner tag. Set this in your terraform.tfvars."
  type        = string
  default     = "platform-team"
}

# --- GitHub federation inputs -------------------------------------------------

variable "github_owner" {
  description = "GitHub username or organisation that owns the monorepo (e.g. 'iscoct')."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo name (e.g. 'globalretail-platform'). Repo must exist before applying."
  type        = string
}

variable "github_main_branch" {
  description = "Branch name that the app workflow pushes to ACR from."
  type        = string
  default     = "main"
}

variable "github_environment_name" {
  description = "GitHub Environment used to gate `terraform apply` against Layer 1. The Platform-RW UAMI is federated to this environment, and the environment is configured with required reviewers."
  type        = string
  default     = "platform-prod"
}

# --- Layer 1 state reference --------------------------------------------------

variable "layer1_tfstate_resource_group" {
  description = "RG of the storage account that holds Layer 1's tfstate (same SA as Layer 1)."
  type        = string
  default     = "rg-tfstate-globalretail-weu"
}

variable "layer1_tfstate_storage_account" {
  description = "Storage account holding Layer 1's tfstate. Copy this from layer1/backend.hcl."
  type        = string
}

variable "layer1_tfstate_container" {
  description = "Blob container holding Layer 1's tfstate."
  type        = string
  default     = "tfstate"
}

variable "layer1_tfstate_key" {
  description = "Blob key (path) for Layer 1's tfstate inside the container."
  type        = string
  default     = "infra/dev/terraform.tfstate"
}
