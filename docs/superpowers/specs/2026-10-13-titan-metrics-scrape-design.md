# titan — scraping titan's node and Kubernetes metrics from k8s-casa's Prometheus

Status: **proposed**. Nothing here is implemented. The design was reached by answering three
questions in order — where node metrics come from, how much of the k8s surface is wanted, and
how a component inside titan's cluster gets read from outside it — and each answer invalidated a
piece of the obvious starting plan.

The question that prompted this was "node-exporter as a DaemonSet here, or in the titan NixOS
config, or both". The answer turned out to be **neither, and no NixOS change at all**, because
both halves of that question were already solved and one of them was solved better than the
DaemonSet would have.

## 1. What is already true, measured rather than assumed

| fact | where it comes from |
|---|---|
| `node_exporter` runs on titan, on the mesh at `192.168.133.1:9100` | `nixos-configurations/hosts/titan/configuration.nix:388` → `prometheus.nodeExporter.enable = true`, via `modules/nixos/prometheus.nix` |
| casa already scrapes it | `k8s-casa/apply/50-apps/monitoring/node-exporter-titan.yaml` — `ScrapeConfig/casa-titan`, `job=casa.hosts`, `namespace=titan`; path measured live 2026-10-12 |
| …and comin's exporter on `:4243` | the final `comin-devices` entry in `prom-scrapes.yaml` |
| `6443 9100 4243 10250 10257 10259` are open to the mesh **and** to `192.168.0.0/24` | `modules/nixos/public-host.nix` `meshTCPPorts` default, plus `publicHost.meshTCPPortExtraSources = [ "192.168.0.0/24" ]` on titan |
| a casa Prometheus pod arrives at titan from the LAN, not a mesh `/32` | the header of `node-exporter-titan.yaml`: the pod is SNAT'd to whichever node it runs on, and is *not* pinned — which is why the whole LAN is whitelisted rather than a `/32` |
| titan's controller-manager and scheduler metrics are **not** loopback-trapped | `hosts/titan/vars.nix`: `k3s.controlPlaneMetricsBindAddress = "0.0.0.0"` |

The last two rows are the load-bearing ones. `k8s-casa/apply/50-apps/monitoring/k3s-control-plane-scrape.yaml`
records that on the casa cluster, `:10257` and `:10259` refused connections because k3s binds them
to `127.0.0.1`, and a Nix module option was written to fix it. titan already sets that option, so
the problem never arises here.

**Consequence: nixos-configurations needs no change.** Every port this design scrapes is already
listening and already reachable from the source address casa's Prometheus actually presents.

## 2. Why not a node-exporter DaemonSet

casa's own convention *is* a DaemonSet — the `kube-prometheus-stack` chart ships
`prometheus-node-exporter` with a `PodMonitor` and a textfile hostPath mount. Copying that here
would be a regression, for three separate reasons:

1. **Port collision or unreachability.** The host already owns `:9100`. A `hostNetwork` pod
   conflicts with it; a pod-network pod is not reachable from another cluster at all.
