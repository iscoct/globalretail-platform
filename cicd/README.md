# Layer 2 — CI/CD with OIDC (GitHub Actions → Azure)

> 🚧 **Status:** in progress. Sections marked `[TBD-AFTER-BUILD]` are filled in once the layer has been deployed end-to-end and broken-and-fixed in practice. Writing "Pitfalls" before you've hit them is dishonest pedagogy.

---

## 1. What this layer does

This layer puts a **CI/CD layer** between the GitHub repo and the Azure platform that:

- **Authenticates GitHub Actions to Azure via OIDC federated identity only.** No PATs, no client secrets, no service principal passwords anywhere in the repo.
- Splits the CI/CD identity into **three User-Assigned Managed Identities**, each scoped to least privilege:
  - **App UAMI** — pushes images to ACR.
  - **Platform-RO UAMI** — runs `terraform plan` on PRs (read-only).
  - **Platform-RW UAMI** — runs `terraform apply` on push to main, gated by a GitHub Environment with required reviewers.
- Provides **three workflows** that exercise these identities: `app-ci.yml`, `infra-plan.yml`, `infra-apply.yml`.
- Locks `main` with **branch protection** so the gates above can't be bypassed.

The runtime artefacts of this layer:
- **Images in ACR** (tagged with the commit SHA), produced by `app-ci.yml`.
- **`terraform plan` comments on PRs** (informational), produced by `infra-plan.yml`.
- **`terraform apply` runs** that mutate Azure infra, produced by `infra-apply.yml` after human approval.

## 2. Why it exists in production

Four problems this layer solves that show up universally on real platform teams:

### 2.1 No long-lived credentials in the repo

The pre-2023 pattern was a service principal client secret as a GitHub Secret. Rotation every 6–24 months, leaks live forever, audit trail is poor. OIDC federation kills the whole class of problem: GitHub mints a **~15-minute JWT** per run; Azure exchanges it for an Entra ID token; both expire fast; the only thing in the repo is the *client ID*, which is public anyway. Nothing to rotate because nothing is secret.

### 2.2 Every change is gated, and the gates can't be skipped

Production releases gate on multiple complementary checks:

| Stage | Catches |
|---|---|
| **Unit tests** | Logic bugs, regressions |
| **SAST** (CodeQL) | Vulnerable code patterns (SQLi, XSS, weak crypto, hardcoded secrets) |
| **SCA** (npm audit) | Known CVEs in third-party deps |
| **Image scan** (Trivy) | OS-level CVEs, misconfigurations, secrets leaked into image layers |
| **`terraform plan` posted to PR** | Drift, accidental destructive changes, unintended scope creep |

Branch protection with `enforce_admins = true` makes these gates real — even the repo owner can't merge red. The infra-apply environment with required reviewers makes destructive operations gated by *a human pressing a button*, not just by branch protection.

### 2.3 Privilege is minimised and made explicit

A single high-privilege CI identity is a juicy target. We split into three:

- **App UAMI** — only AcrPush / AcrPull on the ACR. Worst case a compromised collaborator can push a bad image; can't touch infra.
- **Platform-RO UAMI** — only Reader on the subscription + Storage Blob Reader on tfstate. A malicious PR running `terraform plan` (or arbitrary `az` commands) is read-only.
- **Platform-RW UAMI** — Contributor + UAA on subscription. The dangerous one. Sits behind the environment gate so no token even gets issued without human approval.

### 2.4 The repo is portable

No subscription ID, tenant ID, or org name is committed. Anyone who forks the repo can deploy it in *their* Azure subscription by filling in `terraform.tfvars` (gitignored) and seeding their repo variables. This matters for an educational/public reference architecture: the artefact is reusable, not a screenshot.

## 3. What we built

### File layout

```
cicd/
├── README.md                              ← this file
├── terraform/                             ← Azure side: 3 UAMIs + 4 fed creds + RBAC
│   ├── versions.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── main.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example           ← copy to terraform.tfvars (gitignored)
│   ├── backend.hcl.example
│   └── .gitignore
└── github-setup/                          ← GitHub side: env + vars + branch protection
    ├── setup-environment.ps1              ← gh CLI: create env + required reviewers
    ├── set-github-vars.ps1                ← gh CLI: write the 10 vars (9 repo + 1 env)
    ├── apply-branch-protection.ps1        ← gh CLI: lock main
    └── README.md
```

