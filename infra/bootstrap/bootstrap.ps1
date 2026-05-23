<#
.SYNOPSIS
    Bootstraps the Azure Storage Account that holds Terraform remote state for Layer 1.

.DESCRIPTION
    This script solves the chicken-and-egg problem: Terraform needs a place to store its
    state, but you can't put the state of "the storage account that holds Terraform state"
    inside the storage account itself. So this account is provisioned ONCE, manually, via
    az CLI — and Terraform never touches it after that.

    What it creates:
      1. A resource group dedicated to tfstate (separate from the platform RG, so that
         `terraform destroy` on the platform never tries to delete its own backend).
      2. A storage account with hardened settings (TLS 1.2, no shared key, versioning,
         soft delete) — Entra ID auth only.
      3. A blob container 'tfstate'.
      4. A role assignment granting the current signed-in user 'Storage Blob Data Owner'
         on the storage account (required because we disabled shared key access).
      5. A 'backend.hcl' file in this folder that Terraform consumes via
         `terraform init -backend-config=backend.hcl`.

    Idempotency: if the resource group / storage account / container / role assignment
    already exist, they are not recreated. Safe to run multiple times.

.PARAMETER Workload
    Workload prefix used in resource naming. Default: 'globalretail'.

.PARAMETER Location
    Azure region. Default: 'westeurope'.

.PARAMETER LocationShort
    Short region code used in resource names. Default: 'weu'.

.EXAMPLE
    .\bootstrap.ps1
    Runs with all defaults.

.EXAMPLE
    .\bootstrap.ps1 -Workload contoso -Location northeurope -LocationShort neu
    Overrides defaults.
#>

[CmdletBinding()]
param(
    [string]$Workload = 'globalretail',
    [string]$Location = 'westeurope',
    [string]$LocationShort = 'weu'
)

$ErrorActionPreference = 'Stop'

# --- Derived names -------------------------------------------------------------
# RG dedicated to tfstate. Keeping it OUT of the platform RG means a `terraform destroy`
# of the platform never tries to delete its own state backend.
$tfstateRg = "rg-tfstate-$Workload-$LocationShort"
$saPrefix  = "stgrtfstate"   # 11 chars; SA names are 3-24 lowercase alphanumeric, globally unique
$container = 'tfstate'

Write-Host "===== Layer 1 Bootstrap =====" -ForegroundColor Cyan
Write-Host "Workload      : $Workload"
Write-Host "Location      : $Location"
Write-Host "Resource group: $tfstateRg"
Write-Host ""

# --- Verify az CLI session -----------------------------------------------------
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not logged into az CLI. Run 'az login' first."
    exit 1
}
$subscriptionId = $account.id
$tenantId       = $account.tenantId
Write-Host "Subscription  : $($account.name) ($subscriptionId)"
Write-Host "Tenant        : $tenantId"
Write-Host "Signed-in as  : $($account.user.name)"
Write-Host ""

$userObjectId = az ad signed-in-user show --query id -o tsv
if (-not $userObjectId) {
    Write-Error "Could not resolve the signed-in user's object ID."
    exit 1
}

# --- 1. Resource group ---------------------------------------------------------
Write-Host "[1/5] Resource group" -ForegroundColor Yellow
$rgExists = az group exists --name $tfstateRg
if ($rgExists -eq 'true') {
    Write-Host "  -> Already exists. Skipping."
} else {
    az group create `
        --name $tfstateRg `
        --location $Location `
        --tags "purpose=terraform-state" "managed-by=bootstrap-script" "workload=$Workload" `
        --output none
    Write-Host "  -> Created."
}

# --- 2. Storage account --------------------------------------------------------
# Idempotency strategy: if any SA in this RG matches "$saPrefix*", reuse it. Otherwise
# create a new one with a random suffix (SA names are globally unique).
Write-Host ""
Write-Host "[2/5] Storage account" -ForegroundColor Yellow
$existingSa = az storage account list --resource-group $tfstateRg --query "[?starts_with(name, '$saPrefix')].name | [0]" -o tsv
if ($existingSa) {
    $saName = $existingSa
    Write-Host "  -> Reusing existing: $saName"
} else {
    # 8-char random suffix keeps total name length at 19 (well under the 24-char limit)
    $suffix = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $saName = "$saPrefix$suffix"
    Write-Host "  -> Creating: $saName"

    # Security hardening rationale:
    #   --min-tls-version TLS1_2         : industry baseline; reject SSL/TLS 1.0/1.1 clients
    #   --allow-blob-public-access false : tfstate is sensitive, no anonymous reads ever
    #   --allow-shared-key-access false  : forces Entra ID auth — no static keys to leak
    #   --kind StorageV2                 : required for the modern feature set
    #   --sku Standard_LRS               : LRS is fine for dev; prod would use ZRS or GRS
    #   --https-only true                : redundant with TLS 1.2 setting but explicit
    az storage account create `
        --name $saName `
        --resource-group $tfstateRg `
        --location $Location `
        --kind StorageV2 `
        --sku Standard_LRS `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access false `
        --allow-shared-key-access false `
        --https-only true `
        --tags "purpose=terraform-state" "managed-by=bootstrap-script" "workload=$Workload" `
        --output none

    # Blob versioning + soft delete = "we can recover the state file if something nukes it".
    # Set in a separate call because they live on the blob-service properties, not the SA itself.
    az storage account blob-service-properties update `
        --account-name $saName `
        --resource-group $tfstateRg `
        --enable-versioning true `
        --enable-delete-retention true `
        --delete-retention-days 30 `
        --enable-container-delete-retention true `
        --container-delete-retention-days 30 `
        --output none

    Write-Host "  -> Created and hardened."
}

