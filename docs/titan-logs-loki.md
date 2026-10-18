# titan logs — where they go, and what to do when they stop

Design and reasoning live in this file because the work is one DaemonSet, not a
subsystem. It is written in the same shape as `titan-metrics-scrape.md`: what is
measured, what is assumed, and the ways this produces a confident wrong answer.

Status: the manifests are in this repo. The receiving half is in **k8s-casa** and was
already live before this existed. Flux syncs `main` in both clusters, so nothing here
does anything until it is merged here.

## The split: two agents, two paths, one Loki

There is no Loki on titan and none is planned. Everything lands in k8s-casa's Loki
(`apply/10-infra/monitoring/loki.yaml` — Loki 6.46.0, SingleBinary, S3 bucket
`loki-home`, TSDB schema).

| what | shipped by | path | lands as |
|---|---|---|---|
| **pod logs** (this file) | `apply/20-infra/monitoring/promtail.yaml`, a DaemonSet in `monitoring` | HTTPS push to `https://loki.local.arrieta.eu/loki/api/v1/push` over wg0 | `{cluster="titan", namespace, pod, container, job, …}` |
| **host journald** | the host itself — `rsyslog.enable = true` in `nixos-configurations/hosts/titan/configuration.nix` | rsyslog `*.*` over wg0 to casa's intake at `192.168.0.41:514` → `rsyslog` → `rsyslog-promtail` | `{hostname="titan", job="syslog", application, facility, level}` |

**The journald half predates this file and is not this file's job.** It is worth stating
because "ship titan's logs to Loki" reads as unfinished work that is in fact half done,
and because adding a `journal` job here would double the volume and produce two label
shapes for the same stream. Proof it is live, not a config that might be inert:

```sh
curl -sS -G https://loki.local.arrieta.eu/loki/api/v1/query_range \
  --data-urlencode 'query={hostname="titan"}' \
  --data-urlencode "start=$(( ($(date +%s) - 900) * 1000000000 ))" \
  --data-urlencode "end=$(date +%s)000000000" --data-urlencode limit=3
```

Real `systemd` lines from `comin-pending-metric.service` came back. (That one is
`$`-arithmetic and `$(( ))` — bash. Under fish, use `set N (date +%s)` and
`math "($N - 900) * 1000000000"`.)

## Why the push URL is what it is

`https://loki.local.arrieta.eu` is published in **public, DNSSEC-valid** OVH DNS and
returns **`192.168.0.42`** — an RFC1918 address. So it is unreachable from the internet
by construction rather than by firewall luck, and titan reaches it only because the
OPNsense WireGuard peer advertises `192.168.0.0/24`. Measured from a pod on titan:
HTTPS 200, certificate validates, no `hostAliases` pin needed (unlike
`s3.l.arrieta.eu`, which is pinned in `nixos-configurations` precisely to keep a resolver
out of the backup path).

**Do not use `loki.casa.arrieta`.** It is the other host on casa's `loki-ingress.yaml`,
it has no TLS entry at all, and it does not resolve from titan: titan's own unbound
split zones serve `casa.arrieta` to mesh *clients*, not to the hub itself.

The URL lives in the SOPS Secret `promtail-secrets` (namespace `monitoring`) even though
the value is public, so that a future Loki auth header or tenant ID lands beside it
instead of forcing the endpoint out of `20-infra`. `make release-secrets` cannot vouch
for it — that gate walks `HelmRelease` `valuesFrom`, and this is a plain DaemonSet — so
the only thing standing between a typo'd name and silence is `make secrets-placement`
checking that the file is listed in `apply/10-secrets/kustomization.yaml`.

## Four places this deliberately differs from the casa and techdelivery copies

Both siblings run the same agent. Copying either one verbatim breaks here, and each
breakage is invisible at deploy time.

**1. `cri: {}`, not `docker: {}`.** All three clusters are k3s + containerd (casa's
nodes report `containerd://2.2.7-k3s1`, techdelivery `2.3.4-k3s1`, titan
`2.2.7-k3s1`). The `docker` stage expects one JSON object per line; a CRI line is not
JSON, so promtail passes it through unparsed and **every stored line keeps its
transport prefix**. This is visible in casa's own streams right now:

```
2026-10-18T19:01:17.327514446Z stderr F {"level":"info","ts":"…"}
```

Not data loss — but it breaks every `| json` and `| pattern` filter downstream. The
`cri` stage strips the prefix, uses the CRI timestamp as the entry timestamp, and
exports `stream` (stdout/stderr).

**2. No `/var/lib/docker/containers` mount.** Dead weight on a containerd node.
`/var/log` alone is sufficient on k3s, proven rather than assumed: casa runs the
identical runtime with the same mount set and its streams carry
`filename=/var/log/pods/<ns>_<pod>_<uid>/<container>/0.log`, so those are real files,
not symlinks into `/var/lib/rancher/k3s`.

