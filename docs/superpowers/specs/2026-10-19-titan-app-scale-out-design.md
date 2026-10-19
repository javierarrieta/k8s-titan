# titan — splitting one reconcile unit before the apps arrive

Status: **proposed**. This file decides the target shape and deliberately excludes the migration;
that gets its own plan once the shape is agreed, because §5 is the dangerous part and it should be
reviewed on its own rather than buried in a structural change.

Written 2026-10-19, the same day TeslaMate was fixed in #74/#75. That incident is the reason for this
file: it produced a crash loop that took nine restart cycles to notice, in a namespace that shares a
Flux Kustomization with authentik.

## 1. The problem, measured

`apply/00-bootstrap/stage-apps.yaml` is one object:

```yaml
name: apps
spec:
  dependsOn: [{name: certificates}]
  interval: 10m0s
  path: ./apply/50-apps
  prune: true
```

No `healthChecks`, no `wait`. `apply/50-apps/kustomization.yaml` lists **17** resource files, and
those 17 include authentik, coder, the CNPG Postgres cluster, and all nine Tesla manifests. One
reconcile unit, one failure domain.

So the failure mode is not "Tesla is noisy". It is:

> **one bad manifest out of thirty freezes authentik**, and authentik is forward-auth for every host
> in this cluster.

That is not hypothetical. Two precedents, both already written down:

- `AGENTS.md`: a `PersistentVolumeClaim` LimitRange carrying `default` with no `max` "passed every
  offline gate and took the `apps` stage down on merge." `make dry-run` is the only gate that sees it.
- `docs/teslamate-runbook.md` §9, 2026-10-19: an authentik proxy provider with no `Application`
  answered 404 for every host, silently in both processes, and Traefik's log said nothing wrong.

Both were green at every gate and both took down more than the thing they touched.

What is actually in `apps` right now:

```
tesla-auth-callback  tesla-fleet-telemetry  tesla-forwarder  tesla-grafana
tesla-redis  tesla-streaming  tesla-wellknown  teslamate      ← 8 deployments
reflector  reloader-reloader                                  ← shared infra, defined in 20-infra
```

The operator's intent for `apps` is **small single-purpose apps where a namespace of their own is
more ceremony than the thing is worth**, and a lot of them are coming. Tesla fails that test on every
axis: 8 deployments, 5 public hostnames (`tesla.`, `grafana.`, `streaming.`, `telemetry.`,
`authorize.`), its own CNPG `Database` and `DatabaseRole`, its own `Certificate` — which needed a
namespace-specific exception to the reflector allow-list in #74 — four Secrets, and its own external
partner account with Tesla. The `tesla-` prefix on eight deployments is the system saying the
namespace is wrong.

Also measured, because it changes what isolation is even worth here:

| | |
|---|---|
| `LimitRange` / `ResourceQuota` in `apps` | none |
| `NetworkPolicy` outside `flux-system` | none |
| NetworkPolicy **enforcement** | **none — see §4** |
| `k8s-reader` | ClusterRole binding, so new namespaces are covered automatically |
| nodes | one |

## 2. Why "give Tesla its own namespace" is the wrong unit

A namespace does not split a Flux Kustomization. If Tesla moves to `tesla` and `apply/50-apps` stays
one Kustomization, **the failure mode is untouched** — a typo in a future small app still freezes
authentik, and now it also still freezes Tesla.

Conversely, splitting the stage while moving nothing removes most of the risk immediately.

So the two changes are independent, and the stage split is the one carrying the value. Doing them
together is fine; doing them in the other order is also fine; doing only the namespace is not worth
the risk.

## 3. Decisions

