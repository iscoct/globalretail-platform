# Only azurerm needed — we are not creating Entra ID resources from here.
# The federated credential is on a UAMI, which is azurerm, not azuread.

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      # Don't purge when destroying — we may want to recover. Soft-delete
      # retention from Layer 1 is short (7d) so this is short-lived risk.
      purge_soft_delete_on_destroy = false
    }
  }
}
