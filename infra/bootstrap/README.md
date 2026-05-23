# Bootstrap — Terraform remote state

## What this is

A one-shot PowerShell script that provisions the **Azure Storage Account that holds Terraform state** for everything in Layer 1. It runs *before* Terraform, manually, exactly once per environment.

After this script succeeds, you never run it again. It is the only piece of the platform that is *not* managed by Terraform itself.

## Why this exists (the chicken-and-egg)

Terraform manages infrastructure by comparing the desired state (`.tf` files) against the recorded state (`terraform.tfstate`). For team usage, that state must live in a **remote backend** that supports locking — otherwise two engineers running `terraform apply` at the same time corrupt each other's work.

On Azure, the standard remote backend is an Azure Storage Account blob container. But that storage account itself is infrastructure. If Terraform created it, where would Terraform record the fact that it had created it? You'd be writing the state of the storage account into the very container you don't have yet.

The industry-standard answer: bootstrap the backend with a script, *outside* of Terraform, and never let Terraform manage it. It is the only resource in the platform that is allowed to be artisanally provisioned.

> **Alternative we rejected:** a `00-bootstrap` Terraform module that uses **local state** to provision the storage account, then a second module that uses the remote backend. Cleaner-looking but harder to teach: now you have two distinct Terraform projects, two state files (one local, one remote), and a confusing "import the local state into the remote SA after the fact" dance. The script approach is what most Azure platform teams actually do.

## What the script creates

| Resource | Name | Purpose |
|----------|------|---------|
| Resource group | `rg-tfstate-globalretail-weu` | Dedicated to tfstate. **Separate from the platform RG** so that `terraform destroy` on the platform never touches its own backend. |
| Storage account | `stgrtfstate<8-hex-suffix>` | Holds the blob container. SA names are globally unique, hence the suffix. |
| Blob container | `tfstate` | The actual state files. Each layer / environment writes to its own key inside this container. |
| Role assignment | Signed-in user → `Storage Blob Data Owner` on the SA | Required because shared-key access is disabled (see hardening below). |
| File on disk | `../backend.hcl` | Terraform consumes this on `terraform init -backend-config=backend.hcl`. |

## Security hardening applied

| Setting | Value | Why |
|---------|-------|-----|
| `min-tls-version` | `TLS1_2` | Reject SSL/TLS 1.0/1.1 clients. Industry baseline since 2020. |
| `allow-blob-public-access` | `false` | tfstate is sensitive (contains all secrets, IPs, IDs). No anonymous reads, ever. |
| `allow-shared-key-access` | `false` | **No static keys exist.** All access via Entra ID. A leaked SA key would be game-over for the platform; eliminating the attack surface is the production answer. |
| `https-only` | `true` | Belt-and-braces — TLS 1.2 minimum is already required, but this rejects unencrypted requests at a different layer. |
| Blob versioning | enabled | If a `terraform apply` writes a corrupt state, the previous version is recoverable. |
| Blob soft-delete | 30 days | Accidental container delete or blob delete is recoverable. |

## What we did **not** harden (and why)

These would be the next step in a production setup, deliberately skipped for Layer 1:

- **Private endpoint on the storage account.** Production setup: SA only reachable from within the platform VNet (no public network access). We can't do that here because the VNet doesn't exist yet — it's created by Terraform, which needs to talk to the SA. Solving it requires either a manual VNet bootstrap (more chicken-and-egg) or a workaround like temporarily allowing the runner's IP. Documented as a "Lab vs Production" simplification in the Layer 1 sub-README.
- **Customer-managed encryption keys (CMK).** Microsoft-managed keys are used. CMK adds a Key Vault dependency and is overkill for a sandbox.
- **Geo-redundant storage (GRS).** LRS is used (single region, three copies). tfstate is regenerable from `terraform refresh` and the live Azure resources — the cost of GRS isn't justified for a dev environment.

## Prerequisites

- Azure CLI signed in: `az login`
- The signed-in user must be **Owner** on the target subscription (needed to create the role assignment).
- PowerShell 5.1+ or PowerShell 7+

## Running it

```powershell
cd globalretail-platform/infra/bootstrap
.\bootstrap.ps1
```

With defaults: `Workload=globalretail`, `Location=westeurope`, `LocationShort=weu`.

The script is **idempotent**: running it again with the same inputs is safe and will skip already-created resources.

## After it succeeds

A file `../backend.hcl` is generated containing the backend configuration. Terraform consumes it next:

```powershell
cd ..
terraform init -backend-config=backend.hcl
```

## Tearing it down

The script does NOT include a teardown subcommand because teardown order matters — you must `terraform destroy` the platform BEFORE deleting the tfstate RG, otherwise Terraform can't find its state on subsequent runs.

Correct order:

```powershell
# 1. From globalretail-platform/infra
terraform destroy   # removes the platform: AKS, ACR, KV, VNet, etc.

# 2. After destroy completes
az group delete --name rg-tfstate-globalretail-weu --yes
```

## Common errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Not logged into az CLI` | No active `az` session | `az login` |
| Container creation fails on first try | RBAC propagation lag (the role assignment takes 30–60s to be effective on the data plane) | The script auto-retries 6× with 10s spacing. If it still fails, run the script again — by then propagation is done. |
| `AuthorizationFailed` on role assignment | You are not Owner on the subscription | Ask the subscription Owner to either (a) grant you Owner or (b) create the role assignment for you manually |
