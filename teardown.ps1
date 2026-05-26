<#
.SYNOPSIS
    Tears down every Azure resource created by this reference architecture.

.DESCRIPTION
    Deletes the resource groups created by Layers 1, 2, 4b, and 5 plus the
    bootstrap tfstate resource group. The AKS node resource group and the
    Managed Grafana managed RG are deleted automatically as side effects of
    their parents.

    Optionally also deletes the Entra ID security group that backs Layer 1's
    `azurerm_kubernetes_cluster_role_binding`. Federated credentials and
    role assignments scoped at subscription level go with their owning UAMI
    when the cicd/security resource groups are deleted, so no extra cleanup
    is needed there.

    The deletions run in parallel (`--no-wait`) — the script returns within
    seconds even though Azure may take 10–20 minutes to finish in the
    background. Use `-Wait` to block until everything is actually gone.

    Idempotent. Re-running after a partial deletion is safe; resource
    groups that no longer exist are reported and skipped.

.PARAMETER Workload
    Workload prefix used in resource naming. Default: 'globalretail'.

.PARAMETER Location
    Azure region. Default: 'westeurope'.

.PARAMETER LocationShort
    Short region code used in resource names. Default: 'weu'.

.PARAMETER Environment
    Environment suffix. Default: 'dev'.

.PARAMETER Force
    Skip the interactive confirmation prompt.

.PARAMETER SkipEntraGroup
    Don't delete the Entra ID `aks_admins` group. Useful if other clusters
    share the same group.

.PARAMETER Wait
    Block until every resource group is fully deleted (can take 15–20
    minutes). Default behaviour is fire-and-forget via `--no-wait`.

.EXAMPLE
    .\teardown.ps1
    Lists the target resource groups, prompts for confirmation, then fires
    parallel deletes and returns.

.EXAMPLE
    .\teardown.ps1 -Force -Wait
    No prompt, block until everything is actually gone.

.EXAMPLE
    .\teardown.ps1 -Workload contoso
    Tears down an alternative workload.

.NOTES
    Requires Azure CLI (`az`) logged in with permissions to delete the
    target resource groups. PowerShell 7+.
#>

[CmdletBinding()]
param(
    [string] $Workload      = 'globalretail',
    [string] $Location      = 'westeurope',
    [string] $LocationShort = 'weu',
    [string] $Environment   = 'dev',
    [switch] $Force,
    [switch] $SkipEntraGroup,
    [switch] $Wait
)

$ErrorActionPreference = 'Stop'

# --- 1. Verify az CLI + show identity --------------------------------------
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not signed in to az CLI. Run 'az login' first."
    exit 1
}
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Cyan
Write-Host "Signed in as: $($account.user.name)" -ForegroundColor Cyan
Write-Host ""

# --- 2. Compute the target RG names ----------------------------------------
# Match the names used by the layer Terraform: rg-<scope>-<workload>-<env>-<short>
$targetGroups = @(
    "rg-tfstate-${Workload}-${LocationShort}",                                 # bootstrap (Layer 0)
    "rg-${Workload}-${Environment}-${LocationShort}",                          # Layer 1
    "rg-${Workload}-${Environment}-${LocationShort}-aks-nodes",                # AKS node RG (auto)
    "rg-cicd-${Workload}-${Environment}-${LocationShort}",                     # Layer 2
    "rg-obs-${Workload}-${Environment}-${LocationShort}",                      # Layer 4b
    "rg-security-${Workload}-${Environment}-${LocationShort}"                  # Layer 5
)

# --- 3. Discover which actually exist + their child counts -----------------
Write-Host "Discovering resource groups..." -ForegroundColor Cyan
$existing = @()
foreach ($rg in $targetGroups) {
    $info = az group show --name $rg 2>$null | ConvertFrom-Json
    if ($info) {
        $count = (az resource list --resource-group $rg --query "length(@)" -o tsv 2>$null)
        $existing += [pscustomobject]@{
            Name = $rg
            ResourceCount = $count
        }
    }
}

# Managed Grafana auto-creates a workspace RG with the `MA_` prefix that we
# don't own but is removed when the Grafana resource (in rg-obs-) is gone.
# List it for transparency without trying to delete it directly.
$managedGrafanaRg = az group list --query "[?starts_with(name, 'MA_amw-${Workload}-${Environment}-${LocationShort}')].name" -o tsv 2>$null
if ($managedGrafanaRg) {
    Write-Host "  (informational) Managed Grafana auto-RG present: $managedGrafanaRg" -ForegroundColor DarkGray
    Write-Host "                  goes with rg-obs-${Workload}-${Environment}-${LocationShort} when that one is deleted." -ForegroundColor DarkGray
}

if ($existing.Count -eq 0) {
    Write-Host "Nothing to delete. All target resource groups already gone." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "About to DELETE the following resource groups (and EVERYTHING they contain):" -ForegroundColor Yellow
$existing | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor Yellow

# --- 4. Confirmation -------------------------------------------------------
if (-not $Force) {
    $answer = Read-Host "Type 'destroy' to confirm"
    if ($answer -ne 'destroy') {
        Write-Host "Aborted." -ForegroundColor Red
        exit 1
    }
}

# --- 5. Fire the deletes ---------------------------------------------------
$waitFlag = if ($Wait) { '' } else { '--no-wait' }
Write-Host ""
foreach ($rg in $existing) {
    Write-Host "  deleting $($rg.Name)..." -ForegroundColor Cyan
    az group delete --name $rg.Name --yes $waitFlag 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "    delete returned non-zero exit code for $($rg.Name) — may already be in 'Deleting' state."
    }
}

# --- 6. Entra ID security group cleanup ------------------------------------
# Layer 1's azuread_group.aks_admins is named `aks-admins-<workload>-<env>-<short>`.
# This group is free (no Azure cost) but leaving it orphaned is messy.
if (-not $SkipEntraGroup) {
    $groupName = "aks-admins-${Workload}-${Environment}-${LocationShort}"
    Write-Host ""
    Write-Host "Entra ID group cleanup..." -ForegroundColor Cyan
    $group = az ad group show --group $groupName 2>$null | ConvertFrom-Json
    if ($group) {
        Write-Host "  deleting Entra ID group: $groupName (objectId=$($group.id))" -ForegroundColor Cyan
        az ad group delete --group $groupName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    failed to delete Entra ID group $groupName — check directory permissions."
        }
    }
    else {
        Write-Host "  Entra ID group '$groupName' not found — skipping." -ForegroundColor DarkGray
    }
}
else {
    Write-Host ""
    Write-Host "Entra ID group cleanup skipped (-SkipEntraGroup)." -ForegroundColor DarkGray
}

# --- 7. Summary ------------------------------------------------------------
Write-Host ""
if ($Wait) {
    Write-Host "Done. All resource groups deleted." -ForegroundColor Green
}
else {
    Write-Host "Done. Deletes fired in the background (--no-wait)." -ForegroundColor Green
    Write-Host "Azure will finish deprovisioning in ~10–20 minutes." -ForegroundColor Green
    Write-Host "Poll status with: az group list --query ""[?contains(name,'$Workload')].{name:name, state:properties.provisioningState}"" -o table" -ForegroundColor DarkGray
}
