# Portfolio Prism → Postgres: the database half (2026-11-15)

**Status: this change creates a database and a credential. It does not move the app.**
Portfolio Prism is still running SQLite on a PVC after this merges, and that is deliberate.

The application-side work is done and released: portfolio-prism `v0.1.0-M1` is Postgres-only, and
its own repo carries the design (`docs/superpowers/specs/2026-11-14-postgres-only-design.md`), the
follow-up stub for this repo
(`docs/superpowers/specs/2026-11-14-postgres-gitops-followup.md`) and the operator runbook
(`docs/postgres-cutover.md`). This file is the titan-side record of the first of the two changes
that stub asks for.

## What is true on the cluster, measured before writing any of this

| fact | how it was checked | result |
| --- | --- | --- |
| the live deployment is `apps/portfolio-prism`, not `investment-portfolio-manager` | `kubectl -n apps get deploy` | `portfolio-prism`, `Recreate`, 1 replica |
| **`spec.strategy.type` is `Recreate`** | `kubectl -n apps get deploy portfolio-prism -o jsonpath='{.spec.strategy.type}'` | `Recreate` |
| the running backend image | `kubectl -n apps get deploy portfolio-prism -o jsonpath=...containers` | `backend@sha256:35e2d2f…` |
| the CNPG cluster is healthy and hosts six databases | `kubectl -n databases get cluster,databases,databaseroles` | `postgres`, 1/1 healthy; authentik, coder, mealie, open-webui, sure, teslamate |
| the SQLite volume is in the restic backup set | `kubectl -n apps get pvc -o custom-columns=…` | `portfolio-prism-data` → class `daily` |

The `Recreate` row matters more than it looks. The app repo's runbook had to leave it as an
assumption — its own `k8s/` manifests are stale (#61) and declare no `spec.strategy` — and it told
whoever got here to confirm it on the live object. Confirmed: **the old pod is torn down before the
new one is created**, so a new pod that cannot reach its database is downtime for the whole app,
not a degraded rollout. That single fact is the reason this change is separate from the image roll.

## What this change adds

1. `apply/50-apps/portfolio-prism/portfolio-prism-db.yaml` — a CNPG `Database` and `DatabaseRole`
   for `portfolio_prism` on the existing `postgres` cluster, in namespace `databases`. Postgres
   identifiers use an underscore for the reason open-webui already documents: a hyphenated
   identifier is a quoted identifier, and quoting bugs get found during incidents.
2. `apply/10-secrets/portfolio-prism-db-credentials.yaml` — the role's
   `kubernetes.io/basic-auth` credential, sops-encrypted, carrying `cnpg.io/reload: "true"` on the
   Secret (that is where CNPG looks for the label, not on the `DatabaseRole`).
3. A `DATABASE_URL` key added to the existing `apply/10-secrets/portfolio-prism-secrets.yaml`,
   pointing at `postgres-rw.databases.svc.cluster.local:5432/portfolio_prism` — the same host shape
   open-webui uses.

The password exists twice, in those two Secrets, because CNPG's declarative role and the app's own
connection string are two different consumers of one credential. `make db-url-check` walks the
Deployment's `envFrom` to find the pair and fails if they disagree.

## Why the `DATABASE_URL` in the Secret does nothing yet — and why it is added now anyway

Kubernetes gives an explicit `env:` entry precedence over `envFrom:`. The Deployment still carries
`DATABASE_URL: sqlite:///app/data/portfolio.db?mode=rwc` inline, so **the inline SQLite URL wins
and the app is unaffected by this change.** That is the safety property, not an oversight: the
database can be created, verified and `Ready` while the app keeps running on the old engine.

It is added now rather than with the flip so that `db-url-check` guards the pair from the first
commit instead of being wired up in the same breath as the change that needs it.

## The order, and the change that comes next

The app repo's follow-up spec is explicit that database, credential and image are one atomic set in
the sense that **the image must never roll before the other two exist**. On this cluster that works
out as two changes:

* **This one.** `Database`, `DatabaseRole`, credentials, `DATABASE_URL` in the app Secret. Merging
  it changes nothing observable about the running app.
* **The flip.** Bump the backend digest to `v0.1.0-M1`, **delete** the inline `DATABASE_URL` so the
  Secret's value takes effect, and update `tools/portfolio-prism-check.py`, whose `want_env`
  currently asserts the SQLite URL and will fail until it is changed. Merging *that* one starts the
  cutover window: the old pod goes away, the new one migrates an empty database, and the app is down
  until the runbook's restore step completes.

Before the flip merges, the runbook's steps 1 and 2 have to have actually run against the live
SQLite app — **including the pre-cutover audit against a copy of the real `portfolio.db`, which has
never been done**; every audit so far ran against synthetic files. That is stated in the runbook's
own preamble and it is the first thing to retire.

Rollback for this change is clean and total: delete the `Database`, the `DatabaseRole`, the
credential Secret and the `DATABASE_URL` key. Nothing that holds user data is touched.

## What is not proven here

* **Nothing has been applied.** No `Database` exists on the cluster yet, so `status.applied` is
  unobserved for this role. The first reconcile is the proof, and the two failure modes the repo
  already documents are the ones to look for: a role created `NOLOGIN` (guarded by `login: true`
  here) and a stale `status.message` sitting next to `applied: true` (guarded by the `comment`
  field, the only `DatabaseRole` field that bumps `metadata.generation`).
* **Whether the role can run the app's migrations is argued, not executed.** The claim is that
  owning the database is enough — the migrations create their own objects and no extension. If the
  first Postgres boot disagrees, the fix is a deliberate `superuser: true` with its own note, not a
  silent widening.
* **The SQLite PVC and its restic schedule stay exactly where they are.** They are the rollback path
  until Postgres has survived a backup cycle of its own, and the app repo's follow-up spec §4 wants
  their retirement written down with a date rather than cleaned up opportunistically.
