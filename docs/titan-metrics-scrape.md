# titan metrics — what scrapes this cluster, and what to do when it stops

Design and reasoning: `docs/superpowers/specs/2026-10-13-titan-metrics-scrape-design.md`.
This file is the operational half: the commands, the failure modes, and the two label
traps that produce confident wrong answers.

Status: the manifests are in this repo and in k8s-casa. Nothing here is live until both
trees are on `main`, because Flux syncs `main` in both clusters.

## What scrapes titan, and from where

Everything comes from k8s-casa's Prometheus (`monitoring/prometheus-k8s`), over the
WireGuard mesh, to **`192.168.133.1`** — titan's `wg0` address. Nothing runs a Prometheus
on titan itself.

| what | scrape object (k8s-casa) | target | authenticated |
|---|---|---|---|
| node metrics | `ScrapeConfig/casa-titan` | `:9100` | no |
| comin deploy state | `ScrapeConfig/comin-devices` | `:4243` | no |
| kube-apiserver | `ScrapeConfig/titan-apiserver` | `:6443/metrics` | bearer token |
| kubelet | `ScrapeConfig/titan-kubelet` | `:10250/metrics` | bearer token |
| cAdvisor | `ScrapeConfig/titan-kubelet-cadvisor` | `:10250/metrics/cadvisor` | bearer token |
| kube-controller-manager | `ScrapeConfig/titan-controller-manager` | `:10257/metrics` | bearer token |
| kube-scheduler | `ScrapeConfig/titan-scheduler` | `:10259/metrics` | bearer token |
| kube-state-metrics | `ScrapeConfig/titan-kube-state-metrics` | `:6443` service proxy | bearer token |

Two things about that list are easy to get wrong:

**Node metrics come from the NixOS `node_exporter`, never from a DaemonSet.** The host
already owns `:9100`, and the two `k3s_etcd_snapshot_*` gauges come from a host systemd
timer (`nixos-configurations/modules/nixos/k3s-snapshot-monitor.nix`) that a pod cannot
run. A DaemonSet exporter would collide on the port and could not produce the metrics that
matter most on this box.

**kube-state-metrics is not exposed.** It is a ClusterIP Service in `monitoring`, and its
metrics leave the cluster through the kube-apiserver's service proxy on the already-open
`:6443`. That is deliberate: a NodePort would have to be opened to `192.168.0.0/24` (see
`publicHost.meshTCPPortExtraSources` in `nixos-configurations/hosts/titan/configuration.nix`)
and would be unauthenticated, handing every device on the home LAN titan's full cluster
inventory — pod names, images, env var names, secret names, ingress hosts.

## Measured on the live cluster (2026-10-13)

All six targets, from casa's Prometheus, after both halves merged:

| job | path / port | samples | limit |
|---|---|---|---|
| `apiserver` | `:6443/metrics` | 42,322 | 250k |
| `kubelet` | `:10250/metrics` | 5,352 | 150k |
| `kubelet` | `:10250/metrics/cadvisor` | 42,322 | 250k |
| `kube-state-metrics` | `:6443` proxy | 2,027 | 150k |
| `kube-controller-manager` | `:10257/metrics` | 42,322 scraped → 0 kept | — |
| `kube-scheduler` | `:10259/metrics` | 42,322 scraped → 715 kept | — |

All `up=1`. `count by (namespace) (kube_pod_status_ready{cluster="titan", condition="true"})`
returns real namespaces — `auth`, `coder`, `databases`, `cnpg-system`, `flux-system`,
`cert-manager`, `apps`, `monitoring`, `kube-system`, `coder-workspaces` — so the
`exported_namespace` trap on the kubelet and kube-state-metrics scrapes did not fire.

