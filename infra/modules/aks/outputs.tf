output "id" {
  description = "AKS cluster resource ID."
  value       = azurerm_kubernetes_cluster.this.id
}

output "name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group" {
  description = "Auto-managed infrastructure RG holding VMSS, LBs, NSGs for the cluster."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL — required for Workload Identity federated credentials."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kube_config_host" {
  description = "API server host (FQDN). Used by kubeconfig consumers."
  value       = azurerm_kubernetes_cluster.this.kube_config[0].host
}

output "fqdn" {
  description = "Public FQDN of the cluster's API server."
  value       = azurerm_kubernetes_cluster.this.fqdn
}
