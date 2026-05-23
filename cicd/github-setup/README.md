# github-setup

Three PowerShell scripts that wire the Azure side (Terraform) to the GitHub side (gh CLI). Run **after** Terraform has applied and **after** the GitHub repo exists.

| Script | Purpose | Idempotent |
|---|---|---|
| `setup-environment.ps1`       | Creates the `platform-prod` Environment and configures required reviewers. Must run before `set-github-vars` (the env-scoped var needs the env to exist). | Yes |
| `set-github-vars.ps1`         | Pushes 9 repo-scoped vars + 1 env-scoped var. Reads Terraform outputs and `infra/backend.hcl`. | Yes |
| `apply-branch-protection.ps1` | Locks `main`: PR required, conversation resolution, no force push, enforced-for-admins. Optional `-RequireChecks`. | Yes |

## Why these are scripts, not Terraform

Two reasons:
- The Terraform `github` provider requires a Personal Access Token. Layer 2's whole point is "no PATs anywhere." `gh` CLI uses interactive GitHub login, no PAT required.
- These calls are one-shot bootstrapping, not steady-state state to drift against. Re-running Terraform daily for branch protection adds no value.

## Order of operations

```
1. ../terraform apply              # creates UAMIs, fed creds, RBAC
2. setup-environment.ps1           # creates the platform-prod GitHub Environment
3. set-github-vars.ps1             # reads tf outputs → gh variable set (repo + env)
4. (push initial commit to main)
5. apply-branch-protection.ps1     # protection rules — branch must exist first
```

## Prereqs

```bash
gh --version           # 2.40+
gh auth status         # must be 'Logged in to github.com'
```

If you don't have `gh`, install it from https://cli.github.com/.

## What gets set

### Repo-scope variables (visible to every workflow)
| Variable | Source | Used by |
|---|---|---|
| `AZURE_TENANT_ID`            | tfvars | all workflows |
| `AZURE_SUBSCRIPTION_ID`      | tfvars | all workflows |
| `AZURE_CLIENT_ID_APP`        | TF output `app_identity_client_id` | app-ci.yml |
| `AZURE_CLIENT_ID_INFRA_PLAN` | TF output `platform_ro_identity_client_id` | infra-plan.yml |
| `ACR_LOGIN_SERVER`           | TF output (from Layer 1 remote state) | app-ci.yml |
| `ACR_NAME`                   | TF output | app-ci.yml |
| `TFSTATE_RG`                 | infra/backend.hcl | infra-plan.yml, infra-apply.yml |
| `TFSTATE_STORAGE_ACCOUNT`    | infra/backend.hcl | infra-plan.yml, infra-apply.yml |
| `OWNER_TAG`                  | -OwnerTag param (default `platform-team`) | infra-plan.yml, infra-apply.yml |

### Environment-scope variable on `platform-prod`
| Variable | Source | Used by |
|---|---|---|
| `AZURE_CLIENT_ID_INFRA_APPLY` | TF output `platform_rw_identity_client_id` | infra-apply.yml |

This one is env-scoped because the high-privilege Platform-RW UAMI should only be reachable when a human has approved the run.

## Cleanup

No destructive counterpart. To unwind:

```bash
# Remove repo vars (one per var)
gh variable delete AZURE_CLIENT_ID_APP --repo OWNER/REPO

# Remove env-scoped vars
gh variable delete AZURE_CLIENT_ID_INFRA_APPLY --repo OWNER/REPO --env platform-prod

# Remove the environment entirely
gh api --method DELETE /repos/OWNER/REPO/environments/platform-prod

# Remove branch protection
gh api --method DELETE /repos/OWNER/REPO/branches/main/protection
```
