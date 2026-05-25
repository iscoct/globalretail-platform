# Layer 4 — Observability (kube-prometheus-stack + custom resources)

> 🚧 **Status:** in progress. §6 Pitfalls is `[TBD-AFTER-BUILD]` and gets filled in once the layer is deployed end-to-end on the cluster.

---

## 1. What this layer does

Installs the **kube-prometheus-stack** Helm chart on AKS via ArgoCD (the Layer 3 vehicle), plus a small set of our own resources that wire the platform's first workload — `sample-app` — into the metrics + alerting + visualisation pipeline.

After this layer:

- **Prometheus** scrapes the cluster's standard signals (kube-state-metrics, node-exporter, the control plane) AND the sample-app's `/metrics` endpoint (via a ServiceMonitor).
- **Alertmanager** has a complete routing pipeline (route + receiver) with a placeholder webhook. The plumbing is real; the destination is null.
- **Grafana** auto-loads a curated **GlobalRetail/sample-app** dashboard showing the RED triangle (Rate, Errors, Duration) plus process metrics.
- **A `PrometheusRule`** in the `sample-app` namespace defines an SLO ("99% of `/health` responses under 100ms over 30 days") via recording rules, plus two burn-rate alerts (fast 5m + slow 1h) and a meta-alert for missing scrapes.

The runtime artefact: a working metrics + alerting + viz stack reconciled from git. Adding observability for a new workload becomes **"add a ServiceMonitor next to your Service"** — no chart redeploy, no operator change.

## 2. Why it exists in production

Three problems this layer addresses that show up universally:

### 2.1 You cannot run what you cannot measure

The pre-observability default is "the app is up if `kubectl get pods` says Running." That misses every interesting failure mode: degraded latency, dropped requests, slow downstream dependencies, GC pauses, event-loop saturation. Prometheus + Grafana give you primary signals (RED: Rate / Errors / Duration) at the service level so you can actually answer "is the service serving well?" — not just "is it alive?"

### 2.2 SLOs make trade-offs explicit

A SLO is a commitment ("99% of `/health` calls under 100ms over 30 days"). The corresponding **error budget** is the inverse ("1% of those calls are allowed to be slow"). Once you compute the burn rate, deciding whether to deploy a risky change reduces to math: "we've burned 80% of this month's budget; we're not deploying anything that could burn more this week." It is the first tool that turns operations from heroics into engineering.

### 2.3 Alerts that aren't burn-rate driven page humans for noise

Threshold alerts ("CPU > 80%!") fire on background fluctuations. Burn-rate alerts fire only when the user-visible degradation is fast enough to exhaust the budget. The 5m fast + 1h slow pattern (Google SRE Workbook ch.5) is the canonical recipe and what we implement here. The net effect: fewer alerts, all of which mean something.

## 3. What we built

### File layout

```
observability/
├── README.md                                  ← this file
├── kube-prometheus-stack/
│   └── values.yaml                            ← Helm values (lab-shaped)
└── manifests/
    ├── kustomization.yaml                     ← bundles the three resources below
    ├── sample-app/
    │   └── servicemonitor.yaml                ← scrape sample-app:80/metrics
    ├── alerts/
    │   └── sample-app-slos.yaml               ← PrometheusRule (recording + alerts)
    └── dashboards/
        └── sample-app-dashboard.yaml          ← ConfigMap, auto-loaded by Grafana sidecar

gitops/applications/observability.yaml         ← multi-source ArgoCD Application
```

The Application is **multi-source** (modern ArgoCD ≥ 2.6 pattern):
- Source 1: the upstream chart (`prometheus-community/kube-prometheus-stack@85.3.3`).
- Source 2: this repo, referenced as `$values`, so the chart's overrides come from `kube-prometheus-stack/values.yaml`.
- Source 3: this repo, with `path: observability/manifests`, so the custom CRs land too.

### Apply sequence (from a clean cluster with Layers 1–3 already in place)

There is **no manual step** — adding this layer is just merging `gitops/applications/observability.yaml`:

