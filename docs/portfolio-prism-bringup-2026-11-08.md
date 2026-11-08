# Portfolio Prism bring-up record — 2026-11-08

PR #269, branch `feat/portfolio-prism-deploy`, deploys `portfolio.titan.arrieta.eu`.

This file is the **log**, not the design. The design and the reasoning for each field live in
`apply/50-apps/portfolio-prism/portfolio-prism.yaml` and
`authentik/blueprints-portfolio-prism.yaml`. What lives here is what was measured, what has not
been, what was declined, and how to undo it.

## Status in one paragraph

Nothing in this change has been applied to a cluster. The workspace it was written in has no admin
kubeconfig and no container runtime, so every claim below is labelled with how it was established:
**measured** (a command ran, output seen), **asserted** (a gate in this repo checks it), or
**unverified** (reasoned from source, never executed). The HTTP probes described under "Measured"
were made from the authoring workspace against the live `auth.titan.arrieta.eu` and the public
internet. **Nothing in-cluster was executed.**

## Pre-merge, the one gate that is not `make check`

```sh
make dry-run DRYRUN_CONTEXT=<admin context>
```

`k8s-reader` is Forbidden on the resources this touches, so this needs write authorization on the
cluster, not read. It asks the API server about admission rules — namespace admission under §3.1,
the `fsGroup`/`runAsUser` combination, Secret references. It cannot see whether the volume is
writable or whether nginx can write its cache; those are pod-runtime facts and are listed as
unverified below.

Expected pass signature: the script prints the per-namespace apply plan and exits 0. A §3.1 refusal
names `apps` and the rejected field.

## Gate coverage — what `make check` actually proved

`make check` has **25 members** and all 25 pass on this branch:

```sh
git add -A && make check
# check: all offline gates passed        (exit 0)
```

Two honest caveats on that green:

- **`make check` is the offline set by design** — its own closing line says "all offline gates
  passed". The gate that would answer the questions this PR actually leaves open, `make dry-run`, is
  **not** a member of `check` and has not been run; it needs an admin context (see above).
- `chart-values-check` 504'd on the authentik tarball during authoring and is green now. If it goes
  red, that is the network, not this change.

**`make oidc-check` is not coverage for this app.** `tools/oidc-check.py:33-37` is hardcoded to
coder. A green `oidc-check` says nothing about the portfolio-prism client pair. The pair is checked
by the setup script's own substitution assertions and by nothing in `make check`.

## Access — the single-binding decision, recorded

`apply/50-apps/auth/identity-blueprint.yaml:110-131` states the standing rule for this cluster:
every app is bound to `titan-family` **and** to its own admin group. The reason written there is
that a binding naming a group that does not exist **denies**, so a family-only binding is a lockout
that includes the owner if `titan-family` is ever emptied or renamed.

**This app ships one binding, to `titan-family`, and no second door.** Accepted because:

- the app has no authorization model beyond "has a valid session", so an admin group would gate
  nothing the family binding does not already gate;
- `titan-family` is the group every other family-facing app already trusts.

Not accepted quietly. The residual is a lockout with no in-repo second path. Where `titan-family`'s
membership is declared and measured: `apply/50-apps/auth/identity-blueprint.yaml` (the group and
its members), and `make outpost-binding-check`, which asserts each binding names a group this tree
declares — it does **not** assert a second binding exists.

**Fix if this is ever wrong:** add a `policybinding` with `order: 1` naming
`titan-portfolio-prism-admins` to `authentik/blueprints-portfolio-prism.yaml`, declare the group in
`identity-blueprint.yaml`, then `scripts/rerender-authentik-blueprint.sh portfolio-prism --write`.

`authorization_flow` is the stock implicit-consent flow. It asserts nothing about how the user
authenticated. Whatever factor protects this host is enforced outside this repo and is **not**
recorded here.

## Backup — the SQLite deferral, recorded

The PVC carries the restic opt-in annotation. The daily restic backup is the only second copy this
change knows about; `local-path-retain` is a deletion mitigation, not a backup.

`docs/superpowers/specs/2026-10-22-titan-restic-pv-backups-design.md` §6 records "SQLite-shaped
risk, inherited not new": restic file-copies a **live** SQLite file with no quiescing, and the
`sqlite3 .backup` upgrade was **deferred** cluster-wide, not resolved.

