# Layer 6 — Service Mesh (Istio Ambient)

> 🚧 **Status:** code drafted, end-to-end test pending. §6 Pitfalls is `[TBD-AFTER-BUILD]` and gets filled in once the layer is deployed.

---

## 1. What this layer does

Installs **Istio in Ambient mode** on the AKS cluster and lifts both apps (sample-app, inventory-api) into the mesh without sidecars. The runtime artefacts:

- **mTLS between every pod in the mesh** — encryption + identity (SPIFFE) at the transport layer, automatic cert rotation managed by istiod.
- **Identity-based authorization** — a default-deny in each app namespace plus explicit allows ("the `sample-app` ServiceAccount can call inventory-api"). Network policies operate at IP/port; this operates at workload identity.
- **L7 traffic management** — a `VirtualService` splits sample-app traffic **90% to v1, 10% to v2** through a Waypoint proxy. The split lives in git; ArgoCD applies it.
- **Service-graph observability** — Kiali reads `istio_*` metrics from the in-cluster Prometheus and draws the live traffic graph between sample-app, inventory-api, and the mesh-test curl client.

The pedagogical demo: an in-mesh `curl-client` calls `sample-app/version` every 2 s. Roughly nine of ten responses report `version: 1.0.0`, one of ten reports `2.0.0` — the 90/10 split, observable directly in `kubectl logs`.

## 2. Why it exists in production

Three problems Layer 6 addresses that real platform teams hit once they have more than a handful of services:

### 2.1 Encryption-in-transit between services without per-app TLS

Without a mesh, "TLS between services" means every app has to terminate certs, rotate them, and trust the right CA. Two app teams, two cert mgrs, two ways to misconfigure SNI. A mesh moves that to the platform: a single root CA, automatic mTLS for every connection between mesh pods, automatic rotation. The app stays on plain HTTP — Envoy/ztunnel handles the wire. PCI-DSS, HIPAA, and most internal compliance checklists ask for in-cluster TLS; this is the cheapest way to provide it.

### 2.2 Identity-aware authorization

K8s `NetworkPolicy` operates on namespace+podSelector — L3/L4 only. "Service A can call service B" maps to "pods with label X can reach pods with label Y on port Z". That breaks when:
- Two apps with different security postures share a namespace.
- You want to allow only specific HTTP paths or methods.
- The source's *workload identity* matters, not its IP.

`AuthorizationPolicy` on the mesh uses SPIFFE identities (`cluster.local/ns/<ns>/sa/<sa>`). It survives pod restarts, IP changes, and works at L7 with a Waypoint. The blast radius of a compromised pod gets tighter: even with a routable IP, it can't call services its SA isn't allowed to.

### 2.3 Decoupled traffic management

Canary, blue-green, retries, timeouts, circuit breaking, request mirroring — without a mesh, every app team writes them differently (or, more commonly, not at all). With a mesh, these are declarative L7 primitives (`VirtualService`, `DestinationRule`). The change is a YAML PR; ArgoCD applies it; both Node and Go workloads behave the same way. The platform team stops being the bottleneck for "we want to roll out v2 to 10% of users."

## 3. What we built

### File layout

```
service-mesh/
├── README.md                                  ← this file
├── values/                                    ← Helm values for the Istio + Kiali charts
│   ├── istio-base-values.yaml
│   ├── istiod-values.yaml                     ← profile: ambient
│   ├── istio-cni-values.yaml                  ← profile: ambient + ambient.enabled
│   ├── ztunnel-values.yaml
│   └── kiali-values.yaml                      ← anonymous auth, points at Layer 4 Prometheus
└── manifests/
    ├── kustomization.yaml
    ├── peer-authentication.yaml               ← mesh-wide STRICT mTLS
    ├── authorization-policies.yaml            ← default-deny + explicit allows per ns
    └── canary/
        ├── kustomization.yaml
        ├── mesh-test-namespace.yaml           ← Ambient-labelled namespace for the curl loop
        ├── waypoint.yaml                      ← Gateway w/ class istio-waypoint
        ├── destination-rule.yaml              ← v1 / v2 subsets keyed by `version` label
        ├── virtual-service.yaml               ← 90/10 split
        └── curl-client.yaml                   ← in-mesh curl driving demo traffic

gitops/applications/                           ← seven new Applications, all sync-waved
├── gateway-api-crds.yaml                      ← wave -10
├── istio-base.yaml                            ← wave -5
├── istiod.yaml                                ← wave 0
├── istio-cni.yaml                             ← wave 1
├── ztunnel.yaml                               ← wave 2
├── kiali.yaml                                 ← wave 5
└── service-mesh-policies.yaml                 ← wave 10
```