**3. Positions on a hostPath, not `/tmp/positions.yaml`.** In `/tmp`, every promtail
restart forgets its offset and re-reads every file under `/var/log/pods` from the
start — a duplicate burst concentrated on exactly the pod that is crash-looping.

**4. No tolerations.** The siblings carry
`node-role.kubernetes.io/master:NoSchedule`. `titan` reports **no taints at all**
(`.spec.taints` is empty; techdelivery's single node is the same), and on k3s 1.35 the
label that toleration names is `control-plane` anyway. A toleration the node does not
carry is how a scheduling assumption outlives the fact.

## The label budget, which is a hard limit not a style rule

casa's Loki runs `limits_config.max_label_names_per_series: 18`. The `labelmap` on
`__meta_kubernetes_pod_label_(.+)` maps **every** pod label into the stream, so a
heavily-labelled pod plus `namespace`/`pod`/`container`/`job`/`cluster`, promtail's
`service_name` and Loki's ingest-time `detected_level` goes over the line — and the
rejection is **per stream and silent at the DaemonSet**. promtail reports healthy; Loki
simply has no data for that pod.

The `labeldrop` list in the ConfigMap is what keeps the worst real pod under 18.
`filename` is the expensive one: it embeds the pod UID, so every restart mints a new
series nobody queries. `container` already separates containers, so dropping it costs
nothing. casa keeps `filename`; that is a cardinality leak, not a feature.

Re-measure against live pods before adding labels:

```sh
kubectl --context titan get pods -A -o json | python3 -c 'import json,sys
d=json.load(sys.stdin)
rows=[(len(p["metadata"].get("labels") or {}), p["metadata"]["namespace"]+"/"+p["metadata"]["name"]) for p in d["items"]]
rows.sort(reverse=True)
print(rows[:5])'
```

## `cluster=titan`, and why it is here and nowhere else

Loki had **no `cluster` label at all** before this — `/loki/api/v1/label/cluster/values`
returned empty — while the metrics side has carried `cluster=titan` on every series
since the metrics work landed (`k8s-casa/apply/50-apps/monitoring/titan-k8s-scrape.yaml`
says so in as many words: *"EVERY series here carries cluster=titan, and casa's own
series carry no cluster"*). Without it, `namespace="auth"` means titan's authentik *and*
techdelivery's, and a Grafana panel or an alert cannot tell them apart.

Adding it here only is deliberate and it is also incomplete: casa's and techdelivery's
own promtail still push unlabelled, so the dimension is present for titan and absent
for the others. Series already stored never get one. That is the whole argument for
doing it on the way in rather than "when it hurts".

## Known accepted posture, not a finding

`auth_enabled: false` on casa's Loki means **anyone who can route `192.168.0.42` can
write logs to it** — the whole home LAN and every WireGuard peer. That predates this
change and is why the endpoint resolves to a private address. This file widens the
writer set by one VPS; it does not introduce the property. If it ever needs to go away,
the fix is at the gateway/ingress, not in this DaemonSet.

## The `HOSTNAME` env var, which is the whole reason this failed

The first merged version deployed healthy and shipped nothing, forever:
`1/1 Running`, `RESTARTS 0`, five clean log lines, `positions.yaml` containing
`positions: {}`, `/targets` empty, `promtail_targets_active_total 0`. There was no
error to read at any `log_level`.

Promtail injects a field selector into its own pod informer
(`fulfillKubePodSelector`, `clients/pkg/promtail/targets/file/filetargetmanager.go`):

```go
kube.Selectors = tm.fulfillKubePodSelector(kube.Selectors, hostname)  // spec.nodeName=<hostname>

func hostname() (string, error) {
    if h := os.Getenv("HOSTNAME"); h != "" { return h, nil }
    return os.Hostname()
}
```

In a pod that is not `hostNetwork`, `os.Hostname()` is the **pod name**. Without the
override the informer therefore asks the API for pods scheduled on a node called
`promtail-abcde`. That is a legal query and the API answers it with a valid **empty
list**: the informer syncs, the watch is live, zero target groups are produced, and
nothing is ever logged. Both siblings set
`HOSTNAME` from `fieldRef: spec.nodeName`; the first version of this manifest did not,
and that omission was the entire bug.

Why every obvious check passed anyway, which is what made this expensive:

- `kubectl auth can-i list pods --as=system:serviceaccount:monitoring:promtail` → `yes`.
  RBAC really was correct.
- `kubectl get pods -A --as=system:serviceaccount:monitoring:promtail` → **32 pods**.
  The LIST really does work. A field selector is not an authorization boundary, so the
  empty result is invisible to both commands.
- The pod's TCP connection to `10.63.0.1:443` was `ESTABLISHED`, and `reflector` in the
  same namespace was mirroring Secrets normally, so the API was reachable from pods.
- Editing `__path__` to a catch-all glob changed nothing, because no target group had
  any target for the glob to act on.

The goroutine dump is what ended it: `FileTargetManager.run`, `discovery.Manager.Run`,
`kubernetes.(*Pod).process` and a reflector in `handleWatch` were all alive and healthy.
Nothing was deadlocked; the informer was simply watching an empty set. Enable it with
the CLI flag `-server.profiling_enabled=true` — **not** `server.pprof_enabled` in the
config and **not** `-pprof.enabled`, neither of which exist in 3.6.11; both fail, the
second one loudly at startup.

Three procedural notes from the same investigation. Live edits to the ConfigMap and the
DaemonSet are reverted by the next Flux sync, so an experiment can silently test the
committed config instead of the intended one; promtail logs `sha3sum` of the config it
loaded, and comparing that hash against the previous pod is the only cheap proof that
an edit actually took effect. A third, and the one that fooled this investigation for
longest: **editing the ConfigMap does not restart the pod.** Reloader rolls it only if
`monitoring` is in its namespace list (`apply/20-infra/reloader/reloader.yaml`), and
until it was, the `reloader.stakater.com/auto: "true"` annotation on the DaemonSet did
nothing at all — `kubectl -n monitoring rollout restart ds/promtail` was the only way
to make a config change real. Compare the `sha3sum`; never assume the restart happened. And a diagnostic pattern must be built from the real path
shape: `/var/log/pods/<ns>_<pod>_<uid>/<container>/<file>.log` is **three** segments, so
the catch-all is `/var/log/pods/*/*/*.log`; a four-wildcard version matches nothing and
looks exactly like the bug being hunted.

## Proving it works

Offline, before any push:

    git add -A
    make check
    make dry-run DRYRUN_CONTEXT=<admin context>

`dry-run` is the only gate that asks the live API server; the read-only `k8s-reader`
identity is Forbidden for it.

After merge, in order — each step answers a different failure:

```sh
# 1. scheduled and running
kubectl --context titan -n monitoring get pods -l app=promtail

# 2. config parsed and the push is not erroring (look for "connection refused",
#    "404", "entry too large", "too many label names")
kubectl --context titan -n monitoring logs ds/promtail --tail=50

# 3. it reached Loki. Use a namespace only titan has, so a green answer cannot be
#    another cluster's data.
curl -sS -G https://loki.local.arrieta.eu/loki/api/v1/series \
  --data-urlencode 'match[]={cluster="titan", namespace="databases"}' --data-urlencode limit=3
```

Step 3 has a specific trap. **`namespace="databases"` exists on techdelivery too**, and
before this change a query for it returned a `postgres` stream that was *not* titan's —
techdelivery's pod is `postgres-576c7c55c9-…` (a Deployment ReplicaSet) while titan's
CNPG pod is `postgres-1`. Filtering on `cluster="titan"` is what makes the answer mean
what it says. `coder` and `coder-workspaces` are titan-only namespaces and are the
cheaper sanity check.

## What has NOT been proven

Read this before trusting anything above.

- **Nothing here has run.** The manifests are unmerged; steps 1–3 have not been
  executed against a live titan pod. Everything marked *measured* is about the
  receiving half and the transport, not about this DaemonSet.
- **The label budget was censused against live pods, not guessed — but the census is a
  snapshot.** Measured across the 31 pods running on titan when this was written, after
  the `labeldrop` list is applied: worst case **16 of 18**
  (`databases/postgres-1` and `apps/reloader-reloader`), **0 pods over the limit**. A
  chart that ships more labels than the current maximum can still produce a rejected
  stream, and the rejection is silent — re-run the census command above after any
  chart bump.
- **Volume is unknown.** `coder-workspaces` ships by explicit decision — the Coder
  workspace pods are the highest-volume and the most likely to contain pasted secrets
  in shell output, and the decision was to ship and measure rather than pre-decide. If
  it is bad, a `drop` stage on `namespace=coder-workspaces` is one line.
- **No retention or rate limit is configured for titan's streams.** Loki's limits are
  casa's global ones; nothing here bounds what titan can push.
- **Nothing alerts on absence.** A promtail that stops shipping is visible in its own
  pod, not in Grafana. There is no `absent()` rule for titan logs anywhere, and casa's
  Loki has no log-absence alert.

Out of scope, recorded so it is not silently dropped: adding `cluster` to casa's and
techdelivery's promtail, Grafana log panels, retention/limits, and log-absence
alerting.