```bash
git add observability/ gitops/applications/observability.yaml
git commit -m "feat(observability): Layer 4"
git push   # via PR + merge
```

ArgoCD's `root` Application notices the new `gitops/applications/observability.yaml`, creates the `observability` Application, and that Application installs the stack + applies the custom CRs.

### What ends up in the cluster

| Namespace | What |
|---|---|
| `monitoring` | The kube-prometheus-stack chart's release — operator, prometheus StatefulSet, alertmanager StatefulSet, grafana Deployment, kube-state-metrics, node-exporter (DaemonSet) |
| `sample-app` | Three new objects: a `ServiceMonitor`, a `PrometheusRule`, a `ConfigMap` carrying the Grafana dashboard JSON |
| `argocd` | One new Application (`observability`), discovered by the root app-of-apps |

### What downstream layers consume

Layer 5 will install Kyverno + cert-manager + Secrets Store CSI Driver as additional Applications. Each gets its own ServiceMonitor next to itself; this layer's prometheus-operator picks them up automatically thanks to `serviceMonitorSelectorNilUsesHelmValues=false`.

## 4. Lab vs Production

| Concern | Lab (this code) | Production |
|---|---|---|
| **Storage** | emptyDir on Prometheus + Alertmanager (data lost on pod restart) | PVCs on Azure Disk Premium SSD, retention sized to disk; or remote-write to Azure Monitor Managed Prometheus / Mimir / Thanos for indefinite retention |
| **Retention** | 7 days | 30+ days local + long-term in remote storage |
| **HA** | Single replica of Prometheus, Alertmanager, Grafana | 2x Prometheus replicas with cross-shard alert dedup; Alertmanager cluster of 3; Grafana behind a load balancer with PostgreSQL as backend |
| **Grafana access** | ClusterIP + `kubectl port-forward` | LoadBalancer behind a WAF or an ingress + cert-manager; SSO via Entra ID / Okta |
| **Grafana auth** | Local `admin` + chart default password | SSO only; `admin.enabled: false` |
| **Alertmanager destination** | `null-receiver` placeholder | Slack incoming webhook for `severity: warning`; PagerDuty for `severity: critical`; group routing per team/service |
| **SLOs** | One SLO for sample-app `/health` (99% < 100ms over 30d) | Per-service SLO catalogue, error budgets visible in PR templates ("changing X burns Y% of the Z service's budget"), monthly review cadence |
| **Burn-rate alerts** | Two windows (5m fast + 1h slow) | Two-window-two-alert pattern from SRE Workbook + multi-window guards to avoid alert flapping |
| **Dashboards** | One bespoke for sample-app + the chart's bundled K8s/Prometheus dashboards | The above + per-team dashboards committed via PR; dashboards version-controlled (we DO that here — they live in git) |
| **Logs** | None (kube-prometheus-stack does not include logs) | Loki + promtail or Azure Monitor Logs (Container Insights, which Layer 1 already streams to via diagnostic settings) |
| **Traces** | None | OpenTelemetry Collector + Tempo or Azure Application Insights |
| **Cost** | All compute on the AKS cluster | Mix of in-cluster + Azure Managed services — Managed Prometheus + Managed Grafana lifts the storage/retention/HA burden off the cluster team. Worth doing once the data volume justifies the per-GB pricing. |
| **Azure Managed Prometheus + Managed Grafana** | Skipped | Future Layer 4b. Adds a managed `azurerm_monitor_workspace` (Prometheus) + `azurerm_dashboard_grafana` (Grafana), points the cluster's metrics-server at them, and switches our SSO to Entra-backed Managed Grafana — a tighter integration with the rest of Azure. |
| **CRD lifecycle** | Chart owns CRDs (`crds.enabled: true`) | CRDs applied separately so `helm uninstall` does not orphan instances |
| **Recording-rule density** | Light (3 recording rules total) | Heavy. Every dashboard's queries are pre-aggregated into recording rules so dashboard load is fast and prometheus query workers stay free for alerts |

