# Layer 1 — Platform Foundation (Terraform)

> 🚧 **Status:** in progress. Sections marked `[TBD-AFTER-BUILD]` are filled once we have actually deployed and broken-and-fixed the stack — writing "Pitfalls" before you've hit them is dishonest pedagogy.

---

## 1. What this layer does

This layer provisions the **immutable platform foundation** on Azure: the resource group, networking, observability sink, container registry, secret store, managed identities, and the AKS cluster itself. Everything that lives "above" Kubernetes (CI/CD, GitOps, monitoring stack, policy engine) sits on top of what this layer produces.

Concretely, after running this layer you have:

- An AKS cluster integrated with Entra ID, with Workload Identity and OIDC issuer enabled
- An Azure Container Registry that the cluster can pull from with no image pull secrets
- A Key Vault in RBAC mode, ready to back the Secrets Store CSI Driver in Layer 5
- A VNet with subnets ready for both today's public-cluster mode and a future private-cluster variant
- A Log Analytics workspace receiving diagnostic logs from every resource
- A remote Terraform state in an Azure Storage Account

## 2. Why it exists in production

A real platform team doesn't `az aks create` from a laptop and call it done. The cluster is one resource in a fleet of resources that **must be reproducible, auditable, and version-controlled**:

- **Reproducible:** dev/staging/prod are the same code with different inputs. The reference architecture only deploys `dev`, but the code shape supports environment variants.
- **Auditable:** every change to the platform is a pull request, reviewed and applied through a pipeline (Layer 2). The Terraform state is the source of truth for "what does our platform look like right now."
- **Recoverable:** if the cluster is corrupted or the region has an outage, you re-run Terraform. You don't recreate it from memory.
- **Separable:** the things that change often (apps, manifests, configmaps) live in Layer 3 (GitOps). The things that rarely change (cluster, network, identity) live here. Mixing them is one of the most common platform mistakes.

## 3. What we built

### File layout

```
infra/
├── README.md                          ← this file
├── versions.tf                        ← terraform + provider version pins
├── providers.tf                       ← azurerm/azuread/random/http config
├── variables.tf                       ← root input variables + defaults
├── locals.tf                          ← naming convention, common tags
├── main.tf                            ← RG, Log Analytics, UAMIs, group, module calls
├── outputs.tf                         ← outputs consumed by Layer 2 and beyond
├── terraform.tfvars.example           ← template for tfvars
├── terraform.tfvars                   ← real values (gitignored)
├── backend.hcl                        ← remote-backend config (gitignored, regenerable)
├── .gitignore
├── bootstrap/
│   ├── bootstrap.ps1                  ← idempotent: provisions tfstate SA
│   └── README.md                      ← chicken-and-egg rationale + hardening
├── modules/
│   ├── network/                       ← VNet + subnets
│   ├── acr/                           ← ACR + AcrPull + diagnostic settings
│   ├── keyvault/                      ← KV (RBAC mode) + admin role assignments + diag
│   └── aks/                           ← cluster + role assignments + user pool + diag
└── smoke-test/
    └── workload-identity.sh           ← end-to-end federation verification
```

### Apply sequence (from a clean slate)

```powershell
# 1. One-time: provision the tfstate storage account.
cd globalretail-platform/infra/bootstrap
.\bootstrap.ps1

# 2. Copy tfvars template and fill in subscription_id + tenant_id.
cd ..
cp terraform.tfvars.example terraform.tfvars
# (edit terraform.tfvars)

# 3. Initialise the remote backend.
terraform init -backend-config=backend.hcl

# 4. Apply. With our defaults this creates ~30 resources in ~15-20 minutes
#    (most of the time is AKS create itself).
terraform plan -out=tfplan
terraform apply tfplan

# 5. Run the Workload Identity smoke test.
bash smoke-test/workload-identity.sh
```

### What ends up in the subscription

| Resource group | Holds |
|---|---|
| `rg-tfstate-globalretail-weu` | tfstate storage account (provisioned by `bootstrap.ps1`, never managed by Terraform) |
| `rg-globalretail-dev-weu` | Platform RG: Log Analytics, both UAMIs, VNet/subnets, ACR, Key Vault, AKS cluster manifest |
| `rg-globalretail-dev-weu-aks-nodes` | AKS-managed infrastructure RG: VMSS for each pool, Standard LB, NSGs, public IP for outbound, disks |

### What Layer 2+ consumes from here

Layer 2 (CI/CD) and Layer 3+ read these Terraform outputs:

