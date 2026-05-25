# Layer 3 — GitOps with ArgoCD

> 🚧 **Status:** in progress. §6 Pitfalls is `[TBD-AFTER-BUILD]` and gets filled in after the first end-to-end run breaks-and-fixes the model in practice.

---

## 1. What this layer does

This layer introduces **GitOps as the deployment model** for everything that runs on the cluster. After this layer, no human (and no CI pipeline) ever runs `kubectl apply` against `aks-globalretail-dev-weu`. The cluster's state is whatever Git says it is — full stop.

Concretely:

- **ArgoCD installed on AKS** via Helm, lab-shaped (single instance, ClusterIP, no SSO).
- **App-of-apps pattern**: a single root `Application` watches `gitops/applications/` and auto-creates a sub-Application for every YAML found there.
- **Sample-app workload** deployed via Kustomize: `base/` (env-agnostic shape) + `overlays/dev/` (image rewrite to ACR, dev-specific labels).
- **Auto-sync + self-heal + prune** policies turned on, so manual `kubectl edit` is reverted and removed resources are cleaned up automatically.

The runtime artefact: sample-app pods running in the `sample-app` namespace, pulling images from the ACR built by Layer 2's pipeline, with the cluster's actual state continuously reconciled to `gitops/` in this repo.

## 2. Why it exists in production

Three problems GitOps solves at production scale:

### 2.1 The cluster is auditable

In a non-GitOps cluster, "what's running and why" lives in shell history, Slack messages, and the memory of whoever was on call. After incidents, "I think someone updated the deployment manually two months ago" is a real sentence. With GitOps, the cluster state IS the git tree. Want to know why pod `sample-app-abc` runs with `replicas: 2`? `git blame gitops/workloads/sample-app/base/deployment.yaml`.

### 2.2 Rollback is `git revert`

When a deployment goes bad in a kubectl-driven world, the rollback path is "redeploy the previous chart version + manually undo any companion changes." In GitOps, rollback is `git revert <bad-commit>` + push. ArgoCD reconciles back. No special tooling. The same workflow used for code is used for infra.

### 2.3 The cluster fights drift instead of accumulating it

Real clusters drift. Someone fixes a P0 with `kubectl edit deployment` and forgets to commit. Two months later, the same fix has to be re-discovered. With `selfHeal: true`, ArgoCD reverts manual changes within minutes — the kubectl-edit fix breaks loudly and immediately, forcing the operator to land the fix in git instead.

These three properties are independent of ArgoCD specifically — Flux gives you the same model. The choice between them is mostly culture/team-fit. We picked ArgoCD because of the UI (visual differs for ops review) and the app-of-apps pattern that fits the "platform + multiple workloads" shape of this reference architecture.

## 3. What we built

### File layout

```
gitops/
├── README.md                                  ← this file
├── bootstrap/
│   ├── install-argocd.ps1                     ← one-time: helm install ArgoCD + apply root-app
│   ├── values-argocd.yaml                     ← lab-shaped Helm values
│   └── README.md
├── root-app.yaml                              ← THE seed: an Application that watches applications/
├── applications/
│   └── sample-app.yaml                        ← discovered by root; manages the workload
└── workloads/
    └── sample-app/
        ├── base/
        │   ├── kustomization.yaml
        │   ├── namespace.yaml
        │   ├── deployment.yaml                ← 2 replicas, distroless securityContext, probes on /health
        │   └── service.yaml                   ← ClusterIP on port 80 → pod 3000
        └── overlays/
            └── dev/
                └── kustomization.yaml         ← rewrites image to ACR, sets namespace, adds env label
```

### Apply sequence (from a clean cluster)

```powershell
# Prereqs:
#   - Layer 1 applied (AKS cluster, ACR with the sample-app image)
#   - Layer 2 applied (or at least app-ci has pushed an image to ACR with the
#     :main tag — required for sample-app pods to actually start)
#   - az, helm, kubectl, kubelogin installed and on PATH

# 1. One-shot install
cd gitops/bootstrap
.\install-argocd.ps1

# 2. Watch the root app discover the child apps and start syncing
kubectl get applications -n argocd -w

# 3. Confirm sample-app pods are Running
kubectl get pods -n sample-app

# 4. Access the ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:80
# open http://localhost:8080, login as admin + the password printed by the script
```

