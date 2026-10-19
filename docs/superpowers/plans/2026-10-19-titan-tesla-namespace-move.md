# titan Tesla namespace move — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Tesla stack out of `apps` into its own `tesla` namespace, and move `reflector` into `certificates`, without ever leaving a namespace without the Secrets it needs.

**Architecture:** Create-before-delete, everywhere. The new namespace and a second copy of every Secret land first and are proven in use; the old ones are removed in a later, separate change. `reflector` moves because it exists only to replicate what `certificates` issues. `reloader` does **not** move — it stays in `apps` as the single named exception to the D1 admission rule.

**Tech Stack:** Flux kustomize-controller v1.9.6, cert-manager + Reflector, sops+age, k3s v1.35.8+k3s1.

**Spec:** `docs/superpowers/specs/2026-10-19-titan-app-scale-out-design.md` — D1, D3, D4 as revised.

## ⛔ Execution gate — do not start this plan until it is met

**`scripts/tesla-push-telemetry-config.sh status` must report `synced: true` and frames must be reaching the forwarder (`forwarded` counting up).**

Reason: this plan changes the streaming path. If it is executed while `forwarded: 0`, a breakage cannot be attributed — it will be impossible to tell a namespace mistake from the fact that the pipeline was never proven. Run it after Plan A and after §5 of the runbook, when there is live traffic to compare against.

If this gate cannot be met, **stop and say so.** Do not proceed "to see if it works".

## Global Constraints

- **`ENCRYPTION_KEY` is the irreversible step.** It lives in `teslamate-secrets`. If a TeslaMate container starts in a namespace whose copy of that key is absent or different, every stored vehicle token becomes undecryptable and every vehicle must be paired again. Regenerating it makes that permanent. Never run `setup-tesla-secrets.sh --genkey` or `FORCE=1` as part of this plan. Values are **copied**, never regenerated.
- **`prune: true` deletes the old objects.** The old namespace's Secrets must not be pruned until the new ones are proven in use. This is the same hazard as Plan A Task 2 and the same mitigation applies.
- `teslamate-db-credentials` stays in `databases`. It is what CNPG's `DatabaseRole` reads. It does not move.
- Never set a top-level `namespace:` in a `kustomization.yaml`.
- `make check` before every commit; `make dry-run` with an admin context before any commit that moves a workload.
- Pushing a branch, opening the PR and merging each need separate operator confirmation.

## Measured during planning (2026-10-19)

| fact | value |
|---|---|
| Tesla workloads in `apps` | 8 deployments, 7 running |
| Public hostnames | `tesla.`, `grafana.`, `streaming.`, `telemetry.`, `authorize.` |
| Secrets in `apps` | `teslamate-secrets`, `tesla-grafana-admin`, `tesla-oauth`, `tesla-wellknown` |
| Secret that must not move | `teslamate-db-credentials` (ns `databases`) |
| `k8s-reader` | ClusterRole binding — **no RBAC work needed for a new namespace** |
| Reflector allow-lists | `titan-wildcard.yaml` → `apps,auth`; `tesla-streaming.yaml` → `apps` |
| Forwarder bridge URL | hardcoded `http://tesla-streaming.apps.svc.cluster.local/` at `apply/50-apps/tesla/forwarder.yaml:34` |
| Forward-auth middleware | `apps-teslamate-auth@kubernetescrd` — Traefik resolves `<namespace>-<name>` in the Ingress's own namespace |
| Reloader | HelmRelease + HelmRepository `stakater`, both ns `apps`; watches `coder` + `monitoring`. **Stays.** |
| Reflector | ns `apps`; "replicates TLS material across namespaces and nothing else" |

**The certificates do not move.** Both `Certificate` objects live in `certificates` and are unchanged by this plan, so there is **no new ACME order and no new DNS-01 challenge** — which matters, because a DNS-01 challenge is exactly what knocked `streaming.titan.arrieta.eu` out of DNS on 2026-10-19 (runbook §6). If anyone proposes re-issuing a certificate as part of this move, they have misunderstood the change; stop and check.

## Review Focus