Modifications to existing files:

| File | Change |
|---|---|
| `gitops/workloads/sample-app/base/namespace.yaml` | + label `istio.io/dataplane-mode: ambient` |
| `gitops/workloads/inventory-api/base/namespace.yaml` | + label `istio.io/dataplane-mode: ambient` |
| `gitops/workloads/sample-app/base/deployment.yaml` | + `version: v1` label on pod template AND selector |
| `gitops/workloads/sample-app/base/service.yaml` | + label `istio.io/use-waypoint: sample-app-waypoint` |
| `gitops/workloads/sample-app/base/kustomization.yaml` | + `deployment-v2.yaml` resource |
| `gitops/workloads/sample-app/base/deployment-v2.yaml` | NEW — `version: v2` label, `APP_VERSION=2.0.0` env |

### Apply sequence (from a Layers 1–5 cluster)

```powershell
# 1. Merge this branch. ArgoCD's root app-of-apps picks up the seven new
#    Applications and applies them in sync-wave order:
#
#       wave -10  gateway-api-crds         (Gateway / HTTPRoute CRDs)
#       wave  -5  istio-base               (Istio CRDs + istio-system ns)
#       wave   0  istiod                   (control plane)
#       wave   1  istio-cni                (CNI DaemonSet for redirect)
#       wave   2  ztunnel                  (L4 data plane DaemonSet)
#       wave   5  kiali                    (UI)
#       wave  10  service-mesh-policies    (PeerAuth + AuthZ + canary)
#
# 2. ONE manual step (sample-app v1 Deployment's selector changes — see §6.1):
kubectl delete deployment sample-app -n sample-app
# ArgoCD will re-create it within ~60s with the new selector.

# 3. Verify mTLS + AuthZ + canary all work end-to-end:
kubectl get peerauthentication -A
kubectl get authorizationpolicy -A
kubectl get gateway -n sample-app   # the waypoint
kubectl get virtualservice,destinationrule -n sample-app

# 4. Watch the canary split happen:
kubectl logs -n mesh-test -l app=curl-client --tail=30 | grep -oE '"version":"[^"]+"'
# Expect ~9 "version":"1.0.0" + ~1 "version":"2.0.0" per 10 lines.

# 5. Open Kiali:
kubectl port-forward svc/kiali -n istio-system 20001:20001
# http://localhost:20001/kiali — the Graph view shows mesh-test → sample-app
# with v1/v2 split visible, plus inventory-api as a separate cluster.
```

### What ends up in the cluster

| Namespace | What |
|---|---|
| `istio-system` | istiod (control plane, 1 replica), istio-cni-node (DaemonSet), ztunnel (DaemonSet), kiali (1 replica), the sample-app waypoint (DaemonSet of 1) |
| `sample-app` | The v1 Deployment (2 replicas, label `version: v1`), the v2 Deployment (1 replica, label `version: v2`), the existing Service (now with `use-waypoint` label), DestinationRule, VirtualService |
| `inventory-api` | Same pods, plus AuthorizationPolicies allowing only the sample-app SA + Prometheus |
| `mesh-test` | The curl-client Deployment, its SA, hammering sample-app every 2 s |

Resource usage rough estimate on the AKS user node pool: +200 Mi RAM for istiod, +50 Mi/node for the CNI DaemonSet, +150 Mi/node for ztunnel, +200 Mi for kiali, +100 Mi for the waypoint, +16 Mi for the curl client. **~800 Mi total**, comfortably under the 2-node user pool's headroom but might push KPS's autoscaler if your starting state is already loaded.

## 4. Lab vs Production