2. **It cannot produce the metrics that matter most on this host.**
   `k3s_etcd_snapshot_age_seconds` and `k3s_etcd_snapshot_check_success` come from
   `modules/nixos/k3s-snapshot-monitor.nix`, a host systemd timer running `k3s etcd-snapshot list`
   with S3 flags that a pod would not have. Those two gauges are the only thing that makes a
   silently-broken etcd backup visible (Rancher #14144); six configuration defects were caught by
   them on 2026-10-03. A DaemonSet exporter has no access to that.
3. **It would break existing alert coverage.** `job=casa.hosts` is what puts titan's NVMe inside the
   per-host rules such as `DiskSpaceLow`, which are written without a job filter. A second job
   re-emitting the same host metrics under different labels does not add coverage, it dilutes it.

So: node metrics stay exactly as they are. The work in this spec is Kubernetes metrics only.

## 3. Scope

Chosen: **control plane + containers + workload object metrics.**

In scope: kube-apiserver, kubelet, cAdvisor, kube-controller-manager, kube-scheduler, and
kube-state-metrics — the last of which is what makes the shipped `kubernetes-apps` and
`kubernetes-resources` rule groups mean something for authentik, coder and the CNPG clusters.

Out of scope, stated rather than quietly dropped:

- **etcd metrics.** k3s binds etcd's `:2381` to loopback. Reaching it needs a k3s flag change and
  a server restart on the only node in the cluster. The shipped etcd rules stay inactive, which is
  a known gap, not a passing check.
- **Application metrics**: CNPG's per-cluster Postgres exporter, authentik `:9300/metrics`, coder
  `/metrics`, CoreDNS, Traefik. Each needs its own RBAC and, for Postgres, its own credential.
- **Grafana dashboards for titan.** The node dashboard already picks titan up through
  `casa.hosts`. The Kubernetes dashboards need a `cluster` template variable, which is a separate
  slice of work against a different repo.
- **Alertmanager routing changes** beyond the one inhibit-rule fix in §7.

## 4. Decisions

**D1 — casa pulls directly over the mesh; no Prometheus agent on titan.**
The alternative was a Prometheus agent in titan scraping locally and exposing `/federate`, which
keeps cluster credentials inside titan and survives a mesh outage. Rejected: it adds a component to
run and upgrade, ~200–300 MiB resident on a 150 G single node, and a second place where scrape
config lives, to protect against a mesh outage that is *already* a paging event —
`TitanSnapshotMetricsAbsent` and `CominHostsDownNeedingRestart` both fire on it. Blindness here is
loud, not silent. It also matches the existing convention: casa's target list is hand-curated in
`prom-scrapes.yaml` (AGENTS.md: "the target list must be curated by hand").

**D2 — kube-state-metrics leaves the cluster through the API server's service proxy.**
KSM is ClusterIP-only inside titan. The two ways out were a NodePort plus a new mesh port, or the
apiserver proxy path on the already-open `:6443`.

NodePort was rejected on exposure, not on effort: KSM is unauthenticated, and
`meshTCPPortExtraSources = [ "192.168.0.0/24" ]` means every device on the home LAN — including
the IoT ones nobody trusts — could read titan's full cluster metadata: pod names, namespaces,
container images, environment variable *names*, secret *names*, ingress hosts, node labels.
`hosts/titan/configuration.nix:255` already accepts that blast radius for `:9100` and `:4243`;
KSM is a materially larger payload to hand to the same audience.

The proxy path costs two things, both accepted: KSM's payload (a few hundred KB at titan's size)
transits the apiserver every 30s, and KSM visibility dies with the apiserver — though KSM is an
apiserver watcher and is useless in that moment anyway. In exchange, no firewall change, no new
port, and no unauthenticated listener.

**D3 — kube-state-metrics is a `HelmRelease` from an `OCIRepository`, semver-pinned.**
Consistent with cert-manager and the CNPG operator in this repo, and it gets `driftDetection:
enabled` for free. `replicas: 1`, autosharding off — one node. Rejected: a hand-written Deployment
(fewer lines, but this repo's third-party software comes through Flux's Helm machinery) and the
full `kube-prometheus-stack` chart (pulls in CRDs, alert rules and RBAC that belong to casa).

**D4 — a new ServiceAccount, not `k8s-reader`.**
`k8s-reader` is deliberately Forbidden on Secrets and is the identity agents investigate with;
widening it for a scrape would couple a monitoring credential to every agent that holds it. The new
identity holds exactly three grants and nothing else (§6).

**D5 — the token is minted in titan and stored in k8s-casa.**
ScrapeConfig has no `credentialsFile`; auth is Secret-only. So the credential must live in casa's
tree, sops-encrypted. This is the one genuinely sensitive artifact in the design and §5 treats it
as such.

**D6 — every titan series carries `cluster: titan`; casa's series keep having no `cluster` label.**
Using Prometheus `externalLabels` instead was rejected: external labels are applied to *every*
series that Prometheus stores, including titan's, so `cluster: casa` would stamp titan's data too
unless each scrape overrode it — a footgun that fails silently in the wrong direction. Stamping the
label on the six ScrapeConfigs is local, explicit, and touches nothing that already works.

## 5. The credential chain

1. Flux applies the identity on titan. The ServiceAccount token controller fills `scrape-token`
   in-cluster — the manifest in git carries **no `data`**, exactly like
   `apply/20-infra/k8s-reader/serviceaccount-token.yaml`, which is what lets it live outside
   `apply/10-secrets` and still satisfy `make secrets-placement` (the gate exempts a Secret only
   while it is typed `kubernetes.io/service-account-token` *and* carries no `data`/`stringData`, so
   pasting a real token into it fails the build).
2. Read it out with an admin kubeconfig on titan:
   `kubectl -n monitoring get secret scrape-token -o jsonpath='{.data.token}' | base64 -d`.
3. Write it base64 into a git-ignored staging file under **k8s-casa**/`apply/01-secrets/monitoring/`,
   `sops --encrypt --in-place`, commit. It never appears anywhere in k8s-titan's tree. Casa's
   convention is `data:` with base64 values and a `-secrets.yaml` suffix.
4. Casa's ScrapeConfigs reference it with `bearerTokenSecret`.

What the token can do: read `/metrics` on the apiserver, read the kubelet `nodes/metrics`
subresource, and proxy to one Service in `monitoring`. It cannot read objects, and it cannot read
Secrets. It does not expire — the same trade already made for `k8s-reader`.