1. Is there any commit in which a namespace temporarily has no copy of a Secret it needs?
2. Does any commit move a workload before the Reflector copy has landed in `tesla`?
3. Is the forwarder's hardcoded FQDN updated in the same commit as the namespace change? A forwarder pointing at a dead FQDN connects happily to nothing.
4. Did anything touch `teslamate-db-credentials`, or re-run the secrets script? Neither may happen.

## File Structure

```
apply/00-bootstrap/namespaces.yaml        + tesla
apply/10-secrets/
  teslamate-secrets-tesla.yaml            + new, ns tesla, values copied verbatim
  tesla-grafana-admin-tesla.yaml          + new
  tesla-oauth-tesla.yaml                  + new
  tesla-wellknown-tesla.yaml              + new
  kustomization.yaml                      lists all four new files
apply/40-certificates/
  titan-wildcard.yaml                     allow-list += tesla
  tesla-streaming.yaml                    allow-list += tesla
apply/50-apps/tesla/*.yaml                namespace: apps → tesla
apply/20-infra/reflector/reflector.yaml   namespace: apps → certificates
```

---

### Task 1: Prove the current state, and record it — **partly DONE 2026-10-19T13:20Z**

- [x] **Answered from the `apps` Kustomization inventory, not assumed:** the Tesla DB objects live in `databases`, not `apps` —
  ```
  databases_teslamate_postgresql.cnpg.io_Database
  databases_teslamate_postgresql.cnpg.io_DatabaseRole
  ```
  So `teslamate-db.yaml` does **not** move with the namespace change. The 8 Tesla Deployments, 5 Ingresses, the `IngressRouteTCP` and the `Middleware` are all `apps_`.
- [x] **`reflector` and `reloader` are owned by the `infra` stage, not `apps`** — they are absent from the `apps` inventory and merely deploy into `apps`. Task 5 is therefore an `infra`-stage edit; nothing in the `apps` stage changes when reflector moves.
- [ ] Record the current `ENCRYPTION_KEY` fingerprint so a later step can prove the copy is identical:
  ```bash
  sops -d apply/10-secrets/teslamate-secrets.yaml | sha256sum
  ```
  Record the hash. Do not record the key.
- [ ] Record forwarder counters: `forwarded`, `rejected`, `lastPost` from its `:8080` status endpoint.
- [ ] Record pod `AGE` for all Tesla workloads. Baseline as of 13:20Z: all six non-TeslaMate pods restarts=0 up 44h; `teslamate` restarts=23, up since 07:13:24Z.

### Task 2: Land the namespace and the second copy of every Secret

Nothing is moved in this commit. Nothing is deleted.

- [ ] Add `tesla` to `apply/00-bootstrap/namespaces.yaml`.
- [ ] Create the four `-tesla.yaml` sops files with `namespace: tesla` and **values copied byte-for-byte** from the existing files. Verify the `ENCRYPTION_KEY` copy matches the Task 1 hash before committing.
- [ ] List all four in `apply/10-secrets/kustomization.yaml`. `make secrets-placement` fails an unlisted Secret, and that gate is the guard against a half-done move.
- [ ] Add `tesla` to both reflector allow-lists. Do **not** remove `apps` yet.
- [ ] `git add -A && make check` — expect `secrets-placement` and `release-secrets` green.
- [ ] `make dry-run DRYRUN_CONTEXT=<admin context>`
- [ ] Commit `secrets: a second copy of the Tesla Secrets in namespace tesla`, PR, merge with confirmation.
- [ ] Verify on the cluster: the four Secrets exist in `tesla`, and `titan-tls` and `tesla-streaming-tls` are both present in `tesla` via Reflector. **Do not continue until the reflected TLS copies are there** — moving an Ingress before its Secret exists makes Traefik silently fall back to its default certificate.

### Task 3: Move the workloads

One commit. Every reference updates together.

