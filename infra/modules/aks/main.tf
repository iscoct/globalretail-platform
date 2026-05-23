# ==============================================================================
# AKS module — the cluster itself, plus the two role assignments AKS requires
# to function (Network Contributor on the subnet, Managed Identity Operator on
# the kubelet UAMI) and a diagnostic setting to Log Analytics.
# ==============================================================================

# ------------------------------------------------------------------------------
# Role assignments — these must exist BEFORE the cluster, otherwise create
# fails with cryptic permission errors. Hence they live in this same module
# (so Terraform's dependency graph schedules them first via depends_on).
# ------------------------------------------------------------------------------

# Control-plane UAMI → Network Contributor on the AKS nodes subnet.
# Without this: AKS cannot attach NICs, create the load balancer, or scale
# nodes. Create fails late with "AuthorizationFailed" on subnet operations.
# Scoping at SUBNET level (not VNet) follows least privilege.
resource "azurerm_role_assignment" "controlplane_network_contributor" {
  scope                = var.aks_nodes_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = var.controlplane_identity_principal_id
  principal_type       = "ServicePrincipal"
}

# Control-plane UAMI → Managed Identity Operator on the kubelet UAMI.
# Without this: cluster create fails with
#   "principal does not have permission to perform operation
#    Microsoft.ManagedIdentity/userAssignedIdentities/assign/action".
# Required because the control plane assigns the kubelet UAMI to each node VM
# during provisioning. One of the most common AKS-with-pre-created-identities
# gotchas.
resource "azurerm_role_assignment" "controlplane_kubelet_operator" {
  scope                = var.kubelet_identity_id
  role_definition_name = "Managed Identity Operator"
  principal_id         = var.controlplane_identity_principal_id
  principal_type       = "ServicePrincipal"
}

