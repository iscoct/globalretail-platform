#!/usr/bin/env bash
# ============================================================================
# Workload Identity smoke test for the GlobalRetail AKS cluster
# ============================================================================
# What this proves:
#   - The cluster's OIDC issuer is reachable and valid
#   - A user-assigned managed identity (UAMI) federated to a Kubernetes
#     ServiceAccount can authenticate to Entra ID without any password,
#     client secret, or certificate
#   - From inside a pod, that identity can read a secret from Key Vault
#
# How it works:
#   1. Create a UAMI in Azure
#   2. Federate the UAMI to a Kubernetes ServiceAccount via the cluster's
#      OIDC issuer URL
#   3. Grant the UAMI 'Key Vault Secrets User' on the platform Key Vault
#   4. Put a test secret in the Key Vault
#   5. Apply a ServiceAccount + Pod manifest. The Workload Identity webhook
#      (running in kube-system, auto-installed by AKS) injects environment
#      variables and a projected token volume into pods whose SA has the
#      `azure.workload.identity/client-id` annotation and that have the
#      `azure.workload.identity/use: "true"` label
#   6. Inside the pod, run `az login --federated-token` and read the secret
#
# Cleanup is handled by --cleanup flag at the end of the script.
#
# Pre-requisites:
#   - az CLI logged in (the same identity that ran `terraform apply`)
#   - kubectl configured for the AKS cluster
#   - kubelogin installed (PATH or default `~/.azure-kubelogin/`)

set -euo pipefail

# --- Configuration (matches outputs from `terraform output`) ----------------
RG="rg-globalretail-dev-weu"
LOCATION="westeurope"
KV_NAME="kv-globalretail-72f0"
AKS_NAME="aks-globalretail-dev-weu"
UAMI_NAME="id-wi-test-globalretail-dev-weu"
FED_CRED_NAME="fc-wi-test"
K8S_NAMESPACE="default"
K8S_SA_NAME="wi-test-sa"
K8S_POD_NAME="wi-test-pod"
SECRET_NAME="test-secret"
SECRET_VALUE="hello-from-key-vault-via-workload-identity"

# --- Cleanup mode ------------------------------------------------------------
if [[ "${1:-}" == "--cleanup" ]]; then
    echo "=== Cleaning up Workload Identity smoke test ==="
    kubectl delete pod "${K8S_POD_NAME}" -n "${K8S_NAMESPACE}" --ignore-not-found
    kubectl delete serviceaccount "${K8S_SA_NAME}" -n "${K8S_NAMESPACE}" --ignore-not-found
    az identity federated-credential delete --name "${FED_CRED_NAME}" --identity-name "${UAMI_NAME}" --resource-group "${RG}" --yes 2>/dev/null || true
    az role assignment delete --assignee "$(az identity show -g "${RG}" -n "${UAMI_NAME}" --query principalId -o tsv 2>/dev/null)" --scope "$(az keyvault show -n "${KV_NAME}" --query id -o tsv)" --role "Key Vault Secrets User" 2>/dev/null || true
    az identity delete --name "${UAMI_NAME}" --resource-group "${RG}" 2>/dev/null || true
    az keyvault secret delete --vault-name "${KV_NAME}" --name "${SECRET_NAME}" 2>/dev/null || true
    az keyvault secret purge --vault-name "${KV_NAME}" --name "${SECRET_NAME}" 2>/dev/null || true
    echo "Cleanup done."
    exit 0
fi

echo "=== [1/6] Resolving cluster OIDC issuer URL ==="
OIDC_ISSUER=$(az aks show -g "${RG}" -n "${AKS_NAME}" --query "oidcIssuerProfile.issuerUrl" -o tsv)
echo "OIDC issuer: ${OIDC_ISSUER}"

echo ""
echo "=== [2/6] Creating UAMI '${UAMI_NAME}' ==="
az identity create -g "${RG}" -n "${UAMI_NAME}" --location "${LOCATION}" -o table
UAMI_CLIENT_ID=$(az identity show -g "${RG}" -n "${UAMI_NAME}" --query clientId -o tsv)
UAMI_PRINCIPAL_ID=$(az identity show -g "${RG}" -n "${UAMI_NAME}" --query principalId -o tsv)
echo "UAMI client ID: ${UAMI_CLIENT_ID}"

echo ""
echo "=== [3/6] Federating UAMI to ServiceAccount '${K8S_NAMESPACE}/${K8S_SA_NAME}' ==="
# 'subject' is the SPIFFE-style identifier of the K8s SA inside its cluster.
# 'audience' must be api://AzureADTokenExchange — Entra ID rejects other values.
az identity federated-credential create \
    --name "${FED_CRED_NAME}" \
    --identity-name "${UAMI_NAME}" \
    --resource-group "${RG}" \
    --issuer "${OIDC_ISSUER}" \
    --subject "system:serviceaccount:${K8S_NAMESPACE}:${K8S_SA_NAME}" \
    --audience "api://AzureADTokenExchange" \
    -o table