### What ends up in the cluster

| Namespace | What |
|---|---|
| `argocd` | ArgoCD itself (server, controller, repo-server, redis) + the `root` Application + the `sample-app` Application |
| `sample-app` | Deployment (2 pods), Service, Namespace |

### What downstream layers consume

Nothing yet from this layer's outputs in the strict sense. Layer 3 is the *vehicle* that subsequent layers ride on:

- Layer 4 (monitoring) will install kube-prometheus-stack the same way: a new Application file under `gitops/applications/`. ArgoCD takes care of the rest.
- Layer 5 (security) will install Kyverno + cert-manager + secrets store driver via more Applications.
- Future workloads (real GlobalRetail microservices) follow the same `gitops/workloads/<name>/` convention.

## 4. Lab vs Production

| Concern | Lab (this code) | Production |
|---|---|---|
| **ArgoCD install** | Helm + a one-shot PowerShell script | Same, but the script ships in a wider platform CLI; or `argocd-autopilot` to lay out the repo structure conventionally |
| **Exposure** | ClusterIP + `kubectl port-forward` | LoadBalancer behind a WAF, fronted by an ingress with cert-manager and a real cert; access via SSO only |
| **Auth** | Local `admin` user + bootstrap password | Dex with Entra ID/Okta/Google as upstream IdP; the local `admin` is disabled (`admin.enabled: false`) the moment SSO works; per-team RBAC via ArgoCD Projects |
| **TLS** | Off (`server.insecure: true`) | On, with cert-manager + Let's Encrypt or the org's internal CA |
| **HA** | Single replica each of server, controller, repo-server, redis | 2+ replicas of server + controller; Redis Sentinel or Redis Cluster (`redis-ha.enabled: true`); the application controller sharded by app (`controller.replicas: 3` with `ARGOCD_CONTROLLER_REPLICAS`) |
| **Repo auth** | None — this repo is public | GitHub App or SSH deploy key for private repos; the credentials live in a `repository` Secret in `argocd` namespace |
| **Projects** | Single `default` project | Per-team Projects with `sourceRepos` and `destinations` whitelists; prevents team A from accidentally deploying team B's workloads |
| **Sync policy** | `auto + prune + selfHeal` everywhere | Same for non-prod; for prod often `auto + prune` but **without** selfHeal (require explicit human-driven syncs into prod) |
| **Notifications** | Off | argocd-notifications wired to Slack/Teams on sync failures + health degradations |
| **Image tag strategy** | Mutable `:main`, no PR loop | Immutable `:sha-<sha>` tags. Either (a) CI opens a PR that updates the kustomization with the new SHA — full audit, OR (b) ArgoCD Image Updater polls the registry and writes back to git. See Q in §7 for the trade-off. |
| **Number of environments** | Just `dev` (one overlay) | `dev` / `staging` / `prod` as separate Applications targeting separate clusters (or at least separate namespaces with stricter NetworkPolicies) |
| **AppSets** | Not used (one workload) | `ApplicationSet` resources with cluster generators or list generators that fan out 1 manifest into N Applications across N clusters. This is what "deploy app X to all 4 region clusters" looks like at scale. |
| **Resource quotas** | None | Per-namespace `ResourceQuota` and `LimitRange` so a runaway workload can't starve the cluster |
| **Drift detection cadence** | Default (3 min) | Often tightened to 1 min for prod; or `webhook` mode where ArgoCD reacts to git push events instantly via a GitHub webhook |
| **Backup** | None | velero of `argocd` + `sample-app` namespaces; or rely on the fact that git IS the backup |

## 5. Key concepts the instructor must own

### 5.1 What GitOps actually is

Three properties, all required:

1. **Declarative.** The desired state is described, not the steps to reach it. YAML, not bash.
2. **Versioned in git.** The full history of changes is the git log. Reviews happen via PR.
3. **Pulled, not pushed.** An agent INSIDE the cluster reads the git repo and applies the diff. The CI pipeline never touches the cluster directly — it pushes to git, ArgoCD pulls from git.

