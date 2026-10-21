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
| D2 | **three Flux `Kustomization`s**, grouped by edit frequency and manifest type — `databases`, `tesla`, and one shared `apps` unit — each with `dependsOn` and `healthChecks` | The actual blast-radius fix. Flux apply is **atomic per Kustomization** (a resource failing server-side dry-run means nothing in that unit is applied), so the unit boundary is the failure boundary. Five units was the first guess; auth and coder are `HelmRelease` objects whose bad `values` never fail the Kustomization, so splitting them buys nothing. || D3 | Tesla moves to namespace `tesla` | Fails D1 decisively; authentik and coder already have their own namespaces for the same reason. |
| D4 | `reflector` moves to `certificates`; **`reloader` stays in `apps`** as the one named exception | Reflector's whole contract is the `secretTemplate` annotations on the `Certificate` objects, which live in `certificates`; its own manifest says it "replicates TLS material across namespaces and nothing else". Reloader is a `HelmRelease` plus `HelmRepository stakater` already in `apps`, watching `coder` and `monitoring` — only its home is `apps`, not its scope. It gets no namespace of its own, so `apps` carries one closed, named exception rather than a hole. |
| D5 | `ResourceQuota` per app-group namespace; `LimitRange` only with **both** `max` and `default` | Single node: a namespace buys nothing against resource exhaustion, quotas are the only real protection. The `max`-less LimitRange is the recorded live-cluster failure (§1). |
| D6 | **NetworkPolicy is deferred, not scheduled** (§4) | Committing policies before enforcement exists produces a manifest that reads as protection and does nothing. |
| D7 | A Loki label-budget check joins the gates before the app count grows | casa's Loki caps `max_label_names_per_series` at 18 and the `labeldrop` list in `apply/20-infra/monitoring/promtail.yaml` is a hard limit, not cleanup. Over the line and the stream is rejected per-pod, silently, with promtail reporting healthy. |

**D2 landed as three stages, not five** — `apply/30-databases`, `apply/60-tesla`, `apply/50-apps`,
merged as `5d3a1c6` with `prune` restored in `c7d4dd5`. Verification, all of it readable through the
read-only identity: seven stages `Ready`; inventories 14 + 2 + 27 = 43 total and 43 unique, matching
the pre-split count exactly; every one of the 43 owned objects confirmed present in the API server
after the first `prune: true` reconcile; pod restart counts byte-identical across both changes; and
`ContinuousArchiving=True` throughout, which is the proof the database never blinked. `healthChecks`
from the original D2 wording were **not** added — `dependsOn` alone produced the ordering the split
needed, and adding a second ordering mechanism to prove the first one worked would have been noise.

### 3.1 The admission test for `apps`

> `apps` is for small single-purpose workloads where a namespace of their own would be more ceremony
> than the thing is worth: roughly one or two pods, no database of their own, no public hostname of
> their own, no credentials beyond what they read from their own config. Anything that needs its own
> `Certificate`, its own Secret set, its own database, or more than a couple of pods gets its own
> namespace and its own entry in `apply/00-bootstrap/namespaces.yaml`. If you are adding a workload
> and reaching for a name prefix to tell it apart from its neighbours, that prefix is a namespace
> trying to happen.

The last clause is the one that would have caught Tesla.

**Amended 2026-10-21, because this test was read wrongly the next day.** §3.1 decides **namespace**
only. It says nothing about stages, and the sentence "gets its own namespace and its own entry in
`apply/00-bootstrap/namespaces.yaml`" means exactly what it says — a namespace, not a stage. Read as
a stage rule it disqualifies workloads the tree has already placed in `apps`, which is what §3.2 now
says out loud instead of leaving to inference.

### 3.2 Where the small apps go

A new small app is **a subdirectory of `apply/50-apps/` listed in `apply/50-apps/kustomization.yaml`**
— the shape `auth/` and `coder/` already have. It is not a stage: no numbered directory, no
`stage-*.yaml`, no `Kustomization` of its own. Its namespace is `apps` and its failure domain is the
shared `apps` stage.

**The cost is real and is accepted rather than argued away.** Sharing a stage means a typo in one small
app freezes every other member of that stage, including the authentik and coder `HelmRelease`
objects. That is the exact failure mode D2 exists to bound, and this choice declines to bound it for
the cheapest class of workload.