| Concern | Lab (this code) | Production |
|---|---|---|
| **Mesh mode** | Ambient (no sidecars) | Ambient is the modern default; sidecar mode still valid for fine-grained per-pod resource limits or apps that need Envoy-specific filters |
| **mTLS mode** | `STRICT` from day 1 | `PERMISSIVE` during migration, then `STRICT` once all clients are in the mesh. The migration is a multi-week project in a 100-service cluster |
| **AuthorizationPolicy posture** | Default-deny + explicit allows | Same posture; production has dozens of allow rules per namespace, generated from a service catalog rather than hand-maintained |
| **Waypoints** | One per app namespace, on-demand | Same; some shops do per-SA waypoints for stronger isolation, at higher cost |
| **Ingress** | None — port-forward + in-mesh curl client for testing | Istio Gateway (or Gateway API `Gateway` of class istio-egress) fronts the mesh from the public internet, terminates TLS, routes by host/path |
| **Kiali auth** | `anonymous` — anyone with port-forward gets admin | `openid` against Entra ID or `token` with K8s RBAC; same OIDC config you wire into ArgoCD + Grafana |
| **Replicas** | istiod 1, kiali 1, waypoint 1 | istiod 3 behind a PDB, kiali 2, waypoint per namespace HPA'd on RPS |
| **Resource limits** | Conservative (200m CPU per istiod, 256Mi) | Sized via Prometheus during steady state — istiod CPU is dominated by config-push fan-out, scales with #endpoints |
| **Canary rollout mechanism** | Hand-edit VirtualService weights in git | Same git-driven flow, but driven by an automation: [Flagger](https://flagger.app/) or [Argo Rollouts](https://argoproj.github.io/argo-rollouts/) reads Prometheus SLO and auto-promotes once burn-rate is acceptable |
| **Telemetry** | Mesh emits `istio_*` metrics to in-cluster Prom + Managed Prom (both already configured to scrape) | Same + a tracing backend (Tempo, Jaeger, or Azure Monitor) for distributed traces. Each waypoint emits spans with the service-graph context |
| **Cert management** | Self-signed root CA generated by istiod | Root CA from Vault or `cert-manager` with a long-lived offline root, short-lived intermediate signed by Vault. Required for cross-cluster federation |
| **Multi-cluster** | Single cluster | Istio multi-primary or primary-remote topologies for cross-region traffic, with shared root CA |
| **Cilium integration** | None | If using Cilium CNI: Istio Ambient on top works; Cilium NetworkPolicy + Istio AuthZ together (defence in depth) |

## 5. Key concepts the instructor must own

### 5.1 Ambient vs Sidecar — what actually moved

Sidecar mode runs a full Envoy proxy in every pod, intercepts traffic via iptables rules injected at pod start, and that Envoy does ALL the mesh work (mTLS + L7 routing + AuthZ + telemetry).

Ambient mode splits the work:
- **L4** (mTLS + L4 AuthZ + L4 telemetry) → **ztunnel**, a per-node Rust DaemonSet. One ztunnel pod handles all the pods on its node.
- **L7** (HTTP routing, host/method/path AuthZ, retries, mirroring) → **waypoint proxy**, an Envoy that lives in a namespace or per-SA, and is only deployed if you opt in.

The advantage: a 100-pod node uses ONE ztunnel (~150 Mi) instead of 100 sidecars (~100 Mi each = ~10 Gi). The trade-off: L7 features require a separate hop (client → ztunnel → waypoint → ztunnel → server), which adds ~1 ms of latency.

### 5.2 The Ambient enrolment label

`istio.io/dataplane-mode: ambient` on a Namespace is the single switch. With it:
- istio-cni installs iptables rules in every pod in that namespace at creation, redirecting all traffic to the local ztunnel.
- ztunnel does mTLS + L4 AuthZ + telemetry for that pod's traffic.
- The pod doesn't have a sidecar — it has no Envoy at all.

**Pods that existed BEFORE the label was added do NOT get re-routed automatically.** You need `kubectl rollout restart` on the Deployment to recreate the pods.

### 5.3 SPIFFE identity

Every pod in the mesh has a SPIFFE ID derived from its ServiceAccount:
```
spiffe://cluster.local/ns/<namespace>/sa/<serviceaccount>
```

This is the principal that AuthorizationPolicy matches on (`from.source.principals`). It's also the `Subject Alternative Name` in the pod's mTLS cert. The cert is issued by istiod (the root CA) and rotated every 24h.

The trust chain: a pod's projected SA token → istiod verifies it against the K8s API → istiod issues a cert signed by the mesh's root CA → the pod presents the cert to peers via mTLS handshake → peers verify it against the same root CA. No human ever touches a cert.

### 5.4 Waypoint vs ztunnel — when do you need a waypoint?

| You want… | Need waypoint? |
|---|---|
| Encryption between pods (mTLS) | No — ztunnel does it |
| "Allow pods in ns X with SA Y to call my pods on port Z" | No — ztunnel does L4 AuthZ |
| "Allow GET /api/* but not DELETE /api/*" | **Yes** — that's L7 path/method matching |
| "90/10 traffic split, with the split based on header value" | **Yes** — VirtualService is L7 |
| "Retry 3x on 5xx, with exponential backoff" | **Yes** — retry policy is L7 |
| Request-level telemetry (HTTP method, path, status code) | **Yes** — L7 telemetry is the waypoint |

For our demo, sample-app needs a waypoint (the VirtualService split). inventory-api doesn't (only L4 AuthZ for now).

### 5.5 DestinationRule vs VirtualService

Two CRDs that go together:
- **DestinationRule** says "here's how to divide pods backing this Service into named groups (subsets)." Keyed by pod labels.
- **VirtualService** says "here's how to route requests to a Service — by header, by weight, by path — possibly into a specific subset."

You can use either alone (DR-only for connection-pool tuning, VS-only for routing without subsets), but the canary split needs both.

### 5.6 ServerSideApply for the Istio CRDs

Same lesson as Kyverno + kube-prometheus-stack: the Istio CRDs have very long validation schemas (`VirtualService` alone is ~80 KB). Without `ServerSideApply=true` in the ArgoCD syncOptions, you hit the `metadata.annotations: must be no more than 256 KB` error during apply. Every Istio-related Application in `gitops/applications/` has it set.

### 5.7 PeerAuthentication scope

A `PeerAuthentication` named `default` in `istio-system` with no selector applies to the **entire mesh**. A `PeerAuthentication` in another namespace with no selector applies to that namespace. A selector narrows further (per-workload). The most specific match wins. STRICT in `istio-system` is the cluster-wide default; an app namespace can downgrade to PERMISSIVE during migration if it puts its own PeerAuthentication in place.

### 5.8 The in-mesh curl client trick

`kubectl port-forward` proxies via the kubelet (host network), which bypasses ztunnel. So testing the canary split from your laptop via port-forward gives 100% v1 every time — the VirtualService is never evaluated.

To see the split, the client must be IN the mesh. The `mesh-test` namespace runs a curl loop in a pod with its own SA. That pod's traffic to `sample-app.sample-app.svc.cluster.local` goes through ztunnel → waypoint → backend ztunnel, the waypoint evaluates the VS, and ~10% of requests land on v2. The pod logs become the demo.

This is also true in production: testing canary-routing logic from outside the cluster requires going through your Istio Gateway, not directly to the Service.

## 6. Pitfalls

Confirmed during end-to-end test on 2026-05-26.

### 6.1 The sample-app v1 Deployment's selector changed — Deployment field is immutable

We added `version: v1` to the pod template labels AND to `spec.selector.matchLabels` on sample-app's v1 Deployment, so v1 owns only v1 pods and v2 owns only v2 pods. But `spec.selector` is an immutable field on a `Deployment` — ArgoCD's apply fails with:

```
Deployment.apps "sample-app" is invalid: spec.selector: Invalid value:
  {"matchLabels":{"app.kubernetes.io/name":"sample-app","version":"v1"}}:
  field is immutable.
```

The sample-app Application stays OutOfSync until the operator intervenes.

**Fix:** one-time manual `kubectl delete deployment sample-app -n sample-app`. ArgoCD selfHeal recreates it within ~60s with the new selector. Two ways to avoid the manual step:
- Annotate the Deployment with `argocd.argoproj.io/sync-options: Force=true,Replace=true` so ArgoCD always uses `kubectl replace --force`. Heavier for unrelated edits.
- Vendor v1 under a new name (`sample-app-v1`) and delete the old one — same as the manual delete, just GitOps-driven.

### 6.2 STRICT mesh-wide breaks non-mesh Prometheus scrapes — the biggest gotcha

This was the first pitfall we hit after every component came up. Symptom: every Prometheus scrape against sample-app and inventory-api started returning 0 (or `up{} = 0`), Layer 4 dashboards went dark, Managed Prometheus alerts started firing. The ztunnel logs were unambiguous:

```
error access connection complete src.workload="prometheus-..."
  src.namespace="monitoring"
  dst.workload="sample-app-..."
  error="connection closed due to policy rejection:
         explicitly denied by: istio-system/istio_converted_static_strict"
```

The translation: `PeerAuthentication: STRICT` set on `istio-system` (mesh-wide default) rejects the TCP connection at the ztunnel TLS-handshake layer BEFORE AuthZ is ever evaluated. The Prometheus pod is NOT in the mesh — it has no SPIFFE identity and no mTLS cert — so its plaintext connection is rejected at L4. Our `allow-prometheus-scrape` AuthorizationPolicy never even runs.

**Two viable fixes:**
1. **Add monitoring + kube-system to the mesh** (so Prometheus + ama-metrics get SPIFFE identities and mTLS) — closer to "zero-trust everywhere" but invasive.
2. **Override PeerAuthentication to PERMISSIVE for the namespaces that need to be scraped by non-mesh peers** — mesh-wide STRICT still applies, sample-app and inventory-api accept plaintext, AuthZ decides allow/deny per source. This is what we shipped.

The shipped solution lives in `service-mesh/manifests/peer-authentication.yaml`:

```yaml
# Mesh-wide default STRICT (any new ns starts zero-trust)
PeerAuthentication name=default namespace=istio-system mtls.mode=STRICT
# Per-app override PERMISSIVE (so Prometheus can scrape)
PeerAuthentication name=allow-non-mesh-scrape namespace=sample-app    mtls.mode=PERMISSIVE
PeerAuthentication name=allow-non-mesh-scrape namespace=inventory-api mtls.mode=PERMISSIVE
```

### 6.3 L7 fields in an AuthorizationPolicy without a waypoint silently no-op

The first version of our `allow-prometheus-scrape` policy had `to.operation.paths: ["/metrics"]` — we wanted to constrain Prometheus to ONLY hit `/metrics`, not other routes. That's L7 matching. Without a waypoint on inventory-api (we only deployed one for sample-app to drive the canary), ztunnel can't evaluate path-based rules. The policy was loaded but never matched anything, and connections fell back to `default-deny`.

**Fix:** kept policies L4-only (ports, principals, namespaces). When you genuinely need L7 AuthZ (e.g., "allow GET but not POST"), deploy a Waypoint in that namespace — but be aware that traffic now traverses an extra hop.

### 6.3b Waypoint loses the original principal — pod-level AuthZ sees the waypoint, not the client

The next thing that broke after fixing STRICT: even with PERMISSIVE in `sample-app`, the canary demo started failing with `policy rejection: allow policies exist, but none allowed`. Reason:

- Client → ztunnel → waypoint terminates mTLS → reads VS+DR, picks v1 or v2 → waypoint opens a NEW connection to the backend pod → backend pod's ztunnel sees the connection with source identity `sample-app/sample-app-waypoint`, NOT the original `mesh-test/curl-client`.
- Our backend-pod AuthZ allowed only `mesh-test/curl-client`. The waypoint's identity wasn't on the list → denied.

You have two clean fixes:
- **Move AuthZ to the waypoint** with `targetRefs` pointing at the Gateway. The waypoint sees the original principal. Backend pods then trust anything coming from the waypoint.
- **Allow the waypoint SA at the backend pod** (transitive trust). Simpler but spreads the policy across two layers.

We took a third path: **drop pod-level AuthZ on `sample-app` entirely**. The Service is fronted by the waypoint, but there's no useful pod-level identity check we can do without dealing with the waypoint-passthrough problem. The actual zero-trust teaching is on `inventory-api`, where there's no waypoint and AuthZ is enforced at the pod's ztunnel directly. sample-app keeps `PeerAuthentication: PERMISSIVE` for encryption-aware mesh peers, no AuthorizationPolicy.

### 6.4 ArgoCD reports gateway-api-crds + istiod as OutOfSync forever (cosmetic)

Two ArgoCD Applications stay `OutOfSync` even when the underlying resources are healthy and running:
- `gateway-api-crds` — the CRDs are installed, but ArgoCD's tracking-id labels conflict with the upstream's annotations on `ReferenceGrant`, so it perpetually wants to "apply" a no-op diff.
- `istiod` — the deployment is Healthy with the right revision, but the chart emits some auxiliary resources (a MutatingWebhookConfiguration with rotating CA bundles) that ArgoCD sees as drift on every reconcile.

Both are cosmetic. The mesh works; Kiali shows the traffic graph; the canary split works. Production cleanup is to add `ignoreDifferences` blocks (like we did for the Kyverno CRDs in Layer 5).

### 6.5 Kiali graph empty until ztunnel `istio_*` metrics get scraped

After the mesh came up, Kiali rendered an empty graph for the first few minutes. The reason: the ztunnel and waypoint pods emit Istio's standard metrics on `:15020/stats/prometheus`, and our kube-prometheus-stack Prometheus didn't have a `PodMonitor` selecting them — so the `istio_requests_total` series stayed empty in Prometheus and Kiali had no data to draw.

**Fix:** add a `PodMonitor` selecting `app=ztunnel` and the waypoint pods, into `observability/manifests/istio/`. (Deferred to a follow-up; the canary demo still proves the routing works via the curl-client logs, but the graph view in Kiali stays sparse until the PodMonitor lands.)

## 7. Likely student questions

### "Why Ambient mode instead of the more common sidecar mode?"

Sidecar mode is the historical default — six years of production deployments, more tooling, broader chart ecosystem. Ambient went GA in Istio 1.24 and is the cheaper, simpler default going forward. We chose it because:
- Resource cost is significantly lower for our small cluster.
- The two-layer architecture (ztunnel L4, waypoint L7) makes the concepts cleaner to teach — you can explain mTLS without explaining L7 routing in the same breath.
- Adding a sidecar to every pod requires you to think about its memory limits, its startup ordering, its lifecycle. Ambient avoids that.

The downside: less tooling maturity (Kiali Ambient support is still settling, some tracing integrations lag).

### "If ztunnel handles mTLS for me, why do I need waypoints?"

ztunnel does L4 (TCP) only. It can do mTLS (encrypt the bytes) and decide "allow/deny this connection based on the source's SPIFFE identity and target port." It doesn't read HTTP. So it can't say "allow GET but not DELETE", can't split 90/10, can't retry on 5xx. Waypoints are HTTP-aware Envoy proxies that opt in to those features for the namespaces (or Services) that need them.

### "Does mTLS replace NetworkPolicy?"

No — they're orthogonal. NetworkPolicy operates at L3/L4 on IPs and ports. mTLS provides identity at the application layer. A defence-in-depth setup uses BOTH: NetworkPolicy keeps random pods from even reaching your Service, mTLS ensures only the right workload identity gets a response.

For a dev cluster with Kyverno + Ambient already enforcing a strict posture, NetworkPolicy is the next layer worth adding. Cilium's L7 NetworkPolicy can express some of what Istio AuthorizationPolicy does, but Cilium and Istio AuthZ together is the production-grade setup.

### "Why do you need both DestinationRule and VirtualService for a 90/10 split? Isn't that two CRDs for one job?"

Historical reason: DR existed first (for connection pooling + outlier detection). When VS was added later for routing, it referenced DR's subsets instead of redefining them. Conceptually:
- DR: "here's how pods are grouped"
- VS: "here's how requests pick a group"

You COULD do the split purely with HTTPRoute (Gateway API), which has weighted `backendRefs` and skips the subset concept. We used VS+DR for legacy familiarity — most existing Istio docs assume them.

### "What's the latency overhead of all this?"

Rough numbers from public benchmarks:
- Plain pod-to-pod: ~50 µs
- Through ztunnel (mTLS): +200 µs to +500 µs
- Through ztunnel + waypoint (L7): +1 ms to +2 ms

For HTTP services with millisecond-scale workloads, this is negligible. For latency-critical streaming or microsecond-bound systems (HFT, etc.), you'd skip the mesh for those specific data paths.

### "Can I use this in CI? Run mesh tests on a kind cluster?"

Yes — Istio + Ambient runs on kind/minikube. Useful for end-to-end testing of AuthZ policies and VS rules in CI. The waypoint adds ~10s of startup time per test run.

## 8. References

- **Istio Ambient docs:** https://istio.io/latest/docs/ambient/
- **Gateway API:** https://gateway-api.sigs.k8s.io/
- **Kiali:** https://kiali.io/docs/
- **SPIFFE:** https://spiffe.io/docs/latest/spiffe-about/overview/
- **Flagger (canary automation):** https://flagger.app/
- **Argo Rollouts:** https://argoproj.github.io/argo-rollouts/
- **Kyverno + Istio together (defence in depth):** https://kyverno.io/docs/writing-policies/
- **Istio + Cilium dataplane:** https://docs.cilium.io/en/stable/network/servicemesh/istio/
