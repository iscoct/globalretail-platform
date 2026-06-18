# Layer 5 — Security / DevSecOps

> 🚧 **Status:** in progress. §6 Pitfalls is `[TBD-AFTER-BUILD]` and gets filled in once the layer is deployed end-to-end.

---

## 1. What this layer does

Hardens the platform with three independent pieces, all delivered via the Layer 3 GitOps vehicle:

- **Kyverno** — an admission controller + 4 ClusterPolicies in **Audit** mode. Validates that every pod entering the cluster declares resource limits, doesn't use `:latest`, isn't privileged, and runs as non-root. The audit results land in `PolicyReport` CRs; flipping to **Enforce** is a one-line edit per policy when ready.

- **CSI Secrets Store Driver + Azure Key Vault provider** — lets a pod mount Azure Key Vault secrets as files via Workload Identity, without ever creating a Kubernetes `Secret`.

- **A workload UAMI for sample-app** (in Terraform under `terraform/`) — a per-workload managed identity, federated to the `sample-app/sample-app` ServiceAccount, with `Key Vault Secrets User` scoped to Layer 1's vault. Plus a demo secret seeded into the vault. Layer 2's CI identities, Layer 3's pod identity, and now this workload identity are three independent UAMIs — least privilege per role.

The runtime artefact: sample-app's `/version` endpoint reads a Key Vault secret value via the mounted file and includes it in the response. End-to-end proof of "no K8s Secret, no client_secret in env, just OIDC federation".

## 2. Why it exists in production

Three problems this layer addresses that real platform teams hit early:

### 2.1 Admission control turns runtime policy into pre-deployment guarantee

Without an admission controller, "every container must have resource limits" is a wiki page someone wrote in 2022. With Kyverno, it's a CRD that rejects the pod at admission time. The rule moves from "best practice we hope someone reads" to "schema the cluster enforces."

### 2.2 K8s Secrets are not great at being secret

A K8s `Secret` is base64-encoded YAML in etcd. By default, etcd is not encrypted at rest (you have to enable KMS), and any principal with `get secret` cluster-wide RBAC sees every secret value. The CSI Secrets Store pattern keeps the source of truth in Key Vault, mounts only the specific secret(s) the pod needs, and never materialises a K8s Secret object. The blast radius of "kubectl get secrets all-namespaces" drops to whatever the cluster legitimately needs (TLS certs from cert-manager, etc.).

### 2.3 One UAMI per workload, scoped to exactly what the workload needs

Layer 1 created two AKS identities (control plane + kubelet). Layer 2 created three CI identities (app, platform-RO, platform-RW). Now Layer 5 creates a per-workload identity (sample-app). The pattern: in a production cluster running 50 microservices, you'd have ~50 workload UAMIs, each federated to its own ServiceAccount. A compromised pod can only do what its specific UAMI is allowed to do — no shared "platform" credential.

## 3. What we built

### File layout

```
security/
├── README.md                                       ← this file
├── terraform/                                      ← workload UAMI + KV access + demo secret
│   ├── versions.tf, providers.tf, variables.tf,
│   │   locals.tf, main.tf, outputs.tf
│   ├── terraform.tfvars.example
│   ├── backend.hcl.example
│   └── .gitignore
├── kyverno/
│   ├── values.yaml                                 ← Helm values for kyverno chart
│   └── policies/
│       ├── kustomization.yaml
│       ├── require-resources.yaml                  ← CPU + memory requests + limits
│       ├── disallow-latest-tag.yaml                ← :latest and tagless → reject
│       ├── disallow-privileged.yaml                ← no privileged: true or allowPrivilegeEscalation
│       └── require-runasnonroot.yaml               ← pod-level or container-level
└── secrets-store-csi/
    ├── values-driver.yaml                          ← values for the driver chart
    └── values-azure.yaml                           ← values for the Azure provider chart

gitops/applications/                                ← three new Applications
├── kyverno.yaml                                    ← chart + values + policies (multi-source)
├── secrets-store-csi-driver.yaml                   ← the K8s side
└── csi-secrets-store-provider-azure.yaml           ← the Azure-aware provider DaemonSet
```

