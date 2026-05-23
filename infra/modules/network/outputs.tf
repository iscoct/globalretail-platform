output "vnet_id" {
  description = "Platform VNet resource ID."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Platform VNet name."
  value       = azurerm_virtual_network.this.name
}

output "aks_nodes_subnet_id" {
  description = "Subnet ID for AKS node pools."
  value       = azurerm_subnet.aks_nodes.id
}

output "private_endpoints_subnet_id" {
  description = "Subnet ID reserved for private endpoints."
  value       = azurerm_subnet.private_endpoints.id
}

output "apiserver_subnet_id" {
  description = "Subnet ID reserved for API Server VNet Integration (not used in Iteration 1)."
  value       = azurerm_subnet.apiserver.id
}