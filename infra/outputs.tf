# Outputs.
#
# These are values that downstream layers (CI/CD, GitOps, monitoring) consume.
# They are also the "API contract" of Layer 1 — if you change an output name,
# downstream layers break. Treat them carefully.

output "resource_group_name" {
  description = "Platform resource group name."
  value       = azurerm_resource_group.platform.name
}

output "location" {
  description = "Azure region."
  value       = var.location
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID — consumed by diagnostic settings on every resource."
  value       = azurerm_log_analytics_workspace.platform.id
}

output "aks_controlplane_identity_id" {
  description = "User-assigned managed identity resource ID for the AKS control plane."
  value       = azurerm_user_assigned_identity.aks_controlplane.id
}

output "aks_controlplane_identity_principal_id" {
  description = "Object (principal) ID of the AKS control-plane UAMI — used in role assignments."
  value       = azurerm_user_assigned_identity.aks_controlplane.principal_id
}

output "vnet_id" {
  description = "Platform VNet resource ID."
  value       = module.network.vnet_id
}

output "aks_nodes_subnet_id" {
  description = "Subnet ID for AKS node pools (consumed by the AKS module in Iteration 3)."
  value       = module.network.aks_nodes_subnet_id
}

output "private_endpoints_subnet_id" {
  description = "Subnet ID reserved for private endpoints (consumed by ACR/KV in Iteration 2 if PE is enabled)."
  value       = module.network.private_endpoints_subnet_id
}

# --- Iteration 2 outputs ------------------------------------------------------

output "aks_kubelet_identity_id" {
  description = "User-assigned managed identity resource ID for the AKS kubelet."
  value       = azurerm_user_assigned_identity.aks_kubelet.id
}

output "aks_kubelet_identity_client_id" {
  description = "Client ID of the AKS kubelet UAMI — needed by AKS create."
  value       = azurerm_user_assigned_identity.aks_kubelet.client_id
}

output "aks_kubelet_identity_principal_id" {
  description = "Object (principal) ID of the AKS kubelet UAMI."
  value       = azurerm_user_assigned_identity.aks_kubelet.principal_id
}

output "aks_admin_group_object_id" {
  description = "Object ID of the AKS admin Entra ID group, or null if group creation is disabled."
  value       = var.create_aks_admin_group ? azuread_group.aks_admins[0].object_id : null
}

output "acr_id" {
  description = "ACR resource ID."
  value       = module.acr.id
}

output "acr_name" {
  description = "ACR name."
  value       = module.acr.name
}

output "acr_login_server" {
  description = "ACR login server (e.g., acrXXX.azurecr.io)."
  value       = module.acr.login_server
}

output "key_vault_id" {
  description = "Key Vault resource ID."
  value       = module.keyvault.id
}

output "key_vault_name" {
  description = "Key Vault name."
  value       = module.keyvault.name
}

output "key_vault_uri" {
  description = "Key Vault DNS URI."
  value       = module.keyvault.vault_uri
}

# --- Iteration 3 outputs ------------------------------------------------------

output "aks_cluster_id" {
  description = "AKS cluster resource ID."
  value       = module.aks.id
}

output "aks_cluster_name" {
  description = "AKS cluster name."
  value       = module.aks.name
}

output "aks_node_resource_group" {
  description = "Auto-managed resource group holding the cluster's VMSS, LBs, NSGs."
  value       = module.aks.node_resource_group
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL — federated credentials for Workload Identity reference this."
  value       = module.aks.oidc_issuer_url
}

output "aks_fqdn" {
  description = "Public FQDN of the cluster's API server."
  value       = module.aks.fqdn
}

output "operator_ip_in_authorized_ranges" {
  description = "The public IP whitelisted in api_server_authorized_ip_ranges (auto-discovered)."
  value       = "${chomp(data.http.my_ip.response_body)}/32"
}
