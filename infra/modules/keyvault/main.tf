# ==============================================================================
# Key Vault module
# ==============================================================================
# Creates the platform Key Vault in RBAC mode, grants admin access to a set
# of object IDs (the signed-in user, optionally the AKS admin group), and
# wires diagnostic logs to Log Analytics.

# --- Random suffix for the globally-unique name -------------------------------
# KV names are 3-24 alphanumeric + dashes, globally unique. With our naming
# convention 'kv-globalretail-dev-weu' = 23 chars — already at the limit and
# not unique. So we shorten and add a 4-char hex suffix.
resource "random_id" "kv_suffix" {
  byte_length = 2 # 4 hex chars
}

# --- Key Vault ---------------------------------------------------------------
# Two access models exist:
#   - Access policies (legacy): per-principal grants stored on the vault.
#       Each grant lists the operations allowed (get, list, set, delete,
#       backup, restore, ...). Hard to audit across vaults, no Azure RBAC
#       integration, no inheritance, no Conditional Access support.
#   - RBAC (rbac_authorization_enabled = true): grants are Azure role
#       assignments at the vault scope. Standard Azure RBAC tooling
#       (Conditional Access, PIM, role assignment audit) applies.
#
# RBAC is the production answer in 2025+. CSI Secrets Store Driver (Layer 5)
# also expects RBAC mode in modern configurations.
#
# soft_delete and purge_protection:
#   - soft_delete_retention_days: legally required minimum is 7. We use the
#       default of 7 for the dev sandbox. Prod uses 90.
#   - purge_protection_enabled = false: in dev we WANT to be able to nuke
#       and recreate. In prod this MUST be true (90-day mandatory retention
#       before keys/secrets/certificates can be permanently deleted).
resource "azurerm_key_vault" "this" {
  name                = "kv-${var.workload}-${random_id.kv_suffix.hex}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id

  sku_name                        = "standard"
  rbac_authorization_enabled      = true
  enabled_for_disk_encryption     = false # we don't use this vault for VM disk encryption
  enabled_for_template_deployment = false
  enabled_for_deployment          = false # CRP / classic compute integration, not needed

  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  # Network ACLs: default action 'Allow' means the vault is reachable over
  # the public internet (auth is still required — RBAC isn't bypassed by
  # network access). Lab vs Prod: prod restricts to a known IP range and/or
  # a private endpoint with default action 'Deny'.
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = var.tags
}

# --- Role assignments: admins → Key Vault Administrator ----------------------
# 'Key Vault Administrator' is the data-plane god-mode role: read, write,
# rotate, purge any secret/key/certificate inside the vault. We grant it to
# the operators who need to seed and manage secrets manually.
#
# Workloads (pods via CSI driver) will get a much narrower role in Layer 5:
# 'Key Vault Secrets User' (read-only on secrets) — never Administrator.
#
# Note: var.admin_object_ids may contain the AKS admin GROUP's object ID. RBAC
# resolves group membership at access time, so all current and future
# members of the group get this role automatically. That's the whole point
# of the group-based RBAC model.
resource "azurerm_role_assignment" "admins_kv_admin" {
  for_each = var.admin_object_ids

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = each.value
}

# --- Diagnostic settings → Log Analytics -------------------------------------
# Audit logs capture every secret read/write, every role assignment change,
# every network ACL change. Essential for "who read secret X at time Y"
# questions during incident response or PCI audits.
resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }
  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
