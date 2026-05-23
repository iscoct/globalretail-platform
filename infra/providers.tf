# Provider configurations.
#
# azurerm 4.x REQUIRES subscription_id to be set explicitly (it does not infer
# it from `az account show` like 3.x did). We take it as a variable so the
# same code can target any subscription.

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    # Allow `terraform destroy` to remove the RG even if Azure-managed sub-resources
    # (like the AKS-created node RG) are still present. Without this, AKS leaves
    # orphans that block destroy.
    resource_group {
      prevent_deletion_if_contains_resources = false
    }

    # Key Vault soft delete + purge protection is enabled by Azure default in
    # new tenants. For a dev sandbox we want destroy to actually destroy:
    #   - purge_soft_delete_on_destroy:    purge during destroy (no 90-day wait)
    #   - recover_soft_deleted_key_vaults: if a vault with the same name exists
    #     in soft-deleted state from a previous run, recover it instead of failing
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }

    # Same idea for Log Analytics — without this, destroyed workspaces sit in
    # a "soft-deleted" state for 14 days and re-creating the same name fails.
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}