- [ ] `namespace: apps` → `namespace: tesla` in every Tesla manifest **except** the one that targets `databases`.
- [ ] Forwarder: `BRIDGE_URL` default → `http://tesla-streaming.tesla.svc.cluster.local/`.
- [ ] Forward-auth: the `Middleware` moves to `tesla`, and the Ingress annotation becomes `tesla-teslamate-auth@kubernetescrd`. The suffix stays `@kubernetescrd` — that was settled in #64 and runbook §9; do not reopen it while moving the object.
- [ ] `make check`, `make dry-run`.
- [ ] Commit `apps: move the Tesla stack to its own namespace`, PR, merge with confirmation.
- [ ] Verify, in order:
  - [ ] All Tesla pods `Running` in `tesla`, and **TeslaMate did not crash-loop** — restart count must be 0 on the new pod. A nonzero count means a Secret or the middleware is wrong; look before it takes nine cycles to show.
  - [ ] `kubectl --context titan -n tesla logs deploy/teslamate --tail=50` shows a normal boot and `Migrations already up`.
  - [ ] Forwarder status still `connected: true`, and `forwarded` still counting up.
  - [ ] `streaming.titan.arrieta.eu` still presents the single-name cert (runbook §6 check).
  - [ ] TeslaMate UI reachable through forward-auth at `tesla.titan.arrieta.eu` — this is the only proof the middleware move worked, and a broken middleware reference takes the whole host down.
  - [ ] §4's synthetic `redis-cli PUBLISH` reaches TeslaMate. **This needs an admin context**; `k8s-reader` is Forbidden on `pods/exec`.

### Task 4: Remove the old copies — separate change, separate review

Only after Task 3 has been stable for at least one full day, including one drive.

- [ ] Delete the four `apps`-namespace Tesla Secret files and their entries in `apply/10-secrets/kustomization.yaml`.
- [ ] Remove `apps` from both reflector allow-lists **only if nothing left in `apps` needs those Secrets**. `reloader` stays in `apps` and does not need TLS material; confirm before editing.
- [ ] `make check`, `make dry-run`, commit `secrets: retire the Tesla Secrets from namespace apps`, PR, merge with confirmation.
- [ ] Verify TeslaMate still polls and no vehicle needs re-pairing. This is the point at which an `ENCRYPTION_KEY` mistake finally surfaces, so do not skip the observation period.

### Task 5: Reflector to `certificates`

Independent of the Tesla move; can be done any time after Task 3, or not at all.

- [ ] `apply/20-infra/reflector/reflector.yaml`: `namespace: apps` → `namespace: certificates`, for the HelmRepository and the HelmRelease both.
- [ ] `make check`, `make dry-run`, commit, PR, merge with confirmation.
- [ ] Verify the Reflector pod is `Running` in `certificates` **and that every reflected Secret in every target namespace is still fresh** — a Reflector that comes up misconfigured stops updating copies silently, and the copies look perfectly valid until the next renewal.

### Task 6: Documentation

- [ ] `AGENTS.md`: record the D1 admission test **with its one named exception** — `reloader` lives in `apps` and is not an app. A closed list, not a hole.
- [ ] `AGENTS.md`: the `titan-tls` bullet's exception list grows — the consuming namespace is now `tesla` as well as `apps`/`auth`.
- [ ] `docs/teslamate-runbook.md`: every "everything is in namespace `apps`" statement, and every `kubectl -n apps` command, becomes `-n tesla`. Grep for `-n apps` across all docs; `docs/authentik-runbook.md` may reference Tesla hosts.
- [ ] Note in k8s-casa (separate repo, no gate here) that any dashboard or alert keyed on `namespace="apps"` for Tesla series must become `namespace="tesla"`. **Nothing in this repo can verify that.**

## Not proven / accepted

- **The casa-side Loki label change is invisible from here.** No gate in this repo can see it, and it will not fail loudly.
- ~~**`teslamate-db.yaml`'s real namespace was assumed, not read.**~~ **Resolved 2026-10-19:** the `apps` inventory shows `databases_teslamate_..._Database`, so it targets `databases` and does not move.
- **The middleware move is the most likely single point of failure** and its only proof is loading the UI through authentik. This repo has already lost hours to that object's naming.
- **`reloader` in `apps` is a known wart**, accepted deliberately: the operator does not want a namespace per singleton controller, and `apps` is where it already lives. If it becomes a problem, `reloader-system` following k8s-casa's `kured` precedent is a one-line change.