## 5. Key concepts the instructor must own

### 5.1 The prometheus-operator pattern — CRDs are the API

`prometheus-operator` (which ships with kube-prometheus-stack) introduces a handful of CRDs:

| CRD | Purpose |
|---|---|
| `Prometheus` | A Prometheus server. The chart creates one. |
| `Alertmanager` | An Alertmanager. The chart creates one. |
| `ServiceMonitor` | "Scrape these Services" — operator turns this into a Prometheus scrape_config. |
| `PodMonitor` | "Scrape these Pods" — same idea, for workloads without a Service. |
| `PrometheusRule` | Recording + alerting rules. Operator merges them into Prometheus's rule file. |
| `AlertmanagerConfig` | Per-namespace routing. Lets a workload owner own their alert routes. |
| `Probe` | "Black-box probe these endpoints" (for blackbox-exporter). |

The huge win: **a workload owner adds a ServiceMonitor next to their app, in their own namespace, and Prometheus discovers it automatically**. No central scrape config to edit. No PR against the platform team's repo. The operator pattern turns infrastructure into a self-service API.

### 5.2 Why ServiceMonitor selectors are namespace-scoped by default

A ServiceMonitor only matches Services in its own namespace UNLESS you set `namespaceSelector.matchNames` or `matchLabels`. Our sample-app's ServiceMonitor explicitly says `namespaceSelector: { matchNames: [sample-app] }` — defensive but explicit.

Production teams sometimes use a label selector instead (`namespaceSelector: { matchLabels: { monitor: true } }`) — every namespace labelled `monitor=true` is in scope. Less typing, more risk of accidentally scraping namespaces that shouldn't be.

### 5.3 RED, USE, and the four golden signals

Multiple frameworks. All taxonomies of "what to measure on a service":

- **RED (Rate, Errors, Duration)** — Tom Wilkie. The user-facing view. What this layer's sample-app dashboard shows.
- **USE (Utilization, Saturation, Errors)** — Brendan Gregg. The resource view. What node-exporter + kube-state-metrics give you for free.
- **Four Golden Signals (Latency, Traffic, Errors, Saturation)** — Google SRE Book. A superset of RED + saturation.

You want both. RED for "is the service serving well?", USE for "is the underlying box healthy?". When something breaks, RED tells you it's broken; USE tells you why.

### 5.4 PromQL: counter vs gauge vs histogram

Three metric types in Prometheus, three different query patterns:

| Type | Example | Query pattern |
|---|---|---|
| **Counter** | `http_requests_total` (only goes up) | `rate(x[5m])` — request rate, e.g. 12.4 req/s |
| **Gauge** | `process_resident_memory_bytes` (any value) | `x{job="..."}` — directly readable |
| **Histogram** | `http_request_duration_seconds` | `histogram_quantile(0.99, sum by (le) (rate(x_bucket[5m])))` — p99 |

Histograms are the only way to compute percentiles in Prometheus. You set up *buckets* (we used `[0.005, 0.01, 0.025, ..., 5]`), prom-client counts how many observations fall in each, `histogram_quantile` interpolates a percentile from the bucket counts. If the real p99 lands BEYOND the highest bucket, the function returns `+Inf` — a sign you need wider buckets.

### 5.5 SLOs and burn-rate alerts

An SLI (Service Level Indicator) is a measurable thing — e.g., "fraction of /health calls under 100ms in 5 minutes". An SLO (Service Level Objective) is a target on the SLI — "the SLI is ≥ 99% over a 30-day window". The error budget is `1 - SLO` = 1% of requests can be slow.

The naïve alert is "fire when SLI < SLO." That fires constantly under normal noise. The better alert is **burn-rate**: fire when the rate at which we're consuming the budget would exhaust the month's allowance in some interval.

We compute two:
- **Fast burn (5m window):** if the 5-minute SLI is below 95%, we'd consume the budget in ~2 days. Page someone.
- **Slow burn (1h window):** if the 1-hour SLI is below 98%, we're burning faster than steady-state but not catastrophically. Ticket someone.

