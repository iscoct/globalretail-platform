terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Same pattern as Layer 1 + Layer 2: empty backend block, config supplied at
  # init via -backend-config=backend.hcl. Without this block, init silently
  # falls back to local state (see cicd/README.md §6.8 for the pitfall).
  backend "azurerm" {}
}
