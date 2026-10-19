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

`prune: true` means Flux garbage-collects managed objects when the Kustomization is removed. So the obvious edit —

```
rm apply/00-bootstrap/stage-apps.yaml
+  apply/00-bootstrap/stage-{databases,authentik,coder,tesla}.yaml
```

— **deletes authentik, coder, the CNPG Postgres cluster and all of Tesla, then recreates them.** For the Postgres cluster that is a database outage with real data-loss exposure, and it would happen about one reconcile after the merge.

Flux also refuses to apply an object already owned by another Kustomization: managed objects carry `kustomize.toolkit.fluxcd.io/name` and `…/namespace`, and a second Kustomization touching them fails an ownership annotation check. `spec.force: true` is the documented takeover mechanism.

**Verify the `force` semantics against the kustomize-controller v1.9.6 docs before executing Task 3.** The plan's safety rests on it and the author did not test it. If `force` does not behave as described, stop and reconsider — do not improvise around a live Postgres cluster.

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

### Task 1: Baseline the current state

- [ ] Record what must not be recreated:
  ```bash
  kubectl --context titan -n databases get pods,sts -o wide
  kubectl --context titan -n auth get pods
  kubectl --context titan -n coder get pods
  kubectl --context titan -n apps get pods
  ```
  Save the output. Pod `AGE` is the proof of whether anything was recreated.
- [ ] Record the CNPG cluster health and its current primary.
- [ ] Confirm `apps` owns the objects today:
  ```bash
  kubectl --context titan -n databases get cluster -o jsonpath='{.items[*].metadata.annotations.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}'
  ```
  Expect `apps`.

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
- [ ] Create the four stage files. Each: `dependsOn` per the graph above, `interval: 10m0s`, `prune: true`, `path: ./apply/50-apps/<dir>`, and `force: true` with a comment explaining it is a takeover from the `apps` Kustomization and will be removed in Task 5.
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

### Task 5: Remove the takeover flag, add health checks

- [ ] Drop `force: true` from all four stage files.
- [ ] Add `healthChecks` naming the workload that must be Ready for that group: the CNPG `Cluster` for `databases`, `authentik-server` for `authentik`, the coder `Deployment` for `coder`, the teslamate `Deployment` for `tesla`.
- [ ] `make check`, `make dry-run`, commit, PR, merge with confirmation.
- [ ] Verify all four `Ready` with the health check reported, not just applied.

### Task 6: Documentation

- [ ] `AGENTS.md`: the stage-order line becomes the real graph. Say plainly that `apply/50-apps` is no longer one unit and that adding an app means adding a directory **and** a stage file.
- [ ] Add the D1 admission test from spec §3.1 to `AGENTS.md`.
- [ ] Record in the spec that this plan executed, with the commit that retired the old stage.

## Not proven / accepted

- **`force: true` takeover is untested here.** It is the documented mechanism and the plan depends on it. Task 3 is where it gets proven; if it fails, the escape is that Task 2 already made the old unit non-pruning, so nothing is destroyed and the split can be reverted by restoring `stage-apps.yaml`.
- **`healthChecks` on a split stage has never run in this cluster.** Spec §8 already records this as the real test of D2.
- **Ordering is now explicit and therefore now someone's problem.** File order used to hide it.