What makes it defensible is what actually fails a Kustomization. A `HelmRelease` with a bad `values`
block does not — the release goes red, the Kustomization stays green, which is why authentik and coder
were never in danger from their neighbours. What does fail one is a malformed manifest: a mis-nested
field, a bad `int` where the schema wants a `Quantity`, a typo'd `apiVersion`. For a one-or-two-pod
app with no database and no hostname of its own, a freeze that clears on the next commit is a
proportionate outcome. For Tesla, with 27 hand-written objects and a database behind it, it was not —
which is why Tesla got `60-tesla`.

**Two axes, and the first draft conflated them.** Own `Certificate`, own Secret set, own database or
more than a couple of pods decide **namespace** (§3.1). They do not decide **stage**. A stage is
bought by object count, edit frequency, and whether freezing your neighbours is tolerable — which is
why Tesla got `60-tesla` (27 hand-written objects, own `Certificate`, own database) and coder and
open-webui did not, despite both having their own namespace, their own Secret set, their own public
hostname and open-webui a database as well.

So the rule is: **an app gets its own namespace when it fails §3.1, and its own numbered stage when
freezing it alongside authentik and coder stops being an inconvenience.** The `apps` stage header
already states the accepted cost — a malformed manifest in a small app freezes coder's *updates*, not
coder — and open-webui's D6 recorded the same reading when it landed in `apps` while literally
qualifying for promotion. Neither was an oversight; the text was the problem.

What is *not* softened: the malformed-manifest class is real, and hand-written YAML is where it lives.
An app whose bulk is large hand-written ConfigMaps — dashboards, rules, generated JSON — is closer to
Tesla's risk profile than coder's, because a `HelmRelease` with bad `values` fails on its own and a
ConfigMap with a mis-nested field fails the whole unit. Promote on that shape as well as on freeze
cost.

The shape that promotes is bulk **authored in this repo**, and the distinction is not pedantry: what
fails the unit is a field someone typed into the wrong nesting. Grafana (2026-10-21) is the case that
forced the distinction, and it stayed in `apps` on purpose — see its design spec §10 for the failure
domain it accepted by doing so. Its 24,671 lines of dashboard ConfigMaps are not authored here: they
are byte-for-byte copies of files k8s-casa owns, changed by one anchored `sed` on the namespace line,
and `make kustomize-check` builds every one of them offline before merge. Copied-and-verified bulk
carries the malformed-manifest risk of its source tree, not of this one; bulk someone edits here
carries it here. Alert rules, recording rules and generated JSON written in this repo are the second
kind, and they promote on shape.

**Promotion is a three-commit change, and the order is not optional.** Moving objects out of a stage
that has `prune: true` makes them stale by `inventory.Diff` the instant the move lands, and Flux
deletes them — then the new stage recreates them from nothing. For a `Deployment` that is an outage;
for a `PersistentVolumeClaim` or a CNPG `Cluster` it is data loss. This is the hazard that made Task 2
turn `prune` off *before* the split, and it applies to every later promotion exactly as it applied
then:

1. `prune: false` on the source stage, its own commit, verified live.
2. `git mv` the app to a new numbered directory, add `stage-<name>.yaml`, list it in
   `00-bootstrap/kustomization.yaml`. Prove the source stage's inventory dropped exactly those
   objects and the new stage's holds only its own.
3. `prune: true` back on the source stage, its own commit, with `stale = 0` proved first.

Doing it in one commit while prune is on is how a stage garbage-collects a database.

One hard rule, learned the expensive way: **a subdirectory of a stage never gets its own
`kustomization.yaml`.** The first draft of this section said small apps would each carry a
`Kustomization`, which put units at `find` depth 3, past `KUSTOMIZE_DIRS`' `-maxdepth 2`, and they
left `crd-check`'s scope silently while it still reported a pass. The cap is off now, so the trap no
longer bites — but a nested `kustomization.yaml` is still a second stage pretending to be a folder,
and the layout convention says a stage is a top-level numbered directory.

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
  (`apply/60-tesla/forwarder.yaml:34`). A namespace move that misses it produces a forwarder
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
  stage-apps.yaml            → replaced by three stage files
  namespaces.yaml            → + tesla
apply/30-databases/ → Kustomization `databases`   ns databases
apply/60-tesla/     → Kustomization `tesla`       ns apps   (ns tesla in D3)
apply/50-apps/
  auth/, coder/, coder-workspaces/, <each small app>/
                 → Kustomization `apps`        ns auth / coder / coder-workspaces / apps
apply/20-infra/
  reflector/   → ns certificates                                   (D4)
  reloader/    → stays ns apps, the named exception                (D4)
