<#
.SYNOPSIS
    Creates the GitHub Environment that gates `infra-apply.yml`, and configures
    its required-reviewers protection rule.

.DESCRIPTION
    The high-privilege Platform-RW UAMI's federated credential matches the
    subject `repo:OWNER/REPO:environment:<env-name>`. GitHub only includes
    this subject in the OIDC token when:
      (a) the job declares `environment: <env-name>` and
      (b) all of the environment's protection rules have been satisfied.

    The most important protection rule for our setup is REQUIRED REVIEWERS.
    Until a configured reviewer presses "Approve and deploy" in the run's
    UI, the job stays in a "Waiting" state and no OIDC token is issued —
    so even a compromised collaborator account cannot run `terraform apply`
    without a human acknowledging in GitHub first.

    This script is idempotent. Re-running updates the protection config.

.PARAMETER GithubOwner
    Default: from terraform output.

.PARAMETER GithubRepo
    Default: from terraform output.

.PARAMETER EnvironmentName
    Default: 'platform-prod' (matches the Terraform default).

.PARAMETER ReviewerLogin
    GitHub login of the user who must approve infra-apply runs.
    Default: the repo owner (who is usually the right person for a solo lab).

.PARAMETER WaitTimerMinutes
    Optional wait timer after approval before the apply starts. Default 0.
    Useful in production to give "you sure you want to do this?" pause time.
#>

[CmdletBinding()]
param(
    [string]$GithubOwner,
    [string]$GithubRepo,
    [string]$EnvironmentName,
    [string]$ReviewerLogin,
    [int]   $WaitTimerMinutes = 0,
    [string]$TerraformDir = "$PSScriptRoot/../terraform"
)

$ErrorActionPreference = 'Stop'

Write-Host "===== Layer 2: configure GitHub Environment =====" -ForegroundColor Cyan

# --- gh CLI checks -----------------------------------------------------------
$null = gh --version 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "gh CLI not found."; exit 1 }
$null = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "gh CLI not authenticated."; exit 1 }

# --- Read terraform outputs for defaults -------------------------------------
if (-not $GithubOwner -or -not $GithubRepo -or -not $EnvironmentName) {
    Push-Location $TerraformDir
    try { $tfOut = terraform output -json | ConvertFrom-Json } finally { Pop-Location }
    $parts = $tfOut.github_repo_full_name.value -split '/'
    if (-not $GithubOwner)     { $GithubOwner     = $parts[0] }
    if (-not $GithubRepo)      { $GithubRepo      = $parts[1] }
    if (-not $EnvironmentName) { $EnvironmentName = $tfOut.github_environment_name.value }
}
$target = "$GithubOwner/$GithubRepo"

if (-not $ReviewerLogin) {
    $ReviewerLogin = $GithubOwner   # default: the repo owner approves themselves
}

# --- Resolve reviewer's user ID (the API needs the numeric id, not the login)
$reviewerId = (gh api "/users/$ReviewerLogin" --jq '.id' 2>$null)
if (-not $reviewerId) {
    Write-Error "Could not resolve GitHub user '$ReviewerLogin'. Check the login is correct."
    exit 1
}
Write-Host "Target repo     : $target"
Write-Host "Environment     : $EnvironmentName"
Write-Host "Required reviewer: $ReviewerLogin (id=$reviewerId)"
Write-Host "Wait timer      : $WaitTimerMinutes min"
Write-Host ""

# --- Create / update the environment + its protection rules ------------------
# The /environments/<name> PUT endpoint creates or updates in one call.
$envBody = @{
    wait_timer = $WaitTimerMinutes
    reviewers  = @(
        @{ type = "User"; id = [int]$reviewerId }
    )
    deployment_branch_policy = $null   # any branch — we already gate via paths in the workflow
} | ConvertTo-Json -Depth 10

$tmp = New-TemporaryFile
$envBody | Out-File -FilePath $tmp -Encoding utf8

try {
    gh api `
        --method PUT `
        -H "Accept: application/vnd.github+json" `
        "/repos/$target/environments/$EnvironmentName" `
        --input $tmp.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to configure environment."; exit 1 }
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host "Environment configured." -ForegroundColor Green
Write-Host ""
Write-Host "What this does:"
Write-Host "  - infra-apply.yml jobs target environment '$EnvironmentName'."
Write-Host "  - GitHub holds the run in 'Waiting' until $ReviewerLogin clicks Approve."
Write-Host "  - Only then does the OIDC token for the Platform-RW UAMI get issued."
Write-Host ""
Write-Host "Verify in the UI: https://github.com/$target/settings/environments/$EnvironmentName"