# --- 3. Role assignment: signed-in user as Storage Blob Data Owner -------------
# Because we disabled shared key access, the Terraform AzureRM backend cannot use the
# legacy account-key auth path. It must authenticate via Entra ID — which means the
# principal running terraform needs an RBAC role on the data plane of this SA.
# 'Storage Blob Data Owner' is the minimum that allows read+write+delete of blobs.
Write-Host ""
Write-Host "[3/5] RBAC: granting yourself 'Storage Blob Data Owner' on the storage account" -ForegroundColor Yellow
$saId = az storage account show --name $saName --resource-group $tfstateRg --query id -o tsv
$existingAssignment = az role assignment list `
    --assignee $userObjectId `
    --role "Storage Blob Data Owner" `
    --scope $saId `
    --query "[0].id" -o tsv
if ($existingAssignment) {
    Write-Host "  -> Already assigned. Skipping."
} else {
    az role assignment create `
        --assignee-object-id $userObjectId `
        --assignee-principal-type User `
        --role "Storage Blob Data Owner" `
        --scope $saId `
        --output none
    Write-Host "  -> Assigned. (RBAC propagation can take 30-60 seconds.)"
}

# --- 4. Container --------------------------------------------------------------
Write-Host ""
Write-Host "[4/5] Container '$container'" -ForegroundColor Yellow
# Use --auth-mode login (Entra ID) since shared key is disabled.
# RBAC propagation can be slow — retry up to 6 times with 10s spacing.
$created = $false
for ($i = 1; $i -le 6; $i++) {
    $exists = az storage container exists `
        --account-name $saName `
        --name $container `
        --auth-mode login `
        --query exists -o tsv 2>$null
    if ($exists -eq 'true') {
        Write-Host "  -> Already exists. Skipping."
        $created = $true
        break
    }
    try {
        az storage container create `
            --account-name $saName `
            --name $container `
            --auth-mode login `
            --public-access off `
            --output none 2>$null
        Write-Host "  -> Created."
        $created = $true
        break
    } catch {
        Write-Host "  -> Attempt $i/6 failed (likely RBAC propagation). Retrying in 10s..."
        Start-Sleep -Seconds 10
    }
}
if (-not $created) {
    Write-Error "Could not create container after 6 retries. Check role assignment propagation and try again."
    exit 1
}

# --- 5. Emit backend.hcl -------------------------------------------------------
Write-Host ""
Write-Host "[5/5] Writing backend.hcl" -ForegroundColor Yellow
# State key includes layer + environment so multiple layers / envs can share the SA
# without colliding. Layer 2, 3, etc. will use their own keys.
$backendHclPath = Join-Path $PSScriptRoot '..\backend.hcl'
$backendContent = @"
# Generated by bootstrap.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# Consumed by: terraform init -backend-config=backend.hcl
#
# use_azuread_auth = true is REQUIRED because the storage account has
# shared-key access disabled. Terraform will authenticate to the backend
# using your az CLI session (the same identity that ran bootstrap.ps1).

resource_group_name  = "$tfstateRg"
storage_account_name = "$saName"
container_name       = "$container"
key                  = "infra/dev/terraform.tfstate"
use_azuread_auth     = true
subscription_id      = "$subscriptionId"
tenant_id            = "$tenantId"
"@
Set-Content -Path $backendHclPath -Value $backendContent -Encoding UTF8
Write-Host "  -> Wrote $((Resolve-Path $backendHclPath).Path)"

# --- Done ----------------------------------------------------------------------
Write-Host ""
Write-Host "===== Bootstrap complete =====" -ForegroundColor Green
Write-Host ""
Write-Host "Next step:"
Write-Host "  cd .."
Write-Host "  terraform init -backend-config=backend.hcl"
Write-Host ""
Write-Host "To tear down the bootstrap (after running 'terraform destroy' on the platform):"
Write-Host "  az group delete --name $tfstateRg --yes"