| # | decision | why |
|---|---|---|
| D1 | `apps` gets a written admission test (§3.1) | Nothing today says what `apps` is for, which is exactly why Tesla went there. A stage name is not a policy. |
| D2 | **one Flux `Kustomization` per app-group directory**, each with `dependsOn: certificates` and its own `healthChecks` | This is the actual blast-radius fix. A bad app reddens only itself. |
| D3 | Tesla moves to namespace `tesla` | Fails D1 decisively; authentik and coder already have their own namespaces for the same reason. |
| D4 | `reflector` and `reloader-reloader` move out of `apps` to a `platform` namespace | They are shared infra that happen to sit in `apps`. Once D1 is written they cannot stay: `apps` will mean "small apps". Leaving them is how the next person loses the rule. |
| D5 | `ResourceQuota` per app-group namespace; `LimitRange` only with **both** `max` and `default` | Single node: a namespace buys nothing against resource exhaustion, quotas are the only real protection. The `max`-less LimitRange is the recorded live-cluster failure (§1). |
| D6 | **NetworkPolicy is deferred, not scheduled** (§4) | Committing policies before enforcement exists produces a manifest that reads as protection and does nothing. |
| D7 | A Loki label-budget check joins the gates before the app count grows | casa's Loki caps `max_label_names_per_series` at 18 and the `labeldrop` list in `apply/20-infra/monitoring/promtail.yaml` is a hard limit, not cleanup. Over the line and the stream is rejected per-pod, silently, with promtail reporting healthy. |

### 3.1 The admission test for `apps`

> `apps` is for small single-purpose workloads where a namespace of their own would be more ceremony
> than the thing is worth: roughly one or two pods, no database of their own, no public hostname of
> their own, no credentials beyond what they read from their own config. Anything that needs its own
> `Certificate`, its own Secret set, its own database, or more than a couple of pods gets its own
> namespace and its own entry in `apply/00-bootstrap/namespaces.yaml`. If you are adding a workload
> and reaching for a name prefix to tell it apart from its neighbours, that prefix is a namespace
> trying to happen.

The last clause is the one that would have caught Tesla.

### 3.2 Where the small apps go

Each new small app is one directory under `apply/50-apps/` with its own `kustomization.yaml` and its
own `Kustomization` in `apply/00-bootstrap/`, all pointing at `apps`. They share a namespace and do
**not** share a reconcile unit. That is the whole point: the namespace is a naming and policy scope,
the Kustomization is the failure domain, and they are deliberately not the same granularity.

## 4. NetworkPolicy is not enforced on this cluster

Read from the live cluster on 2026-10-19:

```
kubectl -n kube-system get deploy,ds
  coredns  local-path-provisioner  metrics-server  traefik
kubectl get pods -A | grep -iE 'network-polic|kube-network|calico|cilium'
  (nothing)
```

k3s is running its default flannel CNI with **no network policy controller**. The API server accepts
`NetworkPolicy` objects, stores them, reports them `Applied` — and enforces nothing. The three
existing policies in `flux-system` are therefore inert today as well.

This inverts the obvious move. Writing default-deny policies right now would produce exactly the
class of manifest this repo exists to prevent: one that reads as protection, passes every offline
gate, and does nothing. A silently-inert security control is worse than no security control, because
nobody goes looking for the hole.

So D6 is a deferral with a precondition, not a backlog item:

1. Enable enforcement — k3s' `--enable-network-policy-controller` (runs `kube-network-policies`), or
   a CNI that enforces. That is a `nixos-configurations` change, not a change in this repo.
2. Prove enforcement with a deny-all that actually breaks something, then remove it. A policy that has
   never been observed to deny is not evidence.
3. Only then write the two that matter: the public mTLS intake on `telemetry.:443`, and redis
   reachable only by `tesla-fleet-telemetry` and `tesla-forwarder`.

## 5. The dangerous step, stated before anyone runs it

`prune: true` means **moving a namespace deletes the old objects**. For Tesla that includes
`teslamate-secrets`, which holds `ENCRYPTION_KEY`. If the new namespace's Secret is not present and
correct before the old one is pruned, the next TeslaMate restart comes up with a token store it
cannot decrypt — and per `docs/teslamate-runbook.md` §2 that means every paired vehicle must be
signed in again, and regenerating the key is the way to make that permanent.

Therefore:

- **Create before delete, never the reverse.** Land the new namespace and its Secrets in one change,
  prove the workload reads them, and only then remove the old ones in a separate change.
- The four affected sops files (`teslamate-secrets`, `tesla-grafana-admin`, `tesla-oauth`,
  `tesla-wellknown`) carry `namespace:` inside the encrypted document, so the file itself changes —
  and `make secrets-placement` fails a Secret in `10-secrets` that is not listed in that directory's
  `kustomization.yaml`, which is the guard that catches a half-done move.
- `teslamate-db-credentials` stays in `databases` and must not move; it is what CNPG's `DatabaseRole`
  reads.
- The forwarder hardcodes `http://tesla-streaming.apps.svc.cluster.local/` in its ConfigMap
  (`apply/50-apps/tesla/forwarder.yaml:34`). A namespace move that misses it produces a forwarder
  that connects happily to nothing.
- The forward-auth `Middleware` must move with the Ingress — Traefik resolves middleware only in the
  Ingress's own namespace. That object has already cost this repo several hours (§9 of the runbook);
  do not reopen the suffix question while moving it.
- Reflector allow-lists need editing in two files: `titan-wildcard.yaml` (`apps,auth`) and
  `tesla-streaming.yaml` (`apps`).
- Loki's `namespace` label changes, so any casa-side dashboard or alert keyed on `namespace="apps"`
  stops matching. That is in k8s-casa, not here, and no gate in this repo can see it.

## 6. Target shape

```
apply/00-bootstrap/
  stage-apps.yaml            → replaced by one stage file per app-group
  namespaces.yaml            → + tesla, + platform
apply/50-apps/
  authentik/     → Kustomization `authentik`     ns auth
  coder/         → Kustomization `coder`         ns coder
  databases/     → Kustomization `databases`     ns databases
  tesla/         → Kustomization `tesla`         ns tesla      (D3)
  <each small app>/ → its own Kustomization      ns apps      (D2, §3.2)
apply/20-infra/
  reflector/, reloader/                                        → ns platform   (D4)
```

`dependsOn` stays as it is: everything app-shaped depends on `certificates`. Splitting the stage does
not change the ordering, only the blast radius.

## 7. Verification

Nothing here is done until these pass, and the last two need an admin context:

```bash
make check                       # includes kustomize-listing: every manifest listed, none unlisted
make dry-run DRYRUN_CONTEXT=<admin context>   # the only gate that sees the LimitRange class of error
kubectl --context titan get kustomizations -n flux-system     # every app-group Ready, independently
```

And the acceptance test that actually matters, which is not in this repo's reach:

- §4's synthetic `redis-cli PUBLISH` from `docs/teslamate-runbook.md` reaches TeslaMate **after** the
  move. It is the only way to prove redis → forwarder → bridge → TeslaMate survived a namespace
  change, and it does not need the car. `k8s-reader` is Forbidden on `pods/exec` in `apps`, so this
  needs an admin context.

## 8. Not proven / accepted

- **No availability gain.** One node. A namespace does not make a workload survive anything; it bounds
  the blast radius of a bad manifest and makes policy expressible. Anyone selling this as resilience
  is selling the wrong thing.
- **More Kustomizations cost reconcile time and more gate runtime.** `make kustomize-check` and
  `kustomize-listing` walk every directory; thirty small apps is thirty more entries to keep honest.
  That is the intended trade, but it is a trade.
- **`platform` as a name is a guess.** `certificates` already exists and reflector is arguably cert
  plumbing; the alternative is folding reflector there and leaving only reloader. Not decided here on
  purpose — it is a one-line change and arguing it now is cheaper than discovering it mid-migration.
- **NetworkPolicy enforcement is out of scope and out of this repo.** It lives in
  `nixos-configurations`. Until it lands, D6 stays deferred and this cluster has no network
  segmentation at all. That is a real, currently-accepted exposure, and it should be read as such
  rather than as a TODO.
- **The `apps` stage has never been split**, so the per-app `healthChecks` behaviour is untested here.
  The first small app added after this change is the real test of D2.