| Output | Used by |
|---|---|
| `acr_login_server` | `docker login` step in GitHub Actions |
| `acr_id` | scope for the federated identity's `AcrPush` role assignment |
| `aks_cluster_name`, `resource_group_name` | `az aks get-credentials` in ArgoCD bootstrap |
| `aks_oidc_issuer_url` | federated credentials for app workloads needing KV access |
| `key_vault_uri` | CSI Secrets Store driver `SecretProviderClass` |
| `log_analytics_workspace_id` | Grafana data source, Layer 4 dashboards |

## 4. Lab vs Production

The deliberate simplifications we made for this single-environment dev sandbox, and what a multi-region production deployment changes.

| Concern | Lab (this code) | Production |
|---|---|---|
| **tfstate access** | Public network, TLS 1.2 + Entra ID auth | Private endpoint in the platform VNet, no public network access |
| **tfstate redundancy** | LRS (3 copies in one datacenter) | ZRS or GZRS depending on cross-region recovery needs |
| **Subscription model** | Single subscription | Separate subs per env: prod / staging / dev, often per workload too |
| **Environments** | Just `dev` (one terraform workspace, one state file) | `dev` / `staging` / `prod` with separate states; the same Terraform code, different `.tfvars` and backend keys |
| **Run mechanism** | `terraform apply` from instructor's laptop | Pipeline (Layer 2): GitHub Actions with OIDC federated identity → Azure. No human runs apply against prod. |
| **AKS API server** | Public endpoint + `authorized_ip_ranges` (operator's IP) | API Server VNet Integration (or private cluster) — API endpoint inside the VNet, no internet exposure. Operators access via Bastion / VPN / self-hosted runner. |
| **AKS SKU tier** | Standard (99.9% SLA) | Standard or Premium (long-term support tier) for longer patching windows |
| **AKS auto-upgrade** | `patch` channel | `patch` for most clusters; `none` for highly regulated workloads with scheduled change windows |
| **Node pools** | 1 system (2 nodes) + 1 user (1-3 autoscale), all `D2s_v3` | System pool isolated to small VMs (`B2as`/`D2s_v3`); multiple user pools per workload class: `general`, `memory-optimised`, `gpu`, plus a `spot` pool for batch |
| **Node pool zones** | Single zone (default) | `zones = [1, 2, 3]` for AZ resilience |
| **Maintenance windows** | None (AKS chooses) | `maintenance_window` configured to off-hours / regional low-traffic times |
| **ACR SKU** | Standard ($5/mo) | Premium ($1.65/day + storage): geo-replication, private endpoints, customer-managed keys, repo-scoped tokens, content trust |
| **ACR network** | Public, Entra ID auth | Private endpoint in the platform VNet, public access disabled, geo-replicated to disaster-recovery region |
| **Key Vault SKU** | Standard | Standard for most secrets; Premium ($1/mo + HSM ops) when keys must live in HSM (compliance) |
| **Key Vault network** | Public, Entra ID auth + RBAC | Private endpoint, `network_acls.default_action = "Deny"`, only specific subnets/PEs allowed |
| **Key Vault soft-delete** | 7 days (the minimum) | 90 days |
| **Key Vault purge protection** | Disabled (so we can destroy and recreate during the build) | **Enabled**: keys/secrets/certs cannot be permanently deleted until soft-delete retention expires. Mandatory for PCI/SOC2. |
| **VM family** | `Standard_D2s_v3` (Intel Xeon Skylake, quota-friendly in this sandbox) | Latest gen with available quota: `D2s_v5`, `D2as_v5`, `Dasv6` — newer CPUs, better price/performance |
| **Network plugin** | Azure CNI Overlay + Cilium dataplane | Same — this is the current Microsoft-recommended setup for new clusters |
| **Workload Identity** | Enabled, with a smoke-test pod proving the flow | Enabled, with the Azure Identity SDK used by every workload that needs an Azure-managed resource — never k8s `Secret`s containing static credentials |
| **CSI Secrets Store driver** | Not installed (Layer 5 adds it) | Installed cluster-wide; every namespace that needs KV secrets uses `SecretProviderClass` resources |
| **Observability** | Diagnostic settings → Log Analytics for ACR, KV, AKS. No metrics dashboard. | Same diag settings + kube-prometheus-stack or Azure Managed Prometheus + Grafana (Layer 4) |
| **Backup** | None | Azure Backup for AKS (volumes + cluster state) + Velero for cross-cluster restore |
| **Cost monitoring** | None | Azure Cost Management budgets with alerts at 50%/80%/100% of monthly budget per RG |

## 5. Key concepts the instructor must own

Below: what the instructor must be able to explain confidently when a student asks. Order = build order — these concepts surface in the code in this sequence.

### 5.1 Chicken-and-egg of Terraform state
Terraform needs a place to store state. The standard Azure backend is a Storage Account blob. But that SA is itself infrastructure — if Terraform created it, the state would live inside the SA's own state record, which doesn't exist yet. **The industry answer:** provision the SA once, manually, via a script (`bootstrap.ps1`), and never let Terraform manage it. The SA lives in a *separate* RG so `terraform destroy` of the platform can't touch its own backend.

### 5.2 User-assigned vs system-assigned managed identities
A **system-assigned** identity is created with its parent resource and dies with it. Recreate the AKS cluster, lose the identity, lose every role assignment that referenced it.
A **user-assigned managed identity (UAMI)** is an independent resource you assign to one or more services. Recreate the cluster, keep the UAMI, keep the role assignments. Production setups overwhelmingly use UAMI for the AKS control plane *and* the kubelet — and they keep these two as **separate identities** for least privilege (control plane manages networking; kubelet only pulls images).

### 5.3 Azure RBAC for Kubernetes + Entra ID + local accounts disabled
Three settings together produce the production AKS auth model:
- `azure_active_directory_role_based_access_control { ... }` — wires the cluster to an Entra ID tenant, requires Entra ID-issued tokens for kubectl.
- `azure_rbac_enabled = true` — Kubernetes-level permissions come from **Azure** RBAC roles (`Azure Kubernetes Service RBAC Cluster Admin`, etc.) on the cluster scope, not from K8s `RoleBinding`/`ClusterRoleBinding` resources.
- `local_account_disabled = true` — `az aks get-credentials --admin` is blocked. The pre-shared cluster admin kubeconfig (the equivalent of a root password) cannot be downloaded. The only auth path is Entra ID.

Together: humans access the cluster only after authenticating with Entra ID (potentially with Conditional Access and MFA), and their permissions are managed in Azure RBAC (auditable, group-based, PIM-able). The trust anchor is the Entra ID admin group, not a specific user.

### 5.4 Workload Identity (federated credentials)
The replacement for the deprecated **pod-managed identity (aad-pod-identity)**. Pre-Workload-Identity, pods authenticated to Azure by having a daemonset intercept IMDS requests and translate them — fragile, slow, deprecated.

Workload Identity works via OIDC: AKS publishes an OIDC issuer URL; you create a **Federated Credential** on an Entra ID identity that trusts tokens issued for a specific Kubernetes ServiceAccount on that issuer. The Azure Workload Identity webhook (auto-installed by AKS when `workload_identity_enabled = true`) injects a projected SA token + env vars into pods whose SA carries the annotation. Azure SDKs (or `az login --federated-token`) exchange that K8s token for an Entra ID token via STS. No passwords, no client secrets, no certificates — pure federation.

The smoke test in `smoke-test/workload-identity.sh` proves this end-to-end: a pod reads a Key Vault secret using only its SA token.

### 5.5 Azure CNI Overlay vs traditional vs kubenet
Three pod-networking models on AKS:
- **kubenet** (deprecated): pods get IPs from a `pod_cidr` outside the VNet; node acts as NAT. Lightweight but limited (no Network Policy with newer engines, retirement on the roadmap).
- **Azure CNI traditional**: every pod gets a VNet IP. Pods are first-class network citizens, can be reached directly from VNet-peered services. Downside: IP exhaustion. A /22 subnet with 30 pods per node maxes out at ~30 nodes.
- **Azure CNI Overlay** (our choice): nodes get VNet IPs from the cluster subnet; pods get IPs from an overlay (`pod_cidr`, default `10.244.0.0/16`). Pods are not directly addressable from the VNet but everything inside the cluster works. No IP exhaustion at scale.

The **Cilium dataplane** ("Azure CNI Powered by Cilium") replaces the default kube-proxy iptables rules with eBPF programs running in the kernel. Faster service routing, fewer dropped packets at scale, native L4/L7 NetworkPolicy, and Hubble observability (Layer 4 will use it).

### 5.6 Why ACR-to-AKS auth uses the kubelet identity, not image pull secrets
Kubernetes' native solution for private registries is `imagePullSecrets`: a Secret containing a Docker config that nodes use to authenticate. Problems with this in production:
- Secret rotation: secrets typically hold long-lived passwords. Rotating means updating every pod spec that references the secret.
- Distribution: each namespace needs its own copy, or the secret lives in every namespace and someone has to keep them in sync.
- Audit: who used the secret, when?

The Azure-native answer: the **kubelet's managed identity** has `AcrPull` on the registry. When a node needs to pull an image from `acrXYZ.azurecr.io`, kubelet uses its UAMI's Entra ID token. No secrets in any namespace. Rotation is automatic (managed identities don't expire). Audit lands in the ACR diagnostic logs (Log Analytics).

### 5.7 Key Vault RBAC mode vs Access Policies
Two authorization models exist on Key Vault:
- **Access policies** (legacy): per-principal grants stored on the vault itself. Each policy lists the operations allowed (`get secret`, `list secret`, `set secret`, etc.). Doesn't integrate with Azure RBAC tooling — no PIM, no Conditional Access on KV operations, no policy inheritance, separate audit path.
- **RBAC** (`rbac_authorization_enabled = true`, our choice): grants are standard Azure role assignments at the vault scope. Standard tooling applies: PIM, Conditional Access, role audit logs.

The CSI Secrets Store Driver (Layer 5) works with both, but RBAC is the path Microsoft documents going forward. Workload Identity + CSI Secrets Store + RBAC mode is the canonical 2025+ secret-management story on AKS.

### 5.8 Authorized IP ranges vs private cluster vs API Server VNet Integration
Three modes for restricting access to the AKS API server:
- **Public + `authorized_ip_ranges`** (this lab): public endpoint, only listed CIDRs can reach it. Token auth (Entra ID) still required. Operator-friendly: works from any laptop on a whitelisted IP. Sufficient for many production setups.
- **Private cluster** (`private_cluster_enabled = true`): public endpoint is removed; the API server lives behind a Private Link Service in a private DNS zone. Requires a jumpbox/Bastion/VPN to reach. Higher operational overhead, lower attack surface.
- **API Server VNet Integration** (GA 2024): the API server gets an IP in a *delegated subnet* in your VNet (we reserved `snet-apiserver` for this). No Private Link, no jumpbox needed if your workstations have a VPN to the VNet. Cleanest of the three, but the youngest — fewer docs, more rough edges.

For a reference architecture demo, public + `authorized_ip_ranges` is the right balance. For a real production cluster carrying PCI/HIPAA workloads, ask whether the network team can manage the VPN/Bastion that a private model requires.

## 6. Pitfalls and gotchas

Encountered during this build. Each entry includes the symptom, root cause, and the fix.

### 6.1 PowerShell on Windows mangles `terraform init -backend-config=backend.hcl`
**Symptom:** `terraform init -backend-config=backend.hcl` from `pwsh` errors with `Too many command line arguments. Did you mean to use -chdir?`.
**Cause:** PowerShell's argument tokeniser splits the `=` form into two args, and terraform sees `-backend-config` followed by an orphan `backend.hcl`.
**Fix:** Run terraform from a real Bash shell (Git Bash, WSL, the Bash tool from a multi-shell harness). The same command works in Bash without modification.

### 6.2 Key Vault name length: 24 chars max
**Symptom:** `terraform apply` fails partway through with `"name" may only contain alphanumeric characters and dashes and must be between 3-24 chars`.
**Cause:** First draft used `kv-gr-${name_suffix}-${suffix}` = 31 chars (name_suffix already contains workload+env+region).
**Fix:** Drop env+region from the KV name — they're already implied by the resource group that contains the vault. Pattern: `kv-${workload}-${suffix}` = 20 chars for `globalretail` + 4-hex suffix. The module now takes `workload` (with a `length() <= 16` validation) instead of the full `name_suffix`.

### 6.3 `azurerm_monitor_diagnostic_setting` `metric` block deprecation
**Symptom:** `terraform validate` warns: `metric has been deprecated in favour of the enabled_metric property and will be removed in v5.0 of the AzureRM provider`.
**Fix:** Replace `metric { category = "AllMetrics" }` with `enabled_metric { category = "AllMetrics" }`. Same effect, the new schema makes the categories list explicit.

### 6.4 `for_each` with apply-time-unknown values
**Symptom:** `terraform plan` errors: `Invalid for_each argument: The "for_each" set includes values derived from resource attributes that cannot be determined until apply.`
**Cause:** Passing `[user_id, group_object_id]` as a list to a module that calls `for_each = toset(var.list)`. The group's `object_id` is only known after the group is created.
**Fix:** Convert the input to a `map(string)` with **static labels** as keys and (possibly unknown) IDs as values. Static keys mean Terraform can compute the for_each instance count at plan time even when values are unknown. Pattern used here:
```hcl
admin_object_ids = merge(
  { "signed-in-user" = data.azurerm_client_config.current.object_id },
  var.create_aks_admin_group ? { "aks-admin-group" = azuread_group.aks_admins[0].object_id } : {}
)
```

### 6.5 AKS create fails: vCPU quota in `westeurope`
**Symptom:** `creating Kubernetes Cluster ... "ErrCode_InsufficientVCPUQuota": Insufficient vcpu quota requested 4, remaining 0 for family standardDSv5Family`.
**Cause:** Sandbox / educational subscriptions frequently have zero quota for the latest `DSv5` family in West Europe. This is common across non-enterprise Azure subscriptions and free trials.
**Fix:** Switch VM SKU to a family with quota. `az vm list-usage --location westeurope` shows what's available. We use `Standard_D2s_v3` (35 vCPU quota available — plenty). Same CPU/RAM profile as `D2s_v5`, same price, one CPU generation older. The dev sandbox is unaffected.

### 6.6 `network_dataplane` is `network_data_plane`
**Symptom:** `validate` errors: `An argument named "network_dataplane" is not expected here. Did you mean "network_data_plane"?`
**Cause:** Microsoft docs and most blog posts spell it `network_dataplane` (one word), but the azurerm provider uses `network_data_plane` (three).
**Fix:** Use `network_data_plane = "cilium"` in the `network_profile` block.

### 6.7 `kubectl get nodes` fails: `executable kubelogin not found`
**Symptom:** After `az aks get-credentials` to an Entra ID-integrated cluster, `kubectl` errors with `client-go credential plugin that is not installed ... kubelogin is not installed which is required to connect to AAD enabled cluster`.
**Cause:** AKS Entra ID clusters use a kubeconfig that delegates auth to `kubelogin`. Standard `kubectl` doesn't know how to fetch Entra ID tokens.
**Fix:**
```powershell
az aks install-cli
# Add to PATH (the install warns about this but doesn't do it in the current session)
$env:PATH = "$env:USERPROFILE\.azure-kubelogin;$env:USERPROFILE\.azure-kubectl;" + $env:PATH
kubelogin convert-kubeconfig -l azurecli   # use the az CLI token instead of interactive device code
kubectl get nodes
```
The `-l azurecli` mode is the convenient one for desktop work — it reuses the `az login` session. For unattended runners use `-l workloadidentity` or `-l msi`.

### 6.8 `az role assignment create` returns `MissingSubscription` for a brand-new UAMI
**Symptom:** Creating a role assignment via `az role assignment create --assignee-object-id <new-uami-principal-id> --scope <kv-id> --role 'Key Vault Secrets User'` returns `(MissingSubscription) The request did not have a subscription or a valid tenant level resource provider`, even though `--scope` is a full resource ID with the subscription baked in.
**Cause:** Something in the az CLI 2.86 code path for role assignments mangles the request when the principal is a freshly-created UAMI. The error message is misleading — the subscription is fine; the request URL is malformed.
**Fix:** Bypass `az role assignment create` and call the ARM REST API directly:
```bash
az rest --method PUT \
  --uri "${KV_ID}/providers/Microsoft.Authorization/roleAssignments/$(uuidgen)?api-version=2022-04-01" \
  --body '{"properties":{"roleDefinitionId":"/subscriptions/<sub>/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6","principalId":"<uami-principal-id>","principalType":"ServicePrincipal"}}'
```
The `4633458b-...` GUID is the well-known role definition ID for `Key Vault Secrets User` (stable across Azure). The Terraform `azurerm_role_assignment` resource also bypasses the bug — it talks to ARM directly. Only the `az role assignment create` CLI command is affected. Used in `smoke-test/workload-identity.sh`.

### 6.9 `az account clear` is not a soft revoke — it logs you out everywhere
**Symptom:** Running `az account clear` (intended to "refresh the session") logs you out completely. `az login --identity` fails on a desktop (no IMDS), and `az login` requires an interactive browser flow which doesn't complete in an automated tool loop.
**Fix:** Don't `az account clear` unless you're prepared to re-authenticate interactively. Token refresh in az CLI is automatic; it doesn't need a clear.

## 7. Likely student questions and answers

**Q: Why is there a separate `bootstrap/` script? Couldn't Terraform create the storage account too?**
A: Yes, in theory — with a separate `00-bootstrap/` Terraform module using local state. But that gives you two Terraform projects, two state files (one local, one remote), and a confusing import-into-remote step after the fact. The script approach is what most Azure platform teams actually do, and it makes the chicken-and-egg explicit.

**Q: Why two managed identities for AKS (control plane and kubelet)?**
A: Least privilege. The control plane needs `Network Contributor` on the subnet to create load balancers and attach NICs. The kubelet only needs `AcrPull` to pull images. Different blast radius if one is compromised. Production AKS deployments universally split these.

**Q: Why is `azurerm_role_assignment.controlplane_kubelet_operator` needed?**
A: When you pre-create the kubelet UAMI and pass it to AKS via `kubelet_identity {}`, AKS' control plane needs permission to *assign* that identity to each node VM. The role `Managed Identity Operator` on the kubelet UAMI scope grants exactly that. Without it, cluster creation fails late with a cryptic "principal does not have permission to perform Microsoft.ManagedIdentity/userAssignedIdentities/assign/action" error. One of the most common AKS-with-pre-created-identities gotchas.

**Q: Why public API server instead of private cluster?**
A: For a teaching artifact, the operator (instructor) wants to demo the cluster from a laptop without setting up a Bastion or VPN every session. The token-level auth (Entra ID + Azure RBAC for Kubernetes + `local_account_disabled = true`) is the real security control; the IP restriction is a defence-in-depth layer. Production deployments tend to private cluster *or* API Server VNet Integration — Section 5.8 walks through the trade-offs.

**Q: Why is `local_account_disabled = true` not the default in AKS?**
A: Backward compatibility. AKS predates managed Entra ID integration; `az aks get-credentials --admin` was the only way for years. The default still allows it so existing tutorials don't break. Setting it to `true` is the canonical hardening step in 2024+. If you ever lose access to the admin group, you're locked out — that's why we keep the admin group with multiple members (or break-glass procedures in real orgs).

**Q: Why Cilium and not Azure Network Policy?**
A: Both work with Overlay. Cilium gives you L7 policies (HTTP method/path filtering), Hubble observability for free, and the modern eBPF dataplane. Azure Network Policy is L3/L4 only and uses iptables. Pick Cilium for new clusters unless your security team has compliance constraints on what dataplane you can run.

**Q: How does the cluster pull images from ACR with no `imagePullSecrets`?**
A: The kubelet UAMI on each node has the `AcrPull` role on the registry. When kubelet sees `image: acrXYZ.azurecr.io/...`, it asks Azure IMDS for an Entra ID token, exchanges that for an ACR refresh token, pulls the image. Section 5.6 covers it.

**Q: Could we use Azure Verified Modules (AVM) instead of writing modules ourselves?**
A: For a real platform team, yes — AVMs are battle-tested, supported, and reduce code maintenance. For a *teaching* repo, no — AVM wrappers hide the resource blocks and the configuration knobs we're trying to explain. A student should be able to open `modules/aks/main.tf` and see the literal `azurerm_kubernetes_cluster` resource with every important argument visible. If GlobalRetail were real, the next refactor (after the team has internalised the choices) would be to wrap these in AVMs.

**Q: Why is the kubelet UAMI separate from the kubelet identity that AKS sometimes auto-creates?**
A: AKS can either: (a) auto-create a system-assigned kubelet identity when the cluster is created, or (b) accept a pre-created UAMI via the `kubelet_identity { user_assigned_identity_id = ... }` block. We pick (b) so we can grant the identity `AcrPull` *before* the cluster exists. Otherwise the cluster's first image pull fails with a permission error, and you have to wait for the cluster, fish out the auto-created identity, grant it AcrPull, and retry.

**Q: What happens to my Terraform state if the storage account that holds it gets deleted?**
A: Recovery: blob soft-delete (30 days) and blob versioning are on, so deleted state versions are recoverable from the portal. If both the SA and its soft-deletion are gone, the cluster + RG still exist in Azure and you'd run `terraform import` against each resource — slow but workable. Prevention: never put tfstate in the same RG as the platform; always run `terraform destroy` *before* destroying the tfstate RG.

**Q: Why does the Workload Identity smoke test pod use `mcr.microsoft.com/azure-cli`?**
A: Because `az login --federated-token` is the easiest way to *visibly demonstrate* the federation flow — you see the login succeed, then a normal `az keyvault secret show` works. In real workloads you'd use the Azure Identity SDK (`DefaultAzureCredential` in .NET/Python/Java/Go) which reads the same env vars and exchanges the token transparently. Same mechanism, different visibility.

## 8. References

Sources we vetted while building this layer.

### Microsoft official docs
- [AKS managed Entra ID integration with Azure RBAC](https://learn.microsoft.com/en-us/azure/aks/manage-azure-rbac) — the auth setup we used.
- [AKS Workload Identity overview](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview) — the OIDC + federated credentials story.
- [Azure CNI Powered by Cilium](https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium) — the network plugin we chose.
- [Azure CNI Overlay](https://learn.microsoft.com/en-us/azure/aks/concepts-network-azure-cni-overlay) — why pods don't consume VNet IPs.
- [Pre-create and use a kubelet managed identity](https://learn.microsoft.com/en-us/azure/aks/use-managed-identity#bring-your-own-control-plane-mi) — the BYO-identity flow.
- [AKS auto-upgrade channels](https://learn.microsoft.com/en-us/azure/aks/auto-upgrade-cluster) — what each channel does.
- [Managing Azure resources with Terraform](https://learn.microsoft.com/en-us/azure/developer/terraform/overview) — Microsoft's authoritative Terraform-on-Azure guidance.
- [Terraform AzureRM provider docs](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs) — resource reference (canonical source of truth, not the blog posts).

### Authoring patterns
- [Cloud Adoption Framework: AKS landing zone accelerator](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/scenarios/app-platform/aks/landing-zone-accelerator) — Microsoft's reference architecture for a production AKS landing zone. Heavier than this lab; useful as the "what would prod look like" companion.
- [Azure Verified Modules (AVM) for AKS](https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster) — the AVM we deliberately did *not* use, but worth reading to see what a production team eventually wraps.

### Workload Identity specifically
- [Azure Workload Identity OSS docs](https://azure.github.io/azure-workload-identity/docs/) — what the webhook actually does (the OSS project AKS productised).
- [Federated identity credentials overview](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation) — the Entra ID side of the federation.

### Operational
- [kubelogin docs](https://azure.github.io/kubelogin/) — modes (`devicecode`, `azurecli`, `msi`, `workloadidentity`), when to use which.
- [AKS local accounts disabled](https://learn.microsoft.com/en-us/azure/aks/manage-local-accounts-managed-azure-ad) — the production hardening we applied.
- [Azure quotas overview](https://learn.microsoft.com/en-us/azure/quotas/quotas-overview) — when you hit `ErrCode_InsufficientVCPUQuota` and need to request an increase.

---

## Build progress

- [x] Bootstrap: storage account for tfstate
- [x] Iteration 1: networking + identity + log analytics
- [x] Iteration 2: ACR + Key Vault + Entra ID group
- [x] Iteration 3: AKS cluster
- [x] Smoke test: kubectl access, ACR pull, Workload Identity end-to-end
- [x] Sub-README sections 3–8 written
- [x] Cleanup verified: `terraform destroy` left the subscription clean (no orphan KVs, identities, or admin group)

## Iteration log

### Bootstrap — completed
Provisioned `rg-tfstate-globalretail-weu` + storage account `stgrtfstate15728479` + container `tfstate` via `bootstrap/bootstrap.ps1`. Storage account hardened: TLS 1.2, no shared keys, blob versioning, soft delete. `backend.hcl` emitted for Terraform consumption. Took ~2 minutes; idempotent on re-run. No retries needed for RBAC propagation on this run (often does need them).

### Iteration 1 — completed
Applied 7 resources in ~80 seconds:
- `rg-globalretail-dev-weu` (platform RG, distinct from tfstate RG)
- `log-globalretail-dev-weu` (Log Analytics workspace, PerGB2018, 30-day retention) — *slowest at 48s*
- `id-aks-globalretail-dev-weu` (UAMI for AKS control plane — pre-created so Iter 2 can grant it permissions before AKS exists)
- `vnet-globalretail-dev-weu` (`10.0.0.0/16`)
- `snet-aks-nodes` (`10.0.0.0/22`, sized for headroom — Azure CNI Overlay means pods don't consume these IPs)
- `snet-private-endpoints` (`10.0.4.0/24`, reserved for Iter 2)
- `snet-apiserver` (`10.0.5.0/28`, reserved for a future move to API Server VNet Integration)

### Iteration 2 — completed
Applied 11 resources across two apply rounds (the second forced by a name-length bug, fixed mid-iteration):
- `id-aks-kubelet-globalretail-dev-weu` (second UAMI — kubelet ≠ control plane; least-privilege per function)
- Entra ID security group `globalretail-aks-admins` ✅ — the tenant used for this build allows group creation by the signed-in user (no admin role required). The fallback (`create_aks_admin_group = false`) was therefore not needed but remains in the variables for tenants that restrict it.
- ACR Standard SKU (`acrglobalretaildevweua146d9.azurecr.io`) + diagnostic setting → Log Analytics + AcrPull role to kubelet UAMI
- Key Vault Standard, RBAC mode (`kv-globalretail-72f0` → `https://kv-globalretail-72f0.vault.azure.net/`) + diagnostic setting → Log Analytics + Key Vault Administrator role to (a) signed-in user and (b) the AKS admin group.

**Learned during this iteration:**
- KV name budget (3-24 chars) is tight. The first draft used `kv-gr-${name_suffix}-${suffix}` → 31 chars → apply failed mid-way. Fix: drop env+region from the KV name (they're already in the RG that contains it), keep only `kv-${workload}-${suffix}` → 20 chars. The module variable was renamed from `name_suffix` to `workload` with a `length() <= 16` validation. Documented as a pitfall.
- `azurerm` provider 4.x deprecated the `metric` block in `azurerm_monitor_diagnostic_setting` in favor of `enabled_metric`. Caught by `terraform validate` warnings before apply.
- `for_each` with a list containing apply-time-unknown values (group object_id) fails at plan time. Fix: the module accepts `admin_object_ids` as a **map** with static labels as keys (`"signed-in-user"`, `"aks-admin-group"`); values can be known-after-apply.

### Iteration 3 — completed
First apply attempt failed mid-way at the AKS create with `ErrCode_InsufficientVCPUQuota` (sandbox has zero quota for `DSv5` family in `westeurope`). Pivot: switched VM size to `Standard_D2s_v3` (`DSv3` family has 35 vCPUs of quota — plenty). The 2 role assignments AKS depends on (`Network Contributor` on subnet, `Managed Identity Operator` on kubelet UAMI) were created in the first attempt and persisted in state; only the cluster + user pool + diagnostic setting were recreated in the second apply (3 resources).

End state:
- Cluster `aks-globalretail-dev-weu` running on Kubernetes 1.35.4
- 2× `Standard_D2s_v3` system nodes (taint `CriticalAddonsOnly=true:NoSchedule`)
- 1× `Standard_D2s_v3` user node (autoscale 1–3)
- Network: Azure CNI Overlay + Cilium dataplane; pods on `10.244.0.0/16`, services on `10.245.0.0/16`
- Entra ID integration + Azure RBAC for Kubernetes + local accounts DISABLED + Workload Identity webhook auto-installed
- API server public + `authorized_ip_ranges = ["79.116.225.55/32"]` (operator's IP, auto-discovered via http data source)
- OIDC issuer URL published; federated credentials targeting it work end-to-end

### Smoke test — completed
Three checks, all passed:

1. **Local accounts disabled (negative test):** `az aks get-credentials --admin` was rejected with `BadRequest: Getting static credential is not allowed because this cluster is set to disable local accounts`. The hardening works.
2. **Entra ID auth + Azure RBAC for Kubernetes:** After `az aks get-credentials` (no `--admin`) + `kubelogin convert-kubeconfig -l azurecli`, `kubectl get nodes` returned 3 Ready nodes — auth via the AKS admin group membership.
3. **ACR pull without `imagePullSecrets`:** `az acr import nginx → ACR`, then `kubectl run` with the ACR-hosted image. Pod started Running with no Kubernetes Secret. The kubelet UAMI's `AcrPull` role assignment (Iter 2) is the only credential in play.
4. **Workload Identity end-to-end** (the highlight): `smoke-test/workload-identity.sh` provisions a UAMI, federates it to `default/wi-test-sa`, grants it `Key Vault Secrets User`, plants a test secret in KV, deploys a pod with the right annotation+label, and watches the pod read the secret. Pod logs:
   ```
   === ENV injected by webhook ===
   AZURE_CLIENT_ID:            <uami-client-id>
   AZURE_TENANT_ID:            <tenant-id>
   AZURE_FEDERATED_TOKEN_FILE: /var/run/secrets/azure/tokens/azure-identity-token
   === Federated login ===
   Login OK on attempt 1
   === Reading test-secret from KV ===
   SECRET VALUE: hello-from-key-vault-via-workload-identity
   === SMOKE TEST PASSED ===
   ```
   No passwords, no client secrets, no certificates. The federation flow is operational.

### Cleanup — completed (2026-05-23)
Three-step teardown, ordered so the tfstate storage account is the last thing to go (Terraform needs it until `destroy` finishes):

1. **Remove the Workload Identity smoke-test resources** (created outside Terraform):
   ```bash
   bash smoke-test/workload-identity.sh --cleanup
   ```
   Removes the test pod, ServiceAccount, federated credential, role assignment, UAMI, and the KV secret (with purge).
2. **Destroy the platform via Terraform**:
   ```bash
   terraform destroy
   ```
   Destroys AKS, ACR, KV, VNet, both UAMIs, Log Analytics, the Entra ID admin group, and the platform RG. AKS cleans up its `rg-globalretail-dev-weu-aks-nodes` infrastructure RG as part of the cluster delete.
3. **Delete the tfstate RG** (only after step 2 succeeds):
   ```powershell
   az group delete --name rg-tfstate-globalretail-weu --yes
   ```

**Verification on this build:** `az group list --query "[?contains(name,'globalretail')]"` returned empty; `az keyvault list-deleted` returned no soft-deleted vaults (the provider's `purge_soft_delete_on_destroy = true` worked); `az ad group list --display-name globalretail-aks-admins` returned empty; `az identity list` had no leftovers. Total cleanup time ~12 minutes, dominated by the AKS delete + node-RG cleanup.
