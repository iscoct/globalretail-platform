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
}