The exact percentages come from the SRE Workbook table — they're tuned so the alerts have predictable detection time and don't flap.

### 5.6 Why the dashboard ships as a ConfigMap

Grafana has a "dashboards from disk" provisioning mode. The kube-prometheus-stack chart installs a sidecar that watches ConfigMaps with a specific label (`grafana_dashboard=1`), copies their JSON contents to a directory, and Grafana picks them up.

This means **adding a new dashboard is "add a ConfigMap to git"** — no Grafana API call, no in-cluster state to migrate, no "who saved the latest version?" question. The dashboard is in the same repo as the workload it dashboards. Version control + PR review + audit, for free.

The opposite ("save dashboard in UI") is the antipattern: edits live in Grafana's database, get lost on pod restart (we use no PVC for Grafana), and have no review process. We do it the GitOps way.

### 5.7 The Grafana sidecar is a separate pod

When you look at `kubectl get pods -n monitoring`, the Grafana Deployment runs **two containers**:
- `grafana` — the actual Grafana
- `grafana-sc-dashboard` — the sidecar that watches ConfigMaps and writes JSON files to a shared `emptyDir`

The sidecar pattern is common (auth-proxy sidecars, log-tailing sidecars). Worth understanding because debugging "dashboard isn't showing up" often means looking at the sidecar's logs (`kubectl logs deploy/grafana -c grafana-sc-dashboard -n monitoring`) before looking at Grafana itself.

### 5.8 Alertmanager: routes are a tree

Alertmanager's `route:` block is a tree. The top-level route is the default; nested `routes:` match specific labels and either CONTINUE walking the tree (default) or stop with `continue: false`. The pattern lets you say "send all critical alerts to PagerDuty AND to the team's Slack channel; send warnings only to Slack."

Our lab config has the routing shape (matchers + receivers + group_by) but the receivers all point at `null-receiver` — alerts are routed but go nowhere. Replacing the receivers with real Slack/PagerDuty config is one file edit.

### 5.9 Cardinality is the enemy

Every unique combination of metric name + label values is a separate time series in Prometheus's TSDB. A metric `http_request_duration_seconds{method, route, status}` with 5 methods × 100 routes × 20 statuses = 10,000 time series. Multiply by a few thousand pods and you're at millions of series — Prometheus's memory and disk balloon.

The defensive move (which we do in sample-app/index.js): `req.route?.path` collapses `?id=12345` into `/users/:id`. Without it, every distinct URL is a new label value, and a busy app would explode the TSDB in hours.

Production teams audit cardinality with `topk(20, count by (__name__) ({__name__=~".+"}))` on a regular schedule, and reject PRs that add high-cardinality labels.

### 5.10 The "stack" includes things you may not need

`kube-prometheus-stack` is intentionally batteries-included: it ships Prometheus + Alertmanager + Grafana + kube-state-metrics + node-exporter + the operator + a default set of dashboards + a default set of rules. Disabling components you don't need (`grafana.enabled: false` if you have an external Grafana, for instance) keeps the install smaller. The "minimal" install we have here is already 6 pods + 1 DaemonSet — production installs often run 8-10x larger because of dashboards, federations, and per-team customisations.

## 6. Pitfalls and gotchas

Three things to know after the 2026-05-25 end-to-end run.

### 6.1 kube-prometheus-stack forced a node autoscale (predicted cost, manifested concretely)
**Symptom:** After ArgoCD synced the observability Application, a routine `kubectl rollout restart deployment/sample-app -n sample-app` timed out with "1 out of 2 new replicas have been updated". The new pod was in `Pending` for ~2 minutes.
**Cause:** The stack consumes ~1 vCPU + ~1 GiB across its 6 pods on the user node pool. With our `D2s_v3` nodes (2 vCPU, 8 GiB) and the user pool autoscaled to 1 node, the new sample-app pod couldn't schedule — it triggered AKS Cluster Autoscaler to spin up a second node. The pod sat `Pending` until that node was Ready (~90s on the warm path).
**Fix:** None needed — the autoscaler did its job. But the **practical implication** is real: with kube-prometheus-stack on, the cluster's steady-state floor is ~2 nodes, not 1. That's $$ while it's up. Stop the stack (`kubectl delete app observability -n argocd`) and the user pool will scale back down within ~10 minutes (default autoscaler scale-down delay).
**Lesson:** monitoring is not free even on a tiny cluster. The "absorb the cost" decision in Layer 4's planning conversation was correct; just calibrate the expectation.

