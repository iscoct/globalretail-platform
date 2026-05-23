# Locals: naming convention + common tags.
#
# Why a single name_suffix local: any change to the naming convention (say we
# rename the workload from 'globalretail' to something else) ripples through
# one place instead of every resource block.

locals {
  # Convention: <resource-type>-<workload>-<env>-<region>
  # Resource type prefix is added per-resource (e.g., "rg-", "log-", "aks-").
  name_suffix = "${var.workload}-${var.environment}-${var.location_short}"

  # Tags applied to every resource that supports tagging.
  # 'managed-by=terraform' is the standard marker that lets a human looking
  # at a resource in the portal know not to edit it by hand.
  common_tags = {
    environment  = var.environment
    project      = "globalretail-platform"
    workload     = var.workload
    "managed-by" = "terraform"
    owner        = var.owner
  }
}