# ==============================================================================
# Platform foundation — Iteration 1
# ==============================================================================
# Resources in this file are the "small singletons" that don't justify their own
# module: the resource group, the observability sink, and the platform identity.
# Larger concerns (network, ACR, Key Vault, AKS) live in modules under ./modules.

# --- Platform resource group --------------------------------------------------
# All Layer 1 resources EXCEPT the tfstate storage account live here. The
# tfstate SA lives in `rg-tfstate-globalretail-weu` (provisioned by bootstrap.ps1)
# so that `terraform destroy` of the platform never deletes its own backend.
resource "azurerm_resource_group" "platform" {
  name     = "rg-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

# --- Log Analytics workspace --------------------------------------------------
# Single sink for diagnostic settings across the platform: AKS control plane
# logs, ACR pull events, Key Vault audit logs, NSG flow logs, etc. Layer 4
# (observability) also queries this workspace.
#
# Why one workspace vs one-per-resource:
#   - Cost: ingestion is volume-based, not workspace-based — splitting wastes
#     no money but adds operational overhead.
#   - Correlation: cross-resource KQL queries require everything in one
#     workspace (or expensive cross-workspace joins).
#   - Retention: one policy to manage.
#
# SKU PerGB2018 (now called "Pay-as-you-go" in the portal) gives 5 GB/month
# free per workspace, then ~$2.30/GB. Standard for non-Sentinel workloads.
resource "azurerm_log_analytics_workspace" "platform" {
  name                = "log-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.platform.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30 # minimum; prod typically 90+
  tags                = local.common_tags
}

# --- User-assigned managed identity for the AKS control plane -----------------
# Pre-created here (rather than letting AKS create a system-assigned identity)
# for two reasons:
#
#   1. PERSISTENCE: A user-assigned identity (UAMI) outlives the cluster.
#      Recreate the AKS cluster, keep the same identity, and every role
#      assignment to it (ACR Pull, Key Vault access) still works. A
#      system-assigned identity dies with the cluster — every role assignment
#      has to be recreated.
#
#   2. ORDERING: Iteration 2 (ACR) needs to grant 'AcrPull' to this identity
#      BEFORE the cluster exists. With system-assigned, you'd have to apply
#      the cluster first, fish out its identity object ID, then go back and
#      grant ACR access — chicken-and-egg.
#
# Production platforms use UAMI for the same reasons.
resource "azurerm_user_assigned_identity" "aks_controlplane" {
  name                = "id-aks-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.platform.name
  location            = var.location
  tags                = local.common_tags
}

# --- User-assigned managed identity for the AKS KUBELET -----------------------
# A SECOND identity, separate from the control plane, used by the kubelet on
# each node to pull images from ACR. Separating control plane and kubelet
# identities follows the principle of least privilege:
#
#   - Control plane identity:  network ops, LB creation, attaching NICs
#   - Kubelet identity:        AcrPull on the ACR, nothing else by default
#
# A leaked kubelet credential cannot manage the cluster; a leaked control-plane
# credential cannot pull arbitrary images. Smaller blast radius per identity.
#
# AKS supports either:
#   (a) auto-create a kubelet identity on cluster create (one-line config but
#       you don't control the name, and you can't grant it permissions BEFORE
#       the cluster exists — leading to image pull failures on first boot)
#   (b) pre-create a UAMI and pass it to AKS (our choice)
#
# Production setups overwhelmingly choose (b) for the same reason we use a
# UAMI for the control plane: persistence and pre-grantable permissions.
resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = "id-aks-kubelet-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.platform.name
  location            = var.location
  tags                = local.common_tags
}

# --- Current Azure CLI session ------------------------------------------------
# We need our own object ID to grant ourselves Key Vault Administrator and to
# seed the AKS admin group. azurerm_client_config returns the principal that
# the provider is currently authenticated as.
data "azurerm_client_config" "current" {}