### 6.2 The mutable `:main` tag + the GitOps reconciler don't roll deployments by themselves
**Symptom:** After PR #14 merged and `app-ci` pushed a new `:main` image with the `/metrics` endpoint, the running sample-app pods continued to serve the old image (no `/metrics`). The Application was `Synced + Healthy` — ArgoCD saw no diff in git, the manifest was identical.
**Cause:** This is the canonical mutable-tag problem flagged in Layer 3's §5.6 (Mutable vs immutable image tags). The manifest's `image: …/sample-app:main` did not change because `main` is the same tag; ArgoCD reconciled to "no change"; existing pods kept serving the old image because they had already pulled the old digest and nothing triggered a re-pull.
**Fix:** `kubectl rollout restart deployment/sample-app -n sample-app`. The new ReplicaSet's pods do an `Always` pull and get the new digest. This is acceptable as a lab pattern, but the **production-correct path** stays as described in Layer 3 §5.6: app-ci opens an auto-PR that updates `gitops/workloads/sample-app/overlays/dev/kustomization.yaml` with the new SHA tag, ArgoCD then sees a real diff and rolls automatically with full audit.
**Lesson:** Layer 4 surfaced the cost of Layer 3's mutable-tag shortcut. The first time the instructor pushes a new app version after deploying observability, they will see this — and that's the *teaching* moment for "why immutable tags + auto-PR matter".

### 6.3 Old pod endpoints linger in `up{job=...}` after pod termination (informational)
**Observation:** Querying `up{job="sample-app"}` while the sample-app rollout was in flight returned **four** results — two old pods showing `up=0` (just terminated) and two new pods showing `up=1`. The old entries hung around for one full scrape cycle (~30s) before Prometheus dropped them.
**Cause:** Prometheus discovers targets from the kubelet's endpoint list at scrape time; between discovery and the next scrape, a recently-terminated endpoint is still in the list with `up=0`. Not a bug; not a problem; worth knowing so you don't panic when half your fleet looks "down" during a rollout.
**Fix:** None. If you're computing alerts on `up == 0`, give them a `for: 5m` to avoid the rollout false-positive — which is what we do in the `SampleAppMetricsScrapeMissing` alert via `absent(...)` + `for: 5m`.

## 7. Likely student questions and answers

**Q: Why kube-prometheus-stack instead of installing Prometheus and Grafana separately?**
A: kube-prometheus-stack is the closest thing to a maintained "Prometheus distribution" for Kubernetes. It includes the prometheus-operator (the CRD-based control plane), preconfigured ServiceMonitors for control-plane components, sane alert rules, and a curated set of dashboards. Rolling your own from upstream charts is doable but you end up reinventing the operator's wiring; the stack saves weeks of glue code and is what most production teams run.

**Q: Why is the SLO based on `/health` and not on real customer traffic?**
A: The sample-app has no real users. `/health` is the only meaningful signal we have. In a production app the SLOs would be on customer-facing routes (e.g., POST /checkout for an e-commerce site). The PromQL templates carry over — you change the `route="/health"` filter to your actual route.

**Q: ArgoCD says the observability Application is `Synced` but Grafana doesn't show my dashboard. What's wrong?**
A: Almost always one of three things. (1) The ConfigMap is missing the `grafana_dashboard: "1"` label — the sidecar filters on that label. (2) The ConfigMap is in a namespace the sidecar isn't watching — our config says `searchNamespace: ALL` so this is unlikely but worth checking. (3) The dashboard JSON is invalid — check `kubectl logs deploy/grafana -c grafana-sc-dashboard -n monitoring` for parse errors.

