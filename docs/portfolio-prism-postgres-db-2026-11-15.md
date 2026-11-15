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

## The flip — the change that actually moves the app

The section above describes what landed first (the database and the credential). **This is the
change that starts the clock.**

Merging it begins the cutover window. The deployment is `Recreate` with one replica, so the moment
this applies the SQLite pod goes away and the Postgres build comes up against an empty database. The
app is not usable again until the app repo's `docs/postgres-cutover.md` restore step has completed.
Do not merge before that runbook's steps 1 and 2 have actually been run against the live SQLite app
— **including the pre-cutover audit against a copy of the real `portfolio.db`, which has never been
done.** Every audit so far ran against synthetic files, and the runbook says so in its own preamble.

What changes here:

- backend digest → `sha256:4811d37249cf94d7b68112ea7bb5f5560b3ca8d085aa089f9662b7821fdf14d5`,
  frontend digest → `sha256:a6cc45eb9a2f4b16fef52700ad4597f187ee4c9de20323890ede321df36552af`. Both
  are the `v0.1.0-M1` manifest-list digests, read from the registry rather than derived from the tag.
- the inline `DATABASE_URL` is **deleted**, which is what lets the Secret's value take effect.
- `tools/portfolio-prism-check.py` no longer expects the SQLite URL and now **fails if any inline
  `DATABASE_URL` reappears**. That is not tidiness: an inline entry shadows the Secret's value
  through `envFrom`, so the app would come up healthy against the wrong engine and nothing would
  report it. The failure this guards is invisible from outside the pod.
- the header rationale (`no own database server`) and the startup-probe wording (`init_db`) are
  corrected, and the PVC is labelled as what it now is — the rollback path, not the database.

Deliberately unchanged:

- **The PVC, its mount and its restic annotation stay.** The SQLite file on it is the only copy of
  anything written before the cutover, until Postgres has survived a backup cycle of its own
  (runbook step 7). Retiring it is a decision with a date on it, not a cleanup.
- **`BOOTSTRAP_OWNER_SUBJ` stays absent.** A restored bundle carries the owner it was exported for,
  so a fresh database has no unowned rows. If the audit reports portfolios with a NULL owner, that
  is a one-way handover to read up on first, not a value to guess.
- **`DATABASE_URL` lives in exactly one place** — `portfolio-prism-secrets` — and `make db-url-check`
  proves it agrees with the CNPG role's credential.

After this merges, a green pod is not by itself the proof. The runbook's step 6 compares row counts
against the bundle, and `psql` against the new URL should show
`select version, description from _sqlx_migrations order by version` populated.

### The one check worth running before merging this

The open question is whether the role can create its own schema — `sqlx::migrate!` needs `CREATE`,
and on PostgreSQL 15+ `CREATE` on `public` is not granted to everyone by default. It can be answered
read-only, in seconds, with an **admin** context:

```sh
kubectl -n databases port-forward svc/postgres-rw 55433:5432 &
PGPASSWORD=$(sops -d apply/10-secrets/portfolio-prism-db-credentials.yaml \
  | python3 -c 'import sys,yaml;print(yaml.safe_load(sys.stdin)["stringData"]["password"])') \
psql -h 127.0.0.1 -p 55433 -U portfolio_prism -d portfolio_prism -c \
  "select has_database_privilege('portfolio_prism','portfolio_prism','CREATE') as db_create,
          has_schema_privilege('portfolio_prism','public','CREATE') as public_create;"
```

Both `t` means the migrations will run. `db_create=t, public_create=f` means the app will fail at the
first `CREATE TABLE` and the fix is a deliberate grant or `superuser: true`, decided on purpose
rather than discovered mid-outage.

**This was not run here.** The kubeconfig in the authoring workspace is the read-only `k8s-reader`
service account, which cannot `pods/portforward` — the attempt fails with
`cannot create resource "pods/portforward" in API group "" in the namespace "databases"`. So the
question above is still open, and it is the one thing in this change that a merge should not skip.

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
