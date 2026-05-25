# Outputs the operator copies into the K8s manifests.
#
# Specifically, `workload_identity_client_id` becomes the value of the
# `azure.workload.identity/client-id` annotation on the sample-app
# ServiceAccount (see gitops/workloads/sample-app/base/serviceaccount.yaml).
# Each fork's UAMI has a different client_id; that's why the YAML file
# carries a placeholder and the operator pastes the value here after apply.

output "workload_identity_client_id" {
  description = "Client ID of the workload UAMI. Paste into the sample-app ServiceAccount's azure.workload.identity/client-id annotation."
  value       = azurerm_user_assigned_identity.sample_app.client_id
}

output "workload_identity_principal_id" {
  description = "Principal (object) ID of the workload UAMI."
  value       = azurerm_user_assigned_identity.sample_app.principal_id
}

output "workload_identity_resource_id" {
  description = "Resource ID of the workload UAMI."
  value       = azurerm_user_assigned_identity.sample_app.id
}

output "key_vault_name" {
  description = "Name of the Key Vault the workload UAMI can read from. Used in the SecretProviderClass."
  value       = data.terraform_remote_state.layer1.outputs.key_vault_name
}

output "key_vault_uri" {
  description = "URI of the Key Vault. Useful for portal links / az CLI."
  value       = data.terraform_remote_state.layer1.outputs.key_vault_uri
}

output "welcome_message_secret_name" {
  description = "Name of the demo secret in Key Vault. Referenced from the SecretProviderClass."
  value       = azurerm_key_vault_secret.welcome_message.name
}

output "tenant_id" {
  description = "Tenant ID — needed by the SecretProviderClass."
  value       = var.tenant_id
}
