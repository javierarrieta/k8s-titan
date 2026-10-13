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
| kube-state-metrics | `ScrapeConfig/titan-k8s-scrape` → `titan-kube-state-metrics` | `:6443` service proxy | bearer token |

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

### Rotating it

```bash
# 1. on titan, with an admin context
kubectl -n monitoring delete secret scrape-token
kubectl -n monitoring get secret scrape-token -o jsonpath='{.data.token}'   # controller refills it

# 2. in k8s-casa: re-stage, re-encrypt, commit
B64=$(printf '%s' "$NEW_TOKEN" | base64 -w0)   # then edit apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml
sops --encrypt --in-place apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml
make validate
```

**The consequence window is real and expected:** between the delete and casa's apply, all
six authenticated targets return 401. `up` still exists — it is `0` — so every `absent()`
guard stays silent and **`TargetDown` is the only alert that fires.** That is not a second
incident; it is the rotation in progress.

## What is deliberately not scraped

Saying this out loud, because an unlisted metric looks exactly like a healthy zero.

- **etcd.** k3s binds etcd's `:2381` to loopback (measured: connection refused). Reaching
  it needs a k3s flag change and a restart of the only server. The shipped
  `kube-prometheus-stack-etcd` group holds 15 rules, all keyed on `etcd_*` series or
  `up{job=~".*etcd.*"}`, so with no target they produce nothing and **never fire**. Nothing
  in this stack will tell you titan's embedded etcd is unhealthy. That is silence, not a
  passing check.
- **kube-proxy.** There is no such rule to fire: chart 82.18.x ships no kube-proxy rule
  group at all (measured across 45 PrometheusRules / 326 rules in casa's `monitoring`).
  k3s has no kube-proxy — service proxying is kube-router inside `k3s-agent`. The note at
  the foot of `k3s-control-plane-scrape.yaml` calling `KubeProxyDown` a standing false
  positive is stale against this chart pin.
- **CoreDNS, Traefik, CNPG's Postgres exporter, authentik, coder.** Each needs its own
  RBAC and, for Postgres, its own credential. Deferred as a separate slice.
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
