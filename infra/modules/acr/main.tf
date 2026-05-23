# ==============================================================================
# Azure Container Registry module
# ==============================================================================
# Creates the platform ACR, wires its diagnostic logs to Log Analytics, and
# grants the AKS kubelet identity AcrPull so the cluster can pull images
# without image-pull secrets.

# --- Random suffix for the globally-unique name -------------------------------
# ACR names are 5-50 lowercase alphanumeric, globally unique across all of
# Azure. We use a 6-char hex suffix so we can recreate the resource in another
# subscription without name conflicts.
resource "random_id" "acr_suffix" {
  byte_length = 3
}

# --- ACR ----------------------------------------------------------------------
# SKU choice: STANDARD ($5/month base + storage + pull egress)
#
# What we get with Standard:
#   - Geo-replicated storage:        NO  (Premium only — $1.65/day extra)
#   - Network rules (IP firewall):   NO  (Premium only)
#   - Private endpoints:             NO  (Premium only)
#   - Customer-managed keys:         NO  (Premium only)
#   - Repository-scoped tokens:      NO  (Premium only)
#   - Content trust / image signing: NO  (Premium only)
#   - Webhooks, vulnerability scan:  YES
#
# So Standard means: ACR is publicly reachable over the internet, anyone with
# a valid Entra ID auth token + AcrPull role can pull. That's actually fine
# for many production deployments — auth is enforced, traffic is TLS, and
# images are not secrets. Premium is justified when you have:
#   - Sensitive image contents (proprietary binaries you can't risk leaking)
#   - Compliance requirements forcing private network paths (PCI, HIPAA)
#   - Multi-region deployments needing geo-replication
#
# For this reference architecture (single region, no proprietary code in
# images, dev environment), Standard is the right pick.
resource "azurerm_container_registry" "this" {
  name                = "acr${replace(var.name_suffix, "-", "")}${random_id.acr_suffix.hex}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"

  # Admin user is a SHARED USERNAME+PASSWORD that bypasses Entra ID auth.
  # Every "ACR security: turn this off" guide on the internet starts with this
  # setting. We use the kubelet identity + AcrPull role instead.
  admin_enabled = false

  # Anonymous pull is for community OSS registries (think Docker Hub). For a
  # private platform registry it should always be off.
  anonymous_pull_enabled = false

  tags = var.tags
}

# --- Role assignment: AKS kubelet identity → AcrPull --------------------------
# This is THE assignment that makes "no image pull secrets" possible. The
# kubelet on every AKS node authenticates to ACR using its managed identity;
# this role lets it pull but not push, list, or delete.
#
# 'AcrPull' is the minimum role for pulls. Other ACR roles:
#   - AcrPush       : pull + push (used by CI/CD in Layer 2)
#   - AcrDelete     : delete repositories
#   - Owner         : full control
#   - Contributor   : full control except role assignments
resource "azurerm_role_assignment" "kubelet_acrpull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = var.kubelet_identity_object_id
  principal_type       = "ServicePrincipal" # UAMIs authenticate as service principals at the data plane
}

# --- Diagnostic settings → Log Analytics --------------------------------------
# Capture pull events, push events, and audit logs so we can answer
# questions like:
#   - Which images were pulled the most last week?
#   - Did anyone push to ACR outside of the CI/CD pipeline?
#   - When was image X last pulled (can we delete it)?
#
# Without this, ACR retains nothing visible to us beyond ~30 days of
# in-portal data — and the in-portal data is not queryable with KQL.
resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }
  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
