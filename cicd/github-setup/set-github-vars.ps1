<#
.SYNOPSIS
    Writes the GitHub Actions variables that the three workflows need.

.DESCRIPTION
    After `terraform apply` in ../terraform succeeds, this script reads the
    outputs and uses `gh variable set` to push them into the GitHub repo's
    Actions variables namespace (repo-scope), plus one Environment-scoped
    variable on `platform-prod` for the high-privilege identity.

    Vars at REPO scope (visible to every workflow):
      AZURE_TENANT_ID
      AZURE_SUBSCRIPTION_ID
      AZURE_CLIENT_ID_APP          — App UAMI    (used by app-ci.yml)
      AZURE_CLIENT_ID_INFRA_PLAN   — Platform-RO (used by infra-plan.yml)
      ACR_LOGIN_SERVER
      ACR_NAME
      TFSTATE_RG
      TFSTATE_STORAGE_ACCOUNT
      OWNER_TAG

    Vars at ENVIRONMENT scope on `platform-prod`:
      AZURE_CLIENT_ID_INFRA_APPLY  — Platform-RW (used by infra-apply.yml)
      The reason this one is env-scoped is the same reason `terraform apply`
      itself is env-scoped: GitHub will not even let a workflow READ this var
      until the environment's required reviewer has approved the run.

    NONE of these are secrets. They are public identifiers (client IDs,
    hostnames, RG names). The OIDC federation flow doesn't need any
    client_secret — that is the whole point of federated identity. Putting
    them as `vars` makes them visible in workflow logs (helpful for
    debugging) and conveys the no-secret story clearly.

    Idempotent: re-running overrides values without erroring.

.PARAMETER GithubOwner
    GitHub username / org. Read from terraform output by default.

.PARAMETER GithubRepo
    GitHub repo name. Read from terraform output by default.

.EXAMPLE
    .\set-github-vars.ps1
    Read everything from ../terraform outputs and apply.
#>

[CmdletBinding()]
param(
    [string]$GithubOwner,
    [string]$GithubRepo,
    [string]$TerraformDir = "$PSScriptRoot/../terraform",
    [string]$OwnerTag = "platform-team"
)

$ErrorActionPreference = 'Stop'

Write-Host "===== Layer 2: set GitHub Actions variables =====" -ForegroundColor Cyan

# --- Verify gh CLI is installed + authenticated ------------------------------
$null = gh --version 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "gh CLI not found. Install from https://cli.github.com/."; exit 1 }
$null = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "gh CLI not authenticated. Run 'gh auth login'."; exit 1 }
Write-Host "gh CLI: authenticated"

# --- Read terraform outputs --------------------------------------------------
Push-Location $TerraformDir
try {
    $tfOut = terraform output -json | ConvertFrom-Json
} finally {
    Pop-Location
}

if (-not $tfOut) {
    Write-Error "Could not read terraform outputs. Has 'terraform apply' been run in $TerraformDir ?"
    exit 1
}

if (-not $GithubOwner -or -not $GithubRepo) {
    $parts = $tfOut.github_repo_full_name.value -split '/'
    if (-not $GithubOwner) { $GithubOwner = $parts[0] }
    if (-not $GithubRepo)  { $GithubRepo  = $parts[1] }
}

$target  = "$GithubOwner/$GithubRepo"
$envName = $tfOut.github_environment_name.value

Write-Host "Target repo   : $target"
Write-Host "Environment   : $envName  (for AZURE_CLIENT_ID_INFRA_APPLY)"
Write-Host ""

# --- Sanity-check the repo exists --------------------------------------------
$null = gh repo view $target 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Repo $target not found or not accessible to this gh session. Create it first (gh repo create $target --public)."
    exit 1
}

# --- Read tfstate SA name from infra/backend.hcl (the bootstrap output) ------
$infraBackend = Join-Path $PSScriptRoot "..\..\infra\backend.hcl"
if (-not (Test-Path $infraBackend)) {
    Write-Error "infra/backend.hcl not found at $infraBackend. Run the Layer 1 bootstrap (../../infra/bootstrap/bootstrap.ps1) first."
    exit 1
}
$tfstateSaName = (Select-String -Path $infraBackend -Pattern '^storage_account_name\s*=\s*"(.+)"').Matches.Groups[1].Value
$tfstateRgName = (Select-String -Path $infraBackend -Pattern '^resource_group_name\s*=\s*"(.+)"').Matches.Groups[1].Value
Write-Host "tfstate SA    : $tfstateSaName (in $tfstateRgName)"
Write-Host ""

# --- Repo-scope vars ---------------------------------------------------------
$repoVars = [ordered]@{
    AZURE_TENANT_ID            = $tfOut.tenant_id.value
    AZURE_SUBSCRIPTION_ID      = $tfOut.subscription_id.value
    AZURE_CLIENT_ID_APP        = $tfOut.app_identity_client_id.value
    AZURE_CLIENT_ID_INFRA_PLAN = $tfOut.platform_ro_identity_client_id.value
    ACR_LOGIN_SERVER           = $tfOut.acr_login_server.value
    ACR_NAME                   = $tfOut.acr_name.value
    TFSTATE_RG                 = $tfstateRgName
    TFSTATE_STORAGE_ACCOUNT    = $tfstateSaName
    OWNER_TAG                  = $OwnerTag
}

Write-Host "Setting repo-scope variables..." -ForegroundColor Yellow
foreach ($k in $repoVars.Keys) {
    $v = $repoVars[$k]
    Write-Host ("  {0,-30} = {1}" -f $k, $v)
    gh variable set $k --repo $target --body $v | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to set $k. Aborting."; exit 1 }
}

# --- Environment-scope var (high-privilege UAMI for infra-apply) -------------
# We rely on setup-environment.ps1 to have already created the environment.
# If it has not, the next call will create the env implicitly (no protection
# rules) and the apply workflow will then be UNGATED. Run setup-environment
# first.
Write-Host ""
Write-Host "Setting environment-scope variable on '$envName'..." -ForegroundColor Yellow
$envVar = @{
    AZURE_CLIENT_ID_INFRA_APPLY = $tfOut.platform_rw_identity_client_id.value
}
foreach ($k in $envVar.Keys) {
    $v = $envVar[$k]
    Write-Host ("  {0,-30} = {1}" -f $k, $v)
    gh variable set $k --repo $target --env $envName --body $v | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to set $k on environment $envName. Did you run setup-environment.ps1 first?"
        exit 1
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "Next:"
Write-Host "  - Push the initial commit to main, watch app-ci.yml run"
Write-Host "  - Open a PR that touches infra/ to see infra-plan.yml comment the plan"
Write-Host "  - Merge such a PR to see infra-apply.yml wait on environment approval"