The third property is what separates GitOps from "we ship via CI." Push-based CI deployments still work, but every CI runner with deploy creds is a credential to steal. Pull-based eliminates this — the cluster reaches OUT to git (read-only); the outside never reaches INTO the cluster.

### 5.2 ArgoCD's moving parts

- **argocd-server** — REST/gRPC API + the web UI. Stateless. Talks to controller and repo-server.
- **argocd-application-controller** — the sync engine. Reads Applications, compares git state to cluster state, applies diffs. The thing that actually drives the reconciliation loop.
- **argocd-repo-server** — clones git repos and materialises them (`kustomize build`, `helm template`). Stateless. The controller talks to it instead of running git/helm/kustomize itself, so a malicious manifest can't escape into the controller's process.
- **redis** — job queue + cache for the controller.
- **argocd-dex-server** — OIDC proxy for SSO. Off in the lab; required in production.

The controller and the repo-server are the load-bearing pieces. Server is "just" the UI.

### 5.3 App-of-apps

A regular ArgoCD Application points at a folder of K8s manifests and applies them. An **app-of-apps** points at a folder of **Application resources** and applies them — ArgoCD then notices the new Applications and reconciles them in turn. One level of indirection that gives you:

- **Adding a workload becomes a 5-line YAML file in `gitops/applications/`.** No `kubectl apply`. No bootstrap-specific tooling.
- **Removing a workload is `git rm`.** The Application's finalizer cleans up cluster resources.
- **The "root" Application IS the cluster.** A `kubectl apply -f root-app.yaml` on a clean cluster recreates everything reachable from git.

This pattern scales until you have hundreds of apps; at that point ApplicationSets are the next step (one ApplicationSet generates N Applications from a list/cluster/git generator).

### 5.4 Sync, prune, selfHeal — three independent levers

- **sync** — apply git to cluster. `automated: {}` enables auto-sync; without it, syncs are manual ("Sync" button).
- **prune** — when a resource is REMOVED from git, also remove it from the cluster. Without prune, deletions are no-ops; cluster grows.
- **selfHeal** — when a resource is MUTATED out-of-band in the cluster (`kubectl edit`), revert to what git says. Without selfHeal, drift accumulates.

Lab default: all three on. Production: `selfHeal` is sometimes off in prod to avoid surprising on-call (drift gets ticketed instead of auto-reverted), but mostly stays on as a deliberate forcing function.

### 5.5 Kustomize base + overlay (vs Helm)

The base (`gitops/workloads/sample-app/base/`) is the env-agnostic shape: a Deployment, a Service, a Namespace. The overlay (`overlays/dev/`) layers env-specific changes on top via either:

- **`images:` transformer** (rewrites image references — what we use)
- **`patches:` / `patchesStrategicMerge`** (overrides arbitrary fields)
- **`replicas:`** (scales)
- **`labels:` / `annotations:`** (adds metadata)

The result of `kustomize build overlays/dev` is plain YAML — exactly what ArgoCD applies.

When to reach for **Helm instead of Kustomize**: when the workload itself ships as a chart (Prometheus, cert-manager), use Helm. When the workload is yours, Kustomize is simpler and avoids the template-language tax. Most platform teams end up using BOTH: Helm for third-party, Kustomize for own apps. ArgoCD supports both natively.

### 5.6 Mutable vs immutable image tags — the most important pedagogical point in this layer

The base manifest says `image: globalretail/sample-app:placeholder`; the overlay rewrites it to `acrglobalretaildevweu389ce1.azurecr.io/globalretail/sample-app:main`. The `:main` tag is **mutable** — `app-ci.yml` pushes a new image to it on every push to main.

Consequences:
- The git manifest never changes when a new version ships → `kustomize build` output is identical → ArgoCD sees no diff → no roll.
- A pod that restarts (for any reason) pulls the latest digest → silently runs a different version than its sibling pods.

This is fine for a lab where the only goal is "do pods come up?" In production it's banned. The right pattern there:

1. **Auto-PR from CI.** Every push to main of app-ci.yml that produces an image also opens a PR against this repo updating `newTag:` to the new SHA. The merge to main triggers an ArgoCD sync that rolls the deployment with full audit ("commit X was the deploy of image Y at time Z"). Implementation: a few lines of `sed` + `git push` + `gh pr create` in app-ci, plus a tweak to branch protection to allow the github-actions bot.