Sample-app modifications land in a separate PR (after the Terraform + drivers are in place):
- `gitops/workloads/sample-app/base/serviceaccount.yaml` — SA carrying `azure.workload.identity/client-id`
- `gitops/workloads/sample-app/base/secret-provider-class.yaml` — SPC referencing the KV
- `gitops/workloads/sample-app/base/deployment.yaml` — adds the label `azure.workload.identity/use: "true"`, the SA, and the CSI volume mount
- `apps/sample-app/src/index.js` — `/version` reads the mounted secret and includes it

### Apply sequence (from a Layers 1–4 cluster)

```powershell
# 1. Provision the workload UAMI + fed cred + demo secret in KV.
cd security/terraform
cp terraform.tfvars.example terraform.tfvars         # edit subscription, tenant, tfstate SA
cp backend.hcl.example backend.hcl                   # edit storage_account_name
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
# Note the output `workload_identity_client_id` — you'll paste it into the SA YAML.

# 2. Commit + merge gitops/applications/{kyverno,*csi*}.yaml + this folder.
#    ArgoCD installs Kyverno + the CSI driver + the Azure provider.

# 3. After both Applications are Healthy, commit + merge the sample-app changes
#    (the ServiceAccount with the client_id you just copied + the SPC + the
#    Deployment patch). sample-app re-rolls with the mount.

# 4. Verify the secret flows through:
kubectl port-forward svc/sample-app -n sample-app 8082:80
curl http://localhost:8082/version
# expect: { "welcome_message": "hello-from-key-vault-via-workload-identity", ... }
```

### What ends up in Azure