### Workflows live at the repo root, not under `cicd/`

```
.github/workflows/
├── app-ci.yml         ← App pipeline: test → SAST → SCA → build → scan → push
├── infra-plan.yml     ← terraform plan on PR (matrix: layer1-infra + layer2-cicd)
└── infra-apply.yml    ← terraform apply on push to main, env-gated
```

This is the conventional location in any GitHub repo. `cicd/` holds the Azure-side identity / RBAC, the workflows it enables live where GitHub expects them.

### Apply sequence (from a clean slate — fork or new clone)

Prereqs: Layer 1 must be applied first (we read its outputs from remote state).
gh CLI must be installed and `gh auth login` done.

```powershell
# 1. Apply Layer 2 Terraform.
cd cicd/terraform
cp terraform.tfvars.example terraform.tfvars         # edit: subscription, tenant, github_owner, github_repo, tfstate SA
cp backend.hcl.example backend.hcl                   # edit: same SA as Layer 1 (key = cicd/dev/terraform.tfstate)
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
# Creates: rg-cicd-<...>, 3 UAMIs, 4 federated credentials, 7 role assignments

# 2. Set up GitHub side.
cd ../github-setup
.\setup-environment.ps1          # creates 'platform-prod' env + reviewer
.\set-github-vars.ps1            # seeds 9 repo vars + 1 env var

# 3. Push the initial commit to main (workflows + sample app).
cd ../..
git push -u origin main
gh run watch                     # watch the first workflows run

# 4. Lock the branch.
cd cicd/github-setup
.\apply-branch-protection.ps1    # add -RequireChecks for stricter gate
```

### What ends up in the subscription

| Resource | Role |
|---|---|
| `rg-cicd-globalretail-dev-weu` | RG hosting all three CI UAMIs |
| `id-cicd-app-globalretail-dev-weu` | App UAMI |
| `id-cicd-platform-ro-globalretail-dev-weu` | Platform-RO UAMI |
| `id-cicd-platform-rw-globalretail-dev-weu` | Platform-RW UAMI |
| 4× `azurerm_federated_identity_credential` | Federations to GitHub OIDC subjects |
| 7× `azurerm_role_assignment` | RBAC: see comments in `terraform/main.tf` |

### What Layer 3+ consumes from here

| Output | Used by |
|---|---|
| Images `<acr>/globalretail/sample-app:sha-<sha>` | Layer 3 (GitOps) — ArgoCD pulls these tags |
| Images `<acr>/globalretail/sample-app:main` (mutable) | Layer 3 — convenience tag for "latest known good" |

## 4. Lab vs Production

| Concern | Lab (this code) | Production |
|---|---|---|
| **Auth identity** | UAMIs + federated credentials | Same — this *is* the production pattern. |
| **Number of identities** | 3 (app, platform-RO, platform-RW) | 5+: per app, per env, plus per platform team / per RBAC scope. |
| **Environments** | One: `platform-prod` (gates infra-apply) | `dev`, `staging`, `prod` for apps; `platform-dev`, `platform-prod` for infra. Each with reviewers + deployment branch policy + wait timer. |
| **Platform-RW scope** | Contributor + UAA on the whole subscription | Scoped to specific RGs (`rg-globalretail-*`); UAA scoped to the same RGs. PIM-elevated when needed (just-in-time). |
| **Tenant (Entra ID) permissions** | Layer 1's AKS admin group is created by the laptop bootstrap; CI cannot manage it. | CI runs as a service principal with `Group.ReadWrite.All` on Entra ID, scoped to the platform team's namespace. Layer 1's `create_aks_admin_group` is `true`. |
| **Action pinning** | Major version tags (`@v4`) for readability | Full SHA pins (`@a1b2c3...`). Renovate/Dependabot bump SHAs. |
| **Image tagging** | `sha-<sha>` + mutable `main` | Immutable tags only in prod: `sha-<sha>` + semver release tag. `:main` is dev-only. |
| **Build provenance** | None | SLSA L3 provenance attached (`actions/attest-build-provenance@v1`) + cosign verification gate in Kyverno (Layer 5). |
| **Branch protection** | PR required, conv. resolution, no force push. Required checks **off by default** because of `paths:` filter. | Same + required checks via a workflow-level "ci-summary" job that always runs (so paths filters and required checks coexist). |
| **Approval reviewers** | The repo owner (solo lab) | A reviewer group: at least 2 humans, never the PR author. PIM-temporary access for breakglass. |
| **Wait timer on apply** | 0 minutes | 5–15 minutes — gives the approver time to look at the plan output and back out. |
| **Image scan thresholds** | Fail on HIGH/CRITICAL, ignore unfixed | Fail on MEDIUM+; track unfixed in an exception register reviewed quarterly. |
| **DAST** | Not in this layer | Yes, against a deployed dev instance after Layer 3's GitOps drops the image. |
| **Secrets in CI** | None — pure OIDC | None for Azure. Third-party API keys go in **environment** secrets with approval gates. |
| **Audit** | Default Azure sign-in logs + GitHub audit log | Same + centralised SIEM ingestion; alert on token replay (sign-ins from outside `actions.githubusercontent.com`). |

