<#
.SYNOPSIS
    Enable Azure Monitor managed Prometheus on the AKS cluster and link it
    to a Monitor Workspace + Managed Grafana (both provisioned by
    ../terraform/).

.DESCRIPTION
    Why a script instead of Terraform: `az aks update --enable-azure-monitor-metrics`
    does FIVE things at once:
      1. Sets the AKS monitor_metrics property on the cluster.
      2. Creates a Data Collection Endpoint (DCE) in the Monitor Workspace's
         resource group.
      3. Creates a Data Collection Rule (DCR) that defines which Prometheus
         metrics get ingested.
      4. Creates a DCR Association that links the AKS cluster to the DCR
         (so the cluster's ama-metrics agent knows where to send metrics).
      5. Installs the `ama-metrics` agent on the cluster — a DaemonSet that
         scrapes Prometheus-format endpoints and forwards to Azure Monitor.

    Doing all five via Terraform requires juggling resource dependencies
    (which RG holds which object, lifecycle of the AMA agent, etc.).
    The az command handles it correctly in a single step.

    Idempotent: re-running is a no-op if already enabled with the same
    Monitor Workspace + Grafana resource IDs.

.PARAMETER ResourceGroup
    AKS resource group. Default: rg-globalretail-dev-weu.

.PARAMETER ClusterName
    AKS cluster name. Default: aks-globalretail-dev-weu.

.PARAMETER TerraformDir
    Where to read the Layer 4b TF outputs from. Default: ../terraform.

.EXAMPLE
    .\enable-aks-managed-prometheus.ps1
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-globalretail-dev-weu',
    [string]$ClusterName   = 'aks-globalretail-dev-weu',
    [string]$TerraformDir  = "$PSScriptRoot/../terraform"
)

$ErrorActionPreference = 'Stop'

Write-Host "===== Layer 4b: enable AKS managed Prometheus =====" -ForegroundColor Cyan

# --- Tool checks ----------------------------------------------------------
$null = Get-Command az -ErrorAction SilentlyContinue
if (-not $?) { Write-Error 'az CLI not found on PATH.'; exit 1 }

# --- Read TF outputs ------------------------------------------------------
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

$workspaceId = $tfOut.monitor_workspace_id.value
$grafanaId   = $tfOut.managed_grafana_id.value

Write-Host "Cluster          : $ClusterName" -ForegroundColor Yellow
Write-Host "RG               : $ResourceGroup"
Write-Host "Monitor Workspace: $workspaceId"
Write-Host "Managed Grafana  : $grafanaId"
Write-Host ""

# --- Verify AKS access ----------------------------------------------------
$null = az aks show --resource-group $ResourceGroup --name $ClusterName --query name -o tsv 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "AKS cluster $ClusterName not found in $ResourceGroup."
    exit 1
}

# --- The big az command --------------------------------------------------
# `--enable-azure-monitor-metrics` is the umbrella feature. The two
# resource-id arguments link the cluster to the Monitor Workspace AND to
# the Managed Grafana data source automatically.
Write-Host "Calling az aks update — this takes 3-5 minutes (it deploys the ama-metrics DaemonSet)..." -ForegroundColor Yellow
az aks update `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --enable-azure-monitor-metrics `
    --azure-monitor-workspace-resource-id $workspaceId `
    --grafana-resource-id $grafanaId `
    --output none
if ($LASTEXITCODE -ne 0) {
    Write-Error "az aks update failed."
    exit 1
}

# --- Done ----------------------------------------------------------------
Write-Host ""
Write-Host "===== Managed Prometheus enabled =====" -ForegroundColor Green
Write-Host ""
Write-Host "Verify ama-metrics pods:" -ForegroundColor Yellow
Write-Host "  kubectl get pods -n kube-system -l rsName=ama-metrics"
Write-Host "  kubectl get pods -n kube-system -l dsName=ama-metrics-node"
Write-Host ""
Write-Host "Open Managed Grafana:" -ForegroundColor Yellow
Write-Host "  $($tfOut.managed_grafana_endpoint.value)"
Write-Host "(login with your Entra ID; you should land in Grafana with the Monitor Workspace as a pre-configured data source)"
