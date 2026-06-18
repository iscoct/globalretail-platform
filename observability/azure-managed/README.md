# Layer 4b — Azure Managed Prometheus + Managed Grafana (parallel to Layer 4)

> 🚧 **Status:** in progress. §6 Pitfalls is `[TBD-AFTER-BUILD]` and gets filled in after the first end-to-end test.

---

## 1. What this layer does

Adds an **Azure-native observability stack** that runs **side-by-side** with Layer 4's in-cluster kube-prometheus-stack — not replacing it. The pedagogical goal is concrete comparison: both pipelines scrape the same `ServiceMonitor` we already wrote for sample-app; both show the same metrics; the differences are in **where the data lives**, **who manages it**, **how it scales**, and **what it costs**.

After this layer:

- A new **Azure Monitor Workspace** (Managed Prometheus backend) in `rg-obs-globalretail-dev-weu`.
- A new **Azure Managed Grafana** (Essential SKU) wired to the Monitor Workspace as a data source.
- An **`ama-metrics`** DaemonSet running on AKS (deployed by Azure) that scrapes Prometheus endpoints and forwards to Managed Prometheus.
- The existing `ServiceMonitor` for sample-app is discovered automatically — same source of metrics, two destinations.

Layer 4 keeps doing its thing: in-cluster Prometheus + Grafana via port-forward. Layer 4b adds a parallel pipeline ingesting the same data into Azure-managed storage and a public-internet UI.

## 2. Why both, in production

In real production you don't normally pick "one or the other" forever — you pick **based on which trade-off matters**, and large orgs end up running both for different reasons:

| In-cluster (Layer 4) wins when… | Managed (Layer 4b) wins when… |
|---|---|
| You want full control over retention, queries, recording rules | You don't want to operate Prometheus (HA, sharding, storage) |
| Air-gapped or sovereign-cloud environment | Multi-cluster federation across regions |
| Data is sensitive — must stay in-cluster | Compliance: storage + retention SLAs from Azure |
| Cost predictability (cluster sized once) | Cost-per-ingestion-GB easier to attribute |
| Long history of OSS dashboards to migrate | Tight integration with Azure Monitor alerts + Logic Apps |

Most teams hit both reasons within a year of running Prometheus. The pattern "Managed for the production reporting pane, in-cluster for the high-cardinality debug pane" is increasingly common.

## 3. What we built

### File layout

```
observability/
├── README.md                                    ← top-level observability index (mentions 4b)
├── kube-prometheus-stack/                       ← Layer 4 (intacto)
├── manifests/                                   ← Layer 4 ServiceMonitor + PrometheusRule + dashboard
└── azure-managed/                               ← Layer 4b — THIS FOLDER
    ├── README.md                                ← this file
    ├── terraform/
    │   ├── versions.tf / providers.tf / variables.tf / locals.tf
    │   ├── main.tf                              ← RG + Monitor Workspace + Managed Grafana
    │   ├── outputs.tf
    │   ├── terraform.tfvars.example
    │   ├── backend.hcl.example
    │   └── .gitignore
    └── bootstrap/
        └── enable-aks-managed-prometheus.ps1    ← one az command, big effects
```

### Apply sequence (from a Layer 1–5 cluster)

```powershell
# 1. Apply the TF — provisions Monitor Workspace, Managed Grafana, role
#    assignments. Does NOT touch AKS yet.
cd observability/azure-managed/terraform
cp terraform.tfvars.example terraform.tfvars      # subscription, tenant, tfstate SA, grafana admin object_id
cp backend.hcl.example backend.hcl                 # storage account name
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan

# 2. Run the bootstrap script — calls `az aks update --enable-azure-monitor-metrics`
#    which: (a) flips the AKS feature on, (b) creates DCE + DCR + DCR-association
#    in the Monitor Workspace's RG, (c) installs the ama-metrics DaemonSet,
#    (d) wires Managed Grafana to query the workspace.
cd ../bootstrap
.\enable-aks-managed-prometheus.ps1
# (~3-5 min — most of it is the DaemonSet rollout)

# 3. Verify ama-metrics is scraping.
kubectl get pods -n kube-system -l dsName=ama-metrics-node     # one per node
kubectl get pods -n kube-system -l rsName=ama-metrics          # the central collector

# 4. Open Managed Grafana (URL printed by the script). Login with Entra ID.
#    The Monitor Workspace data source is already configured.
#    Query: health_checks_total{app="globalretail-sample-app"}
```

