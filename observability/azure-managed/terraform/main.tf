# Layer 4b — Azure Managed Prometheus + Managed Grafana.
#
# Created here:
#   - Resource group `rg-obs-<...>` (separate from the platform RG)
#   - `azurerm_monitor_workspace` — the Managed Prometheus backend (Azure
#     Monitor Workspace; stores metric time-series, queries via PromQL).
#   - `azurerm_dashboard_grafana` — the Managed Grafana instance, linked to
#     the Monitor Workspace via the `azure_monitor_workspace_integrations`
#     block. Grafana's system-assigned identity automatically gets the
#     `Monitoring Data Reader` role on the workspace (the AzureRM provider
#     handles this).
#   - Role assignment for the operator user on Grafana (Grafana Admin role).
#
# NOT created here (handled by ../bootstrap/enable-aks-managed-prometheus.ps1):
#   - The DCR / DCE / DCR association objects.
#   - The `monitor_metrics` enablement on the AKS cluster.
#   - The `ama-metrics` DaemonSet in the AKS cluster.
# The `az aks update --enable-azure-monitor-metrics` command creates all of
# the above in one shot, which is much less code than wiring DCR + DCE +
# association by hand.

# --- Read Layer 1 outputs (for AKS cluster reference + region match) ---------
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

# --- Resource group --------------------------------------------------------
resource "azurerm_resource_group" "obs" {
  name     = "rg-obs-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

# --- Azure Monitor Workspace (= Managed Prometheus backend) ------------------
resource "azurerm_monitor_workspace" "this" {
  name                = local.monitor_workspace_name
  resource_group_name = azurerm_resource_group.obs.name
  location            = azurerm_resource_group.obs.location

  # Public access on: easier demo via az + portal. Production sets
  # `public_network_access_enabled = false` and uses private endpoints.
  public_network_access_enabled = true

  tags = local.common_tags
}

# --- Azure Managed Grafana --------------------------------------------------
resource "azurerm_dashboard_grafana" "this" {
  name                = local.managed_grafana_name
  resource_group_name = azurerm_resource_group.obs.name
  location            = azurerm_resource_group.obs.location

  sku = var.managed_grafana_sku

  # System-assigned managed identity for Grafana → Monitor Workspace auth.
  # The AzureRM provider creates the identity AND the role assignment
  # automatically when `azure_monitor_workspace_integrations` is set.
  identity {
    type = "SystemAssigned"
  }

  # Link Managed Grafana to our Monitor Workspace. The provider creates
  # the Monitoring Data Reader role assignment on this workspace for the
  # Grafana system identity behind the scenes.
  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }

  # Public-internet-accessible by default. Production: set
  # `public_network_access_enabled = false` + create a private endpoint.
  public_network_access_enabled = true

  # Disable email notifications from Grafana itself (we route alerts via
  # Alertmanager, not via Grafana's own notifier).
  grafana_major_version = 11

  tags = local.common_tags
}

# --- Operator → Grafana Admin role -----------------------------------------
# Without this, no one can log into Grafana even after deployment. The
# system-assigned identity manages the backend; HUMAN access goes through
# Entra ID + a Grafana-scoped role. "Grafana Admin" is the highest of three
# Grafana roles (Admin > Editor > Viewer).
resource "azurerm_role_assignment" "grafana_admin" {
  count = var.grafana_admin_user_object_id == "" ? 0 : 1

  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Admin"
  principal_id         = var.grafana_admin_user_object_id
  description          = "Initial human admin for Managed Grafana."
}