**Rotation.** `kubectl -n monitoring delete secret scrape-token` on titan, let the controller
recreate it, re-copy, re-sops, commit casa. Until the new value lands in casa, the six titan targets
return 401 and `TargetDown` fires — visible, not silent. This belongs in a runbook section of
`docs/`, not in tribal knowledge, because the failure will be noticed months later by someone who
was not here for it.

## 6. Manifest inventory

**k8s-titan**

| file | contents |
|---|---|
| `apply/00-bootstrap/namespaces.yaml` | add `monitoring`, same shape and annotation style as the existing six |
| `apply/20-infra/monitoring/scrape-identity.yaml` | SA `prometheus` in `monitoring`; ClusterRole + Binding with `nonResourceURLs: ["/metrics"] get` and `nodes/metrics get`; Role + Binding in `monitoring` for `services/proxy get` |
| `apply/20-infra/monitoring/scrape-token.yaml` | the token *request* Secret, no `data` |
| `apply/20-infra/monitoring/kube-state-metrics.yaml` | `OCIRepository` + `HelmRelease`, `replicas: 1`, ClusterIP `:8080`, small requests |
| `apply/20-infra/kustomization.yaml` | **list all four.** `make kustomize-listing` exists because `coder-db.yaml` was committed, built green, reviewed green, and named by nothing |

**k8s-casa**

| file | contents |
|---|---|
| `apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml` | sops-encrypted token |
| `apply/50-apps/monitoring/titan-k8s-scrape.yaml` | the six ScrapeConfigs (§7) |
| `apply/50-apps/monitoring/titan-k8s-guards.yaml` | `absent()` guards for the titan jobs |
| `apply/50-apps/monitoring/instrumentation-guards.yaml` | one-line change, §7.1 |
| `apply/01-secrets/monitoring/alertmanager-…yaml` | inhibit-rule change, §7.2, separate commit |

## 7. Scrape definitions

Six `ScrapeConfig` objects, all `192.168.133.1`, all `interval: 30s` (the shipped rules' rate
windows assume ≤30s), all labelled `cluster: titan`, all `insecureSkipVerify` where TLS is k3s'
self-signed serving cert.

| object | target and path | forced `job` |
|---|---|---|
| `titan-apiserver` | `:6443/metrics` | `apiserver` |
| `titan-kubelet` | `:10250/metrics` | `kubelet`, `metrics_path=/metrics` |
| `titan-kubelet-cadvisor` | `:10250/metrics/cadvisor` | `kubelet`, `metrics_path=/metrics/cadvisor` |
| `titan-controller-manager` | `:10257/metrics` | `kube-controller-manager` |
| `titan-scheduler` | `:10259/metrics` | `kube-scheduler` |
| `titan-kube-state-metrics` | `:6443/api/v1/namespaces/monitoring/services/…/proxy/metrics` | `kube-state-metrics` |

Three details are carried over from casa's recorded findings rather than reinvented:

- **`metrics_path` must be set by relabeling.** The endpoint's `path` does not become that label.
  Without it, 18 shipped rules that select `{job="kubelet", metrics_path="/metrics/cadvisor"}`
  match zero series — a failure casa already lived through.
- **`honorLabels: true` on kubelet and cAdvisor.** The operator stamps the Service's namespace onto
  the target, which otherwise overrides the real `namespace` label and mislabels volume and
  container alerts. Casa measured 23 of 23 PVCs mislabelled before fixing this.
- **`metricRelabelings` keep-lists on `:10257` and `:10259`.** Casa measured that k3s serves one
  merged registry on 6443/10257/10259 — identical sample counts on all three, and zero
  `controller_manager_*` families on 10257. Without keep-lists these two jobs store a second full
  copy of the apiserver payload under different job names. Casa keeps `up|scrape_.*` for
  controller-manager and `up|scrape_.*|scheduler_.*` for scheduler. **This was measured on the
  casa cluster; step V2 re-measures it on titan before the keep-lists are trusted.**

`sampleLimit` is set generously on every target from day one — casa's Prometheus has an OOM history
(exit 137 at 600 Mi, a 3 Gi limit today, ~15 GiB/day ingest) and a runaway target should truncate
itself rather than restart the evaluator. Limits get tightened to ~2× measured after V4.

### 7.1 `KubeStateMetricsScrapeMissing` goes blind without a change

The existing guard is `absent(up{job="kube-state-metrics"})`. Once titan's KSM is scraped under the
same job name, casa's own KSM scrape can disappear — the exact regression that file was written
for, 37 dead rules and no signal — and the guard will not fire, because titan's `up` still exists.

Fix in the same commit as the scrape: scope it to `absent(up{job="kube-state-metrics", cluster=""})`
and add a `cluster="titan"` twin in `titan-k8s-guards.yaml`. The empty matcher works *because* of
D6: casa's series carry no `cluster` label, so they still match. The honest caveat: if anyone later
adds `externalLabels`, that arm becomes wrong and must be revisited.