### What ends up in Azure

| Resource | Purpose |
|---|---|
| `rg-obs-globalretail-dev-weu` | RG holding the new resources |
| `amw-globalretail-dev-weu` | Azure Monitor Workspace (Managed Prometheus backend) |
| `amg-globalretail-dev` | Managed Grafana Essential SKU |
| `MSPROM-westeurope-amw-globalretail-dev-weu` (DCE) | Data Collection Endpoint (auto-created by the script) |
| `MSProm-westeurope-amw-globalretail-dev-weu` (DCR) | Data Collection Rule (auto-created) |
| (DCR association) | Links the AKS cluster to the DCR |
| 2 system role assignments | Grafana SystemAssigned MI → `Monitoring Data Reader` on the workspace; you → `Grafana Admin` on the Grafana resource |

### What ends up in the cluster

| Namespace | What |
|---|---|
| `kube-system` | `ama-metrics` Deployment + `ama-metrics-node` DaemonSet — the agent that scrapes endpoints and forwards to Managed Prometheus |

The existing in-cluster Prometheus from Layer 4 is **unaffected**. Both agents scrape the same `ServiceMonitor` resources independently.

## 4. Lab vs Production

| Concern | Lab (this code) | Production |
|---|---|---|
| **Network exposure** | Monitor Workspace + Managed Grafana both `public_network_access_enabled = true`. Internet-reachable for demo convenience. | Both with `public_network_access_enabled = false` + private endpoints. Operators access via VPN/Bastion. |
| **Grafana SKU** | Essential (~€7-9/mo, 24x7, no SLA) | Standard (~€55-110/mo) with autoscale, SLA, alerts engine, Grafana Enterprise plugins |
| **Multi-cluster** | Single AKS cluster | Same Monitor Workspace shared across N clusters via DCR-associations on each. One Grafana queries them all. |
| **DCR customisation** | Default DCR — scrapes K8s control plane, kubelet, node-exporter, kube-state-metrics + auto-discovered ServiceMonitors | Customised DCR via `ama-metrics-settings-configmap` in kube-system to drop high-cardinality metrics, set scrape intervals per target, configure remote-write to a long-term store |
| **Retention** | Default (18 months) | Same default; extend via long-term storage (Azure Data Explorer link, or remote-write to an external store) |
| **Grafana auth** | Entra ID single-user (the operator). Role assignments granted directly. | SSO via Entra ID + per-team Azure RBAC roles (Grafana Admin / Editor / Viewer scoped to the resource) |
| **Cost visibility** | One Monitor Workspace, one ingest stream | Per-cluster cost allocation via Azure Cost Management tags on the DCRs; per-team chargeback for ingestion |
| **Alerts** | Use Layer 4's PrometheusRule (in-cluster Alertmanager) | EITHER Alertmanager OR Azure Monitor's Prometheus rule groups (`azurerm_monitor_alert_prometheus_rule_group`) which fire to Action Groups (Slack/Teams/PagerDuty/email/Webhook) |
| **Rule storage** | PrometheusRule CRs in the cluster | `azurerm_monitor_alert_prometheus_rule_group` resource in Terraform; reviewed via PR, alerts persist independent of cluster state |
| **Dashboards** | ConfigMaps loaded by the Grafana sidecar | Either: import the same JSON via Managed Grafana's API, OR use `azurerm_dashboard_grafana_managed_private_endpoint` + `grafana-operator` to push them. Often: a CI step that exports dashboards-as-code from the kube-prometheus-stack Grafana and uploads them to Managed Grafana. |
| **Disaster recovery** | None (cluster goes, Prometheus goes) | Managed: Microsoft handles the workspace's redundancy. Grafana dashboards: backed up via the API to git. |

## 5. Key concepts the instructor must own

### 5.1 "Managed Prometheus" is a *backend*, not a Prometheus install

`azurerm_monitor_workspace` is Azure's **PromQL-compatible time-series database** + ingestion endpoint. It is NOT a Prometheus server — there's nothing to operate, no rules engine of its own (you use `azurerm_monitor_alert_prometheus_rule_group` separately), no UI of its own (Managed Grafana is the UI).

