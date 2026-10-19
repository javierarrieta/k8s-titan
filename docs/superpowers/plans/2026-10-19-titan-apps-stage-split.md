# titan apps stage split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `apps` Flux Kustomization with one Kustomization per app-group, so that a bad manifest in one group can no longer freeze authentik, coder, the Postgres cluster or Tesla.

**Architecture:** `apply/50-apps/` stops being one reconcile unit. Each subdirectory becomes its own `Kustomization` with its own `dependsOn` and `healthChecks`, and the ordering that today is implicit in file order becomes explicit in the stage graph. **No namespace changes and no Secret changes in this plan** — that is deliberately Plan B, and the two must not be combined.

**Tech Stack:** Flux kustomize-controller **v1.9.6**, kustomize, k3s v1.35.8+k3s1.

**Spec:** `docs/superpowers/specs/2026-10-19-titan-app-scale-out-design.md` — decisions D1, D2, D5. D3 and D4 are Plan B.

## Global Constraints

- **Never delete the `apps` Kustomization while `prune: true` is in effect and its replacement does not own the objects.** See *The hazard* below. This is the one step that can take the cluster down.
- Every stage object gets its own file under `apply/00-bootstrap/`. Do not merge stage objects into one file (`AGENTS.md`).
- Every `kustomization.yaml` lists its resources explicitly. Plain-directory fallback cannot be built offline, and offline validation is the only kind this repo can run (`AGENTS.md`).
- Never set a top-level `namespace:` in a `kustomization.yaml`. These trees span namespaces.
- `make check` before every commit. `make dry-run` with an admin context before the commit that changes the stage graph.
- Pushing a branch, opening the PR and merging each need separate operator confirmation.

## Measured during planning (2026-10-19, live cluster)

```
kustomize-controller image: ghcr.io/fluxcd/kustomize-controller:v1.9.6

kubectl -n flux-system get kustomization apps -o jsonpath='{.spec}'
  dependsOn: [{name: certificates}]
  force: false
  interval: 10m0s
  path: ./apply/50-apps
  prune: true                      ← live and effective
  (no healthChecks, no wait)
```

**`prune` is the correct field name in v1.9** — it is declared by the CRD, and `gc` is not. Verified rather than assumed, because a structural-schema CRD silently drops unknown fields and a `prune` that did nothing would have made this plan safe when it is not.

`apply/50-apps/kustomization.yaml` lists 17 files, and their order is load-bearing today:

```
databases/postgres.yaml            ← the CNPG Cluster, first
databases/postgres-backup.yaml
auth/authentik-db.yaml             ← CNPG Database, needs the Cluster
coder/coder-db.yaml                ← same
coder/coder.yaml
auth/tesla-outpost-blueprint.yaml
auth/authentik.yaml
coder/workspaces.yaml
tesla/teslamate-db.yaml            ← same
tesla/wellknown.yaml … tesla/auth-callback.yaml   (6 more)
```

Within one Kustomization Flux applies in this order but does not wait. Splitting the unit makes that implicit ordering an explicit dependency, which is the point — but it also means **the ordering must be declared, not inherited.**

## The hazard

**Measured at execution (Task 1, 2026-10-19T13:20Z), and it is worse than the shape of the change suggests.** `kubectl -n flux-system get kustomization apps -o jsonpath='{.status.inventory}'` lists **43 objects**, and among them:

```
databases_postgres_postgresql.cnpg.io_Cluster        ← deleting this destroys the production database
databases_{authentik,coder,teslamate}_..._Database   + 3 DatabaseRole
 databases_postgres-daily_postgresql.cnpg.io_ScheduledBackup
auth_authentik_helm.toolkit.fluxcd.io_HelmRelease    ← finalizer ⇒ helm uninstall
coder_coder_helm.toolkit.fluxcd.io_HelmRelease       ← same
apps_teslamate_apps_Deployment  (+7 more tesla Deployments, 5 Ingresses,
                                  the IngressRouteTCP and the Traefik Middleware)
coder-workspaces_coder-workspaces__ResourceQuota / LimitRange
```

So `prune: true` plus deleting the `apps` Kustomization does not "recreate the workloads" — it **deletes the CNPG `Cluster`, which destroys the database**, and it deletes the authentik and coder `HelmRelease` objects, whose finalizers make helm uninstall those releases as well.

