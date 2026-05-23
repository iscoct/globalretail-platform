locals {
  name_suffix = "${var.workload}-${var.environment}-${var.location_short}"

  common_tags = {
    environment  = var.environment
    project      = "globalretail-platform"
    workload     = var.workload
    layer        = "cicd"
    "managed-by" = "terraform"
    owner        = var.owner
  }

  # GitHub OIDC issuer + subjects.
  #
  # The "subject" of a GitHub-issued OIDC token follows a strict shape that
  # we match in the federated credential. Mismatched subject = silent
  # 'AADSTS70021: No matching federated identity record found' at runtime.
  #
  # We use FOUR subjects in this layer, one per (workflow, event) combination:
  #
  # - App / push to main : repo:OWNER/REPO:ref:refs/heads/<branch>
  #     Used by app-ci.yml on push to main → push image to ACR.
  #
  # - App / pull_request : repo:OWNER/REPO:pull_request
  #     Used by app-ci.yml on PR → build+scan (push step gated in workflow).
  #
  # - Platform-RO / pull_request : repo:OWNER/REPO:pull_request
  #     Used by infra-plan.yml on PR → terraform plan (read-only).
  #     Same subject as the app-pr cred above but on a DIFFERENT UAMI, so the
  #     blast radius of a malicious PR is bounded by what each UAMI can do.
  #
  # - Platform-RW / environment : repo:OWNER/REPO:environment:<env-name>
  #     Used by infra-apply.yml on push to main → terraform apply.
  #     GitHub gates this token issuance behind the environment's protection
  #     rules (required reviewers). No reviewer approval → no token issued.
  github_oidc_issuer  = "https://token.actions.githubusercontent.com"
  github_subject_main = "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_main_branch}"
  github_subject_pr   = "repo:${var.github_owner}/${var.github_repo}:pull_request"
  github_subject_env  = "repo:${var.github_owner}/${var.github_repo}:environment:${var.github_environment_name}"
  github_audience     = ["api://AzureADTokenExchange"]
}
