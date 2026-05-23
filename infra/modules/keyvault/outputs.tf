output "id" {
  description = "Key Vault resource ID."
  value       = azurerm_key_vault.this.id
}

output "name" {
  description = "Key Vault name."
  value       = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "Key Vault DNS URI (e.g., https://kv-gr-...vault.azure.net/). Used by SDKs and the CSI driver."
  value       = azurerm_key_vault.this.vault_uri
}
