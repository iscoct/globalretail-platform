# Reference Architecture — GlobalRetail on Azure

> **What this is:** an opinionated, end-to-end Azure platform stack built the way a real platform team would build it — Terraform for the foundation, OIDC-federated GitHub Actions for CI/CD, GitOps for delivery, observability and policy from day one. Every decision is documented with its production rationale and the trade-offs.
> **What this is NOT:** a step-by-step tutorial. Read it layer by layer. Fork it. Stand up your own copy in your own Azure subscription.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## The fictional company case — GlobalRetail

**GlobalRetail** is a mid-sized European retail company (≈800 stores, e-commerce site, mobile app, corporate ERP). Until last year their platform ran on a mix of on-prem VMware VMs and a few isolated Azure VMs lifted-and-shifted in 2021. The pain points that triggered the migration to a cloud-native platform on Azure:

- **Release velocity:** changes to the e-commerce site take 2–3 weeks from merge to production because of manual environment promotions and a fragile staging cluster.
- **Cost visibility:** they pay for VMware capacity 24/7 even though Black Friday peaks are 8× the average load — they want autoscaling per workload, not per VM.
- **Compliance:** PCI-DSS requires audited deployments, image provenance, and secret rotation — none of which their current scripts enforce.
- **Resilience:** the e-commerce site went down for 45 min in March because nobody noticed disk filling up on the order-processing VM. There is no real observability stack.
- **Team scale:** the platform team is 4 engineers serving 60+ developers across 8 product squads. Self-service is mandatory; gatekeeping the platform doesn't scale.

The Azure stack in this repo is the platform team's answer. It is **production-shaped**, not toy-sized — but it runs in a single dev environment so it's affordable to keep around for learning. Every layer documents what changes when you take it to multi-region prod.

## High-level architecture

```
                                ┌─────────────────────────────────┐
                                │      Entra ID (tenant)          │
                                │  - AKS admin group              │
                                │  - 3 UAMIs (app, RO, RW)        │
                                │  - Federated credentials        │
                                └────────────┬────────────────────┘
                                             │
                ┌────────────────────────────┼────────────────────────────┐
                │                            │                            │
        ┌───────▼────────┐          ┌────────▼────────┐         ┌─────────▼────────┐
        │ GitHub         │  OIDC    │  Subscription   │         │  Log Analytics   │
        │ (Actions + PRs)│─────────▶│   (yours)       │◀────────│  Workspace       │
        └───────┬────────┘          │                 │         └──────────────────┘
                │                   │  ┌───────────┐  │
                │ push image        │  │   VNet    │  │
                │                   │  │  ┌─────┐  │  │
                ▼                   │  │  │ AKS │──┼──┼──▶  Workloads (Layer 3+)
        ┌───────────────┐           │  │  └──┬──┘  │  │
        │     ACR       │◀──────────┼──┤     │     │  │
        │  (Layer 1)    │   pull    │  │     │     │  │
        └───────────────┘           │  │     ▼     │  │
                                    │  │  Key Vault│  │
                                    │  │  (Layer 1)│  │
                                    │  └───────────┘  │
                                    └─────────────────┘
```

## Repository layout

```
globalretail-platform/
├── README.md                          ← you are here
├── LICENSE                            ← MIT
├── .github/
│   ├── dependabot.yml                 ← weekly dep + image + actions bumps
│   └── workflows/
│       ├── app-ci.yml                 ← App pipeline: test → SAST → SCA → build → scan → push
│       ├── infra-plan.yml             ← Terraform plan on PR (Platform-RO UAMI)
│       └── infra-apply.yml            ← Terraform apply on push to main (env-gated)
├── infra/                             ← Layer 1 — Platform foundation (Terraform)
├── cicd/                              ← Layer 2 — CI/CD with OIDC
├── apps/
│   └── sample-app/                    ← Tiny Node.js app exercising the app pipeline
├── gitops/                            ← Layer 3 — GitOps delivery (ArgoCD)
├── observability/                     ← Layer 4 — Monitoring, logging, tracing
└── security/                          ← Layer 5 — Policy, secrets, scanning
```

The folder names are flat and unprefixed on purpose — this is what a platform team's monorepo looks like in a real company. The reading order is captured in the layer table below.