When you query it via PromQL, you go through Managed Grafana (or `az monitor account` API). The semantics are the same as Prometheus, the storage is Azure's.

### 5.2 The ama-metrics agent is what actually scrapes

The agent runs IN your cluster. The `--enable-azure-monitor-metrics` flag is what installs it. It auto-discovers:
- Kubernetes control plane components (etcd, apiserver, controller-manager, scheduler, kubelet)
- The kube-state-metrics and node-exporter installed by anyone (including Layer 4's kube-prometheus-stack)
- ServiceMonitor / PodMonitor CRs (if you opt them in via `ama-metrics-settings-configmap`)

For our sample-app, the ServiceMonitor we wrote in Layer 4 (`observability/manifests/sample-app/servicemonitor.yaml`) gets picked up by ama-metrics — but ONLY if we enable the ServiceMonitor scraping in the config (default is off for the platform's safety against high cardinality).

### 5.3 Two scrapers, two TSDBs, one ServiceMonitor

The KEY pedagogical point: **you don't have to instrument your app twice**. The same `/metrics` endpoint, exposed by sample-app on port 3000, is scraped:

- Every 30s by Layer 4's Prometheus (configured by the `ServiceMonitor` CR via prometheus-operator).
- Every 30s by Layer 4b's ama-metrics (configured by the same `ServiceMonitor` CR via Azure's auto-discovery).

The app does ONE scrape's worth of CPU. Two independent pipelines store the results.

### 5.4 Managed Grafana auth: SystemAssigned MI + Grafana RBAC

Three different identities you need to keep straight:

1. **Operator (you)** authenticates to Grafana via Entra ID. Your access level (Admin/Editor/Viewer) is controlled by Azure role assignments on the Grafana resource.
2. **Grafana's SystemAssigned managed identity** authenticates to Azure when QUERYING the Monitor Workspace. The AzureRM provider auto-creates a `Monitoring Data Reader` role assignment on the workspace for this MI.
3. **The ama-metrics agent in the cluster** uses the cluster's kubelet identity (Layer 1) to authenticate to the Monitor Workspace for INGESTION. The DCR association handles the wiring.

If Grafana can log you in but no metrics show, it's almost always #2: the MI didn't get its role assignment. The TF `azure_monitor_workspace_integrations` block handles this automatically.

### 5.5 PromQL is the same, the source isn't

In Layer 4's in-cluster Grafana, your data source is the Prometheus pod (URL `http://prometheus-kube-prometheus-stack-prometheus:9090`). In Managed Grafana, your data source is the Monitor Workspace (no URL — it's a typed `azuremonitor` data source).

The PromQL queries are IDENTICAL. The sample-app dashboard JSON you wrote in `manifests/dashboards/` can be imported into Managed Grafana with zero changes — Grafana picks up the configured data source.

### 5.6 DCE / DCR / DCR-association — Azure's "what to collect from where"

The collection pipeline has three Azure resources you didn't write (the script did):

- **DCE** (Data Collection Endpoint): the HTTPS ingestion endpoint. Per-region. Shared across rules.
- **DCR** (Data Collection Rule): "from sources matching X, collect Y, send to Z". Z is the Monitor Workspace. X is the AKS cluster (via association).
- **DCR Association**: the binding between the cluster (source) and the DCR. Without it, the cluster's agent has nowhere to send data.

The `az aks update --enable-azure-monitor-metrics` creates a default DCR that says "scrape Prometheus-format endpoints from the cluster, send to this Monitor Workspace". For custom scrape jobs you either:
1. Edit the auto-created DCR (Terraform via `azurerm_monitor_data_collection_rule` + import existing).
2. Use the `ama-metrics-settings-configmap` in `kube-system` to opt in/out of categories — easier for most cases.

### 5.7 Cost model: ingestion + queries

Managed Prometheus is **pay-per-ingested-time-series-sample**. Roughly $0.16 per million samples ingested (varies by region). For a small lab with ~1k active series at 30s scrape interval, that's ~3 million samples/day → ~$0.50/day → ~$15/month. With the sample-app and KPS combined, our actual ingest is in this range.

Managed Grafana Essential is a fixed ~$8-9/month (24x7). Standard is ~$55/month with autoscale.

