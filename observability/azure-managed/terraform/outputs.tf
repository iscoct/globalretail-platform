output "monitor_workspace_id" {
  description = "Resource ID of the Azure Monitor Workspace (Managed Prometheus). Pass to the bootstrap script."
  value       = azurerm_monitor_workspace.this.id
}

output "monitor_workspace_name" {
  description = "Name of the Monitor Workspace."
  value       = azurerm_monitor_workspace.this.name
}

output "monitor_workspace_query_endpoint" {
  description = "PromQL query endpoint. Useful for ad-hoc curl + jq tests."
  value       = azurerm_monitor_workspace.this.query_endpoint
}

output "managed_grafana_id" {
  description = "Resource ID of the Managed Grafana instance. Pass to the bootstrap script."
  value       = azurerm_dashboard_grafana.this.id
}

output "managed_grafana_endpoint" {
  description = "Public URL of the Managed Grafana UI."
  value       = azurerm_dashboard_grafana.this.endpoint
}

output "managed_grafana_identity_principal_id" {
  description = "Principal ID of Grafana's system-assigned MI. Useful for ad-hoc role assignments (extra Monitor Workspaces, Log Analytics, etc.)."
  value       = azurerm_dashboard_grafana.this.identity[0].principal_id
}

output "resource_group_name" {
  description = "RG holding the Monitor Workspace + Managed Grafana."
  value       = azurerm_resource_group.obs.name
}