```

**One numbered directory = one stage = one Flux `Kustomization`.** That is the repo's layout convention, and the split preserves it by adding `30-databases` and `60-tesla` rather than nesting stages inside `50-apps` — an earlier revision of this section put them *inside* `apply/50-apps`, which builds and reconciles correctly and breaks the convention; the operator caught it in review.

Grouping is by **edit frequency and manifest type**, not by namespace — a stage may span namespaces, and the shared `apps` stage deliberately does. The dependency runs one way: `infra → databases → certificates → {apps, tesla}`.

Ordering across units is the only ordering this cluster can have. Inside a unit, kustomize-controller sorts and applies concurrently (`ApplyAll` → `sort.Sort(SortableUnstructureds(...))`, then an `errgroup` under `SetLimit`), so **file order guarantees nothing** — a point an earlier revision of this document got wrong.

`dependsOn` is unchanged in spirit: `databases` depends on `infra` transitively through the operator
it installs, and `apps` and `tesla` depend on both `certificates` and `databases`. Splitting the
stage does not change what must exist first — it changes what a typo can stop.

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

### 7.1 The two plans

Split deliberately, because they are different risk classes. Bundling them would make the safe change
wait on the dangerous one, and a revert of the second would drag the first with it.

- `docs/superpowers/plans/2026-10-19-titan-apps-stage-split.md` — D2. Touches no Secrets, so it carries
  none of the `ENCRYPTION_KEY` exposure. **Done: merged `5d3a1c6` (split) and `c7d4dd5` (prune restored),
  2026-10-19.** It carried a hazard not obvious from the shape of the change: `prune: true` was live on
  the current `apps` Kustomization (verified on the cluster, and `prune` is the correct v1.9 field name,
  not `gc`), and its inventory contained the CNPG `Cluster` — so a naive stage split garbage-collects
  the production database. Prune was turned off first, in its own merged commit (`1a81071`), which is
  what made the split revertible; it went back on only after each stage's live inventory was proved
  equal to what git builds for it, so the first prune reconcile was a provable no-op.
- `docs/superpowers/plans/2026-10-19-titan-tesla-namespace-move.md` — D3 and D4. **Not executed.** It is
  now smaller than when it was written: the reconcile-unit work it assumed has already been done by
  Plan A, so what remains is editing `namespace:` inside `apply/60-tesla/` (plus the `Namespace` object,
  the `dependsOn`/URL rewrites and the D4 reflector move). It still contains the one irreversible step
  in the programme, and is still gated on §5 of the runbook producing a working telemetry baseline.
  Executing it while `forwarded: 0` would make any breakage unattributable.

**No admin context exists on the agent box or in CI, by operator decision.** `make dry-run` therefore
always skips, and the offline gates plus the unit boundary are the whole mitigation. The residual risk
— immutable-field changes and core-type CEL rules — is named in the plan rather than assumed away.

## 8. Not proven / accepted

- **No availability gain.** One node. A namespace does not make a workload survive anything; it bounds
  the blast radius of a bad manifest and makes policy expressible. Anyone selling this as resilience
  is selling the wrong thing.
- **More Kustomizations cost reconcile time and more gate runtime.** `make kustomize-check` and
  `kustomize-listing` walk every directory; thirty small apps is thirty more entries to keep honest.
  That is the intended trade, but it is a trade.
- **`platform` was this spec's first guess for D4 and is rejected.** It was wrong on evidence, not
  taste: no cluster in this fleet uses it. Live namespaces are `casa`, `auth`, `certificates`,
  `monitoring`, `security`, `kured`, `longhorn-system`, `metallb-system`, `traefik-system`,
  `cattle-system`, `democratic-csi`, `strix-scans`, `apps`, `databases`, `coder`,
  `coder-workspaces`, `k8s-reader`. The convention is a named namespace per app-group and a named
  namespace per infrastructure component — casa runs `kured` and `democratic-csi` as single-pod
  namespaces. A `platform` would have been a fourth convention whose contents mean "things we did not
  know where to put", which is the category error this change exists to remove.
- **`reloader` in `apps` is an accepted wart.** If the single exception ever becomes a problem,
  `reloader-system` following casa's `kured` precedent is a one-line change.
- **NetworkPolicy enforcement is out of scope and out of this repo.** It lives in
  `nixos-configurations`. Until it lands, D6 stays deferred and this cluster has no network
  segmentation at all. That is a real, currently-accepted exposure, and it should be read as such
  rather than as a TODO.
- **The `apps` stage has never been split**, so the per-app `healthChecks` behaviour is untested here.
  The first small app added after this change is the real test of D2.
