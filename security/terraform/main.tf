# Layer 5 — Workload Identity binding for sample-app + demo secret.
#
# What gets created (4 resources):
#   - 1 User-Assigned Managed Identity (the "workload" UAMI)
#   - 1 Federated credential on it, scoped to AKS OIDC + the
#     sample-app/sample-app ServiceAccount subject
#   - 1 RBAC role assignment: Key Vault Secrets User on Layer 1's Key Vault
#   - 1 Key Vault secret (the lab demo payload)
#
# Why a SEPARATE UAMI from the AKS control-plane / kubelet UAMIs (Layer 1):
# least privilege per workload. The sample-app's identity has access ONLY to
# the secret(s) it owns — it cannot, for example, read other apps' secrets
# from the same Key Vault. In a multi-app cluster every workload has its
# own UAMI federated to its own ServiceAccount.

# --- Read Layer 1 outputs ---------------------------------------------------
data "terraform_remote_state" "layer1" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.layer1_tfstate_resource_group
    storage_account_name = var.layer1_tfstate_storage_account
    container_name       = var.layer1_tfstate_container
    key                  = var.layer1_tfstate_key
    use_azuread_auth     = true
    subscription_id      = var.subscription_id
    tenant_id            = var.tenant_id
  }
}

# --- Resource group ---------------------------------------------------------
# Per-workload RG for the security artefacts. Could share the platform RG;
# we keep it separate to mirror the Layer 2 pattern (CI identities in their
# own RG) — clearer ownership in the portal.
resource "azurerm_resource_group" "security" {
  name     = "rg-security-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

# --- Workload UAMI ----------------------------------------------------------
resource "azurerm_user_assigned_identity" "sample_app" {
  name                = "id-workload-sample-app-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.security.name
  location            = azurerm_resource_group.security.location
  tags                = local.common_tags
}

# --- Federated credential: AKS OIDC -> sample-app SA ------------------------
# The subject must EXACTLY match the projected token's `sub` claim
# (system:serviceaccount:NS:SA). The issuer is the AKS cluster's OIDC
# issuer URL, published by Layer 1 and exported as a remote-state output.
resource "azurerm_federated_identity_credential" "sample_app" {
  name                = "aks-sample-app-sa"
  resource_group_name = azurerm_resource_group.security.name
  parent_id           = azurerm_user_assigned_identity.sample_app.id
  audience            = local.workload_audience
  issuer              = data.terraform_remote_state.layer1.outputs.aks_oidc_issuer_url
  subject             = local.workload_subject
}

# --- Role assignment: Key Vault Secrets User on Layer 1's Key Vault --------
# `Key Vault Secrets User` (NOT Administrator). The principle of least
# privilege: sample-app only READS secrets. Layer 1 already wired RBAC
# mode on the vault, so this is a standard Azure role assignment.
resource "azurerm_role_assignment" "sample_app_kv_secrets_user" {
  scope                = data.terraform_remote_state.layer1.outputs.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.sample_app.principal_id
  description          = "Workload UAMI for sample-app: read secrets from the platform Key Vault."
}

# --- Demo secret in the Key Vault -------------------------------------------
# In a real production setup the secret is set out-of-band (by the team that
# owns the secret, or by a sealed-secrets pipeline). For the lab we set it
# here so a single `terraform apply` lays down everything needed for the
# /version endpoint demo to work end-to-end.
resource "azurerm_key_vault_secret" "welcome_message" {
  name         = var.welcome_message_secret_name
  value        = var.welcome_message_secret_value
  key_vault_id = data.terraform_remote_state.layer1.outputs.key_vault_id

  # Tag the secret so we can find demo secrets in the portal.
  tags = merge(local.common_tags, {
    "consumed-by" = "sample-app"
  })
}