**Decision here: inherit the deferral, do not resolve it in this PR.** The single SQLite file on this
volume is the user's entire financial history. Consequences accepted:

- a snapshot taken mid-write can restore as a corrupt database;
- any restore **must** run `PRAGMA integrity_check` before the app is pointed at it;
- **no restore of this volume has ever been drilled.** Not this volume, not any volume shaped like
  it. The first drill is the first evidence.

The fix is a `sqlite3 "$DB" ".backup '$TMP'"` step in the backup job, which is a change to
`apply/70-backup/` and to every other SQLite-shaped PVC, not to this manifest.

## Storage — 2Gi is a guess, and the class cannot grow

`local-path-retain` sets `allowVolumeExpansion: false`
(`apply/20-infra/storage-retain.yaml`), so `storage: 2Gi` cannot be grown later. Nothing measured
the expected size. Six other PVCs already live under the same class, so the class is not this PR's
problem; the fix if it is ever tight is one line in that StorageClass, which is cluster-wide and
deliberately not done here.

## Unverified, and how to settle each one

| Item | Symptom if wrong | Settle it with |
| --- | --- | --- |
| Does kubelet apply `fsGroup` to a hostPath-backed `local-path` volume? | backend logs SQLite error 14, `unable to open database file` | `kubectl -n apps exec deploy/portfolio-prism -c backend -- sh -c 'touch /app/data/.w && ls -ln /app/data'`. If it fails, try `fsGroupChangePolicy: Always` (OnRootMismatch can treat a half-fixed root as matched and skip the chmod); if that fails, chown the PV host path on the node — the route `apply/50-apps/investing-agent/investing-agent.yaml` ended up on. |
| nginx writable paths (`/var/run`, `/var/cache/nginx/client_temp`) | CrashLoopBackOff at container start | `kubectl -n apps logs deploy/portfolio-prism -c frontend` |
| `redirect_uri_type: logout` accepted by the pinned authentik (2026.8.5) | blueprint `status: ERROR`; login never works | the `--dry-run` below, **before** the real apply |
| Slug match reuses the UI-created provider instead of creating a second one | two `portfolio-prism` providers | list Providers in the authentik UI after apply |
| HTTP probes | — | **not run in-cluster at all**; the probes cited below were workspace-to-public-internet |

To read the backend image's uid without a container runtime, use the skopeo + tar technique at
`docs/superpowers/specs/2026-10-24-titan-llm-endpoint-design.md`, against the pinned **digest** in
the manifest, not the tag.

## Post-merge: mounting is not applying

Flux syncs the Secret; authentik's worker discovers it on its own schedule, which can be ~50
minutes. During that window **login failing is the correct state**, not a fault.

To force it, use `docs/authentik-runbook.md` §5. The §5 UI path is read-only status; the write path
is the `ak` shell. **Start with the redaction filter** — a validation failure prints `client_secret`
in plaintext, and this blueprint's secret is exactly the 64-hex shape the filter redacts:

```sh
kubectl -n auth exec deploy/authentik-worker -- \
  ak apply_blueprint --dry-run \
  /blueprints/mounted/secret-authentik-portfolio-prism-blueprint/portfolio-prism.yaml \
  2>&1 | sed -E 's/[a-f0-9]{64}/REDACTED/g' | tail -20
```

Then the same command without `--dry-run`. Needs an admin context; `k8s-reader` is Forbidden on
`pods/exec`.

Proof of success is `BlueprintInstance.status` for `titan-portfolio-prism` — expect `successful`
(UI → Directory → Blueprints, or the `ak` shell one-liner in `docs/grafana-runbook.md`). The worker
log line "Applying blueprint due to changed file" proves **dispatch**, not success.

Then, in order:

1. `curl -s https://auth.titan.arrieta.eu/application/o/portfolio-prism/.well-known/openid-configuration` → 200.
2. Log in through the browser at `https://portfolio.titan.arrieta.eu`. Confirm the redirect returns
   to the app and not to an authentik error page — this is the `redirect_uri_type: logout` check.
3. Log out. If authentik shows an error instead of returning to the app, the logout URIs were
   rejected; see the unverified table.
