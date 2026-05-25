<#
.SYNOPSIS
    One-time install of ArgoCD on the AKS cluster, then apply the root
    app-of-apps Application so ArgoCD starts managing itself.

.DESCRIPTION
    Why a script and not Terraform: ArgoCD is a Kubernetes-native tool. The
    canonical install path is `helm install` against the cluster, not
    `azurerm_*` resources. Terraform's Helm provider exists but adds an
    indirection that buys nothing for a one-shot bootstrap.

    Why a script and not just instructions: idempotency. Re-running this on
    a cluster where ArgoCD already exists upgrades the release; on a clean
    cluster it installs fresh. Same command both ways.

    What it does:
      1. Acquire AKS kubeconfig via `az aks get-credentials`.
      2. Convert kubeconfig via `kubelogin` so kubectl can mint Entra ID
         tokens non-interactively from your `az login` session.
      3. Add the argo Helm repo, update it.
      4. `helm upgrade --install argocd argo/argo-cd` with our values.
      5. Wait for the ArgoCD server pod to be Ready.
      6. Apply the root-app Application (the app-of-apps seed).
      7. Print the bootstrap admin password + how to access the UI.

    Pre-requisites:
      - Layer 1 applied (AKS cluster + your user in the `aks-admins` Entra
        group).
      - az, helm, kubectl, kubelogin installed locally.

.PARAMETER ResourceGroup
    AKS resource group. Default: rg-globalretail-dev-weu.

.PARAMETER ClusterName
    AKS cluster name. Default: aks-globalretail-dev-weu.

.PARAMETER Namespace
    Namespace to install ArgoCD into. Default: argocd.

.PARAMETER ChartVersion
    Pin to a specific argo-cd chart version. Default: '' (use latest stable).
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-globalretail-dev-weu',
    [string]$ClusterName   = 'aks-globalretail-dev-weu',
    [string]$Namespace     = 'argocd',
    [string]$ChartVersion  = ''
)

$ErrorActionPreference = 'Stop'

Write-Host "===== Layer 3: install ArgoCD =====" -ForegroundColor Cyan
Write-Host "Cluster   : $ClusterName"
Write-Host "RG        : $ResourceGroup"
Write-Host "Namespace : $Namespace"
Write-Host ""

# --- 1. Tools present? -------------------------------------------------------
# `az aks install-cli` installs kubectl + kubelogin into per-user directories
# that it does NOT add to PATH. Prepend them ourselves if they exist there.
$kubeloginDir = Join-Path $env:USERPROFILE '.azure-kubelogin'
$kubectlDir   = Join-Path $env:USERPROFILE '.azure-kubectl'
if ((Test-Path (Join-Path $kubeloginDir 'kubelogin.exe')) -and $env:PATH -notlike "*$kubeloginDir*") {
    $env:PATH = "$kubeloginDir;$env:PATH"
}
if ((Test-Path (Join-Path $kubectlDir 'kubectl.exe')) -and $env:PATH -notlike "*$kubectlDir*") {
    $env:PATH = "$kubectlDir;$env:PATH"
}

foreach ($cmd in @('az', 'helm', 'kubectl', 'kubelogin')) {
    $null = Get-Command $cmd -ErrorAction SilentlyContinue
    if (-not $?) {
        Write-Error "$cmd not found in PATH. Install it and re-run. For kubectl + kubelogin: 'az aks install-cli'."
        exit 1
    }
}

# --- 2. AKS credentials ------------------------------------------------------
Write-Host "[1/6] Fetching AKS credentials" -ForegroundColor Yellow
az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --overwrite-existing | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "az aks get-credentials failed. Check you have access to $ClusterName."
    exit 1
}

# Layer 1's cluster uses Entra ID + Azure RBAC for K8s + local accounts
# disabled. kubelogin converts the kubeconfig so kubectl mints Entra tokens
# non-interactively from the `az login` session.
Write-Host "[2/6] Converting kubeconfig (kubelogin -l azurecli)" -ForegroundColor Yellow
kubelogin convert-kubeconfig -l azurecli | Out-Null

# Sanity: a no-op kubectl call to surface auth issues now, not later.
kubectl get nodes -o name | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "kubectl get nodes failed. Are you in the aks-admins Entra group?"
    exit 1
}

# --- 3. Helm repo ------------------------------------------------------------
Write-Host "[3/6] Adding the argo Helm repo" -ForegroundColor Yellow
helm repo add argo https://argoproj.github.io/argo-helm --force-update | Out-Null
helm repo update argo | Out-Null

# --- 4. Install / upgrade ArgoCD --------------------------------------------
Write-Host "[4/6] helm upgrade --install argocd argo/argo-cd" -ForegroundColor Yellow
$valuesFile = Join-Path $PSScriptRoot 'values-argocd.yaml'
$helmArgs = @(
    'upgrade', '--install', 'argocd', 'argo/argo-cd',
    '--namespace', $Namespace,
    '--create-namespace',
    '--values', $valuesFile,
    '--wait',
    '--timeout', '10m'
)
if ($ChartVersion) {
    $helmArgs += @('--version', $ChartVersion)
}
& helm @helmArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "helm upgrade --install failed."
    exit 1
}

# --- 5. Wait for the server pod ---------------------------------------------
Write-Host "[5/6] Waiting for argocd-server Deployment to be Available" -ForegroundColor Yellow
kubectl wait --for=condition=Available deployment/argocd-server --namespace $Namespace --timeout=5m | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "argocd-server is not Available. Inspect: kubectl describe deployment argocd-server -n $Namespace"
    exit 1
}

# --- 6. Apply the root app ---------------------------------------------------
$rootAppPath = Join-Path $PSScriptRoot '..' 'root-app.yaml'
$rootAppPath = (Resolve-Path $rootAppPath).Path
Write-Host "[6/6] Applying root-app: $rootAppPath" -ForegroundColor Yellow
kubectl apply -f $rootAppPath
if ($LASTEXITCODE -ne 0) {
    Write-Error "kubectl apply on root-app.yaml failed."
    exit 1
}

# --- Done --------------------------------------------------------------------
Write-Host ""
Write-Host "===== ArgoCD installed =====" -ForegroundColor Green
Write-Host ""

# Initial admin password lives in a secret created by the chart.
$adminPwd = kubectl -n $Namespace get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>$null
if ($adminPwd) {
    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($adminPwd))
    Write-Host "Initial admin password (one-time, change immediately in prod):" -ForegroundColor Yellow
    Write-Host "  $decoded"
} else {
    Write-Host "Initial admin secret already removed (or never created). If you need access, reset via the CLI." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Access the UI:"
Write-Host "  kubectl port-forward svc/argocd-server -n $Namespace 8080:80"
Write-Host "  open http://localhost:8080"
Write-Host ""
Write-Host "Watch the root app converge:"
Write-Host "  kubectl get applications -n $Namespace -w"