The obvious edit —

```
rm apply/00-bootstrap/stage-apps.yaml
+  apply/00-bootstrap/stage-{databases,authentik,coder,tesla}.yaml
```

— is a full-cluster outage with data loss, about one reconcile after the merge.

**Ownership is tracked on the Kustomization, not on the objects.** Measured: the live `apps/teslamate` Deployment carries only `deployment.kubernetes.io/revision` — there is **no `kustomize.toolkit.fluxcd.io/name` annotation on it**, and none on authentik's or coder's workloads either. Ownership lives in `.status.inventory.entries` on the Kustomization.

That invalidates the `force: true` takeover this plan originally specified. `force` exists to resolve conflicts with a per-object ownership annotation; with no annotation on these objects there may be nothing for it to resolve, and the real conflict is two Kustomizations listing one object in their inventories. **Task 3 opens by establishing, against the kustomize-controller v1.9.6 docs, how a second Kustomization claims an object already in another's inventory.** Do not assume `force` is the answer — the first version of this plan assumed it and was measured wrong.

The mitigation ordering is unchanged and is now clearly the only safe one: make the old unit non-pruning first, prove it, then split.

## Review Focus

1. Does any task delete a Kustomization before its replacement owns the objects? That is the outage.
2. Is the CNPG ordering explicit in the new graph, not inherited from file order?
3. Does every new `kustomization.yaml` list its files explicitly?
4. Is there any Secret touched anywhere? There must not be.

## File Structure

```
apply/00-bootstrap/
  stage-apps.yaml            → deleted in Task 4, last
  stage-databases.yaml       → new, ns databases
  stage-authentik.yaml       → new, ns auth
  stage-coder.yaml           → new, ns coder
  stage-tesla.yaml           → new, ns apps   (namespace moves in Plan B)
apply/50-apps/
  kustomization.yaml         → deleted in Task 4
  databases/kustomization.yaml   → new
  auth/kustomization.yaml        → new
  coder/kustomization.yaml       → new
  tesla/kustomization.yaml       → new
```

Target graph:

```
certificates ─→ databases ─→ authentik
                      ├─────→ coder
                      └─────→ tesla
```

`databases` first because every `Database` in the other three groups is a child of the CNPG `Cluster` it holds.

---

### Task 1: Baseline the current state — **DONE 2026-10-19T13:20Z**

- [x] Pod baseline. Pod `AGE` is the proof of whether anything was recreated later:
  ```
  databases  pod/postgres-1   1/1 Running restarts=1  up 5d16h
  auth       authentik-server 1/1 Running restarts=0  up 22h ; authentik-worker restarts=0 up 21h
  coder      coder            1/1 Running restarts=3  up 5d16h
  apps       teslamate        1/1 Running restarts=23 — last crash 07:08:06Z, up since 07:13:24Z
             tesla-{redis,streaming,forwarder,wellknown,grafana,fleet-telemetry} restarts=0 up 44h
             reflector restarts=1 up 5d16h ; reloader restarts=0 up 6h58m
  ```
  The last TeslaMate crash was **07:08:06Z, before the streaming-cert fix was reconciled** — the stage was still on `da57ea6` then, and `5b33b89` applied at 07:52. The count has not moved since. Consistent with the fix holding; **not proof**, because the trigger is a car coming online.
- [x] `apps` inventory captured: 43 entries, the load-bearing ones listed under *The hazard*.
- [x] **Correction — `databases` has no StatefulSet.** `pod/postgres-1` is owned directly by `Cluster/postgres`; CNPG manages the pods itself here. `get sts` is not a usable health check for this cluster.
- [x] **Correction — `reflector` and `reloader` are not in the `apps` inventory.** They are owned by the `infra` stage and merely deploy into `apps`. Plan B's reflector move is an `infra`-stage change, not an `apps`-stage change.
- [ ] CNPG cluster health and primary: **not readable with `k8s-reader`** — `clusters.postgresql.cnpg.io` is Forbidden, as documented. Needs an admin context before Task 4.

### Task 2: Turn garbage collection off on the old unit

Single commit, single line. This is the safety net and it must be merged and reconciled **before** anything else moves.

