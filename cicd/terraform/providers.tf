# Provider configurations.
#
# Layer 2 only needs azurerm (UAMI + federated credentials + role assignments
# are all azurerm resources). No azuread provider here: we are not creating
# any Entra ID groups or app registrations.

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}