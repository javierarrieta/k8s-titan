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
  stage-databases.yaml   → new
  stage-tesla.yaml       → new
  stage-apps.yaml        → rewritten, same name, narrower path
  kustomization.yaml     → lists the new stage files in numeric order
apply/30-databases/      ← NEW STAGE DIRECTORY: postgres.yaml, postgres-backup.yaml
apply/60-tesla/          ← NEW STAGE DIRECTORY: the 9 Tesla files
apply/50-apps/
  kustomization.yaml     → keeps auth/ and coder/ only
```

**Stages are top-level numbered directories, not subdirectories.** The first draft of this plan put
`databases/` and `tesla/` *inside* `apply/50-apps`, which builds and reconciles correctly and breaks
the repo's layout convention: in this tree the numbered directories under `apply/` **are** the
stages, one directory to one Flux `Kustomization`. The operator caught it in review. Nesting stages
collapses separate failure domains back into one directory, which is the opposite of what the split
is for, and it also pushed the new units to `find` depth 3 — where `KUSTOMIZE_DIRS`' `-maxdepth 2`
cap silently dropped them out of `crd-check`. Both facts are in that second bullet for a reason.

Graph:

```
certificates ─→ databases ─→ tesla
                      └────→ apps   (auth, coder, coder-workspaces, small apps)
