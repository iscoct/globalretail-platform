locals {
  name_suffix = "${var.workload}-${var.environment}-${var.location_short}"

  common_tags = {
    environment  = var.environment
    project      = "globalretail-platform"
    workload     = var.workload
    layer        = "observability-azure-managed"
    "managed-by" = "terraform"
    owner        = var.owner
  }

  # Managed Grafana name MUST be 2-23 chars, alphanumeric + hyphens, globally
  # unique. With workload=globalretail + env=dev that's already 20 chars; we
  # drop the region from the name (it's a global resource).
  managed_grafana_name   = "amg-${var.workload}-${var.environment}"
  monitor_workspace_name = "amw-${local.name_suffix}"
}