2. **ArgoCD Image Updater.** A separate controller polls the registry. When a new image matching a policy (`update-strategy: latest`) appears, it writes back to git (commits to a branch, or directly to main with an SSH key). ArgoCD then reconciles. Less code in CI, more complexity in the cluster.

Lab choice + documentation > production-quality but distracting work for a single workload. Move to (1) when there are real release deliveries to track.

### 5.7 ArgoCD authenticates to the cluster as itself

ArgoCD pods run with a ServiceAccount (`argocd-application-controller`) that the chart grants `ClusterRole/argocd-application-controller` — essentially cluster-admin. There's no kubeconfig, no out-of-cluster service principal. The "what can ArgoCD do?" question reduces to "what does its SA's ClusterRole allow?" Production setups scope this down via `additionalProjectDestinations` and per-Project RBAC.

### 5.8 ArgoCD authenticates to git as nobody (for public repos)

Because `iscoct/globalretail-platform` is a public repo, ArgoCD just clones it anonymously. For a private repo, you create a `Secret` in the `argocd` namespace with a deploy key or GitHub App credentials, labelled `argocd.argoproj.io/secret-type: repository`. ArgoCD picks it up automatically. This is also how you give ArgoCD access to enterprise GitHub or self-hosted Gitea.

### 5.9 The "first sync" race that doesn't bite us — but could

When the root Application is first applied, it discovers `gitops/applications/sample-app.yaml`. It then creates the sample-app Application. But sample-app expects the `sample-app` namespace to exist (a namespace is one of its resources). The first sync would race: create the Namespace, then try to apply namespaced resources at the same time → "namespaces sample-app not found" errors.

ArgoCD's `CreateNamespace=true` syncOption handles this by ensuring the namespace exists before any namespaced resource lands. We set it explicitly. Without it, the workload would still converge eventually (after a few retries), but the first sync UI would show alarming red errors that confuse operators.

### 5.10 ArgoCD self-management (the next step we did NOT take)

The ultimate GitOps move is for ArgoCD to manage *itself*: a `gitops/applications/argocd.yaml` Application that points at a kustomized version of `bootstrap/values-argocd.yaml`. Then changes to ArgoCD's config land via PR, not via a `helm upgrade` from your laptop.

We don't do this in this iteration because (a) the values file currently includes secrets-shaped fields (admin password seed) that need a different vehicle, (b) the bootstrap script is already idempotent so the cost of re-running it on changes is low, and (c) it adds a meaningful layer of complexity to a lab. Future iteration.

## 6. Pitfalls and gotchas

`[TBD-AFTER-BUILD]` — filled in after the first end-to-end run reveals what breaks.

## 7. Likely student questions and answers

**Q: Why ArgoCD and not Flux?**
A: Both work. Flux is closer to "GitOps as a kernel" (a small set of CRDs + reconcilers); ArgoCD is closer to "GitOps as a platform" (UI, SSO, Projects, RBAC, AppSets, image-updater all in one). Picking is a culture/team-fit question. Teams that prefer minimal tooling + heavy customisation go Flux; teams that want a ready-made platform that ops can use without `kubectl` go ArgoCD. The reference architecture goes ArgoCD because the UI carries pedagogical weight — in class, a student can SEE the reconciliation loop they couldn't see with Flux.

**Q: Why ArgoCD instead of `helm install` from CI?**
A: Same security model as Layer 2's choice of OIDC over service principal secrets. With CI-driven Helm, every CI runner with deploy creds is a credential to steal. With ArgoCD, the cluster reads from git; nothing outside the cluster has cluster-write access. Plus: `helm install` from CI is push; you have to track "what's deployed where" in your head. ArgoCD shows you the live cluster state and the git state side by side.

**Q: What happens if I `kubectl edit deployment sample-app -n sample-app`?**
A: With `selfHeal: true` (our setting), ArgoCD reverts your edit on the next reconciliation tick (~3 min default). Out-of-band changes are NOT how the platform changes; the platform changes via git. This is the entire point.