In-cluster Prometheus (Layer 4) has zero per-sample cost — but you pay for the compute the Prometheus pod consumes (small) and the disk it would use if you turn off emptyDir storage (small to moderate).

### 5.8 When Managed Grafana CAN'T see your in-cluster data

A common confusion: "I'm in Managed Grafana but I can't query the in-cluster Prometheus". You can't — they're separate. Managed Grafana queries:
- Azure Monitor Workspace (Managed Prometheus) — what this layer enabled
- Azure Monitor Logs (Log Analytics) — Layer 1's diagnostic settings already feed this
- Azure SQL, Cosmos, etc. — irrelevant here

To query the in-cluster Prometheus from Managed Grafana, you'd add it as an external data source manually — requires exposing the Prometheus pod via an Ingress + auth, which we deliberately don't do.

### 5.9 The Layer 4 alerts (PrometheusRule) DON'T propagate to Layer 4b

The `PrometheusRule` we wrote in Layer 4 lives in the IN-CLUSTER Prometheus. The Managed Prometheus has its own rule engine via `azurerm_monitor_alert_prometheus_rule_group`. If you want the same SLO alert running both places (defense in depth), you author it twice — once as PrometheusRule (Layer 4) and once as `azurerm_monitor_alert_prometheus_rule_group` (Layer 4b).

There's no "convert PrometheusRule to Azure Monitor rule" built-in tool. Some teams write a small generator that does this from a single source. Future iteration.

### 5.10 Side-by-side is the point — pick which to LEAD with

For an app team's day-to-day debugging, the in-cluster Grafana + Alertmanager is closer to the code: fast, no auth, can be rebuilt from git. For platform-wide SLOs, audits, and multi-cluster views, Managed Grafana is centralised and survives a single cluster outage.

Most production teams I've worked with end up with BOTH:
- In-cluster as the "I'm debugging RIGHT NOW" pane.
- Managed as the "what did our SLOs look like last month, across all clusters" pane.

The fact that they share `ServiceMonitor` instrumentation means **you write app metrics once and they go everywhere**. That's the win.

## 6. Pitfalls and gotchas

Two pitfalls hit during the 2026-05-26 end-to-end run.

### 6.1 Azure Managed Grafana `Essential` SKU was deprecated — only `Standard` accepted
**Symptom:** `terraform apply` fails on the `azurerm_dashboard_grafana` resource with:
`Bad Request: SkuIsNotSupported: The Grafana Workspace sku name 'Essential' is not a supported value. Supported sku values are: Standard`
**Cause:** Microsoft retired the `Essential` SKU in late 2024 — newer subscriptions can only create `Standard`. Older Azure docs and many blog posts still reference `Essential` as the cheap option (it was the entry tier).
**Fix:** Set `sku = "Standard"`. The variable's validation now hard-rejects anything else with an explanatory error. Cost impact: `Standard` is ~$55/month vs the deprecated `Essential`'s ~$8. For a lab that runs intermittently, you can `terraform destroy` between sessions to control this.

### 6.2 ama-metrics does NOT auto-discover `ServiceMonitor` CRs
**Symptom:** After `az aks update --enable-azure-monitor-metrics`, the Monitor Workspace ingests the K8s control plane + cAdvisor + kube-state-metrics + node metrics — but `health_checks_total` (and other sample-app custom metrics) are absent. Layer 4's in-cluster Prometheus, scraping the SAME ServiceMonitor, has them.
**Cause:** Even though the AKS cluster runs prometheus-operator (from Layer 4) which manages `ServiceMonitor` CRs, the ama-metrics agent is an INDEPENDENT scraper. It does NOT speak the `ServiceMonitor`/`PodMonitor` vocabulary — those are kube-prometheus-stack-specific abstractions on top of upstream Prometheus's scrape config. ama-metrics has its own opt-in path via the `ama-metrics-prometheus-config` ConfigMap (a well-known name in `kube-system`).
**Fix:** Create a `ConfigMap` named `ama-metrics-prometheus-config` in `kube-system` with a `prometheus-config:` key whose value is a Prometheus YAML `scrape_configs:` block (same syntax as a vanilla `prometheus.yml`). The file [`manifests/ama-metrics-prometheus-config.yaml`](manifests/ama-metrics-prometheus-config.yaml) shows the scrape job for sample-app. After applying it, restart the ama-metrics Deployment so it re-reads the config: `kubectl rollout restart deployment/ama-metrics -n kube-system`. Within ~60s, `health_checks_total` and the rest of sample-app's metrics appear in the Monitor Workspace.

