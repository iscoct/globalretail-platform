# Smoke tests — Layer 1

Manual end-to-end verifications that the cluster, its identities, and its registry integrations actually work after `terraform apply`. These are NOT Terraform-managed; they create resources outside the platform Terraform's state so they can be re-run without interfering with the platform.

## What's here

### `workload-identity.sh`

Proves that **Workload Identity federation works end-to-end** — from "no credentials in any pod manifest" to "pod successfully reads a secret from Key Vault." This is the pedagogically critical test of Layer 1 because it ties together five things:

1. The cluster's OIDC issuer (enabled by `oidc_issuer_enabled = true` on the AKS resource)
2. The Workload Identity mutating webhook (auto-installed by AKS when `workload_identity_enabled = true`)
3. A user-assigned managed identity federated to a Kubernetes ServiceAccount
4. An Azure RBAC role on Key Vault granted to the UAMI
5. A pod that uses the projected SA token to exchange for an Entra ID token

#### Run

Pre-requisites:
- `az` CLI signed in as a principal with Owner on the subscription (or at least Contributor on the platform RG + User Access Administrator on the KV)
- `kubectl` configured for the AKS cluster (`az aks get-credentials` + `kubelogin convert-kubeconfig -l azurecli`)
- Bash (Git Bash, WSL, or a Bash tool from a multi-shell harness)

```bash
bash workload-identity.sh
```

Expected output ends with:

```
=== Reading test-secret from KV ===
SECRET VALUE: hello-from-key-vault-via-workload-identity
=== SMOKE TEST PASSED ===
```

#### Cleanup

```bash
bash workload-identity.sh --cleanup
```

This deletes the test pod + ServiceAccount, removes the federated credential, deletes (and purges) the UAMI and the KV secret. Run this *before* `terraform destroy` so the platform RG is empty of orphaned identities.

### Why these tests are scripts, not Terraform

The Workload Identity smoke test mixes Azure resources (UAMI, federated credential, role assignment, KV secret) with Kubernetes resources (ServiceAccount, Pod). Doing it in Terraform would require configuring the Kubernetes provider against a cluster Terraform itself created — workable but fragile (provider auth, version pinning, `depends_on` chains). For a manual smoke test that the instructor runs once, a script is clearer and easier to reason about.

If/when these tests need to run on every CI/CD pipeline run, they migrate to a Terraform `tests/` directory or to a GitHub Actions job — but that decision belongs to Layer 2.