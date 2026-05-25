# Pin Terraform + providers. Same pins as Layer 1, on purpose: both layers
# run against the same Azure tenant and should agree on schema versions.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # All backend values come from -backend-config=backend.hcl at init time.
  # The empty backend block makes Terraform USE the azurerm backend; without
  # it, terraform init silently falls back to local state (one of the most
  # subtle pitfalls when adopting remote state).
  backend "azurerm" {}
}