4. Confirm no second provider exists.
5. The UI-created client from 2026-11-07 stops working if the slug match held. Anything still using
   it needs `sops -d apply/10-secrets/portfolio-prism-secrets.yaml`.

The first authentik user to sign in takes ownership of any ownerless rows. On a fresh volume there
are none. `titan-family` has more than one member, so on a restored volume this is a race. Do not
set `BOOTSTRAP_OWNER_SUBJ` without reading the app's `docs/auth-testing.md` §6 — the transfer is
one-way.

## Rollback — `git revert` does not back this out

Every blueprint entry is `state: present`. Reverting git does not delete the provider, the
application, or the binding from authentik's database; it leaves a live client whose credentials no
longer exist in this tree. In order:

1. **App.** `kubectl -n apps delete deployment portfolio-prism service portfolio-prism ingress
   portfolio-prism`. Revert the kustomization entry so Flux does not rebuild them.
2. **Decide about the data before touching it.** The PVC holds the only copy. Either keep the PVC
   and the Secret for a later restore, or take a deliberate backup first
   (`kubectl -n apps cp` out of the pod, then `PRAGMA integrity_check` on the copy). Deleting the
   PVC and the Secret together is unrecoverable.
3. **authentik.** Delete the Application (cascades the provider) and the policy binding in the UI,
   or with `ak`. Then delete the blueprint Secret and its mount entry in
   `apply/50-apps/auth/authentik.yaml`, or authentik keeps a `BlueprintInstance` for a file that is
   gone.
4. **Secrets.** `apply/10-secrets/portfolio-prism-secrets.yaml` and
   `apply/10-secrets/authentik-portfolio-prism-blueprint.yaml`. Reverting the file removes them from
   the cluster on next sync; the credentials remain in git history, which is why they were minted
   rather than reused.
5. **`tools/ingress-auth-check.py`.** Remove the `NOT_PROXY_GATED` and `PIN_REQUIRED` rows for
   `apps/portfolio-prism`, or the stale-entry check fails the build.

## What was measured

**Ran in the authoring workspace:**

- `git add -A && make check` — exit 0, all 25 offline gates, on the branch as pushed.
- `scripts/rerender-authentik-blueprint.sh portfolio-prism --write` — the committed
  `authentik-portfolio-prism-blueprint.yaml` was re-rendered from the edited template with the
  existing client pair, so the mounted blueprint and the reviewed template are the same bytes. This
  is the only path that keeps them in step; re-running the setup script would have rotated the client
  and the cookie key.
- The rendered blueprint decrypts, parses under a tag-tolerant loader, and carries 3 authorization +
  3 logout redirect URIs.

**Against live public endpoints — not in-cluster:**

- `https://auth.titan.arrieta.eu/application/o/portfolio-prism/.well-known/openid-configuration`
  answered 200 before this PR, proving the UI-created provider's slug is `portfolio-prism`. This is
  the fact the blueprint's `identifiers` choice rests on.
- Composing `.../o/<slug>/authorize/` returns 404 — the endpoints must be read from the discovery
  document, per `blueprints-grafana.yaml`.
- The app's own smoke script asserts the issuer byte-for-byte comparison and the
  `post_logout_redirect_uri` origin form (`origin_of()` in the app repo, whose test pins the
  no-trailing-slash form).

## Declined, with the reason on the record

- **nginx half-hardening** (`runAsUser: 101` + `NET_BIND_SERVICE` + emptyDirs) — works without
  touching the image, declined only to avoid a second deviation from the upstream manifest in the
  same PR. This is the internet-facing container and the least hardened of the two.
- **Full `readOnlyRootFilesystem` for nginx** — needs an unprivileged image and moved paths; an
  app-repo change.
- **Resolving the SQLite backup deferral here** — cluster-wide, see Backup above.
- **Growing the StorageClass** — cluster-wide, see Storage above.
- **A second group binding** — see Access above.
- **A per-app OIDC gate in `make check`** — the honest gap: no gate asserts the portfolio-prism
  client pair agrees between the blueprint and the app Secret. `oidc-check` is coder-only. Adding a
  `portfolio-prism-oidc-check` is the fix and was not done here.