## 5. Key concepts the instructor must own

### 5.1 What an OIDC token actually is

OIDC is a thin layer on OAuth 2.0 whose only job is to issue **ID tokens** — short-lived JWTs (`header.payload.signature`) that say, cryptographically, *"this is who the holder is."*

For a GitHub Actions OIDC token, the payload includes:

```json
{
  "iss":              "https://token.actions.githubusercontent.com",
  "aud":              "api://AzureADTokenExchange",
  "repository":       "iscoct/globalretail-platform",
  "ref":              "refs/heads/main",
  "sha":              "a1b2c3...",
  "job_workflow_ref": "iscoct/globalretail-platform/.github/workflows/app-ci.yml@refs/heads/main",
  "actor":            "iscoct",
  "event_name":       "push",
  "sub":              "repo:iscoct/globalretail-platform:ref:refs/heads/main",
  "environment":      "platform-prod",
  "iat":              1716480000,
  "exp":              1716480900
}
```

GitHub signs the JWT with one of its rotating keys (published at `https://token.actions.githubusercontent.com/.well-known/jwks`). Azure fetches the JWKS, verifies the signature, then checks `iss`, `aud`, and `sub` against the federated credentials we configured. Match = Entra ID issues a token for the corresponding UAMI. No match = `AADSTS70021`.

### 5.2 The "subject" string — exact-match, no wildcards

The four subjects we federate:

| Subject | Triggered by |
|---|---|
| `repo:OWNER/REPO:ref:refs/heads/main`         | Push to main of the repo |
| `repo:OWNER/REPO:pull_request`                | Any pull_request event (same-repo only — forks don't get tokens) |
| `repo:OWNER/REPO:environment:platform-prod`   | A job declaring `environment: platform-prod`, *after* env reviewers approve |

Misspell any field and you get `AADSTS70021` at runtime with no helpful detail. The token's actual subject is visible in workflow logs when you turn on `ACTIONS_STEP_DEBUG=true` — the canonical first-debugging-step when federation fails.

### 5.3 `id-token: write` permission

By default a workflow's `GITHUB_TOKEN` does NOT include the permission to mint OIDC tokens. You must request it explicitly, per job:

```yaml
permissions:
  id-token: write
  contents: read
```

We scope this *per job*, not at workflow root, so only jobs that actually log in to Azure can mint tokens. The unit-test job doesn't need it.

### 5.4 Why vars and not secrets

`AZURE_*` values are **identifiers**, not secrets — visible to anyone with read access to the Azure portal. Storing them as `secrets` would:
- hide them from workflow logs (debugging harder),
- imply they need protection (misleading — the whole OIDC model is "no secrets"),
- prevent them from being inherited from environment-level vars in a clean way.

Putting them as `vars` makes the no-secret story explicit and the debugging easy.

### 5.5 PRs from forks don't get OIDC tokens

GitHub deliberately does NOT issue OIDC tokens to workflows triggered by `pull_request` events from forks. The reason: an external contributor could otherwise mint a token for your federated credential.

Implications:
- For a private repo or a same-repo PR (this lab): OIDC works.
- For a fork PR against a public repo (like *this repo*): the build/test/scan jobs run, but the Azure-login step fails because no token is issued.
- For OSS projects accepting fork PRs that need Azure auth, the pattern is `pull_request_target` with explicit code review of the workflow file before any maintainer-elevated run.

### 5.6 The environment gate — what it actually does

When a job declares `environment: platform-prod`:
1. GitHub puts the run in **"Waiting"** state.
2. Required reviewers get a notification.
3. **No OIDC token is minted** until a reviewer presses "Approve and deploy".
4. After approval, the JWT includes `"environment": "platform-prod"` in its claims and `sub` becomes `repo:OWNER/REPO:environment:platform-prod`.
5. Azure matches it against the `gh-platform-rw-env` federated credential.

This is the **only way** the Platform-RW UAMI can be reached. Approval is logged in the GitHub audit log. A compromised collaborator account that can push code to main cannot apply Terraform without a human in the loop.

### 5.7 Multi-stage Docker + distroless runtime

The Dockerfile has two stages. **Deps** uses `node:20-bookworm-slim` (full Debian, has compilers). **Runtime** uses `gcr.io/distroless/nodejs20-debian12` (no shell, no package manager, no curl). Trivy will routinely report 50–100 CVEs against `node:20` and 0–2 against the distroless variant.

Tradeoffs:
- Debugging is harder — `kubectl exec sh` doesn't work. Use `kubectl debug` with an ephemeral debug container.
- Healthchecks must be HTTP, not exec — the cleaner pattern anyway.

### 5.8 SAST vs SCA vs DAST vs image scan

| Tool type | Examines | Catches |
|---|---|---|
| **SAST** | Source code, statically | Vulnerable code patterns (SQLi, XSS, hardcoded secrets) |
| **SCA**  | Dependency manifests | Known CVEs in 3rd-party packages |
| **DAST** | Running application | Behavioural vulns: auth bypass, business-logic flaws |
| **Image scan** | Built container | OS package CVEs, misconfig, secrets in image layers |

This layer covers SAST, SCA, image scan. DAST belongs to the integration stage post-deploy (Layer 3+).

### 5.9 The "paths filter vs required checks" trap

GitHub's branch protection requires checks to *exist*, not just to be green. If `paths:` filter on a workflow trigger means the workflow didn't run for this PR, the required check is "missing" — and the PR is unmergeable. There is no built-in "missing = pass" mode.

Two workarounds:
- Remove paths filter; pay the CI cost on every PR.
- Add a workflow-level "ci-summary" job (no paths filter) that depends on path-conditional jobs and posts a single check. Required-check the summary only.

In this repo we ship neither (the lab is OK with non-required CI checks); we document the trap.

### 5.10 The order: Layer 1 first, then Layer 2

A common student question is "can I apply everything in one go?" The answer is no:
- Layer 2 reads the ACR ID from Layer 1's remote state.
- Layer 2 grants role assignments on Layer 1 resources.
- Layer 2's tfstate lives in the same SA as Layer 1's (created by Layer 1's bootstrap).

Layer 1 must exist before Layer 2 can plan, let alone apply.

## 6. Pitfalls and gotchas

Eight pitfalls hit during the first end-to-end run on 2026-05-25. Each entry: **symptom**, **root cause**, **fix**.

### 6.1 `aquasecurity/trivy-action@0.28.0` does not exist
**Symptom:** Workflow's `Build, scan, push` job fails at "Set up job" with
`Unable to resolve action 'aquasecurity/trivy-action@0.28.0', unable to find version '0.28.0'`.
**Cause:** Tags on the trivy-action repo follow the `vX.Y.Z` convention (with a leading `v`). I had pinned `0.28.0` — a tag that simply does not exist. The action setup phase silently fails when the tag is not found, *before* any step actually runs.
**Fix:** Look at the actual releases (`gh api repos/aquasecurity/trivy-action/releases --jq '.[].tag_name'`) and pin to a real `v`-prefixed version. We use `v0.36.0`. Same care needed for any third-party action — copy-pasted tags from blog posts age badly.

### 6.2 Distroless base images ship unfixed-in-upstream OS CVEs
**Symptom:** Trivy reports HIGH/CRITICAL CVEs against `libssl3` in our supposedly "0 CVE" distroless image. Specifically:
```
CVE-2026-31789 CRITICAL  libssl3 3.0.18-1~deb12u2 (fixed 3.0.19-1~deb12u2)
CVE-2026-28387 HIGH      ...
```
**Cause:** Distroless images are rebuilt periodically against upstream Debian. Between a Debian package update and the next distroless rebuild there is a window — sometimes weeks — where Trivy sees a CVE whose fix is *available in Debian* but *not yet shipped in the distroless image*. There is nothing we can patch from our side.
**Fix:** A `.trivyignore` file listing the specific CVE IDs. Production teams keep this short, comment every entry with the upstream rebuild URL, and review quarterly. Tried `exp:YYYY-MM-DD` (Trivy's expiration syntax) but the trivy-action wrapper's SARIF flow doesn't honor it — see §6.3 — so we use plain CVE IDs and rely on calendar reminders to revisit.

### 6.3 Trivy `.trivyignore` doesn't filter exit-code when output is SARIF
**Symptom:** Even with `.trivyignore` correctly loaded (workflow log shows `Found ignorefile 'apps/sample-app/.trivyignore'` with the right content), the Trivy step still fails with exit 1.
**Cause:** Specific to `aquasecurity/trivy-action` + `format: sarif`: the ignore list is applied to the SARIF *output* (so the GitHub Security tab is clean), but the exit-code computation happens *before* the ignore filter is applied. Net result: the build still fails on ignored CVEs.
**Fix:** Split into two Trivy invocations. First with `format: sarif` + `exit-code: 0` for the upload (informational). Second with `format: table` + `exit-code: 1` + `trivyignores:` — table format honours the ignore file for exit-code computation. Confirmed: the build now passes with the same image, same ignore file.

### 6.4 Branch protection blocks even CI-fix pushes
**Symptom:** While the workflows themselves are buggy and you want to push a small fix to `main` directly, `git push` is rejected with `(protected branch hook declined)`.
**Cause:** This is by design — `apply-branch-protection.ps1` enforces `enforce_admins = true`. There is no "I'll bypass just this once" path.
**Fix:** Even tiny CI fixes go through a PR. The first time you hit this on a green-field repo it feels slow; after the third one, the muscle memory of `git checkout -b fix/X && git push -u && gh pr create && gh pr merge --squash` is faster than direct push ever was. Resist the temptation to disable the rule.

### 6.5 `terraform plan` from the Platform-RO UAMI fails on state lock acquisition
**Symptom:** infra-plan workflow fails with `Error acquiring the state lock — 403 AuthorizationPermissionMismatch ... blob metadata "terraformlockid" was empty`.
**Cause:** Acquiring the Azure blob lease requires write access to the blob's metadata (`terraformlockid` field). The Platform-RO UAMI has `Storage Blob Data Reader` — which can read the blob but cannot write metadata. A read-only identity is, by design, unable to *write the lock that protects writes*.
**Fix:** Pass `-lock=false` to `terraform plan` in `infra-plan.yml`. Plan is read-only by intent — multiple concurrent plans against the same state are safe (worst case the second one sees an outdated view that the first one's plan rendered moot). Apply (`infra-apply.yml`) keeps locking on, using the Platform-RW UAMI's `Storage Blob Data Contributor` role.

### 6.6 CI UAMIs cannot refresh `azuread_*` resources
**Symptom:** After fixing 6.5, infra-plan fails on Layer 1 with
`Error: Retrieving Group (Group: "<id>") ... 403 Forbidden ... Authorization_RequestDenied: Insufficient privileges to complete the operation.`
**Cause:** The Platform-RO and Platform-RW UAMIs hold only Azure RBAC roles. Reading or modifying Entra ID objects (groups, users, app registrations) requires *tenant-level* Microsoft Graph permissions like `Group.Read.All` — not subscription RBAC. By default a UAMI has no Graph permissions.
**Fix (workflow-side, applied):** Pass `-refresh=false` to both `terraform plan` and `terraform apply` in CI. The CI UAMI never reads live Entra state — the workflow operates on the last known tfstate values. Trade-off documented: drift between Azure and tfstate is no longer detected by CI; it becomes the laptop operator's responsibility.
**Fix (root-cause, not applied):** Grant the CI UAMIs an Entra ID role (`Directory.Read.All` for RO, `Group.ReadWrite.All` for RW) via a tenant admin. This is a one-shot tenant-admin operation that the lab cannot assume access to, so the workflow-side workaround stays as the default.

### 6.7 Layer 1's `azuread_group.aks_admins` produces a phantom diff under CI
**Symptom:** Even with `-refresh=false`, Layer 1 apply from CI fails with `Updating Group ... 403 Forbidden` on `azuread_group.aks_admins[0]`.
**Cause:** Layer 1's group resource sets `owners` and `members` to `[data.azurerm_client_config.current.object_id]`. From a laptop, that data source returns the human user's object ID. From CI, it returns the *UAMI*'s object ID — different value. Terraform sees a diff between state (`owners = [<human-id>]`) and config (`owners = [<UAMI-id>]`), plans to update — and the UAMI cannot perform the update (no Entra ID Directory write).
**Fix (workflow-side, applied):** Remove `layer1-infra` from the CI plan/apply matrices entirely. Layer 1 plan/apply runs from a laptop only. CI handles Layer 2 (and future layers that do not touch Entra ID).
**Fix (root-cause, deferred):** Refactor Layer 1 to accept the admin user's object ID as a variable (`aks_admin_group_object_id`) instead of evaluating `data.azurerm_client_config.current.object_id` inline. Then config stays stable regardless of who runs Terraform. Documented as a future refactor; not applied because Layer 1 is intended to be a teaching artefact that explains the laptop bootstrap pattern.

### 6.8 The missing `backend "azurerm" {}` block — silent fallback to local state
**Symptom:** infra-apply from CI fails with `a resource with the ID "rg-cicd-globalretail-dev-weu" already exists - to be managed via Terraform this resource needs to be imported into the State`. The plan tried to *create* all 15 Layer 2 resources, even though the laptop apply had just succeeded.
**Cause:** Layer 2's `versions.tf` was missing the `backend "azurerm" {}` declaration. With no backend declared, `terraform init -backend-config=backend.hcl` silently ignores the backend file and falls back to *local state*. Layer 2's apply from the laptop saved the state to a local `terraform.tfstate` in the working directory — invisible to CI. CI then connected to an empty remote state at `cicd/dev/terraform.tfstate` (since init created the SAS-leased blob) and rightly concluded "I need to create everything."
**Fix:** Add `backend "azurerm" {}` to `cicd/terraform/versions.tf` (Layer 1 already had it). Then run `terraform init -backend-config=backend.hcl -migrate-state` to push the local state into the remote backend. Verified by `az storage blob list` showing both `infra/dev/terraform.tfstate` and `cicd/dev/terraform.tfstate` present.

**Lesson:** the empty backend block is *load-bearing*. Without it, `-backend-config=` is a no-op and you get the worst possible failure mode — silently working until someone else tries to use your state.

### Bonus — Dependabot PRs cannot mint OIDC tokens
**Symptom:** All five Dependabot PRs that landed overnight reported `Login failed with Error: Using auth-type: SERVICE_PRINCIPAL. Not all values are present.`
**Cause:** Dependabot workflows run with the `dependabot` actor, and by default GitHub does NOT issue OIDC tokens for that actor (security feature — an external repo bot otherwise could mint tokens against your federated identity). Repo vars (which `azure/login@v2` needs for `client-id` etc.) are also scoped separately for Dependabot via the `DEPENDABOT_*` namespace.
**Fix (none applied):** This is expected behaviour, not a bug. For a public repo, Dependabot PRs will always fail the steps that touch Azure. The right approach is either (a) accept the failures, manually review the diff, and merge when satisfied; or (b) add a Dependabot-aware variant of the workflow that skips OIDC steps when `github.actor == 'dependabot[bot]'`. Documented; not implemented in this iteration.

## 7. Likely student questions and answers

**Q: Why three UAMIs instead of one?**
A: Principle of least privilege. The App UAMI can only push images. The Platform-RO can only read. Only Platform-RW can change things, and even it needs human approval. A compromised collaborator account on a PR can at worst exercise the PR-eligible UAMI (RO). On a push to main, it can push an image (App UAMI) — bad but not catastrophic. To run `terraform apply` they still need a human to click "Approve" in GitHub.

**Q: Why does the platform-RW UAMI need User Access Administrator on the subscription? Isn't Contributor enough?**
A: Contributor can create resources but not role assignments. Layer 1 creates ~5 role assignments (AcrPull for kubelet, Key Vault roles for the admin group, etc.). Without UAA, the apply fails at the first role assignment with "AuthorizationFailed". UAA is the role that grants the ability to grant — yes, very meta. In production this gets scoped to specific RGs and elevated via PIM.

**Q: Why can't CI create the Entra ID AKS admin group?**
A: Creating Entra ID groups requires *tenant-level* permissions (the `Group.Create` permission), not subscription-level RBAC. Granting this to a UAMI is possible but requires a tenant admin to assign the `Groups Administrator` Entra ID role to the UAMI. We don't do it in this lab because it's a tenant-admin-only operation and outside the subscription-scoped story. Workaround: the laptop bootstrap creates the group; CI runs with `create_aks_admin_group = false` and the existing group is referenced.

**Q: Why is `terraform plan` on PR safe even though the UAMI can read everything?**
A: "Read everything" is a strong privilege but doesn't change anything. A malicious PR could read tfstate (which contains resource IDs, no secrets), enumerate resources, see how the environment is configured. It cannot create, modify, or delete. For most threat models that's acceptable — the value of plan visibility outweighs the read-information disclosure.

**Q: Why is the infra-apply environment named `platform-prod` when we only have a `dev` Azure environment?**
A: Because the environment name refers to the *deployment target*, not the *Azure environment*. "platform-prod" = "the production version of the platform deployment process". In a multi-env setup you'd have `platform-dev`, `platform-staging`, `platform-prod`, each with different reviewers and different deployment branches. Naming it `platform-prod` here keeps the convention future-compatible.

**Q: Can the workflow run `terraform destroy`?**
A: Technically yes — the Platform-RW UAMI has Contributor + UAA, which is enough. We don't expose a `terraform destroy` workflow because destroying the platform from CI is an antipattern: it requires careful coordination (drain workloads, back up state, communicate downtime). Destroys are run from a laptop with explicit intent. If you want a "tear down for demos" path, add a separate workflow with `workflow_dispatch: only` (no automatic triggers) and a stronger reviewer policy.

**Q: A PR-only change to `apps/sample-app/` triggers app-ci but not infra-plan. How does branch protection deal with that?**
A: Default branch protection in this repo does **not** require status checks (see §5.9). Direct pushes are blocked, force-push is blocked, conversation resolution is required — these gates apply regardless of which workflow ran. If you want hard required checks, add `-RequireChecks` to `apply-branch-protection.ps1` and accept that infra-only PRs will be blocked by "missing app-ci checks" until you implement the `ci-summary` workflow pattern.

**Q: How do I verify the federation actually works before pushing real code?**
A: After `terraform apply` succeeds, run a one-shot workflow_dispatch on app-ci.yml from the GitHub UI. If `azure/login@v2` succeeds, the federation works. If it fails with `AADSTS70021`, the subject string doesn't match — most often a wrong `github_owner` or `github_repo` in tfvars. The token's subject is logged when you run with `ACTIONS_STEP_DEBUG=true` (set it as a repo secret).

**Q: How long do these OIDC tokens live?**
A: GitHub JWT: ~15 minutes. The Entra ID token after exchange: ~1 hour. Both are short enough that token exfiltration is mostly useless — by the time anyone could use a stolen token, it has expired.

## 8. References

### Microsoft official docs
- [Configure OIDC in Azure for GitHub Actions](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect) — canonical end-to-end guide.
- [Workload identity federation overview](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation) — Entra ID side.
- [Federated identity credential rules](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-considerations) — issuer/audience/subject constraints and limits.
- [`azurerm_federated_identity_credential`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) — Terraform resource reference.

### GitHub official docs
- [Security hardening with OIDC](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect) — GitHub-side, subject reference.
- [Configure OIDC for Azure](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure) — GitHub's parallel doc to Microsoft's.
- [Using environments for deployment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) — environment + required-reviewers feature this layer uses.
- [Branch protection rules API](https://docs.github.com/en/rest/branches/branch-protection) — schema for the `gh api` call in `apply-branch-protection.ps1`.
- [`azure/login@v2`](https://github.com/Azure/login) — exchanges the OIDC JWT for an Entra ID access token.

### Tools used in the workflows
- [CodeQL action](https://github.com/github/codeql-action)
- [Trivy action](https://github.com/aquasecurity/trivy-action)
- [Distroless images](https://github.com/GoogleContainerTools/distroless)
- [hashicorp/setup-terraform](https://github.com/hashicorp/setup-terraform)

### Wider reading
- [OWASP CI/CD Top 10](https://owasp.org/www-project-top-10-ci-cd-security-risks/)
- [SLSA Build Levels](https://slsa.dev/spec/v1.0/levels) — Layer 5 will use these.

---

## Build progress

- [x] Iteration 1: code drafted (TF + workflows + scripts + sample-app)
- [x] Iteration 2: end-to-end test (bootstrap → laptop apply → push → workflow runs → image in ACR → PR plan visible → apply approved)
- [ ] Iteration 3: cleanup verified (terraform destroy + repo cleanup)
- [x] Sub-README §6 (pitfalls) filled with real incidents

## Iteration log

### Iteration 1 — code drafted (2026-05-23)
Wrote Terraform for 3 UAMIs + 4 federated credentials + 7 role assignments. Wrote three workflows (app-ci, infra-plan, infra-apply). Wrote three github-setup scripts (setup-environment, set-github-vars, apply-branch-protection). Wrote the sample-app (Node.js + Jest + Dockerfile distroless). Pushed to public repo `iscoct/globalretail-platform`. **Not tested end-to-end.**

### Iteration 2 — end-to-end test (2026-05-25)
Eight pitfalls discovered and documented in §6. Final state:
- **Bootstrap (laptop):** `infra/bootstrap/bootstrap.ps1` provisioned `stgrtfstate33edbd1b` cleanly in ~2 min.
- **Layer 1 apply (laptop):** ~6 min. AKS cluster up, ACR + KV + VNet present. Stays laptop-only (§6.7).
- **Layer 2 apply (laptop):** ~36 s for the 15 resources. But silently used local state (§6.8) — fixed in iteration by adding the missing backend block and migrating state.
- **github-setup scripts:** all 3 idempotent runs succeeded first try. `platform-prod` environment created with `iscoct` as required reviewer; 9 repo vars + 1 env-scoped var seeded; branch protection applied (`-RequireChecks` off by default — see §5.9).
- **app-ci end-to-end:** validated via PR #6 (the fix-trivy-version PR itself). After the fixes in §6.1–§6.3 the full pipeline runs in ~2m28s. Image landed in ACR with both `sha-<sha>` and `main` tags.
- **infra-plan on PR:** validated via PR #7 then PR #9. After the fixes in §6.5 and §6.6, plan posts cleanly to PR comment.
- **infra-apply with env gate:** validated via PR #9 merge. Run stayed in `waiting` state until approval via API (`POST /repos/.../actions/runs/<id>/pending_deployments`). After approval, Platform-RW UAMI got its OIDC token, terraform apply succeeded — 4 in-place tag updates (the `owner` tag from the laptop apply's `francisco.cotan` got overwritten with CI's `platform-team`).

**Total elapsed for iteration 2:** ~3.5 hours, of which ~80% was iterating on the 8 pitfalls. The actual happy-path apply once everything was wired correctly was a few minutes end-to-end.

**State at end of iteration 2:**
- App-ci pipeline: working from `main` pushes. Image current at `acrglobalretaildevweu389ce1.azurecr.io/globalretail/sample-app:main`.
- Infra workflows: working for Layer 2. Layer 1 is laptop-only (documented in §6.7).
- Five Dependabot PRs from overnight are still open (failing because they cannot mint OIDC tokens — see Bonus pitfall). Treat as informational: review the diffs, merge from the UI if acceptable. Do not enable them in CI without the Dependabot-aware refactor.