**Q: What if I push a manifest with an error to git?**
A: ArgoCD's sync fails. The Application goes to `OutOfSync` / `Degraded` / `SyncFailed` state in the UI. The cluster keeps running whatever was last successfully synced — bad manifests do not break running workloads. You fix the manifest in a follow-up commit and ArgoCD recovers.

**Q: How is ArgoCD itself updated?**
A: Today, by re-running `bootstrap/install-argocd.ps1` (idempotent — same command upgrades the chart). The future-state is the "ArgoCD self-management" pattern from §5.10.

**Q: Why does the manifest say `:placeholder` for the image tag in the base?**
A: Defensive — to make it obvious that the base is incomplete without an overlay. If someone tried to `kubectl apply` the base directly (without going through Kustomize), the image pull would fail fast with a clearly-labelled tag. A real production base manifest might use `:latest` (less obvious that it's wrong) or omit the tag (a syntax error).

**Q: Should the ACR hostname really be in the dev overlay's `images:` block?**
A: For a forkable reference repo, no — anyone who deploys their own copy in their own Azure subscription gets a different ACR name with a different random suffix, and the overlay would need editing. A real production setup parameterises this via either a kustomize-generated ConfigMap or via Helm. We leave it inline for clarity; the path to fixing it is documented in the overlay's comment.

**Q: ArgoCD has a `Resources` view that shows me every Pod, every PV, every ConfigMap. Doesn't that need RBAC to see everything?**
A: Yes. Its ServiceAccount has cluster-admin-equivalent rights, which is why `argocd` is one of the most attractive namespaces on a cluster. The pattern around it: lock down access to the `argocd` namespace itself (NetworkPolicy + Pod Security Standards), restrict who can `kubectl get/edit` Applications via Azure RBAC for Kubernetes (already on from Layer 1), and prefer SSO-gated Projects to scope what each team's Applications can do.

**Q: My new app-ci pushed a new image to ACR but the pods didn't restart. What gives?**
A: §5.6 — the `:main` tag is mutable, the manifest didn't change, ArgoCD didn't see a diff, deployment didn't roll. Workarounds: `kubectl rollout restart deployment sample-app -n sample-app` (manual), or move to the SHA-pinned + auto-PR pattern (production). The lab default exposes the trade-off honestly so the question above comes up naturally.

**Q: Why does the root Application target `argocd` namespace?**
A: Because ArgoCD's CRDs (Application, ApplicationSet, AppProject) live in `argocd`. The `destination.namespace` on `root-app.yaml` is where the child resources LAND, not where the source comes from — and the children of the root are themselves Application resources, which live in `argocd`. Kind of a 4D-chess corner of the model.

**Q: Why is ArgoCD installed via Helm but the workload is in Kustomize?**
A: The workload is small + bespoke; Kustomize is the lighter tool. ArgoCD itself is large + parameterised; Helm is the standard tool for it. Use the right hammer.

**Q: How do I roll back?**
A: `git revert <bad-commit>` + push. ArgoCD picks up the revert on the next sync. There is no special rollback command. If you want a faster rollback than the auto-sync interval, hit the "Sync" button in the UI after pushing the revert. Worst case: `argocd app rollback sample-app <revision>` from the CLI, but that's a manual override of the GitOps model and should be temporary.

## 8. References

### ArgoCD official
- [Argo CD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)
- [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Application Sync Policies](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- [argo-cd Helm chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
- [ApplicationSets](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
- [ArgoCD Projects (multi-tenancy)](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#projects)

### Kustomize
- [Kustomize Reference](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [Common transformers](https://kubectl.docs.kubernetes.io/references/kustomize/builtins/) — images, labels, namespace, etc.

### Adjacent
- [ArgoCD Image Updater](https://argocd-image-updater.readthedocs.io/) — the production answer to §5.6.
- [OpenGitOps principles](https://opengitops.dev/) — the CNCF working group's formal definition.
- [Flux v2 docs](https://fluxcd.io/) — the comparable alternative.

---

## Build progress

- [x] Iteration 1: code drafted (install script + values + root-app + sample-app Application + Kustomize base/overlay)
- [ ] Iteration 2: end-to-end test (bootstrap → root app discovers child → sample-app pods Running)
- [ ] §6 Pitfalls filled with real incidents

## Iteration log

`[TBD-AFTER-BUILD]` — appended after each iteration.