- [ ] In `apply/00-bootstrap/stage-apps.yaml`, set `prune: false` with a comment naming this plan and saying why it is temporary.
- [ ] `git add -A && make check`
- [ ] `make dry-run DRYRUN_CONTEXT=<admin context>`
- [ ] Commit as `infra: turn apps stage prune off ahead of the split`, push, PR, merge with confirmation.
- [ ] Verify: `kubectl -n flux-system get kustomization apps -o jsonpath='{.spec.prune}'` → `false`.

**Do not continue until this is reconciled on the cluster.**

### Task 3: Per-group kustomizations and stages

- [ ] Create `apply/50-apps/{databases,auth,coder,tesla}/kustomization.yaml`, each listing exactly the files that today live in that directory, in the current order.
- [ ] Establish how a new Kustomization claims an object already listed in the `apps` inventory, **given that the objects carry no ownership annotation**. Check the kustomize-controller v1.9.6 docs; do not assume `force: true`. If the answer is not clean, **stop** — Task 2 has already made the split revertible, so there is no pressure to guess.
- [ ] Create the four stage files. Each: `dependsOn` per the graph above, `interval: 10m0s`, `prune: true`, `path: ./apply/50-apps/<dir>`, plus whatever the answer above requires.
- [ ] Leave `stage-apps.yaml` and `apply/50-apps/kustomization.yaml` in place for now.
- [ ] `make check` — `kustomize-listing` must report **0 unlisted**. Every new file must be listed in its own directory's kustomization.
- [ ] `make dry-run DRYRUN_CONTEXT=<admin context>`
- [ ] Commit `infra: one Flux Kustomization per app-group directory`, push, PR, merge with confirmation.
- [ ] Verify each is `Ready` **and that no pod was recreated**:
  ```bash
  kubectl --context titan -n flux-system get kustomizations
  kubectl --context titan -n databases get pods,sts -o wide    # AGE must be unchanged
  ```
- [ ] If any Kustomization reports an ownership error, **stop**. Do not delete objects to make it happy. Capture the message and escalate.

### Task 4: Retire the old unit

- [ ] Delete `apply/00-bootstrap/stage-apps.yaml` and `apply/50-apps/kustomization.yaml`.
- [ ] `make check`, `make dry-run`, commit `infra: retire the single apps stage`, PR, merge with confirmation.
- [ ] Verify the four new Kustomizations are `Ready`, and re-check pod `AGE` in all four namespaces. Nothing may have restarted.
- [ ] Verify the CNPG cluster still reports its original primary and no failover occurred.

### Task 5: Drop the takeover mechanism, add health checks

- [ ] Remove whatever Task 3 used to claim ownership, once every object appears in exactly one new inventory and the old `apps` Kustomization is gone.
- [ ] Add `healthChecks` naming the workload that must be Ready for that group: the CNPG `Cluster` for `databases`, `authentik-server` for `authentik`, the coder `Deployment` for `coder`, the teslamate `Deployment` for `tesla`.
- [ ] `make check`, `make dry-run`, commit, PR, merge with confirmation.
- [ ] Verify all four `Ready` with the health check reported, not just applied.

### Task 6: Documentation

- [ ] `AGENTS.md`: the stage-order line becomes the real graph. Say plainly that `apply/50-apps` is no longer one unit and that adding an app means adding a directory **and** a stage file.
- [ ] Add the D1 admission test from spec §3.1 to `AGENTS.md`.
- [ ] Record in the spec that this plan executed, with the commit that retired the old stage.

## Not proven / accepted

- **How a second Kustomization claims an object from another's inventory is NOT established.** The original assumption (per-object ownership annotation + `force`) is **measured false**; Task 3 now opens with the question instead of an answer. The escape is that Task 2 already made the old unit non-pruning, so nothing is destroyed and the split can be reverted by restoring `stage-apps.yaml`.
- **CNPG cluster health was never observed.** `k8s-reader` is Forbidden on `clusters.postgresql.cnpg.io`, so Task 4 needs an admin context to prove no failover occurred.
- **`healthChecks` on a split stage has never run in this cluster.** Spec §8 already records this as the real test of D2.
- **Ordering is now explicit and therefore now someone's problem.** File order used to hide it.