**Lesson:** ama-metrics + in-cluster Prometheus running on the SAME `ServiceMonitor` is a useful pattern but requires instrumenting the workload twice (once via SM for in-cluster Prometheus, once via the ama-metrics ConfigMap for Managed Prometheus). Some teams write a small generator that takes a single source of truth (e.g., a custom CRD or labels) and emits both. For the lab, two manifests is fine and makes the architectural difference visible.

## 7. Likely student questions and answers

**Q: Why both? Won't they fight?**
A: No — they scrape independently and store independently. Each adds ~1-3% CPU overhead to the scrape target (your pod's `/metrics` is read by two agents instead of one). For the sample-app's tiny `/metrics` payload, this is unmeasurable. The only "fight" is for OPERATOR ATTENTION when you're trying to remember which Grafana to open — see §5.10.

**Q: My PromQL works in Grafana #1 but not Grafana #2. Why?**
A: Different storage. The in-cluster Prometheus has 7-day retention (our values setting); Managed Prometheus has 18 months by default. So a query like `health_checks_total[30d]` works in Managed but fails (no data) in in-cluster. Conversely, if you turned off the in-cluster Prometheus, the in-cluster Grafana queries return empty; Managed Grafana keeps working because its backend is separate.

**Q: Can I use Layer 4's PrometheusRule alerts AND Layer 4b's rule groups?**
A: Yes — you'd be paying for "alerts deduplicated by Azure Monitor's Action Group + alerts handled by Alertmanager". Some teams want both for defense in depth (the in-cluster one fires fast; the Azure one survives cluster outage). Most teams pick one. Pick by where your on-call rotation expects to be paged from.

**Q: Why didn't we use `azurerm_monitor_data_collection_rule` in Terraform?**
A: Because `az aks update --enable-azure-monitor-metrics` creates the DCE + DCR + DCR-association in one shot, and they all have to be in the SAME region as the cluster, and the DCR-association must reference the cluster — which means we'd have to plumb the cluster's resource ID from Layer 1's remote state into our TF anyway. The az command auto-creates them with conventional names. For customisation (add a scrape job, drop a metric) you'd then `terraform import` them and start managing in TF. We document this as a future iteration — not needed for the demo.

**Q: How do I see the same dashboard in both Grafanas?**
A: For the in-cluster Grafana, it's auto-loaded from `manifests/dashboards/sample-app-dashboard.yaml` (the ConfigMap). For Managed Grafana, you import the same JSON manually via the UI (Plus → Import → paste JSON) or via `azapi_resource` in TF. Production teams script this — exporting from in-cluster and uploading to Managed via the API on each merge.

**Q: Can I remove the in-cluster Prometheus once Managed is up?**
A: Yes, just delete `gitops/applications/observability.yaml`. ArgoCD will tear down kube-prometheus-stack. Your sample-app dashboard in the in-cluster Grafana goes away with it. The ServiceMonitor stays (it's an unmanaged CR if KPS is gone), but ama-metrics doesn't need KPS to be present — it scrapes via its own logic. Layer 4b is fully self-sufficient if you want to commit to the Managed path.

**Q: How much does this cost?**
A: Approximate steady state, lab-shape:
- Monitor Workspace ingestion: ~$10-15/month for ~3M samples/day
- Managed Grafana Essential: ~$8-9/month
- DCR/DCE: free
- ama-metrics agent compute: noise (it's already on your node)

Total: **~$20/month** while running. Stops accruing the moment you `terraform destroy` + `az aks update --disable-azure-monitor-metrics`. For multi-cluster prod, ingestion dominates and grows linearly with active series.

**Q: Why is the operator role `Grafana Admin` and not just Owner?**
A: `Grafana Admin` is a **Grafana-scoped** role (admin level within Grafana — manage dashboards, data sources, users). Azure RBAC roles like `Owner` give you control over the Grafana RESOURCE (delete it, change SKU, etc.), but NOT login access to Grafana itself. Grafana access requires one of three Grafana-scoped roles: `Grafana Admin`, `Grafana Editor`, `Grafana Viewer`. Confusing the two is a common first-day Managed Grafana pitfall.

## 8. References

### Azure Managed Prometheus + Grafana
- [Azure Monitor managed service for Prometheus](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/prometheus-metrics-overview)
- [Azure Managed Grafana docs](https://learn.microsoft.com/en-us/azure/managed-grafana/)
- [Enable Managed Prometheus on AKS](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/kubernetes-monitoring-enable)
- [`azurerm_monitor_workspace`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_workspace)
- [`azurerm_dashboard_grafana`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/dashboard_grafana)
- [`azurerm_monitor_alert_prometheus_rule_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_alert_prometheus_rule_group) — Azure Monitor's PrometheusRule analogue

### Configuration
- [ama-metrics settings configmap](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-scrape-configuration) — how to opt ServiceMonitors in/out
- [Importing dashboards to Managed Grafana](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-create-dashboard) — the API approach

### Comparing the two stacks
- [Managed vs self-hosted Prometheus: when to choose what (Microsoft)](https://techcommunity.microsoft.com/blog/azureobservabilityblog/managed-vs-self-hosted-prometheus/4123737)

---

## Build progress

- [x] Iteration 1: Terraform + bootstrap script + ama-metrics scrape configmap + sub-README drafted
- [x] Iteration 2: TF applied + bootstrap script run + ama-metrics-prometheus-config applied + sample-app custom metrics ingested by Managed Prometheus
- [x] §6 Pitfalls filled (2)

## Iteration log

### Iteration 1 — code drafted (2026-05-26)
Wrote `terraform/` (azurerm_resource_group + azurerm_monitor_workspace + azurerm_dashboard_grafana with azure_monitor_workspace_integrations + Grafana Admin role assignment). Wrote `bootstrap/enable-aks-managed-prometheus.ps1` (calls `az aks update --enable-azure-monitor-metrics` with the two resource IDs). Wrote `manifests/ama-metrics-prometheus-config.yaml` (Prometheus scrape_config for sample-app). Sub-README §1–§5, §7, §8.

### Iteration 2 — end-to-end test (2026-05-26)
- `terraform apply` succeeded on the second try after pitfall 6.1 (Essential SKU deprecated → Standard). Created RG, Monitor Workspace, Managed Grafana, role assignment.
- `bootstrap/enable-aks-managed-prometheus.ps1` ran in ~3 minutes. ama-metrics Deployment + DaemonSet + kube-state-metrics + operator-targets all Running in `kube-system`.
- Within ~90s of the agent install, the `up` metric appeared in the Monitor Workspace with jobs `cadvisor`, `kubelet`, `node`, `kube-state-metrics`, `networkobservability-cilium`.
- `container_memory_working_set_bytes{namespace="sample-app"}` returned 20.7 and 20.4 MiB for the two sample-app pods — pod-level cAdvisor metrics flowing without any custom config.
- Pitfall 6.2 hit: `health_checks_total` was MISSING. Sample-app's custom metrics weren't being scraped because ama-metrics doesn't auto-discover `ServiceMonitor`. Applied `manifests/ama-metrics-prometheus-config.yaml`, restarted the ama-metrics Deployment.
- Within ~60s of the restart, `health_checks_total{app="globalretail-sample-app"}` returned 405 and 401 for the two sample-app pods. **Both backends (in-cluster Prometheus + Managed Prometheus) now ingest the same sample-app metrics independently, from the same `/metrics` endpoint.**

**State at end of iteration 2:**
- 6 ArgoCD Applications (Layers 3–5) + the Layer 4b stack outside of ArgoCD (Azure-managed)
- 7 UAMIs in the subscription (Layer 1's 2 + Layer 2's 3 + Layer 5's 1 + Layer 4b's 1 — Grafana system-assigned)
- Two parallel observability pipelines ingesting the same source data:
  - In-cluster Prometheus (Layer 4): port-forward to Grafana on :3000, login `admin / prom-operator`
  - Managed Prometheus (Layer 4b): https://amg-globalretail-dev-ggfdb7cxf9cze6f7.weu.grafana.azure.com, login with Entra ID
- Approximate steady-state cost adds (while running): ~$55/mo Grafana Standard + ~$10-15/mo Monitor Workspace ingestion = ~$65-70/mo on top of Layer 1's AKS spend.
