# Outputs consumed by github-setup/set-github-vars.ps1 to seed GitHub repo
# variables and (where the environment scope demands) GitHub Environment vars.
# None of these are secret — they are identifiers visible in the Azure portal
# to anyone with read access.

# --- App UAMI ----------------------------------------------------------------
output "app_identity_client_id" {
  description = "Client ID of the App CI UAMI. Goes into repo var AZURE_CLIENT_ID_APP."
  value       = azurerm_user_assigned_identity.app.client_id
}

output "app_identity_principal_id" {
  description = "Principal (object) ID of the App CI UAMI."
  value       = azurerm_user_assigned_identity.app.principal_id
}

# --- Platform RO UAMI --------------------------------------------------------
output "platform_ro_identity_client_id" {
  description = "Client ID of the Platform-RO UAMI. Goes into repo var AZURE_CLIENT_ID_INFRA_PLAN."
  value       = azurerm_user_assigned_identity.platform_ro.client_id
}

output "platform_ro_identity_principal_id" {
  description = "Principal (object) ID of the Platform-RO UAMI."
  value       = azurerm_user_assigned_identity.platform_ro.principal_id
}

# --- Platform RW UAMI --------------------------------------------------------
output "platform_rw_identity_client_id" {
  description = "Client ID of the Platform-RW UAMI. Goes into the GitHub Environment var AZURE_CLIENT_ID_INFRA_APPLY (env-scoped, gated by required reviewers)."
  value       = azurerm_user_assigned_identity.platform_rw.client_id
}

output "platform_rw_identity_principal_id" {
  description = "Principal (object) ID of the Platform-RW UAMI."
  value       = azurerm_user_assigned_identity.platform_rw.principal_id
}

# --- Shared ------------------------------------------------------------------
output "cicd_resource_group" {
  description = "RG that holds the three CI identities."
  value       = azurerm_resource_group.cicd.name
}

output "tenant_id" {
  description = "Entra ID tenant ID. Goes into repo var AZURE_TENANT_ID."
  value       = var.tenant_id
}

output "subscription_id" {
  description = "Subscription ID. Goes into repo var AZURE_SUBSCRIPTION_ID."
  value       = var.subscription_id
}

output "acr_login_server" {
  description = "ACR login server (e.g., acrXXX.azurecr.io). Goes into repo var ACR_LOGIN_SERVER. Read from Layer 1 state."
  value       = data.terraform_remote_state.layer1.outputs.acr_login_server
}

output "acr_name" {
  description = "ACR name. Goes into repo var ACR_NAME."
  value       = data.terraform_remote_state.layer1.outputs.acr_name
}

output "github_repo_full_name" {
  description = "OWNER/REPO — the federation subject references this string."
  value       = "${var.github_owner}/${var.github_repo}"
}

output "github_environment_name" {
  description = "GitHub Environment that gates infra-apply.yml."
  value       = var.github_environment_name
}