**Q: Why does our SLO query divide bucket count by total count? Isn't that what `histogram_quantile` does?**
A: Different question. `histogram_quantile(0.99, ...)` answers "what's the p99 latency right now?" — useful for graphing. The SLI question is "what fraction of requests is under THE TARGET LATENCY?" — that's a ratio of two counters. The bucket counter for `le=0.1` (which prom-client emits automatically because 0.1 is in our `buckets` list) is the numerator; total count is the denominator. The SRE Workbook discusses this distinction in chapter 4.

**Q: Why do recording rules update every 30s instead of per-scrape?**
A: Recording rules run on a separate evaluator inside Prometheus. They're evaluated at the rule group's `interval`. 30s is a reasonable cadence for SLO math — the SLI moves slowly enough that more frequent evaluation wouldn't show different values, and the rule evaluator's CPU isn't free.

**Q: My PrometheusRule says `severity: critical` but Alertmanager isn't paging me.**
A: Three layers to check. (1) Did the rule actually fire? `kubectl get prometheusrule sample-app-slo -n sample-app -o yaml` shows the rule definitions; the Prometheus UI's Alerts tab shows whether they're firing. (2) Did Alertmanager receive it? `kubectl logs sts/alertmanager-kube-prometheus-stack-alertmanager -n monitoring` shows incoming alerts. (3) What does the routing tree say? Our config routes `critical` to `null-receiver` — change that to a Slack webhook to see real notifications.

**Q: Should we run two Prometheus replicas?**
A: For HA on the metrics side: yes. The pattern is two replicas scraping the same targets independently; if one dies, the other still has data. Alertmanager dedups identical alerts across the two. For the lab one replica is fine — we accept brief outages on pod restart, which would lose ~5 minutes of in-memory data with emptyDir storage.

**Q: How big does Prometheus actually get?**
A: As a function of (active series × samples-per-second × retention). With our config — small workload, 7d retention, ~1000 series — it's around 50-100 MiB of disk and 200-400 MiB of RAM. Real production with thousands of pods, hundreds of thousands of series, 30d retention: tens of GB of disk, several GB of RAM, and frequently the bottleneck driving cluster sizing.

**Q: I want to query Prometheus from outside the cluster.**
A: Port-forward (lab pattern), Ingress with auth (some production), or Thanos sidecar pushing to object storage which is then queried via Thanos Query (production at scale). The kube-prometheus-stack chart can attach the Thanos sidecar with a values flag (`prometheus.thanosService.enabled: true`); we don't enable it.

**Q: Why does our PrometheusRule live in the sample-app namespace and not in monitoring?**
A: Same reason as the ServiceMonitor: it belongs WITH the workload. The team that owns the sample-app owns its SLO. The monitoring namespace owns the platform (the Prometheus pod, the operator, the Grafana). Putting rules with workloads keeps team ownership clean. Operator picks them up regardless of namespace because we set `ruleSelectorNilUsesHelmValues=false`.

## 8. References