# ------------------------------------------------------------------------------
# The AKS cluster
# ------------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.name_suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "aks-${var.name_suffix}"
  kubernetes_version  = var.kubernetes_version

  # AKS auto-creates an INFRASTRUCTURE resource group holding the cluster's
  # VMSS, LBs, NSGs, disks, etc. Default name is `MC_<rg>_<aks>_<region>`,
  # which is ugly. Override it for clarity.
  node_resource_group = "rg-${var.name_suffix}-aks-nodes"

  # 'Standard' SKU has an SLA (99.9% / 99.95% multi-AZ). 'Free' has no SLA.
  # The price difference is the SLA fee (~$0.10/hr) — for a dev sandbox it's
  # optional, but enabling it teaches the production setup. The SLA is the
  # whole reason you'd buy AKS over self-hosted k8s, so the reference repo
  # should show it.
  sku_tier = "Standard"

  # ------------- Identity ----------------------------------------------------
  identity {
    type         = "UserAssigned"
    identity_ids = [var.controlplane_identity_id]
  }

  # Pre-created kubelet UAMI (AcrPull already granted in Iter 2).
  # Using a UAMI here (not auto-created system-assigned) lets us survive
  # cluster recreations without losing image-pull permissions.
  kubelet_identity {
    client_id                 = var.kubelet_identity_client_id
    object_id                 = var.kubelet_identity_object_id
    user_assigned_identity_id = var.kubelet_identity_id
  }

  # ------------- Networking --------------------------------------------------
  # Azure CNI Overlay + Cilium dataplane ("Azure CNI Powered by Cilium").
  # What this gives us:
  #   - Pods are in an overlay network (pod_cidr), NOT in the VNet
  #     → no IP exhaustion at scale
  #   - Cilium eBPF dataplane: faster than iptables-based kube-proxy,
  #     better observability (Hubble), L7 policies
  #   - network_policy = "cilium" is REQUIRED when dataplane is cilium
  #     (other values are rejected at apply time)
  #
  # service_cidr is chosen to not overlap with vnet (10.0.0.0/16) or
  # pod_cidr (10.244.0.0/16). dns_service_ip must be inside service_cidr.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.245.0.0/16"
    dns_service_ip      = "10.245.0.10"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  # ------------- Entra ID + Azure RBAC for Kubernetes ------------------------
  # azure_rbac_enabled = true means kubectl access is gated by Azure RBAC
  # role assignments on the cluster scope ('Azure Kubernetes Service RBAC
  # Cluster Admin', 'Azure Kubernetes Service RBAC Admin', '... Reader',
  # '... Writer'). No more kubeconfig flat files passed around.
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
    tenant_id              = var.tenant_id
  }

  # Disables `az aks get-credentials --admin`. Once this is true, the only
  # way into the cluster is through Entra ID auth. Lose your Entra ID
  # access and you're locked out — hence the admin GROUP, so multiple
  # humans can be in it.
  local_account_disabled = true

  # ------------- Workload Identity -------------------------------------------
  # OIDC issuer URL is published on the cluster; the next layer can federate
  # an Entra ID UAMI to a Kubernetes ServiceAccount via that URL.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # ------------- API server access -------------------------------------------
  # 'authorized_ip_ranges' allows only the listed CIDRs to reach the public
  # API server endpoint. Entra ID auth is still required ON TOP of this —
  # network-level + token-level defense-in-depth. The IP we whitelist is
  # auto-discovered from the operator's current public IP (see root main.tf).
  #
  # Note: AKS RBAC + Entra ID would be sufficient on its own — but PCI
  # compliance + most "production cluster" checklists demand network-level
  # restriction too.
  api_server_access_profile {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  # ------------- Auto-upgrade ------------------------------------------------
  # 'patch' channel: AKS auto-applies security patches WITHIN the current
  # minor version (1.35.X). Minor upgrades stay manual. Sweet spot for prod:
  # security patches land without intervention, intentional upgrades remain
  # opt-in.
  automatic_upgrade_channel = "patch"

  # ------------- System node pool (must be inline) ---------------------------
  # AKS requires at least one node pool defined inline on the cluster
  # resource (the "system" pool). The user pool is a separate resource.
  default_node_pool {
    name           = "system"
    vm_size        = var.system_node_size
    node_count     = var.system_node_count
    vnet_subnet_id = var.aks_nodes_subnet_id

    os_disk_size_gb = 30
    os_disk_type    = "Managed"

    # Adds taint 'CriticalAddonsOnly=true:NoSchedule' so that only system
    # add-ons (CoreDNS, metrics-server, konnectivity, etc.) land here.
    # User workloads schedule on the user pool. Separating them means a
    # runaway user workload can't OOM the system pods.
    only_critical_addons_enabled = true

    upgrade_settings {
      max_surge = "10%"
    }

    tags = var.tags
  }

  tags = var.tags

  # AKS create takes time; explicitly state dependency on the role
  # assignments so they're created first. Terraform usually figures this
  # out, but the explicit depends_on documents intent for readers.
  depends_on = [
    azurerm_role_assignment.controlplane_network_contributor,
    azurerm_role_assignment.controlplane_kubelet_operator,
  ]
}

# ------------------------------------------------------------------------------
# User node pool — where workloads actually run
# ------------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.user_node_size
  vnet_subnet_id        = var.aks_nodes_subnet_id

  os_disk_size_gb = 30
  os_disk_type    = "Managed"
  mode            = "User"

  auto_scaling_enabled = true
  min_count            = var.user_node_min_count
  max_count            = var.user_node_max_count

  upgrade_settings {
    max_surge = "10%"
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Diagnostic settings → Log Analytics
# ------------------------------------------------------------------------------
# Captures control-plane logs that AKS does NOT expose via kubectl logs:
#   - kube-apiserver:            API request/response, slow queries, etc.
#   - kube-audit:                every authenticated request — required for
#                                PCI / SOC2 audits
#   - kube-audit-admin:          subset of audit, admin actions only
#   - kube-controller-manager:   controller decisions
#   - kube-scheduler:            scheduling decisions
#   - cluster-autoscaler:        scale up/down events with reasons
#   - guard:                     Entra ID auth events
#
# Without this, AKS retains these for ~14 days IF you have monitoring
# enabled on the cluster, but they're not queryable. With it, they land in
# our Log Analytics workspace and can be queried with KQL alongside ACR/KV
# logs.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "kube-apiserver"
  }
  enabled_log {
    category = "kube-controller-manager"
  }
  enabled_log {
    category = "kube-scheduler"
  }
  enabled_log {
    category = "kube-audit"
  }
  enabled_log {
    category = "kube-audit-admin"
  }
  enabled_log {
    category = "cluster-autoscaler"
  }
  enabled_log {
    category = "guard"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}