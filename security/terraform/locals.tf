locals {
  name_suffix = "${var.workload}-${var.environment}-${var.location_short}"

  common_tags = {
    environment  = var.environment
    project      = "globalretail-platform"
    workload     = var.workload
    layer        = "security"
    "managed-by" = "terraform"
    owner        = var.owner
  }

  # The Workload Identity federation subject for the sample-app pods.
  #
  # Format documented at https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation:
  #   system:serviceaccount:<namespace>:<service-account>
  #
  # AKS publishes its OIDC issuer URL (we read it from Layer 1's remote state
  # below). Pods using the labelled ServiceAccount get a projected SA token
  # whose 'sub' claim matches this exact string — the federated credential
  # we create then exchanges that token for an Entra ID access token scoped
  # to the workload UAMI.
  workload_subject = "system:serviceaccount:${var.sample_app_namespace}:${var.sample_app_service_account}"

  workload_audience = ["api://AzureADTokenExchange"]
}