echo ""
echo "=== [4/6] Granting 'Key Vault Secrets User' on the vault ==="
KV_ID=$(az keyvault show -n "${KV_NAME}" --query id -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
# 'Key Vault Secrets User' role definition (well-known GUID, stable across Azure).
KV_SECRETS_USER_ROLE_DEF_ID="4633458b-17de-408a-b874-0445c86b69e6"

# *** PITFALL ***
# We do NOT use `az role assignment create` here. With az CLI 2.86+ and certain
# combinations of a brand-new UAMI + KV scope + `Key Vault Secrets User`, the
# command consistently returns:
#     "(MissingSubscription) The request did not have a subscription or a
#      valid tenant level resource provider."
# even though --scope is a full resource ID with the subscription.
# Workaround: use `az rest` to call the role-assignment PUT API directly.
# This bypasses whatever CLI-side request munging causes the bug.
RA_GUID=$(python -c "import uuid; print(uuid.uuid4())" 2>/dev/null || powershell -Command "[guid]::NewGuid().Guid")
ROLE_DEF_FULL="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/${KV_SECRETS_USER_ROLE_DEF_ID}"
RA_URI="${KV_ID}/providers/Microsoft.Authorization/roleAssignments/${RA_GUID}?api-version=2022-04-01"
RA_BODY=$(cat <<JSON
{"properties":{"roleDefinitionId":"${ROLE_DEF_FULL}","principalId":"${UAMI_PRINCIPAL_ID}","principalType":"ServicePrincipal"}}
JSON
)
# RBAC propagation lag may still happen here; retry with backoff.
for i in 1 2 3 4 5 6; do
    if echo "$RA_BODY" | az rest --method PUT --uri "$RA_URI" --body @- -o none 2>/dev/null; then
        echo "Role assigned on attempt $i."
        break
    fi
    if [[ $i -eq 6 ]]; then
        echo "ERROR: Role assignment failed after 6 attempts."
        exit 1
    fi
    echo "Attempt $i failed (RBAC propagation or new-UAMI lag), retrying in 15s..."
    sleep 15
done

echo ""
echo "=== [5/6] Seeding a test secret into Key Vault ==="
az keyvault secret set --vault-name "${KV_NAME}" --name "${SECRET_NAME}" --value "${SECRET_VALUE}" --query "{name: name, version: properties.version}" -o table

echo ""
echo "=== [6/6] Deploying ServiceAccount + Pod ==="
# RBAC propagation: KV role assignments take 30-60 seconds before the data
# plane recognises them. The pod retries via az login retry; if it still
# fails, re-run only this step.
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${K8S_SA_NAME}
  namespace: ${K8S_NAMESPACE}
  annotations:
    # The workload identity webhook reads this annotation and configures the
    # pod to authenticate as this UAMI.
    azure.workload.identity/client-id: "${UAMI_CLIENT_ID}"
---
apiVersion: v1
kind: Pod
metadata:
  name: ${K8S_POD_NAME}
  namespace: ${K8S_NAMESPACE}
  labels:
    # This label tells the workload identity webhook to inject the projected
    # token + env vars into this pod. Without the label, nothing is injected.
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: ${K8S_SA_NAME}
  restartPolicy: Never
  containers:
    - name: az-cli
      image: mcr.microsoft.com/azure-cli:latest
      command:
        - /bin/sh
        - -c
        - |
          echo "=== Environment injected by the workload identity webhook ==="
          echo "AZURE_CLIENT_ID:           \$AZURE_CLIENT_ID"
          echo "AZURE_TENANT_ID:           \$AZURE_TENANT_ID"
          echo "AZURE_FEDERATED_TOKEN_FILE: \$AZURE_FEDERATED_TOKEN_FILE"
          echo ""
          echo "=== Logging in to Entra ID with the federated token ==="
          for i in 1 2 3 4 5; do
            if az login --service-principal \\
                  --tenant "\$AZURE_TENANT_ID" \\
                  --username "\$AZURE_CLIENT_ID" \\
                  --federated-token "\$(cat \$AZURE_FEDERATED_TOKEN_FILE)" \\
                  --allow-no-subscriptions \\
                  -o none; then
              echo "Login OK on attempt \$i"
              break
            fi
            echo "Login attempt \$i failed, retrying in 5s..."
            sleep 5
          done
          echo ""
          echo "=== Reading the test secret from Key Vault ==="
          for i in 1 2 3 4 5 6; do
            if VAL=\$(az keyvault secret show --vault-name ${KV_NAME} --name ${SECRET_NAME} --query value -o tsv 2>&1); then
              echo "SECRET VALUE: \$VAL"
              echo ""
              echo "=== SMOKE TEST PASSED ==="
              exit 0
            fi
            echo "KV read attempt \$i failed (RBAC propagation?), waiting 10s..."
            echo "Error was: \$VAL"
            sleep 10
          done
          echo "=== SMOKE TEST FAILED ==="
          exit 1
EOF

echo ""
echo "=== Watching pod logs ==="
kubectl wait --for=condition=Ready pod/${K8S_POD_NAME} -n ${K8S_NAMESPACE} --timeout=60s || true
kubectl logs ${K8S_POD_NAME} -n ${K8S_NAMESPACE} -f
echo ""
echo "Pod exit status:"
kubectl get pod ${K8S_POD_NAME} -n ${K8S_NAMESPACE}