**It did fire on the apiserver, for a different reason.** k3s' single registry means `:6443` also
serves `kubelet_volume_stats_*`, `kubelet_container_log_filesystem_used_bytes` and
`pv_collector_bound_pvc_count`. Those carry a real namespace, the apiserver target preconfigures
`namespace: titan` without `honorLabels`, and the preconfigured label wins — 31 titan series and 40
casa series reported a namespace that was wrong. Fixed by dropping `kubelet_.*|pv_collector_.*` from
both apiserver targets (k8s-casa#233); the kubelet scrape is the canonical source for those
families. Check with `count({job="apiserver", exported_namespace!=""})` — it should read zero.

**The guards were observed firing**, though not the way anyone would choose: the first merge set the
`job` label on four ScrapeConfigs and not two, so `TitanSchedulerScrapeMissing` and
`TitanControllerManagerScrapeMissing` went pending for targets that were healthy. `absent()` with an
empty `cluster=""` matcher is also confirmed to return 1 for a job that does not exist, which is the
assumption every casa-scoped guard rests on.

## First triage: is it the mesh, titan, or the credentials?

Run this from anywhere with a path to the mesh — **from a host, not a podman container**
(bridge-sourced traffic is `10.88.0.0/16`, which OPNsense's LAN→WG_MESH rule excludes by
design, so a container gives a false negative; see `hosts/titan/README.md`):

```bash
curl -m 6 -sk -o /dev/null -w '%{http_code}\n' https://192.168.133.1:6443/metrics
curl -m 5 -s  -o /dev/null -w '%{http_code}\n' http://192.168.133.1:9100/metrics
```

| result | meaning | next step |
|---|---|---|
| `401` and `200` | path and host are fine | the problem is the token or a component — go to "The token" |
| timeout / `000` on both | mesh or titan is down | `wg show` on the hub, then titan itself |
| `401` but `000` on `:9100` | node_exporter died, mesh is fine | `systemctl status prometheus-node-exporter` on titan |
| `403` on `:10257`/`:10259` | **normal** for an unauthenticated probe | not a fault; those ports answer 403 to anonymous by design |

Then, with a valid token, confirm the grants rather than guessing which one is missing:

```bash
TOKEN=$(kubectl -n monitoring get secret scrape-token -o jsonpath='{.data.token}')
for p in 6443/metrics 10250/metrics; do
  curl -m 8 -sk -o /dev/null -w "$p -> %{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" "https://192.168.133.1:$p"
done
```

`401` means the token is not the one the cluster issued (or was deleted). `403` means it is
a valid token whose RBAC is missing a grant — check `apply/20-infra/monitoring/scrape-identity.yaml`.

## The token

- **Where it lives:** minted in titan as `monitoring/scrape-token` (a
  `kubernetes.io/service-account-token` request — the git file carries no data, which is
  what `make secrets-placement` enforces). The value lives only in k8s-casa as
  `monitoring/titan-scrape-token`, sops-encrypted.
- **What it can do:** `/metrics` on the apiserver, `nodes/metrics` on the kubelet, and
  `services/proxy` in titan's `monitoring` namespace. It cannot read any object, and it
  cannot read Secrets. It does not expire.
- **It is not `k8s-reader`.** That identity is the read-only investigation identity and is
  deliberately Forbidden on Secrets; keeping the two apart is the point.

### Getting the token — Flux applies it, nobody hand-applies

The git file is a *request*, not a token: it carries no `data`, which is what lets
`make secrets-placement` allow it. Merge to `main` and the chain fills itself — Flux applies the
ServiceAccount, then the request, then the token controller populates `.data.token`. Ordering is
handled by the stage graph, not by a human holding `kubectl apply`.

```bash
# 1. merge the titan branch, then watch titan's Flux do the work
kubectl --context titan -n flux-system get kustomization infra -o wide
kubectl --context titan -n monitoring get sa,role,rolebinding | grep prometheus-scrape
kubectl --context titan -n monitoring get helmrelease kube-state-metrics
```

The read-only `k8s-reader` context sees all of that — it is admin-minus-Secrets — but the token
is the one thing it is Forbidden on, so the operator's part is exactly one read and no apply:

```bash
# 2. the only step that needs an admin context
T=$(kubectl --context <admin> -n monitoring get secret scrape-token -o jsonpath='{.data.token}')
```

Empty means the controller has not filled it yet, or `kubernetes.io/service-account.name` does
not name a real ServiceAccount. It fails by staying empty rather than by erroring, so confirm
the ServiceAccount exists before re-reading.

**Why the filled token survives every later reconcile**, which is the question this raises: the
token is not in git, so Flux's server-side apply never declares `data` and never claims that
field — the token controller owns it. Re-applying the manifest does not blank it.

Prove the grants before moving the value anywhere. `200` is the only acceptable answer:

```bash
printf -v TOK '%s' "$(printf %s "$T" | base64 -d)"
curl -m 8 -sk -o /dev/null -w 'apiserver  %{http_code}\n' -H "Authorization: Bearer $TOK" https://192.168.133.1:6443/metrics
curl -m 8 -sk -o /dev/null -w 'kubelet    %{http_code}\n' -H "Authorization: Bearer $TOK" https://192.168.133.1:10250/metrics
```

`403` means the token is valid and RBAC is missing a grant; `401` means it is not the token the
cluster issued. The kube-state-metrics proxy path 404s until the chart is actually running —
that is a missing workload, not a broken grant.

Then carry it to casa. `data:` wants base64 and `$T` already is base64, so do **not** re-encode
it. Keep it out of shell history and out of any chat transcript:

```bash
cd ~/k8s-casa && git checkout metrics-scrape && umask 077
cat > apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: titan-scrape-token
  namespace: monitoring
type: Opaque
data:
  token: $T
EOF
sops --encrypt --in-place apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml
make validate            # proves it decrypts and the MAC is valid
git add apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml
```

Once `sops --encrypt` has run, that file *is* the artifact — commit it, do not delete it. If you
need to abort instead, `shred -u` the plaintext file before encrypting, and clear `T`/`TOK`.

The last line only applies *before* encryption; after `sops --encrypt` the file is the artifact
and must be committed. If you shred the encrypted file by mistake, re-run the `cat` block.

### Rotating it

```bash
# 1. on titan, with an admin context. The Secret object itself is Flux-owned, so deleting it
# leaves it absent until Flux reconciles -- either wait for the sync interval or ask Flux now.
kubectl --context <admin> -n monitoring delete secret scrape-token
flux --context <admin> --namespace flux-system reconcile kustomization infra --with-source
kubectl --context <admin> -n monitoring get secret scrape-token -o jsonpath='{.data.token}'

# 2. in k8s-casa: overwrite the file with fresh plaintext, THEN encrypt. Running
#    `sops --encrypt --in-place` on a file that is already encrypted double-encrypts
#    it and the result decrypts to garbage -- re-stage from scratch, do not edit in place.
cd ~/k8s-casa && umask 077
T=$(kubectl --context <admin> -n monitoring get secret scrape-token -o jsonpath='{.data.token}')
cat > apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: titan-scrape-token
  namespace: monitoring
type: Opaque
data:
  token: $T
EOF
sops --encrypt --in-place apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml
make validate
```

`data:` wants base64 and the value read above already is base64 — do not re-encode it.

**The consequence window is real and expected:** between the delete and casa's apply, all
six authenticated targets return 401. `up` still exists — it is `0` — so every `absent()`
guard stays silent and **`TargetDown` is the only alert that fires.** That is not a second
incident; it is the rotation in progress.

## What is deliberately not scraped

Saying this out loud, because an unlisted metric looks exactly like a healthy zero.

- **kube-controller-manager metrics beyond liveness — and this one is now measured on titan,
  not borrowed from casa.** k3s serves one merged registry: `:6443`, `:10257` and `:10259` each
  return **42,322 samples**, identically. `controller_manager_*` on titan is **0 series**, so the
  keep-list that retains only `up` and `scrape_*` drops nothing real. Scheduler differs: `scheduler_*`
  is 715 series and all 715 are kept. Without the keep-lists these two jobs would store ~85k
  duplicate copies of the apiserver payload.
- **Nothing that would tighten `sampleLimit` yet.** Measured on day one: apiserver 42,322 against
  a 250k limit (~6×), kube-state-metrics 2,027 against 150k (~74×). The limits are deliberately
  loose until a week of data says otherwise. Know the direction of the risk before tightening:
  exceeding `sample_limit` **fails the scrape**, so `up` goes to 0 and `TargetDown` pages. A limit
  set too tight fabricates an outage; it does not silently drop samples.
- **etcd.** k3s binds etcd's `:2381` to loopback (measured: connection refused). Reaching
  it needs a k3s flag change and a restart of the only server. The shipped
  `kube-prometheus-stack-etcd` group holds 15 rules, all keyed on `etcd_*` series or
  `up{job=~".*etcd.*"}`, so with no target they produce nothing and **never fire**. Nothing
  in this stack will tell you titan's embedded etcd is unhealthy. That is silence, not a
  passing check.

  **The merged registry does not rescue this, and it looks like it should.** `:6443/metrics` does
  carry 7,988 `etcd_*` series — but every one is *client*-side (`etcd_request_duration_seconds`,
  `etcd_requests_total`, `etcd_bookmark_counts`). Measured across `etcd_server_*`, `etcd_disk_*`,
  `etcd_cluster_*` and `etcd_network_*`: **zero**. The rules need server metrics; the apiserver
  exposes the apiserver's own view of etcd. Do not conclude etcd is covered because a query for
  `etcd_.*` returns thousands of series.
- **kube-proxy.** There is no such rule to fire: chart 82.18.x ships no kube-proxy rule
  group at all (measured across 45 PrometheusRules / 326 rules in casa's `monitoring`).
  k3s has no kube-proxy — service proxying is kube-router inside `k3s-agent`. The note at
  the foot of `k3s-control-plane-scrape.yaml` calling `KubeProxyDown` a standing false
  positive is stale against this chart pin.
- **CoreDNS, Traefik, CNPG's Postgres exporter, authentik, coder.** Each needs its own
  RBAC and, for Postgres, its own credential. Deferred as a separate slice.
  Measured 2026-10-19 so the slice has a starting point: the exporter is **already running** —
  `pod/postgres-1` listens on `:9187` (`metrics`) and `:8000` (instance-manager status) — and
  nothing scrapes it. titan has no prometheus-operator CRDs at all (`kubectl get podmonitor`
  returns "doesn't have a resource type"), and there is no metrics `Service` in `databases`,
  only `postgres-r`/`-rw`/`-ro` on 5432. So the KSM trick does not transfer directly: there is
  no Service for the apiserver proxy to reach, and even with one, postgres_exporter needs a
  `pg_monitor`-role credential that does not exist yet. Two independent pieces of work, which
  is why this stayed deferred.
  In the meantime database health is answerable without metrics: `cnpg.io/instanceRole` is a pod
  label, so the read-only identity can already say which instance is primary, and since 2026-10-19
  it can read the `Cluster` status directly.
- **`kube_secret_*`.** Excluded via `collectorsExclude` on the kube-state-metrics
  HelmRelease. The chart's default collector list grants that pod cluster-wide
  `get/list/watch` on Secrets so it can emit metadata, and on this cluster that grant
  reaches `AUTHENTIK_SECRET_KEY`, the CNPG and coder passwords, the OVH DNS credential and
  the S3 backup key. Zero rules in casa reference `kube_secret_*`, so the exclusion is free.
- **Grafana dashboards for titan.** The node dashboard already picks titan up through
  `casa.hosts`; the Kubernetes dashboards need a `cluster` template variable.

## Two label traps

Both produce data that looks present and is wrong.

**1. Never put a `namespace` label on the kubelet, cAdvisor or kube-state-metrics scrapes.**
With the default `honor_labels: false`, a preconfigured *target* label wins over the
scraped one and the scraped value is renamed to `exported_namespace`. Every `kube_*` and
`kubelet_volume_stats_*` series would then report `namespace="titan"` instead of `auth`,
`coder`, `databases`, and every pod and volume alert would group wrong. Check:

```
count by (namespace) (kube_pod_status_ready{cluster="titan", condition="true"})
count by (__name__) ({cluster="titan", exported_namespace!=""})
```

The first must return real namespaces; the second must return **no data**.

The three namespace-free control-plane targets *do* carry `namespace: titan`, so their `up`
series do not land in the empty-namespace inhibition group described in `prom-scrapes.yaml`.

**2. `KubeStateMetricsScrapeMissing` is scoped `cluster=""`.** That is only correct while
casa's own series carry no `cluster` label. If anyone adds `externalLabels: {cluster: casa}`
to the Prometheus CR, that arm stops firing forever and the regression it exists to catch —
kube-state-metrics unscraped, 37 rules dead, nobody noticing — comes straight back. The
titan twin (`cluster="titan"`) lives in `titan-k8s-guards.yaml`.

Related: titan and casa share namespace names (`auth`, `certificates`, `cert-manager`,
`default`, `flux-system`, `monitoring`, `kube-system`). Alertmanager's inhibit rule groups
on `[namespace, cluster]` so the two clusters do not mute each other. If that `equal` list
is ever narrowed back to `[namespace]` alone, cross-cluster muting returns silently.