# --- Entra ID admin group for the AKS cluster ---------------------------------
# In production, Kubernetes admin access is governed by membership in an Entra
# ID group, not by direct user assignment. Rotate humans in/out of the group;
# their cluster access follows automatically. This is the realism check we
# want to teach.
#
# REQUIRES: the signed-in user has permission to create security groups in
# the tenant. Most tenants allow this for any user by default; some
# corporate tenants restrict it. If terraform apply fails with
# "Authorization_RequestDenied" on this resource, set
# create_aks_admin_group = false in your tfvars and we'll fall back to
# direct role assignments to the signed-in user.
resource "azuread_group" "aks_admins" {
  count = var.create_aks_admin_group ? 1 : 0

  display_name     = "${var.workload}-aks-admins"
  description      = "Members of this group are Kubernetes cluster admins on the ${var.workload}-${var.environment} AKS cluster (via Azure RBAC for Kubernetes)."
  security_enabled = true

  # The signed-in user is the initial owner AND member, so we don't lock
  # ourselves out the moment the group is created.
  owners  = [data.azurerm_client_config.current.object_id]
  members = [data.azurerm_client_config.current.object_id]
}

# --- ACR ---------------------------------------------------------------------
module "acr" {
  source = "./modules/acr"

  name_suffix                = local.name_suffix
  resource_group_name        = azurerm_resource_group.platform.name
  location                   = var.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.platform.id
  kubelet_identity_object_id = azurerm_user_assigned_identity.aks_kubelet.principal_id
  tags                       = local.common_tags
}

# --- Key Vault ----------------------------------------------------------------
module "keyvault" {
  source = "./modules/keyvault"

  workload                   = var.workload
  resource_group_name        = azurerm_resource_group.platform.name
  location                   = var.location
  tenant_id                  = var.tenant_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.platform.id
  # Map with STATIC labels (known at plan time) and object IDs as values (some
  # known only at apply time). This shape is required so for_each in the module
  # can iterate without unknowns in its key set.
  admin_object_ids = merge(
    {
      "signed-in-user" = data.azurerm_client_config.current.object_id
    },
    var.create_aks_admin_group ? {
      "aks-admin-group" = azuread_group.aks_admins[0].object_id
    } : {}
  )
  tags = local.common_tags
}

# --- Network ------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  name_suffix         = local.name_suffix
  resource_group_name = azurerm_resource_group.platform.name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

# --- Operator's public IP (auto-discovered) -----------------------------------
# Used in api_server_authorized_ip_ranges. The 'http' provider queries
# ipify.org on every plan; if your ISP rotates your IP between runs,
# `terraform apply` regenerates the rule. Documented trade-off: if you
# `apply` from network A and then try to use kubectl from network B, you'll
# be locked out until you `apply` again from network B.
data "http" "my_ip" {
  url = "https://api.ipify.org"
}

# --- AKS ---------------------------------------------------------------------
module "aks" {
  source = "./modules/aks"

  name_suffix         = local.name_suffix
  resource_group_name = azurerm_resource_group.platform.name
  location            = var.location
  kubernetes_version  = var.kubernetes_version
  tenant_id           = var.tenant_id

  controlplane_identity_id           = azurerm_user_assigned_identity.aks_controlplane.id
  controlplane_identity_principal_id = azurerm_user_assigned_identity.aks_controlplane.principal_id
  kubelet_identity_id                = azurerm_user_assigned_identity.aks_kubelet.id
  kubelet_identity_client_id         = azurerm_user_assigned_identity.aks_kubelet.client_id
  kubelet_identity_object_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id

  aks_nodes_subnet_id        = module.network.aks_nodes_subnet_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.platform.id

  admin_group_object_ids = var.create_aks_admin_group ? [azuread_group.aks_admins[0].object_id] : []

  api_server_authorized_ip_ranges = ["${chomp(data.http.my_ip.response_body)}/32"]

  system_node_count   = var.system_node_count
  system_node_size    = var.system_node_size
  user_node_size      = var.user_node_size
  user_node_min_count = var.user_node_min_count
  user_node_max_count = var.user_node_max_count

  tags = local.common_tags
}