# titan apps stage split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `apply/50-apps` into **three** reconcile units so that a manifest which passes every offline gate cannot freeze the database.

**Architecture:** `databases`, `tesla`, and one shared `apps` unit holding `auth`, `coder`, `coder-workspaces` and every future small app. Grouping is by **edit frequency and manifest type**, not by namespace — namespaces were never the constraint. Ordering that does not exist inside a unit becomes explicit in `dependsOn` across units.

**Tech Stack:** Flux kustomize-controller **v1.9.6**, kustomize, k3s v1.35.8+k3s1.

**Spec:** `docs/superpowers/specs/2026-10-19-titan-app-scale-out-design.md` — D1, D2 (as revised below), D5. D3/D4 are Plan B.

## Global Constraints

- **There is no admin context on this box or in CI, and that is a deliberate operator decision, not a gap to work around.** `make dry-run` will therefore always print `SKIPPED`. Do not treat that as a pass. For any PR that moves live objects, say so explicitly and hand `scripts/dry-run-check.sh <context>` to the operator to run from wherever admin credentials exist.
- **`prune` is already off on the `apps` stage** — merged as `1a81071` (PR #80), verified live at 14:11:19Z. Do not re-enable it on that object; this plan deletes it.
- Every stage object gets its own file under `apply/00-bootstrap/` (`AGENTS.md`).
- Every `kustomization.yaml` lists its resources explicitly.
- Never set a top-level `namespace:` in a `kustomization.yaml`.
- `make check` before every commit. Pushing a branch, opening the PR and merging each need separate operator confirmation.

## Measured — planning and execution

**Apply is atomic, and that is the whole reason this plan exists.** From stefanprodan (Flux lead) on kustomize-controller #1170:

> "Flux server-side apply is atomic, if a resource doesn't pass the server-side apply dry-run nothing gets applied."

Confirmed in `fluxcd/pkg/ssa/manager_apply.go`: `ApplyAll` runs the dry-run phase in an `errgroup`, and `g.Wait()` returning an error makes `ApplyAll` return **before the apply loop is entered**. One bad object → zero objects applied. The freeze is **not positional** — a typo in the last file blocks the first object just as thoroughly.

**File order is not load-bearing.** `ApplyAll` calls `sort.Sort(SortableUnstructureds(objects))` and then applies concurrently under `g.SetLimit(m.concurrency)`. Within one Kustomization there is **no ordering guarantee at all**. (An earlier revision of this plan claimed the file order in `apply/50-apps/kustomization.yaml` was load-bearing. It is not, and that claim is deleted.) What `dependsOn` + `healthChecks` across units buys is the only real ordering this cluster can have.

**The `apps` inventory is 43 objects** (`kubectl -n flux-system get kustomization apps -o jsonpath='{.status.inventory}'`):

```
apps       8 Deployment · 7 Service · 5 Ingress · 2 ConfigMap · 1 Middleware · 1 IngressRouteTCP
databases  1 Cluster · 3 Database · 3 DatabaseRole · 1 ScheduledBackup
auth       1 HelmRelease · 1 HelmRepository · 1 ConfigMap
coder      1 HelmRelease · 1 HelmRepository · 1 Ingress
coder-workspaces  1 ResourceQuota · 1 LimitRange · 1 Role · 1 RoleBinding
```

**Ownership lives on the Kustomization, not on the objects.** The live `apps/teslamate` Deployment carries only `deployment.kubernetes.io/revision` — **no `kustomize.toolkit.fluxcd.io/name` annotation exists**, on it or on authentik's or coder's workloads. Ownership is `.status.inventory.entries`. This invalidates the `force: true` takeover an earlier revision specified; see Task 3.

**Now observable, which it was not when this plan was written:** `k8s-reader` gained read on `postgresql.cnpg.io` (PR #79, `f56d2d3`). Cluster health is readable during the migration without an admin context:

```
conditions  Initialized  ConsistentSystemID  Ready  ContinuousArchiving  LastBackupSucceeded
currentPrimary  postgres-1     instances 1/1     timeline 1
```

Also measured: `databases` has **no StatefulSet** — `pod/postgres-1` is owned directly by `Cluster/postgres`, so `get sts` is not a health check here.

## The hazard

`prune` on a Kustomization garbage-collects its inventory when the Kustomization is removed. The `apps` inventory contains `databases_postgres_postgresql.cnpg.io_Cluster` and the authentik and coder `HelmRelease` objects, so a naive split **destroys the production database** and helm-uninstalls authentik and coder via their finalizers.

This is why Task 2 (prune off) landed first, in its own merged commit, and why nothing in this plan may proceed until it is verified live. It is verified: `apps.prune = false` since 14:11:19Z, inventory still 43, every pod at its baseline restart count.

## Why three units and not five

Split by **edit frequency × manifest type**, because the failure mode is a typo and the cost is a freeze:

| unit | contents | why alone |
|---|---|---|
| `databases` | 8 CNPG objects | Never edited, highest consequence, dependency for everything else. A freeze here is unacceptable. |
| `tesla` | 24 objects, hand-written YAML | **Highest typo probability by a wide margin** — it is what gets edited constantly. |
| `apps` | `auth`, `coder`, `coder-workspaces`, future small apps | authentik and coder are `HelmRelease` **objects**: a bad `values` block does not fail the Kustomization at all — the CR applies cleanly and the HelmRelease fails separately. Only a malformed HelmRelease *manifest* propagates, and those are rarely touched. A typo in a future small app freezes coder's *updates*, not coder. |

Five units was the spec's first guess. It buys nothing over three for auth/coder, and every extra unit is another migration step that cannot be dry-run validated on this box.

## Review Focus

1. Does any commit remove objects from one inventory before another claims them?
2. Is `databases` free of any dependency on `tesla` or `apps`? The dependency runs one way.
3. Does every new `kustomization.yaml` list its files explicitly?
4. Does any task assume `make dry-run` ran? It cannot have.

## File Structure

```
apply/00-bootstrap/
  stage-apps.yaml        → replaced by three stage files
  stage-databases.yaml   → new
  stage-tesla.yaml       → new
  stage-apps.yaml        → rewritten, same name, narrower path
apply/50-apps/
  kustomization.yaml     → loses the databases/ and tesla/ entries
  databases/kustomization.yaml  → new
  tesla/kustomization.yaml      → new
```

Graph:

```
certificates ─→ databases ─→ tesla
                      └────→ apps   (auth, coder, coder-workspaces, small apps)
```

---

### Task 0: Extend `crd-check` beyond CNPG — independent, do first

With no admin context, the offline schema gate is the only validation this repo can run against CRs. It currently covers only `vendor/cnpg-crds/`. `k8s-reader` **can read CRDs**, so the rest can be vendored the same way.

- [ ] Vendor the Flux `Kustomization`/`HelmRelease`, Traefik (`Middleware`, `IngressRouteTCP`, …) and cert-manager (`Certificate`, `Issuer`) CRDs into `vendor/`, following the `vendor/cnpg-crds/` pattern.
- [ ] Extend `crd-check` to validate every built object against all vendored CRDs, not just CNPG's.
- [ ] Add a `make update-crds` generalising `make update-cnpg-crds`.
- [ ] Prove it works: introduce a deliberate mis-nested field in a throwaway branch and confirm `crd-check` fails. A gate that has never been seen to fail is not evidence.
- [ ] `make check`, commit, PR, merge with confirmation.

This closes the largest offline-catchable slice of what `make dry-run` would have caught. It does **not** close immutable-field changes or core-type CEL rules — those stay unmitigated, and that is the residual risk the split exists to bound.

### Task 1: Baseline — **DONE 2026-10-19T13:20Z**

Recorded above. Pod baseline for later comparison:

```
postgres-1 r=1 5d16h · authentik-server r=0 22h · authentik-worker r=0 21h · coder r=3 5d16h
teslamate r=23 (last crash 07:08:06Z, before the streaming-cert fix was reconciled at 07:52)
tesla-{redis,streaming,forwarder,wellknown,grafana,fleet-telemetry} r=0 44h
reflector r=1 · reloader r=0
```

CNPG health at 13:40Z, all conditions True, primary unchanged since 2026-10-04, PITR window open from 2026-10-05T08:27Z.

### Task 2: Prune off — **DONE, merged `1a81071` (PR #80)**

Verified live: `apps.prune = false` at 14:11:19Z, inventory still 43, no pod restarted.

### Task 3: Answer the inventory-claim question — **research, no cluster change**

**Open question, and nothing below it may proceed until it is answered:** how does a new Kustomization claim an object already listed in another Kustomization's inventory, given the objects carry no ownership annotation?

- [ ] Read `kustomize-controller` v1.9.6 `internal/controller/kustomization_controller.go` — specifically how `prune` computes removals from `.status.inventory`, and what happens when two Kustomizations list the same object.
- [ ] Determine whether the old unit must stop listing the objects *before* the new ones claim them, or whether the transition is safe in one commit.
- [ ] Record the answer, with the file and function cited, in this plan. **If it is not clean, stop.** Task 2 makes the whole thing revertible; there is no pressure to guess.

An earlier revision of this plan asserted `force: true` here. That was measured wrong and must not be reintroduced without evidence.

### Task 4: Split into three units

One commit. `databases` and `tesla` leave the shared unit; `auth`/`coder`/`coder-workspaces` stay.

- [ ] Create `apply/50-apps/databases/kustomization.yaml` and `apply/50-apps/tesla/kustomization.yaml`, each listing exactly its own files.
- [ ] Remove those entries from `apply/50-apps/kustomization.yaml`.
- [ ] Create `stage-databases.yaml` and `stage-tesla.yaml`; rewrite `stage-apps.yaml` to the narrower path. All three: `interval: 10m0s`, `prune: true`, `dependsOn` per the graph, plus whatever Task 3 says is required.
- [ ] `make check` — `kustomize-listing` must report **0 unlisted**.
- [ ] `make dry-run` → will print `SKIPPED`. **Say so in the PR body** and hand the operator `scripts/dry-run-check.sh <context>` to run before merging.
- [ ] Commit, PR, merge with confirmation.

### Task 5: Verify — and this is now possible without admin

- [ ] `kubectl --context titan -n flux-system get kustomizations` — three units, all `Ready`.
- [ ] **The database check that matters:** `kubectl --context titan -n databases get cluster postgres -o jsonpath='{.status.conditions}'` — every condition still True, `currentPrimary` still `postgres-1`, `timeline` still 1, `instances` 1/1. Any change here means the Cluster was touched. It must not have been.
- [ ] Pod `AGE` and restart counts match the Task 1 baseline in every namespace.
- [ ] Each new unit's inventory sums to the old 43, with no object listed twice and none missing.

### Task 6: Documentation

- [ ] `AGENTS.md`: stage graph; the D1 admission test; that adding an app means a directory **and** a stage file.
- [ ] Record in the spec that D2 landed as three units, not five, and why.
- [ ] Note that Plan B (Tesla namespace move) now only edits namespaces inside the `tesla` unit — the reconcile-unit work is already done.

## Not proven / accepted

- **The inventory-claim mechanism is unknown.** Task 3 exists because guessing here is the one way this plan could damage the cluster. Escape hatch: prune is off, so a failed split is reverted by restoring `stage-apps.yaml` with nothing destroyed.
- **Immutable-field changes and core-type CEL rules remain uncatchable here.** No admin context means no server-side validation, and no offline schema substitutes for those two classes. The split bounds the damage; it does not detect the error.
- **`healthChecks` on a split stage has never run in this cluster.**
- **More units cost gate runtime.** `kustomize-check` and `kustomize-listing` walk every directory. Accepted trade.