Each layer has its own `README.md` answering eight questions (what it does, why it exists in production, what we built, lab vs production simplifications, key concepts, pitfalls, likely student questions, references).

## How to read this repo

- **By layer**, in order. Each layer builds on the previous one.
- **Decisions over how-to.** When you see a configuration choice in the code, the README always says *why* and what the alternative would have been.
- **Lab vs production.** Every layer has a "Lab vs Production" section that lists exactly what we simplified for a single-environment dev sandbox.

## Layer status

| # | Layer | Folder | Status |
|---|-------|--------|--------|
| 1 | Platform foundation (Terraform) | `infra/`  | ✅ Built + tested + teardown verified |
| 2 | CI/CD with OIDC (GitHub Actions → Azure) | `cicd/` | 🚧 Code drafted, end-to-end test pending |
| 3 | GitOps delivery (ArgoCD) | `gitops/` | ✅ Built + tested end-to-end (sample-app reconciled via app-of-apps) |
| 4 | Observability (Prometheus, Grafana, Azure Monitor) | `observability/` | ⏳ Not started |
| 5 | Security (Kyverno, Trivy, Workload Identity, Key Vault CSI) | `security/` | ⏳ Not started |

## How to deploy this in your own Azure subscription

This repo is designed to be deployable from a **fork** into **any Azure subscription**. None of your IDs are committed — subscription, tenant, and GitHub owner all come from `terraform.tfvars` (gitignored) and GitHub repo variables.

### Prerequisites
- An Azure subscription you can deploy into. Owner role on the subscription (the bootstrap creates role assignments).
- `az` CLI, `terraform` ≥ 1.9, `gh` CLI ≥ 2.40, `git`. PowerShell 7+ for the bootstrap scripts.
- A GitHub account (this repo is currently `iscoct/globalretail-platform`; you can fork or clone).

### Phases

1. **Bootstrap (laptop, ~2 min, one-time)** — provision the storage account that will hold Terraform remote state. See `infra/bootstrap/README.md`.

2. **Layer 1 (laptop, ~15–20 min, first time)** — apply `infra/` to create AKS, ACR, Key Vault, Log Analytics, VNet. After this, Layer 1 can be re-applied from CI (see Phase 4).

3. **Layer 2 (laptop, ~3 min, one-time)** — apply `cicd/terraform/` to create the three CI identities (App, Platform-RO, Platform-RW), federate them to your GitHub repo, and grant RBAC. Then run the three `cicd/github-setup/` scripts to seed GitHub variables, create the `platform-prod` environment, and apply branch protection.

4. **Iterate from CI (everything else)** — push changes to `infra/` or `apps/sample-app/`, see the corresponding workflow run, approve `infra-apply` runs in the GitHub UI when they appear.

The full step-by-step is in `cicd/README.md` §3.

### Why laptop-first then CI

Two things genuinely cannot start from CI:
- The tfstate storage account itself (chicken-and-egg with Terraform's remote backend).
- The CI managed identities (you need an identity to authenticate; chicken-and-egg).

After those exist, all subsequent changes — Layer 1 adjustments, new app versions, future layers — run through CI with the gating model described in `cicd/README.md`.

## Conventions

- **Region:** `West Europe` (`westeurope`). Override via `terraform.tfvars` if you want a different region.
- **Naming:** `<resource-type>-<workload>-<env>-<region>`, e.g. `aks-globalretail-dev-weu`.
- **Workload prefix:** `globalretail` (customisable via the `workload` variable — must be ≤ 16 chars).
- **Environment:** `dev` (single environment for the reference architecture; the code shape supports staging/prod).
- **Tags on every resource:** `environment`, `project=globalretail-platform`, `workload`, `managed-by=terraform`, `owner` (configurable).

## License

MIT. See [LICENSE](LICENSE).

## Notes for the bootcamp

This repo is the reference architecture for the **IDDA DevOps + Cloud Native (Azure)** bootcamp by Ironhack. It is the artifact the instructor builds in parallel to the course and demos in class when the relevant topic appears. Students do **not** build it from scratch — they observe demos and read the layer READMEs after class. The bootcamp's authoring plan lives in the `devops-azure-bootcamp` repo.