### kube-prometheus-stack
- [Chart README](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) — values reference + upgrade notes.
- [prometheus-operator design doc](https://prometheus-operator.dev/docs/getting-started/design/) — why the CRD-based pattern exists.

### Prometheus & PromQL
- [Prometheus Query Functions](https://prometheus.io/docs/prometheus/latest/querying/functions/)
- [Best practices: histograms vs summaries](https://prometheus.io/docs/practices/histograms/) — critical reading before changing buckets.
- [Naming conventions](https://prometheus.io/docs/practices/naming/) — `_total`, `_seconds`, `_bytes` suffixes matter.

### SLOs and burn rate
- [Google SRE Workbook — Implementing SLOs](https://sre.google/workbook/implementing-slos/) — the canonical reference for the burn-rate alert recipe we use.
- [Sloth](https://sloth.dev/) — a tool that compiles a SLO spec into the PrometheusRules we wrote by hand. Worth knowing for production.
- [Pyrra](https://github.com/pyrra-dev/pyrra) — the alternative compiler, ships its own operator + UI.

### Grafana
- [Provisioning dashboards](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards) — the ConfigMap+sidecar pattern we use.
- [Grafana Operator](https://grafana.github.io/grafana-operator/) — the next step up: dashboards as CRDs instead of ConfigMaps.

### Azure (for the future Layer 4b)
- [Azure Monitor Managed Prometheus](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/prometheus-metrics-overview)
- [Azure Managed Grafana](https://learn.microsoft.com/en-us/azure/managed-grafana/overview)
- [Container Insights](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-overview) — already wired via Layer 1's diagnostic settings to Log Analytics.

---

## Build progress

- [x] Iteration 1: sample-app `/metrics` instrumentation (PR #14, prom-client)
- [x] Iteration 2: observability/ code drafted — helm values, ServiceMonitor, PrometheusRule, dashboard ConfigMap, multi-source Application
- [x] Iteration 3: end-to-end test — 3 Applications Synced + Healthy, Prometheus scrapes sample-app `/metrics`, custom metrics queryable, Grafana auto-loaded the GlobalRetail dashboard
- [x] §6 Pitfalls filled (3)
- [ ] Iteration 4: teardown verified
- [ ] Demo prepared for class
- [ ] Future: Layer 4b — Azure Managed Prometheus + Managed Grafana

## Iteration log

### Iteration 1 — sample-app `/metrics` (2026-05-25)
Added `prom-client@15.1.3` to `apps/sample-app/`. Wired default process metrics (CPU, heap, GC, event-loop lag) + custom `http_request_duration_seconds` histogram + `health_checks_total` counter + a `/metrics` route in Express format. Four new tests (7 total, 100% statements). PR #14 merged; `app-ci` built and pushed the new image to ACR.

### Iteration 2 — observability/ code drafted (2026-05-25)
Wrote the multi-source ArgoCD Application (kube-prometheus-stack@85.3.3 + this repo as `$values` + this repo for the kustomize bundle). Wrote ServiceMonitor (scrape sample-app `:80/metrics` every 30s), PrometheusRule (3 recording rules + 2 burn-rate alerts + 1 scrape-missing meta-alert), and a 6-panel Grafana dashboard delivered as a labelled ConfigMap. Sub-README §1–§5, §7, §8.

### Iteration 3 — end-to-end test (2026-05-25)
- PR #15 merged. ArgoCD's `root` Application discovered `gitops/applications/observability.yaml` within ~30 s of the merge.
- The `observability` Application converged Synced + Healthy in ~2 min. 6 pods in `monitoring` namespace: prometheus-operator, prometheus, alertmanager, grafana (with 2 sidecars), kube-state-metrics, node-exporter DaemonSet on each node.
- The user node pool autoscaled from 1 → 2 nodes during the install (pitfall §6.1). Auto-recovery, no human intervention.
- After `kubectl rollout restart deployment/sample-app` (pitfall §6.2), the new `/metrics`-aware image rolled out, Prometheus discovered the endpoints, and `health_checks_total{app="globalretail-sample-app"} = 4` was queryable in Prometheus within ~30 s of the rollout completing.
- Grafana auto-loaded the `GlobalRetail sample-app` dashboard via the sidecar (verified by `GET /api/search?query=GlobalRetail` against the Grafana API).
- Burn-rate alerts not yet observable in firing state — they need real traffic to /health AND latency variation that the lab isn't generating. Future iteration could add a load generator to demonstrate alerts firing.

**State at end of iteration 3:**
- AKS user pool: 2 nodes Ready.
- ArgoCD: 3 Applications, all Healthy (`root`, `sample-app`, `observability`).
- Prometheus: scraping ~700 series including the sample-app custom metrics + the standard kube-state-metrics + node-exporter set.
- Grafana: GlobalRetail dashboard loaded; access via `kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80`, login `admin / prom-operator`.
- Alertmanager: routing configured, null receiver, no alerts firing.
