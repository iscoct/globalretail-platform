# gitops/bootstrap

One-time install of ArgoCD itself on the AKS cluster.

## The chicken-and-egg

ArgoCD is the system that delivers changes to the cluster via GitOps. But ArgoCD has to *exist* in the cluster before it can deliver anything — including itself. So the very first install can't come from GitOps. It comes from this script.

After ArgoCD is installed and the **root Application** (the app-of-apps) is applied, ArgoCD takes over its own lifecycle: any change to `../root-app.yaml` or any `../applications/*.yaml` is picked up automatically. From that point on, the only laptop-touch needed is when the script itself or the Helm values change — but even those could in principle be reconciled by ArgoCD (a future iteration adds the ArgoCD self-managing pattern).

## What the script does (in order)

1. `az aks get-credentials` — fetches the kubeconfig.
2. `kubelogin convert-kubeconfig -l azurecli` — converts the kubeconfig so kubectl reuses the `az login` session for Entra ID auth (Layer 1 disabled local accounts; Entra is the only path in).
3. `helm repo add argo https://argoproj.github.io/argo-helm` + repo update.
4. `helm upgrade --install argocd argo/argo-cd` with `values-argocd.yaml`. Idempotent.
5. `kubectl wait` for the argocd-server deployment to be Available.
6. `kubectl apply -f ../root-app.yaml` — the seed Application.

## Prerequisites

- Layer 1 deployed (AKS cluster exists, your user is in the `globalretail-aks-admins` Entra group).
- `az`, `helm`, `kubectl`, `kubelogin` all on PATH.

## Running it

```powershell
.\install-argocd.ps1
```

Optional flags:

| Flag | Purpose | Default |
|---|---|---|
| `-ResourceGroup` | AKS RG | `rg-globalretail-dev-weu` |
| `-ClusterName` | AKS cluster name | `aks-globalretail-dev-weu` |
| `-Namespace` | Namespace for ArgoCD | `argocd` |
| `-ChartVersion` | Pin a specific chart version | empty (latest stable) |

## After running

1. Port-forward to the ArgoCD server:
   ```powershell
   kubectl port-forward svc/argocd-server -n argocd 8080:80
   ```
2. Open `http://localhost:8080`. Login `admin` + the password printed by the script (also retrievable later via `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).
3. Watch ArgoCD discover and reconcile the root Application:
   ```powershell
   kubectl get applications -n argocd -w
   ```
4. Confirm sample-app pods come up in the `sample-app` namespace:
   ```powershell
   kubectl get pods -n sample-app
   ```

## Teardown

```powershell
# Remove the workloads first (Application finalizer ensures clean removal)
kubectl delete application root -n argocd

# Then uninstall ArgoCD itself
helm uninstall argocd -n argocd
kubectl delete namespace argocd

# Optional: delete the sample-app namespace if Application finalizer didn't
kubectl delete namespace sample-app --ignore-not-found
```

Layer 1's `terraform destroy` will then take down the AKS cluster including any remaining workloads.
