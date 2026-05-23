# Layer 2 — CI/CD identities (UAMIs + federated credentials + RBAC).
#
# THREE managed identities, each scoped to exactly what its workflow needs:
#
#   id-cicd-app-<...>           AcrPush + AcrPull on the ACR
#                               Federations: gh-app-main, gh-app-pr
#                               Used by: .github/workflows/app-ci.yml
#
#   id-cicd-platform-ro-<...>   Reader on subscription
#                               Storage Blob Data Reader on tfstate SA
#                               Federations: gh-platform-ro-pr
#                               Used by: .github/workflows/infra-plan.yml
#
#   id-cicd-platform-rw-<...>   Contributor + User Access Administrator on sub
#                               Storage Blob Data Contributor on tfstate SA
#                               Federations: gh-platform-rw-env
#                               Used by: .github/workflows/infra-apply.yml
#                               (Token issuance gated by GitHub Environment
#                               with required reviewers.)
#
# Why split into three: principle of least privilege. A compromised PR
# (a malicious commit by a collaborator with push access — fork PRs do not
# get OIDC tokens) can at worst exercise what the corresponding UAMI can
# do. The high-privilege UAMI requires environment approval, so even a
# compromised collaborator account cannot run `terraform apply` without
# a human pressing "Approve" in the GitHub UI.

# --- Read Layer 1 outputs from remote state -----------------------------------
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

# --- Reference the tfstate SA so we can grant RBAC on it ---------------------
# The SA was provisioned out-of-band by ../../infra/bootstrap/bootstrap.ps1.
# We read it via data source rather than managing it (the bootstrap script
# owns its lifecycle).
data "azurerm_storage_account" "tfstate" {
  name                = var.layer1_tfstate_storage_account
  resource_group_name = var.layer1_tfstate_resource_group
}

# --- Resource group hosting all three CI UAMIs --------------------------------
# Separated from the platform RG so platform destroys don't kill the CI
# identities, and rebuilds don't force re-federation of GitHub.
resource "azurerm_resource_group" "cicd" {
  name     = "rg-cicd-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

# ============================================================================ #
# Identity 1 — APP (image push to ACR)
# ============================================================================ #

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-cicd-app-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.cicd.name
  location            = azurerm_resource_group.cicd.location
  tags                = local.common_tags
}

resource "azurerm_federated_identity_credential" "app_main" {
  name                = "gh-app-main"
  resource_group_name = azurerm_resource_group.cicd.name
  parent_id           = azurerm_user_assigned_identity.app.id
  audience            = local.github_audience
  issuer              = local.github_oidc_issuer
  subject             = local.github_subject_main
}

resource "azurerm_federated_identity_credential" "app_pr" {
  name                = "gh-app-pr"
  resource_group_name = azurerm_resource_group.cicd.name
  parent_id           = azurerm_user_assigned_identity.app.id
  audience            = local.github_audience
  issuer              = local.github_oidc_issuer
  subject             = local.github_subject_pr
}

resource "azurerm_role_assignment" "app_acr_push" {
  scope                = data.terraform_remote_state.layer1.outputs.acr_id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  description          = "App CI UAMI: push images built by app-ci.yml."
}

resource "azurerm_role_assignment" "app_acr_pull" {
  scope                = data.terraform_remote_state.layer1.outputs.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  description          = "App CI UAMI: pull existing image tags during builds."
}

# ============================================================================ #
# Identity 2 — PLATFORM READ-ONLY (terraform plan on PR)
# ============================================================================ #

resource "azurerm_user_assigned_identity" "platform_ro" {
  name                = "id-cicd-platform-ro-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.cicd.name
  location            = azurerm_resource_group.cicd.location
  tags                = local.common_tags
}

resource "azurerm_federated_identity_credential" "platform_ro_pr" {
  name                = "gh-platform-ro-pr"
  resource_group_name = azurerm_resource_group.cicd.name
  parent_id           = azurerm_user_assigned_identity.platform_ro.id
  audience            = local.github_audience
  issuer              = local.github_oidc_issuer
  subject             = local.github_subject_pr
}

resource "azurerm_role_assignment" "platform_ro_reader" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.platform_ro.principal_id
  description          = "Platform RO UAMI: read all Azure resources during terraform plan."
}

resource "azurerm_role_assignment" "platform_ro_tfstate_read" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.platform_ro.principal_id
  description          = "Platform RO UAMI: read tfstate during plan."
}

# ============================================================================ #
# Identity 3 — PLATFORM READ-WRITE (terraform apply, env-gated)
# ============================================================================ #

resource "azurerm_user_assigned_identity" "platform_rw" {
  name                = "id-cicd-platform-rw-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.cicd.name
  location            = azurerm_resource_group.cicd.location
  tags                = local.common_tags
}

resource "azurerm_federated_identity_credential" "platform_rw_env" {
  name                = "gh-platform-rw-env"
  resource_group_name = azurerm_resource_group.cicd.name
  parent_id           = azurerm_user_assigned_identity.platform_rw.id
  audience            = local.github_audience
  issuer              = local.github_oidc_issuer
  subject             = local.github_subject_env
}

resource "azurerm_role_assignment" "platform_rw_contributor" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.platform_rw.principal_id
  description          = "Platform RW UAMI: create/modify Azure resources during terraform apply."
}

# Required so the apply can create role assignments (Layer 1 grants AcrPull
# to the kubelet, Key Vault roles to the AKS admin group, etc.). User Access
# Administrator is the role that allows creating role assignments.
resource "azurerm_role_assignment" "platform_rw_uaa" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "User Access Administrator"
  principal_id         = azurerm_user_assigned_identity.platform_rw.principal_id
  description          = "Platform RW UAMI: create role assignments during terraform apply."
}

resource "azurerm_role_assignment" "platform_rw_tfstate_write" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.platform_rw.principal_id
  description          = "Platform RW UAMI: read/write tfstate during apply."
}