### 7.2 Inhibition groups merge across clusters

Titan has `auth`, `certificates`, `cert-manager`, `default`, `flux-system`, `monitoring` and
`kube-system` — every one of which casa also uses. The inhibit rule added in PR #169 is
`equal: [namespace]`, so a titan `KubePodCrashLooping{namespace="auth"}` and a casa info alert in
`auth` share one group and can mute each other.

Fix: add `cluster` to that `equal` list in the sops-encrypted alertmanager config. Titan's `titan`
never compares equal to casa's absent label, so the groups split. This changes grouping fleet-wide,
so it ships as its own commit **after** the scrape is live and its labels are confirmed.

### 7.3 Rules expected to misfire, and the policy about them

`KubeProxyDown` — k3s has no kube-proxy at all; already a documented false positive in casa. The
etcd rule group stays inactive per §3. Rather than pre-emptively muting, the policy is: ship, let a
few days pass, read what actually fires for `cluster="titan"`, and suppress only what is
demonstrably wrong. A rule muted on a guess is a rule nobody will ever re-enable.

## 8. Failure modes

| failure | what happens | what makes it visible |
|---|---|---|
| mesh down | all six titan targets vanish at once | `TargetDown`; `TitanSnapshotMetricsAbsent`; `CominHostsDownNeedingRestart` |
| token rotated or deleted | six 401s | `TargetDown` (`up == 0`), not `absent()` — the targets still exist |
| KSM pod down | proxy returns 503 | `TargetDown` on `job=kube-state-metrics`, plus `KubePodNotReady` from KSM's own series if it is still up |
| apiserver down | every titan series dies together | accepted correlation (D2); `KubeAPIDown` fires |
| new volume OOMs casa's Prometheus | evaluator restarts, WAL replay | `sampleLimit` per target, V4 measurement, and the existing startup-probe fix |
| scrape config silently absent | rules go inactive | `absent()` guards in `titan-k8s-guards.yaml` — the class of failure `instrumentation-guards.yaml` exists for |

## 9. Verification

Each step is cheap and gates the next. Do not skip V2; it is where two guessed details get measured.

- **V1 — RBAC on titan, before any scrape exists.** With the minted token:
  `curl -sk -H "Authorization: Bearer $TOKEN" https://192.168.133.1:6443/metrics | head -3` and the
  same against `:10250/metrics`. Expect samples, not 401.
- **V2 — measure, do not assume.** From a debug pod in casa's `monitoring` namespace, curl the
  apiserver proxy path and confirm the exact URL form (`services/http:NAME:8080/proxy/` vs
  `services/NAME:8080/proxy/`) rather than guessing it. In the same pass, compare sample counts on
  titan's 6443 / 10257 / 10259 to confirm the merged-registry finding holds here before the
  keep-lists are trusted. A debug pod is a valid test here — unlike the llm01 podman-bridge trap
  recorded in `hosts/titan/README.md`, a casa pod's source is the node's LAN address, which titan
  whitelists.
- **V3 — after apply:** `count by (job) (up{cluster="titan"})` → six jobs, all `1`.
- **V4 — cost:** `sum(rate(prometheus_tsdb_head_samples_appended_total[15m]))` before and after,
  recorded here against casa's ~15 GiB/day, 3 Gi limit and 21d/500 Gi retention. Then set
  `sampleLimit` to ~2× observed per target.
- **V5 — test the guards by breaking them.** Point one ScrapeConfig at a dead port and confirm the
  titan `absent()` guard fires; separately confirm `absent(up{job="nonexistent", cluster=""})`
  returns 1, which is the assumption §7.1 rests on. A guard that has never been observed firing is
  a guess.
- **V6 — gates.** k8s-titan: `git add -A && make check` (`kustomize-listing` catches an unlisted
  file; `secrets-placement` rejects a token pasted into `scrape-token.yaml`), plus
  `make dry-run DRYRUN_CONTEXT=<admin context>` — the only check that asks the live API server, and
  the new HelmRelease and namespace are exactly the kind of object it catches. k8s-casa:
  `make validate` and `make check-alert-rules`.

## 10. Rollout order

1. k8s-titan: namespace + identity + token request + KSM. Apply, confirm KSM is `Running` and V1
   passes.
2. Mint and copy the token; sops-encrypt into k8s-casa.
3. k8s-casa: the six ScrapeConfigs and the guards, plus the §7.1 one-liner. Confirm V3–V5.
4. Separately, once labels are confirmed: the inhibit-rule change (§7.2).

Titan first, deliberately. Applying casa's scrapes first produces six red targets and a
`TargetDown` storm for a cluster that has not been told about the scrape yet.
