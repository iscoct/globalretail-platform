<#
.SYNOPSIS
    Applies branch protection rules to main.

.DESCRIPTION
    Branch protection enforces the CI/CD policy on the GitHub side:
    direct pushes to main are blocked, all changes must come through a PR,
    and (when -RequireChecks is set) the CI jobs must pass before merge.

    Default rules (applied always):
      1. Require a pull request before merging (no direct pushes).
      2. Require N approving reviews (-RequiredApprovals, default 0 for solo).
      3. Dismiss stale reviews on new commits.
      4. Require all conversations resolved before merging.
      5. Enforce for admins too (no 'I'll bypass just this once' button).
      6. No force pushes, no branch deletions.

    With -RequireChecks (off by default):
      7. Require the four app-ci.yml checks to pass.
         CAVEAT: app-ci.yml uses `paths:` filter, so a PR that doesn't touch
         apps/sample-app will not trigger it, and the required checks will
         be MISSING — blocking the merge. For a polyglot monorepo where
         infra/ and docs/ PRs are common, leave this OFF and accept that
         the checks are advisory; for an app-only repo, turn it ON.

         Production fix (not implemented here): a workflow-level "ci-summary"
         job that always runs and conditionally succeeds or fails based on
         path filters. That single check is what gets required.

    Idempotent.

.PARAMETER GithubOwner
    Default: from terraform output.

.PARAMETER GithubRepo
    Default: from terraform output.

.PARAMETER RequiredApprovals
    PR approvals required. Default 0 (solo lab). Production: ≥ 1.

.PARAMETER RequireChecks
    Add the four app-ci.yml checks to the required-checks list. Default off.

.EXAMPLE
    .\apply-branch-protection.ps1
    Minimal protection: PR required, conversation resolution, no force push.

.EXAMPLE
    .\apply-branch-protection.ps1 -RequireChecks -RequiredApprovals 1
    Strict mode for production.
#>

[CmdletBinding()]
param(
    [string]$GithubOwner,
    [string]$GithubRepo,
    [string]$TerraformDir = "$PSScriptRoot/../terraform",
    [int]   $RequiredApprovals = 0,
    [switch]$RequireChecks,
    [string]$Branch = "main"
)

$ErrorActionPreference = 'Stop'

Write-Host "===== Layer 2: apply branch protection =====" -ForegroundColor Cyan

# --- gh CLI checks -----------------------------------------------------------
$null = gh --version 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "gh CLI not found."; exit 1 }
$null = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "gh CLI not authenticated."; exit 1 }

# --- Read terraform outputs --------------------------------------------------
if (-not $GithubOwner -or -not $GithubRepo) {
    Push-Location $TerraformDir
    try { $tfOut = terraform output -json | ConvertFrom-Json } finally { Pop-Location }
    $parts = $tfOut.github_repo_full_name.value -split '/'
    if (-not $GithubOwner) { $GithubOwner = $parts[0] }
    if (-not $GithubRepo)  { $GithubRepo  = $parts[1] }
}

$target = "$GithubOwner/$GithubRepo"
Write-Host "Target repo  : $target"
Write-Host "Branch       : $Branch"
Write-Host "Approvals    : $RequiredApprovals"
Write-Host "RequireChecks: $RequireChecks"
Write-Host ""

# --- Build the protection payload --------------------------------------------
$requiredStatusChecks = $null
if ($RequireChecks) {
    $requiredStatusChecks = @{
        strict   = $true
        contexts = @(
            'Unit tests',
            'SAST (CodeQL)',
            'SCA (npm audit)',
            'Build, scan, push'
        )
    }
}

$payload = @{
    required_status_checks           = $requiredStatusChecks
    enforce_admins                   = $true
    required_pull_request_reviews    = @{
        required_approving_review_count = $RequiredApprovals
        dismiss_stale_reviews           = $true
        require_code_owner_reviews      = $false
    }
    required_conversation_resolution = $true
    restrictions                     = $null
    allow_force_pushes               = $false
    allow_deletions                  = $false
} | ConvertTo-Json -Depth 10

$tmp = New-TemporaryFile
$payload | Out-File -FilePath $tmp -Encoding utf8

try {
    gh api `
        --method PUT `
        -H "Accept: application/vnd.github+json" `
        "/repos/$target/branches/$Branch/protection" `
        --input $tmp.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to apply branch protection. Does '$Branch' exist (first commit pushed)?"
        exit 1
    }
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host "Branch protection applied to $target@$Branch." -ForegroundColor Green
Write-Host "Verify: https://github.com/$target/settings/branches" -ForegroundColor Yellow