```

---

### Task 0: Extend `crd-check` beyond CNPG — **DONE**

Vendored `Kustomization`, `HelmRelease`, `Certificate`, `Middleware` and `IngressRouteTCP`.
The gate went from 4 CRDs to 9, and from ~8 objects to **25**.

Two things worth recording, both of which the repo's own gates caught rather than me:

**`GROUPS` is a bash builtin.** The first version of `scripts/update-crds.sh` used it as an
array name, the assignment was silently refused, and the script vendored a CRD named `1000`
(the caller's GID). No error, no warning. The script now says so in a comment.

**`make leak-check` fired twice on this change, and was right both times.** cert-manager's
`Certificate` schema spells certificate policy OIDs — four-part dotted decimals, not
addresses — inside its descriptions, and the IPv4 pattern reads them as concrete public
addresses. The tempting fix was an exclusion, which would have weakened the gate. The correct
fix was to drop descriptions from the vendored schemas: `crd-field-check` walks
`properties`/`items`/`additionalProperties` only and never reads prose. That removed the false
positive, shrank the vendored set from 239 KB to 84 KB, and left the leak gate untouched. The
gate then fired again on this script, because the OIDs were quoted here as literals.

**Provenance differs from CNPG, deliberately.** These three groups are vendored from the live
cluster through the read-only identity (`make update-crds`), not from upstream tags: Traefik
ships its CRDs only inside a release tarball, and the schema the cluster enforces is the one
that will reject our manifest. The files are committed, so CI never needs cluster access.

**Proven to fail, not just to pass.** Mis-nesting a real field — moving a `Kustomization`'s
`interval` under `sourceRef` — is caught and reported as `spec.sourceRef.interval`, the same
class as the CNPG `retentionPolicy` outage that created this gate. Unknown keys in `Middleware`
and `HelmRelease` are caught too.

**What it still cannot do:** validate values. Wrong enums, bad quantities and core-type CEL
rules remain invisible offline, and immutable-field changes with them. That gap is why the split
exists, and the Makefile comment now says so rather than implying the gate is complete.

- [x] Vendor the Flux, cert-manager and Traefik CRDs.
- [x] Extend `crd-check` to validate against all vendored groups.
- [x] `make update-crds`, generalising `make update-cnpg-crds`.
- [x] Prove the gate fails on a deliberate mis-nested field.
- [x] `make check` green, commit, PR, merge with confirmation.

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

### Task 3: The inventory-claim question — **ANSWERED, from the v1.9.6 source**

Read directly rather than assumed. Files: `internal/controller/kustomization_controller.go`,
`api/v1/kustomization_types.go`, `fluxcd/pkg/ssa/manager_apply.go`.

**1. There is no ownership annotation and no ownership-conflict check in v1.9.6.** Grepping the
controller for `OwningKustomizeAnnotation`, `SetKustomizeMetadata` and `unknown or non-usable`
returns **zero hits**. That matches what was measured on the cluster — no
`kustomize.toolkit.fluxcd.io/name` on any live object. Adoption is plain server-side apply with
`client.ForceOwnership` and field owner `kustomize-controller`, which is the same field manager for
every Kustomization, so **a second Kustomization applying an object already applied by another simply
succeeds.** No takeover step is needed.

**2. `force` was never an ownership mechanism.** `ApplyOptions.Force` in `fluxcd/pkg/ssa` is
documented as: *"configures the engine to recreate objects that contain immutable field changes."*
The original revision of this plan was wrong twice over — wrong that it was needed, and wrong about
what it does.

**3. Prune is driven entirely by the inventory diff.** In `reconcile()`:

```go
oldInventory := inventory.New()          // snapshot of status.inventory
... apply ...
newInventory := inventory.New()
inventory.AddChangeSet(newInventory, changeSet)   // built from what THIS pass applied
obj.Status.Inventory = newInventory
staleObjects, _ := inventory.Diff(oldInventory, newInventory)
r.prune(ctx, ..., staleObjects)
```

and `prune()` opens with:

```go
if !obj.Spec.Prune {
    return false, nil, nil
}
```

So with `prune: false`, objects removed from the path are **orphaned, not deleted**. Task 2 was not
merely prudent — it is the mechanism that makes the transition safe.

**4. Deleting a Kustomization is also covered.** `finalizerShouldDeleteResources()` switches on
`GetDeletionPolicy()`, and `GetDeletionPolicy()` returns `DeletionPolicyMirrorPrune` when unset —
which is this repo's state. `MirrorPrune` returns `obj.Spec.Prune`, i.e. **false**. Note the
asymmetry: `DeletionPolicyDelete` and `WaitForTermination` return `true` unconditionally and would
ignore prune. Nobody here sets them; do not start.

**Consequences for Task 4:**

- No takeover flag, no annotation surgery, no two-phase claim.
- The old unit must stop listing the moved files **in the same commit** the new units start listing
  them, so no object is unmanaged between reconciles.
- Because the three-unit split **rewrites** `stage-apps.yaml` rather than deleting it, no
  Kustomization is deleted at all and point 4 never comes up.
- Residual: if the split fails halfway, moved objects are orphaned — still managed by nobody, still
  running, and `make kustomize-listing` will not notice because it reads the tree, not the cluster.
  Task 5's inventory-sum check is what catches that.

### Task 4: Split into three units — **DONE, merged `5d3a1c6` (PR #84)**

One commit. `databases` and `tesla` leave the shared unit; `auth`/`coder`/`coder-workspaces` stay.

- [x] Create `apply/30-databases/kustomization.yaml` and `apply/60-tesla/kustomization.yaml` as **new top-level stage directories**, `git mv`-ing the files out of `apply/50-apps/` so history follows them.
- [x] Remove those entries from `apply/50-apps/kustomization.yaml`.
- [x] Create `stage-databases.yaml` and `stage-tesla.yaml` with `prune: true`; **rewrite `stage-apps.yaml` to the narrower path but leave `prune: false` on it.** All three: `interval: 10m0s`, `dependsOn` per the graph. **No takeover flag — Task 3 established that adoption is plain SSA.** The old unit must stop listing the moved files in this same commit.

**Why the rewritten `apps` unit must keep `prune: false` in this commit.** It is the *same object* as before, so its `status.inventory` still holds all 43 entries. The moment it stops listing the `databases/` and `tesla/` files, those 32 objects become stale by `inventory.Diff`. With `prune: true` on that commit, **it deletes the CNPG Cluster and the whole Tesla stack** — the exact hazard Task 2 exists to prevent, reintroduced by the split itself. The new units are safe with `prune: true` from the start because their inventories begin empty, so `Diff(empty, new)` yields nothing stale.

- [x] `make check` — `kustomize-listing` must report **0 unlisted**.
- [x] `make dry-run` → will print `SKIPPED`. **Say so in the PR body** and hand the operator `scripts/dry-run-check.sh <context>` to run before merging.
- [x] Commit, PR, merge with confirmation.

### Task 5: Verify — and this is now possible without admin — **DONE on `main@5d3a1c6`**

All four checks passed, and the cascade itself was the first real exercise of the `dependsOn` graph:
`secrets → infra → certificates → databases → {apps, tesla}`, with `databases` and `tesla` correctly
reporting `dependency ... is not ready` until their inputs came up.

- [x] All seven stages `Ready` on `main@sha1:5d3a1c6`.
- [x] **The database check that matters:** `currentPrimary=postgres-1`, and every condition True —
      `Initialized=True ConsistentSystemID=True Ready=True ContinuousArchiving=True LastBackupSucceeded=True`.
      `ContinuousArchiving=True` is the load-bearing one: it proves WAL archiving never dropped, so the
      Cluster did not blink while its owning Kustomization changed identity underneath it.
- [x] Pod diff pre-split vs post-split is **byte-identical** — `teslamate` 23 restarts, `postgres-1` 1,
      `coder` 3, `authentik-server` 0. Nothing bounced.
- [x] Inventories: `apps` 14 + `databases` 2 + `tesla` 27 = **43 total, 43 unique, 0 claimed twice**.
      Each stage's live inventory also equals what git builds for it, stale = 0 — which is exactly the
      precondition Task 5b needs.

### Task 5b: Restore prune on the shared unit — **DONE, merged `c7d4dd5` (PR #85)**

Unblocked by Task 5. The precondition is not just "the split reconciled" but **stale = 0**: prune
deletes exactly `inventory.Diff(old, new)`, so if the live inventory equals the git build, the first
reconcile with prune on is provably a no-op.

One correction to an earlier draft of this plan, because it would mislead the next person: turning
prune back on was described as risking objects created out of band during the `prune: false` window.
It is not. **Prune only deletes entries its own inventory holds that git no longer builds.** It never
touches objects it never owned. The real exposure of `prune: false` is the inverse — objects removed
from git linger indefinitely, which is drift, not deletion.

- [x] Confirm first: `apps` inventory 14 == build 14, `databases` 2 == 2, `tesla` 27 == 27, **stale = 0
      on all three**. A stray-object scan across the five namespaces (81 objects, 17 kinds) found
      **0 created during the `prune: false` window**; the 38 unclaimed are `kube-root-ca.crt`, the
      `infra`-owned reflector/reloader, and CNPG operator children — all accounted for.

      **Trap, learned the hard way:** the first version of that scan reported a clean zero while
      scanning nothing. It passed *Kinds* (`Deployment`, `Cluster`) to `kubectl get`, which takes
      *resource names* (`deployments`, `clusters.postgresql.cnpg.io`); every call errored, empty
      stdout was read as an empty list, and the check passed vacuously. Resolve Kind → resource via
      `kubectl api-resources -o json` and exit non-zero when a call fails. The scan is ad hoc and
      not committed, so this note is the only place the trap is written down.
- [x] Set `prune: true` on `stage-apps.yaml`, with a comment saying why it was off and what must be true before it is ever turned off again.
- [x] `make check`, PR, merge with confirmation.
- [x] Verify all three units still `Ready` and no object was deleted — the diff of `kubectl get all -n tesla-ns` style counts before and after, plus the CNPG conditions again.

### Task 6: Documentation — **DONE**

The AGENTS.md layout block went in with the split itself (PR #84), because that is the commit that
changed the layout; leaving it for later would have meant main briefly documented a tree it no longer
held.

- [x] `AGENTS.md`: stage graph; the D1 admission test; that adding an app means a directory **and** a stage file.
- [x] Record in the spec that D2 landed as three units, not five, and why.
- [x] Note that Plan B (Tesla namespace move) now only edits namespaces inside the `tesla` unit — the reconcile-unit work is already done.

## Not proven / accepted

- **Immutable-field changes and core-type CEL rules remain uncatchable here.** No admin context means no server-side validation, and no offline schema substitutes for those two classes. The split bounds the damage; it does not detect the error.
- **Orphaned objects are invisible to the offline gates.** If a split half-fails, an object can end up running and managed by no Kustomization, and `kustomize-listing` will not see it because it reads the tree. Task 5's inventory-sum check is the only detector.
- **`healthChecks` on a split stage has never run in this cluster.**
- **More units cost gate runtime.** `kustomize-check` and `kustomize-listing` walk every directory. Accepted trade.
