# Provider and Terraform version constraints.
#
# We pin to MAJOR versions (~> X.Y), not exact patches, so security updates
# inside the major land automatically while breaking changes do not.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # 'http' is used in Iteration 3 to auto-discover the operator's public IP
    # for the AKS API server authorized_ip_ranges. See main.tf for details.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # All backend values are supplied at init time via -backend-config=backend.hcl
  # (emitted by bootstrap.ps1). Keeping this block empty here means the same
  # code can target different state files (dev / staging / prod) by swapping
  # the .hcl file at init.
  backend "azurerm" {}
}