| Resource group | Holds |
|---|---|
| `rg-security-globalretail-dev-weu` | The workload UAMI + its federated credential |
| `rg-globalretail-dev-weu` (Layer 1's RG) | A new secret `sample-app-welcome-message` in the existing Key Vault, plus a new role assignment (Key Vault Secrets User) for the workload UAMI |

### What ends up in the cluster

| Namespace | What |
|---|---|
| `kyverno` | Kyverno admission controller + background controller + cleanup controller + reports controller |
| `kube-secrets-store-csi-driver` | The CSI driver DaemonSet (one pod per node) + the Azure provider DaemonSet (one pod per node) |
| `sample-app` | A new ServiceAccount, a SecretProviderClass, and an updated Deployment that mounts the CSI volume |

## 4. Lab vs Production

| Concern | Lab (this code) | Production |
|---|---|---|
| **Policy mode** | All policies in `Audit` — existing violations land in PolicyReports, nothing is blocked | Audit during rollout, then `Enforce` once known violations are fixed; per-policy decision based on risk |
| **Webhook failurePolicy** | `Ignore` — if Kyverno crashes, admission continues unprotected | `Fail` — admission blocks when Kyverno is unavailable; requires HA Kyverno + careful rollout |
| **Kyverno replicas** | 1 of each controller | 3 admission controllers (the critical-path one), 2 of background/cleanup/reports |
| **Policy library** | 4 hand-rolled policies | The above + the [Kyverno Policy Catalog](https://kyverno.io/policies/) (~150 community-maintained policies) opted into by category; org-specific policies in their own repo |
| **Pod Security Standards alignment** | Hand-rolled rules | PSA labels (`pod-security.kubernetes.io/enforce: restricted`) at the namespace level as the FIRST line of defence; Kyverno for things PSA doesn't cover |
| **Image signing** | None | `kyverno verifyImages` rule checking cosign signatures from the CI pipeline + a Notary-style attestation chain |
| **Secret rotation** | Off (`enableSecretRotation: false` in driver values) | On (`enableSecretRotation: true`, `rotationPollInterval: 2m`). Apps that need rotation also need to be designed to re-read on file change (fsnotify) or accept a restart |
| **K8s Secret sync** | Off (`syncSecret.enabled: false`) | Off in production too — the whole point is to NOT materialise K8s Secrets |
| **Workload UAMI per app** | One: `sample-app` | Per workload + per environment. A 50-app prod cluster has 50+ UAMIs federated to 50+ ServiceAccounts |
| **KV access scope** | `Key Vault Secrets User` on the whole vault | Same role but scoped to per-secret RBAC if your secret count is small enough; otherwise per-app vaults |
| **Trivy cluster-side** | None (Trivy is in CI only — Layer 2) | The [Trivy Operator](https://aquasecurity.github.io/trivy-operator/) periodically scans running images for new CVEs that appeared after the push; emits `VulnerabilityReport` CRs |
| **Network policies** | None | Default-deny per namespace + explicit allow rules. Cilium's NetworkPolicy + L7 awareness (Layer 1 chose Cilium dataplane on purpose) |
| **Service mesh / mTLS** | None | Istio or Linkerd for mTLS between services + east-west authZ. Future Layer 6. |
| **cert-manager** | None | Installed via GitOps. Lets-Encrypt for public endpoints, internal CA for private. The Layer 4 README's "expose Grafana via Ingress + TLS" path goes through here. |
| **Backups** | None | Velero for cluster + volumes |

## 5. Key concepts the instructor must own

### 5.1 What admission control IS

A K8s **admission webhook** is an HTTPS endpoint that the API server calls *before* persisting a CREATE / UPDATE request. The webhook can ALLOW, DENY, or MUTATE the request. The API server times out the call (we set 10s) and falls back to its `failurePolicy`.

There are two kinds:
- **MutatingAdmissionWebhook** — can modify the request (e.g., inject sidecars).
- **ValidatingAdmissionWebhook** — can only allow/deny.

Kyverno registers both. The mutating part is for `mutate:` rules (we don't use any in v1); the validating part runs our `validate:` rules.

### 5.2 Audit vs Enforce + PolicyReport

Each `ClusterPolicy` has `validationFailureAction: Audit | Enforce`.
- **Audit** — failing requests still go through; Kyverno emits a `PolicyReport` CR summarising the violation. View with `kubectl get policyreport -A`.
- **Enforce** — failing requests are rejected at admission with a 4xx and the violation message.

Recommended path: Audit first → fix violations one by one → flip to Enforce → over time the cluster's PolicyReport count tends to zero.

### 5.3 ClusterPolicy vs Policy

`Policy` is namespace-scoped (only matches resources in its own namespace). `ClusterPolicy` is cluster-wide (matches via `match.resources.namespaces` selector). We use ClusterPolicy throughout — the policies are platform-team-owned and shouldn't be droppable by a team that has admin on their own namespace.

### 5.4 ServerSideApply for big CRDs

`syncOptions: [ServerSideApply=true]` on the Application. Without it, Kyverno's `ClusterPolicy` CRD (~700 KB of validation schema) trips the `metadata.annotations` 256 KB client-side apply limit. ServerSideApply moves the merge into the API server, which doesn't have the limit. We learned this in Layer 4 too (kube-prometheus-stack has the same problem).

### 5.5 CSI Secrets Store: driver + provider, two pieces

The **driver** is provider-agnostic. It implements the K8s CSI volume interface ("when a pod mounts a volume of type `secrets-store.csi.k8s.io`, here's how"). It doesn't know how to talk to any secret store on its own — it forwards the call to a **provider** that runs as a sidecar/DaemonSet on each node.

The **Azure provider** is what makes "secret from Azure Key Vault" work. It runs as its own DaemonSet, exposes a Unix socket on each node, and the driver calls it when a pod with an Azure-flavoured SecretProviderClass requests a mount.

Both DaemonSets land in `kube-secrets-store-csi-driver` (the chart's default namespace).

### 5.6 SecretProviderClass — the only K8s resource that's secret-store-specific

A `SecretProviderClass` is a namespaced CRD with three things in it:
- `provider: azure`
- `parameters: { keyvaultName, tenantId, ... }` — which Key Vault, which tenant
- `parameters.objects` — a list of which secrets/keys/certs to mount and what filename they get inside the volume

The pod's volume references the SPC by name. The driver reads it, calls the provider, the provider authenticates to Azure (via Workload Identity), pulls the secrets, and the driver writes them to a tmpfs that becomes the volume.

### 5.7 Workload Identity federation: the subject mapping

We have THIS chain on the wire:
1. The pod's ServiceAccount is annotated with `azure.workload.identity/client-id: <UAMI-client-id>`.
2. The pod is labelled with `azure.workload.identity/use: "true"`.
3. The AKS Workload Identity webhook (auto-installed since Layer 1's `workload_identity_enabled = true`) injects:
   - Env vars `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`
   - A projected ServiceAccount token mounted at `AZURE_FEDERATED_TOKEN_FILE`
4. The Azure SDK (or in our case the CSI provider) calls Entra ID's STS endpoint with the projected token. The token's `sub` claim is `system:serviceaccount:<ns>:<sa>`.
5. Entra ID checks its federated credentials for the requested UAMI. It looks for one matching:
   - `issuer = <AKS OIDC issuer URL>`
   - `audience = api://AzureADTokenExchange`
   - `subject = system:serviceaccount:<ns>:<sa>`
6. Match → Entra ID issues an access token scoped to the UAMI. The provider uses that token to talk to Key Vault. KV's RBAC says "this UAMI has Key Vault Secrets User" → returns the secret value.

Mess up ANY of those: typo in the SA name, wrong namespace, wrong issuer URL, missing federated credential → silent 401 or "permission denied". The debugging trick is `kubectl describe pod` → look at the WI webhook's annotations and env vars; if they're missing the label didn't take.

### 5.8 The image is pulled by a DIFFERENT identity than the secrets

Worth being explicit about: the **kubelet UAMI** (Layer 1) pulls images from ACR. The **workload UAMI** (Layer 5) authenticates to KV. They are different UAMIs with different scopes. Two reasons:
- Image pull happens at pod create time, before any pod-level identity has been established. Kubelet has to use ITS identity to pull.
- The workload UAMI doesn't need ACR access (and shouldn't have it).

If the kubelet UAMI's `AcrPull` ever gets revoked, image pulls fail with `ImagePullBackOff` — separate failure mode from "can't read the secret".

### 5.9 Rotation is not transparent to apps

`enableSecretRotation: true` on the driver means: every `rotationPollInterval`, the driver re-fetches the secret from KV and atomically swaps the file in the mount. The app's mount continues to work, the file content changes.

But: most apps read secrets ONCE at startup, into memory, and never look again. They won't see the rotation until you restart them. Apps that DO see rotations either:
1. Use a file watcher (Node's `fs.watch`, Go's `fsnotify`) to re-read on change.
2. Use a "config reloader" sidecar that signals the app via SIGHUP / API call.
3. Are designed to fail fast on auth errors and let K8s restart them.

The reflexive answer "of course rotation works" is mostly wrong. Specifically what an app does on rotation has to be designed in.

### 5.10 Per-workload UAMIs scale by convention, not by tooling

We have, after Layer 5, six UAMIs total:
- 2 from Layer 1 (AKS control plane + kubelet)
- 3 from Layer 2 (app, platform-RO, platform-RW)
- 1 from Layer 5 (workload sample-app)

In a 50-workload production cluster you'd have ~60. There is no built-in K8s primitive that creates a UAMI when you create a ServiceAccount — the binding is by convention. Platform teams typically wrap this in either:
- A Crossplane / Terraform module per workload (declarative)
- A CLI that wraps `az` + `kubectl` + cert generation (imperative)

We document the per-workload-UAMI pattern via Terraform; what we don't do (yet) is automate the generation. Doing so is a Layer 6+ concern.

## 6. Pitfalls and gotchas

Six pitfalls hit during the 2026-05-25 / 2026-05-26 end-to-end run.

### 6.1 Kyverno policy `validate.message` cannot reference `{{element.name}}` outside `foreach`
**Symptom:** Kyverno's admission webhook rejects the policy at apply time with
`'element.name' present outside of foreach at path /validate/message`.
**Cause:** The `message:` field at `spec.rules[].validate.message` is only used when `foreach` is NOT in play. When you use `foreach`, the message has to live INSIDE the foreach block — because `element` is only defined inside the loop.
**Fix:** Move the `message:` field into each `foreach[]` element. Or remove the top-level message (Kyverno's default error text still names the policy + rule, useful enough for the lab).

### 6.2 Kyverno's defaulting webhook fills in spec fields → ArgoCD sees endless drift
**Symptom:** After installing Kyverno + ClusterPolicies, the `kyverno` Application stays `OutOfSync` forever. Every refresh shows the policies as drifted.
**Cause:** Kyverno's defaulting webhook fills in `spec.admission: true`, `spec.emitWarning: false`, per-rule `skipBackgroundRequests: true`, and `validate.allowExistingViolations: true` on every ClusterPolicy after our YAML is applied. ArgoCD then diffs "what's in git (no field)" vs "what's in cluster (field set)", sees a delta, marks OutOfSync, and selfHeal tries to remove the field → Kyverno re-injects it → loop.
**Fix:** Add `ignoreDifferences` to the kyverno Application for those specific jq paths + `RespectIgnoreDifferences=true` in syncOptions so selfHeal honours the ignore list:
```yaml
ignoreDifferences:
  - group: kyverno.io
    kind: ClusterPolicy
    jqPathExpressions:
      - .spec.admission
      - .spec.emitWarning
      - .spec.rules[].skipBackgroundRequests
      - .spec.rules[].validate.allowExistingViolations
syncOptions:
  - RespectIgnoreDifferences=true
```

### 6.3 Distroless `nonroot` user + Kyverno `require-runasnonroot` audit warning
**Observation:** Even though the sample-app's deployment sets `runAsNonRoot: true` and `runAsUser: 65532` at the CONTAINER securityContext level, the `require-runasnonroot` policy still emits PolicyViolation warnings against the pod. The policy looks for `spec.securityContext.runAsNonRoot` at the POD level (or every initContainer too).
**Cause:** The policy's `anyPattern` uses two patterns: pod-level OR ALL containers including initContainers. We set it only on the container, and we have no initContainers, so the second pattern's `initContainers: [{...}]` matches "must exist with these properties" — but we have no initContainers, so the pattern fails. The first pattern wants `pod-level securityContext.runAsNonRoot` which we don't set.
**Fix:** In Audit mode this is informational, not blocking — PolicyReports get emitted. For Enforce mode either (a) add the field to the pod-level `spec.securityContext`, or (b) tighten the policy's anyPattern. We left it as-is for the lab because the violation is exactly the kind of "Audit caught a real misconfiguration" example we want students to see.

### 6.4 CodeQL flagged a test using `Date.now()` for a temp filename
**Symptom:** PR 20 (sample-app `/version` reads secret) blocked from merge with a "CodeQL / Insecure temporary file" review comment on the test that did `path.join(os.tmpdir(), \`welcome-message-${Date.now()}\`)`.
**Cause:** `Date.now()`-derived temp paths are predictable. CodeQL's `js/insecure-temporary-file` rule flags them because an attacker who can write to /tmp could pre-create a symlink at the predictable path, hijacking the file.
**Fix:** Use `fs.mkdtempSync(prefix)` which creates a directory with a kernel-randomised suffix and 0700 perms before returning the path — no TOCTOU window. The fix is a one-line change but worth noting: even test code that touches /tmp gets scanned, and the fix is the same as for production code.

### 6.5 Trivy SARIF alerts persist in the GitHub Security tab even with `.trivyignore` in CI
**Symptom:** PR 20 was blocked by a "CodeQL" status check showing "1 high severity security vulnerability" (and more). The alerts were the libssl3 OS CVEs we documented in Layer 2 (`cicd/README.md §6.2`) and explicitly ignored in `apps/sample-app/.trivyignore`.
**Cause:** Our two-step Trivy flow (cicd/README.md §6.3) splits scan into "SARIF upload (no gate)" and "table-format gate (with ignorefile)". The SARIF upload step honours severity filtering but NOT `.trivyignore` — by design, because the Security tab is supposed to show ALL findings. So the alerts always show up in the Security tab, and GitHub's branch-protection-friendly "CodeQL" status check goes RED when any unresolved alerts are present on the PR's introduced code.
**Fix:** Dismiss the alerts via the code-scanning API with `state=dismissed`, `dismissed_reason="won't fix"`, and a comment linking to the Trivy ignore (`gh api PATCH .../alerts/<n> --field state=dismissed ...`). After dismissal, push a fresh commit (or rerun the workflow) so the CodeQL status check re-evaluates — it doesn't refresh automatically.

### 6.6 SecretProviderClass needs explicit `clientID` to use Workload Identity
**Symptom:** Pod stuck in `ContainerCreating` with
`MountVolume.SetUp failed for volume "secrets-store": ... failed to build auth config for mode None: failed to get credentials, nodePublishSecretRef secret is not set`
**Cause:** The Azure CSI Secrets Store provider does NOT auto-detect Workload Identity from the pod's ServiceAccount annotation. The `azure.workload.identity/client-id` annotation tells the WI webhook what UAMI to inject env vars for, but the CSI provider treats authentication mode as a SecretProviderClass parameter — and "no parameter → mode None → can't authenticate".
**Fix:** Add `clientID: <workload-uami-client-id>` to the SecretProviderClass `parameters` block. Same value as the SA annotation.

### 6.7 CSI Secrets Store Driver needs `tokenRequests` audience for Workload Identity
**Symptom:** After fixing 6.6, the mount failed with a different error:
`failed to parse workload identity tokens, error: service account tokens not found`
**Cause:** The CSI driver and the Azure provider live in DIFFERENT pods (separate DaemonSets). When the driver mounts a volume for a workload pod, it needs to *forward* the workload pod's projected SA token to the provider — but only if the driver has been configured to request tokens for that audience via its `tokenRequests` setting. Without it, the driver doesn't request the token, the provider has nothing to authenticate with.
**Fix:** Add to the driver's Helm values:
```yaml
tokenRequests:
  - audience: api://AzureADTokenExchange
```
After re-applying the chart, the CSIDriver resource (a cluster-scoped K8s object) gets `spec.tokenRequests` populated. The audience MUST be exactly `api://AzureADTokenExchange` — the same audience the workload UAMI's federated credential matches on.

### 6.8 ArgoCD schema-diff error on the CSIDriver `spec.serviceAccountTokenInSecrets` field
**Symptom:** After 6.7 ships, the `secrets-store-csi-driver` Application's status goes to `Unknown` with
`Failed to compare desired state to live state: failed to calculate diff: error building typed value from config resource: .spec.serviceAccountTokenInSecrets: field not declared in schema`
**Cause:** The CSIDriver K8s resource has a `spec.serviceAccountTokenInSecrets` field that varies by Kubernetes version. ArgoCD's cached OpenAPI schema disagrees with what the chart renders, and the structured-merge-diff library refuses to compute a diff for an unknown field.
**Fix (workaround):** Add `Replace=true` to the Application's syncOptions. That makes ArgoCD use `kubectl replace` semantics for the resource, bypassing the typed-diff path. The Application may still show `Unknown` because the diff *display* still fails — but the apply itself succeeds. The CSIDriver is functional regardless of ArgoCD's diff status.
**Fix (cleaner):** kubectl-patch the CSIDriver directly to add `spec.tokenRequests` while accepting the ArgoCD diff failure as cosmetic. The Application stays `Unknown` but the runtime state is correct. This is the operational reality of running ArgoCD against fast-moving upstream CRDs/resources.

## 7. Likely student questions and answers

**Q: Why Kyverno and not OPA Gatekeeper?**
A: Both are CRD-based admission controllers backed by the K8s API. The split:
- **Gatekeeper** uses Rego (a declarative query language) for policy expression. Powerful, harder to read.
- **Kyverno** uses YAML — policies look like K8s manifests. Easier to read, slightly less expressive.

For a teaching reference architecture the YAML readability tips the balance to Kyverno. For a company with an existing OPA investment (REST APIs already enforced by Rego), Gatekeeper makes sense. Both are CNCF-graduated.

**Q: Why Audit instead of Enforce from day one?**
A: The cluster already has running workloads (kube-prometheus-stack from Layer 4, ArgoCD from Layer 3) that violate at least one policy each. Enforce-from-day-one would either:
- Block new pods of those workloads when they restart → cluster degrades
- Force us to add exclusions immediately, defeating the policy's purpose

Audit gives us PolicyReports to discuss in class ("look, KPS has 8 containers without limits!") and lets us add policies one by one as we fix the violations.

**Q: What happens to existing K8s Secrets I have?**
A: They keep working — CSI Secrets Store is additive, not a replacement that automatically migrates anything. Migration is per-workload: change the workload's volume from `secret:` to `csi:`, point it at a SPC, delete the old Secret once everything is rolled. Some teams use the `syncSecret` driver feature during transition (creates a K8s Secret from the mounted file for backwards compatibility with legacy apps that need `valueFrom.secretKeyRef`). We deliberately have `syncSecret: false` because the lab's path is "new app, do it right from day one".

**Q: Can the workload UAMI access other secrets in the same Key Vault?**
A: With the role assignment as we configure it (`Key Vault Secrets User` on the whole vault scope): **YES**. It can read EVERY secret in the vault, not just `sample-app-welcome-message`. To scope tighter you either:
- Create a per-app Key Vault (cleanest, what most prod teams do).
- Use Key Vault's secret-level RBAC (preview at the time of writing — works but operationally fiddly).
- Use Azure ABAC (Attribute-Based Access Control) conditions on the role assignment — works but tied to label conventions.

For the lab, vault-scope is fine because the only secret in there is the demo one. Document the production fix.

**Q: Why do I need a federated credential when AKS already has Workload Identity enabled?**
A: AKS's `workload_identity_enabled = true` flag turns ON the webhook that injects the projected token into pods. It does NOT create any Entra ID trust relationships. The federated credential is the Entra ID side of the trust: "Entra ID, trust tokens from THIS issuer with THIS subject as proof that the holder is this UAMI". Without it, the pod gets a projected token but Entra ID has no idea what to do with it (`AADSTS70021: No matching federated identity record found`).

**Q: Can sample-app's CSI provider use the same workload UAMI to pull images?**
A: No, and you don't want it to. Image pulls happen during pod creation, by the kubelet, BEFORE the pod-level identity exists. Kubelet uses ITS UAMI (Layer 1's kubelet identity), which has `AcrPull`. The workload UAMI is for runtime — KV access, blob storage, downstream Azure services. The two paths never overlap.

**Q: What if my app needs the secret as an environment variable, not a file?**
A: Three options, none of them as clean as "just read the file":
1. Use the driver's `syncSecret` feature to ALSO create a K8s Secret from the mounted file. Then your Deployment's `envFrom.secretRef` picks it up. You're back to having a K8s Secret object — the whole thing you were trying to avoid. Sometimes acceptable for legacy apps.
2. Write an initContainer that `cat`s the file and writes it to a shared `emptyDir`, then your app reads from there. Convoluted.
3. Change the app. Honestly the right answer — files-as-secrets is the modern pattern and lets you mount certs as multiple files.

**Q: Are PolicyReports also reconciled by ArgoCD?**
A: No. PolicyReports are emitted BY Kyverno; they aren't part of the desired state in git. They're cluster facts. ArgoCD doesn't care.

**Q: My pod is failing to mount the CSI volume with "kubeletauth failed". Why?**
A: 90% of the time, the pod's ServiceAccount doesn't have the `azure.workload.identity/client-id` annotation, OR the pod doesn't have the `azure.workload.identity/use: "true"` label. The webhook only injects the token if BOTH are present. Verify with `kubectl describe pod` — there should be `env` entries for `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`. If those are missing, the labels/annotations don't match.

**Q: How do I rotate the secret without restarting sample-app?**
A: Today, you can't — `enableSecretRotation: false` in our values. To turn it on:
1. Edit `security/secrets-store-csi/values-driver.yaml`, set `enableSecretRotation: true`.
2. Commit + merge → ArgoCD upgrades the driver.
3. Update the secret in KV (`az keyvault secret set ...`).
4. Within `rotationPollInterval` the mounted file's content changes.
5. sample-app re-reads the file on every `/version` request (it doesn't cache), so the response updates immediately — without a restart.

If your app caches at startup, see §5.9.

## 8. References

### Kyverno
- [Kyverno docs](https://kyverno.io/docs/)
- [Kyverno policy library](https://kyverno.io/policies/) — community-maintained policy catalog
- [JMESPath for Kyverno](https://kyverno.io/docs/writing-policies/jmespath/) — the query language used in policy expressions
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) — the K8s-side complement (Restricted profile labels at the namespace level)

### CSI Secrets Store + Azure
- [Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io/)
- [Azure Key Vault Provider](https://azure.github.io/secrets-store-csi-driver-provider-azure/)
- [AKS Workload Identity overview](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [`SecretProviderClass` reference](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-identity-access)

### Adjacent / future work
- [cosign + Kyverno verifyImages](https://kyverno.io/docs/writing-policies/verify-images/) — image signing verification at admission
- [Trivy Operator](https://aquasecurity.github.io/trivy-operator/) — cluster-side image scanning
- [cert-manager](https://cert-manager.io/) — TLS automation
- [Cilium Network Policies](https://docs.cilium.io/en/stable/security/policy/) — L3/L4/L7 network policy; Layer 1 chose Cilium dataplane

---

## Build progress

- [x] Iteration 1: code drafted (Terraform + Kyverno values + 4 policies + CSI driver values + 3 Applications)
- [x] Iteration 2: PR 17 — security/terraform/ applied (workload UAMI + fed cred + KV secret); Kyverno + CSI Applications converged
- [x] Iteration 3: PR 20 — sample-app SA + SPC + Deployment change; /version returns the KV secret via Workload Identity
- [x] §6 Pitfalls filled (8 hit during the end-to-end run)
- [ ] Iteration 4: teardown verification
- [ ] Demo prepared for class

## Iteration log

### Iteration 1 — code drafted (2026-05-25)
Wrote `security/terraform/` (workload UAMI + federated credential targeting `sample-app/sample-app` + Key Vault Secrets User on Layer 1's KV + demo secret). Wrote `security/kyverno/values.yaml` + 4 ClusterPolicies (in Audit mode). Wrote `security/secrets-store-csi/values-driver.yaml` + `values-azure.yaml`. Wrote 3 new ArgoCD Applications. Sub-README §1–§5, §7, §8.

### Iteration 2 — PR 17, security infra (2026-05-25)
- `terraform apply` in security/terraform/: 5 resources (RG, UAMI, federated credential, KV role assignment, KV secret).
- `workload_identity_client_id` output noted: `62cc370a-e14b-4f32-8b20-e22d9acd2944`.
- PR 17 merged. Pitfall 6.1 (Kyverno foreach.message) discovered + fixed via PR 18.
- Pitfall 6.2 (Kyverno defaulting webhook drift) discovered + fixed via PR 19 (added ignoreDifferences).
- Kyverno + secrets-store-csi-driver + csi-secrets-store-provider-azure all Applications converged Healthy. ClusterPolicies all `Ready: True`. The 4 audit policies emit PolicyReports against kube-prometheus-stack, ArgoCD, and (later) sample-app — exactly the "audit caught real violations" pedagogical moment.

### Iteration 3 — PR 20, sample-app wiring (2026-05-26)
- Modified `gitops/workloads/sample-app/base/`: added serviceaccount.yaml + secret-provider-class.yaml, updated deployment.yaml (label + SA + CSI volume mount), updated kustomization.yaml.
- Modified `apps/sample-app/src/index.js`: read `/mnt/secrets/welcome-message` at request time, return in `/version`. Added 4 tests (10 total, 100% statements).
- PR 20 blocked by pitfall 6.4 (CodeQL flagged `Date.now()` temp filename) and pitfall 6.5 (stale Trivy alerts in Security tab blocking the merge gate). Fixed test + dismissed alerts via the code-scanning API.
- Pitfall 6.6 (missing `clientID` in SPC) discovered + fixed via PR 21.
- Pitfall 6.7 (missing `tokenRequests` on CSI driver) discovered + fixed via PR 22 (chart values) + direct CSIDriver patch (since ArgoCD's diff failed due to pitfall 6.8).
- Pitfall 6.8 (ArgoCD schema-diff error on CSIDriver field) discovered. Workaround: `Replace=true` syncOption + direct kubectl-patch. CSI driver Application remains `Unknown` in ArgoCD UI; the runtime state is correct.

**End-to-end test verified:**
```
curl http://localhost:8082/version
{
  "name": "globalretail-sample-app",
  "version": "dev",
  "commit": "unknown",
  "welcome_message": "hello-from-key-vault-via-workload-identity"
}
```
The entire chain works: pod's projected SA token → CSI driver requests it via TokenRequest API → Azure provider receives token + SPC clientID → Entra ID STS exchanges for workload UAMI's access token → Key Vault RBAC (`Key Vault Secrets User`) → secret value → file in /mnt/secrets/ → JSON response. Zero K8s Secret, zero client_secret, pure OIDC federation.

**State at end of iteration 3:**
- 6 ArgoCD Applications (root, sample-app, observability, kyverno, secrets-store-csi-driver, csi-secrets-store-provider-azure). Two carry diff issues that are functionally harmless (kyverno OutOfSync briefly during sync attempts, secrets-store-csi-driver Unknown forever — both documented above).
- Kyverno admission webhook running, 4 ClusterPolicies in Audit. PolicyReports queryable via `kubectl get policyreport -A`.
- CSI Secrets Store Driver + Azure provider DaemonSets healthy on each node; tokenRequests configured for the WI audience.
- sample-app pods running with the CSI mount, serving the welcome_message from Key Vault.
- Six total UAMIs in the subscription: AKS control plane + kubelet (Layer 1), CI app + CI platform-RO + CI platform-RW (Layer 2), and the sample-app workload UAMI (Layer 5). Each scoped to least privilege.
