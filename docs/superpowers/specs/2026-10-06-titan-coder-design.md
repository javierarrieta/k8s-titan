# titan — Coder as the first in-cluster workload with persistent homes

- **Date:** 2026-10-06
- **Status:** design approved in conversation; not implemented. No manifest for this exists yet.
- **Repo:** `javierarrieta/k8s-titan` (public)
- **Cluster:** `titan` — single-node k3s on OVH bare metal, NixOS-managed, live and green
- **Builds on:** `2026-10-03-k8s-titan-flux-bootstrap-design.md` (stages, sops, age key, certificate
  path) and `2026-10-03-titan-authentik-cnpg-design.md` (the shared `Cluster`, declarative
  per-app databases, the reflector path, authentik as identity provider). This spec **adds a
  second uncompensated backup override** and says so in §13 rather than absorbing it.
- **Modelled on:** `../k8s-casa`'s Coder install, deliberately diverging where casa's choices do
  not transfer (§2.3).

---

## 0. Ground rules carried forward

Everything in bootstrap spec §0 applies unchanged: this repo is public, so no credentials and no
concrete public IPv4 — write `<OVH_PUBLIC_IP>`. Secrets live only in `apply/10-secrets/`, sops-
encrypted, and every file there is listed in that directory's `kustomization.yaml`. Stage order is
`flux-system → secrets → infra → certificates → apps`, wired by `dependsOn`. No top-level
`namespace:` in any `kustomization.yaml`.

This spec adds no stage. Everything it creates lands in the existing `certificates` and `apps`
stages, plus two namespaces.

---

## 1. Intent and success criteria

**Intent.** Give one person a remote, rebuildable development environment on titan, with a home
directory that survives a workspace restart, authenticated by titan's own identity provider rather
than a second password.

Success is:

1. `https://coder.titan.arrieta.eu/` serves Coder and logs in through authentik.
2. A workspace builds from a Terraform template that exists in this repo, lands in
   `coder-workspaces`, and mounts a 40 G home PVC.
3. Two such workspaces run at once without the control plane noticing. A third refuses to schedule
   visibly rather than degrading the database invisibly.
4. Deleting a workspace's PVC does not erase its bytes (§9.2 — this is the mitigation, and it is
   proven, not assumed).
5. Coder's own state — templates, users, workspace metadata — is recoverable through the existing,
   already-drilled Postgres restore path.

**Explicitly not in scope**, named so it is not silently dropped (§14): backups of workspace home
directories, automatic template deployment, a break-glass local login, and monitoring.

---

## 2. Context this design inherits, and what was checked

### 2.1 Verified against the live cluster and DNS, not assumed

| Fact | How it was checked |
|---|---|
| `*.titan.arrieta.eu` resolves at **any depth** — `a.b.titan.arrieta.eu` answers | DNS-over-HTTPS query against `dns.google/resolve`; Status 0 with an answer. The record behind it is `ovh_domain_zone_record.titan_wildcard` in **`../public-dns-tf/titan.arrieta.eu.tf`** (§7) |
| Therefore `*.coder.titan.arrieta.eu` needs **no DNS record** | Same check; OVH's wildcard is not limited to one label (the common "one label only" reading of RFC 4592 is wrong — a wildcard matches any descendant with no closer node) |
| An X.509 wildcard matches **exactly one label**, so the existing `*.titan.arrieta.eu` SAN will not cover `x.coder.titan.arrieta.eu` | RFC 6125 §6.4.3 / certificate semantics. This is the opposite of the DNS rule above, and the asymmetry is the whole reason §7 exists |
| titan allocates **12 CPU / 131,793,372 Ki (~126 Gi) / 110 pods** | `kubectl get node -o jsonpath` with the read-only `k8s-reader` identity |
| The only StorageClass is `local-path` (rancher.io/local-path), `reclaimPolicy: Delete`, `allowVolumeExpansion: false` | `kubectl get storageclass` |
| Latest Coder Helm chart is **2.37.4** | `curl https://helm.coder.com/v2/index.yaml`, highest `version: 2.x.y` |
| The reflector allow-list on `titan-wildcard` is currently `apps,auth` | Read from `apply/40-certificates/titan-wildcard.yaml` |

### 2.2 The pattern this copies, verbatim

`apply/50-apps/auth/authentik-db.yaml` already establishes how an app gets a database here, and
its comments record why each field is load-bearing: a CNPG `Database` must share a namespace with
its `Cluster` (so "where the app lives" loses to "where the cluster lives"); `DatabaseRole` needs
`login: true` or the role is created NOLOGIN and every connection fails with a message that points
somewhere else; `passwordSecret` must be `kubernetes.io/basic-auth`; and the `cnpg.io/reload`
label belongs on the referenced **Secret**, not on the `DatabaseRole`. Coder follows this exactly.

### 2.3 What casa does, and the three places that does not transfer

casa's `apply/50-apps/casa/coder.yaml` is a 127-line HelmRelease on chart `2.35.1`, with
`CODER_PG_CONNECTION_URL`, `CODER_OIDC_*`, an Ingress, and podman **client** TLS certs
(`ca.pem`/`cert.pem`/`key.pem`) mounted at `/run/secrets/`. No PVC, and no Terraform anywhere in
that repo.

| casa | titan, and why |
|---|---|
| Workspaces build on a **remote podman host** over TLS | Workspaces build **in-cluster** on titan. titan has 12 CPU and 126 Gi sitting mostly idle, and adding a second host to administer to reach them is the worse trade |
| OIDC against Keycloak at `/application/o/coder/` | authentik, which exposes the **same-shaped** path. The env var names transfer nearly unchanged; the issuer host does |
| Templates exist only in coder's database | Templates live in this repo (§10). Casa can afford that because its homes are disposable; here the template is the definition of what gets a PVC that is not backed up |
| Everything in one shared `casa` namespace | Two namespaces (§5.1), because coder needs RBAC that creates pods and PVCs and that capability should be fenced |

---

## 3. Program decomposition

This is one slice. It is not the backup work, and it does not pretend to be.

| # | Piece | Depends on | Status |
|---|---|---|---|
| 1 | Coder server + DB + OIDC + workspaces, as specified here | authentik + CNPG (both live) | **this spec** |
| 2 | General PV backups (`30-backup` stage, restic → object store) | — | deferred, §14; **its trigger has now fired a second time** |
| 3 | Automatic template deployment (git push → `coder templates push`) | 1 | deferred, §14 |
| 4 | Populating authentik with more than one user | — | deferred, authentik spec §12.1 |

---

## 4. Decisions and rejected alternatives

| # | Decision | Rejected alternative, and why |
|---|---|---|
| C1 | Workspaces run **in-cluster** with **persistent** homes | Disposable homes (no new backup obligation) or off-cluster podman like casa. Persistent won because a dev environment that loses `/home` on rebuild is not a dev environment; the backup cost is taken as an explicit override (§13), not hidden |
| C2 | **No backup** for workspace homes | Build `30-backup` first. Rejected as a sequencing preference: the data is a cache of a person's working state, the mitigation in §9.2 covers the realistic accident, and the override is recorded where it will be found |
| C3 | `local-path-retain` StorageClass for homes | Accepting `Delete` on an unbacked volume. A four-line manifest converts "deleted the wrong PVC" from data loss into "recreate the PV object" |
| C4 | **Separate** `coder-wildcard` Certificate → `coder-tls` | Adding `*.coder.titan.arrieta.eu` as a third SAN on `titan-wildcard`. That was the first instinct and it is worse: it forces an edit to the reflector allow-list AGENTS.md treats as the controlled mechanism, and it re-issues the whole cluster wildcard every time coder's cert renews. Separate object, separate Secret, `titan-wildcard.yaml` untouched |
| C5 | **Path-free wildcard** workspace hostnames (`CODER_WILDCARD_ACCESS_URL`) | Path-based `/@owner/@workspace/@app`. Zero cert work, but apps that emit absolute redirects or assume a host-per-port fail in ways discovered mid-worksession, not at deploy time |
| C6 | authentik OIDC only, **no local admin** | Coder-local password, or OIDC plus break-glass. A second credential with its own rotation story is the thing this cluster already has too few of. §8.4 resolves the lockout risk this creates: coder ships a database-level escape hatch that needs no existing user |
| C7 | Templates in git, **pushed by hand** | Templates only in coder's UI (invisible to review and to every gate here) or automatic push (a Terraform-executing CI path against a live cluster — its own spec, §14) |
| C8 | Two workspaces at 4 CPU / 8 Gi / 40 G, quota 8 CPU / 16 Gi / 80 G | One generous, or three or four small. Two leaves the control plane comfortable and makes "the third one is Pending" an explainable outcome |
| C9 | Chart pinned at `2.37.4` | casa's `2.35.1` (two minors stale) or floating. Every other chart here is pinned |
| C12 | coder's OIDC client declared as an **authentik blueprint in git** | Clicking it into existence in the UI. A hand-made client exists only inside one authentik database: invisible to review, unreproducible after a restore, and the reason this spec had a manual prerequisite blocking every later task |

---

## 5. Architecture

### 5.1 Namespaces

Both declared in `apply/00-bootstrap/namespaces.yaml`, which stays the only place namespaces are
declared:

- **`coder`** — the Coder server, its Ingress, its Secrets. Receives `coder-tls` by reflection.
- **`coder-workspaces`** — everything coder creates. A `ResourceQuota` and a `LimitRange` live
  here. Coder's service account is RBAC-bound to this namespace and to nothing else; it cannot
  reach `databases` or `auth`, which is the property that makes it safe to give pod-creation rights
  at all.

### 5.2 New and changed files

```
apply/00-bootstrap/namespaces.yaml            + coder, coder-workspaces
apply/40-certificates/coder-wildcard.yaml     new Certificate → coder-tls, reflected to coder
apply/50-apps/kustomization.yaml              + coder/coder-db.yaml, coder/coder.yaml (in order)
apply/50-apps/coder/coder-db.yaml             CNPG Database + DatabaseRole, namespace databases
apply/50-apps/coder/coder.yaml                HelmRepository + HelmRelease + Ingress, ns coder
apply/10-secrets/coder-secrets.yaml           db-url, oidc-client-id, oidc-client-secret
apply/10-secrets/coder-db-credentials.yaml    kubernetes.io/basic-auth, cnpg.io/reload: "true"
coder/templates/dev/main.tf                   the workspace template (repo root, not apply/)
Makefile                                      + db-url-check (§6.3)
```

`coder/` at the repo root rather than under `apply/` is deliberate: `apply/` stays pure Kubernetes
manifests, so `kustomize-check`, `secrets-placement` and `crd-check` never have to reason about
Terraform, and `leak-check` still scans it like everything else.

Ordering in `apply/50-apps/kustomization.yaml` matters and is commented in place, as it already is
for authentik: the `Database` cannot resolve its `clusterRef` before the `Cluster`, and the
HelmRelease would install and crash-loop before the role exists.

---

## 6. Database layer

### 6.1 The CRs

`Database coder` (name `coder`, owner `coder`, cluster `postgres`) and `DatabaseRole coder`
(`login: true`, `passwordSecret: coder-db-credentials`), both in namespace `databases`, both
copied from the authentik pair including the comments explaining `login: true` and the label
placement.

### 6.2 The duplication this design is forced into

Coder accepts exactly one knob, `CODER_PG_CONNECTION_URL` — a full URL with the password inline.
CNPG's declarative role takes a `kubernetes.io/basic-auth` Secret. Neither can be derived from the
other at apply time: kustomize cannot read one Secret and template it into another, and there is no
init-container trick worth its complexity here. So the same password is stored twice, in two
sops-encrypted files.

That is a drift hazard with a quiet failure mode: rotate one, forget the other, and coder fails to
start with an authentication error that reads like a database problem.

### 6.3 The gate that closes it

`make db-url-check`, offline, following `release-secrets`' design so it cannot pass vacuously:

- It is driven by **references found in built output**, not by a list of files. For every
  `HelmRelease` that reads a secret key whose value looks like a Postgres URL
  (`postgres://` / `postgresql://`), it resolves that Secret and key in `apply/10-secrets/`.
- It decrypts that Secret and the `DatabaseRole`'s `passwordSecret` for the matching role, and
  asserts the URL's password equals the basic-auth password, and that the URL's user equals the
  role name.
- It reports what it checked — `db-url-check: 1 URL reference(s) checked, 0 mismatch(es)` — so a
  silent no-op is visible, which is the failure mode `make validate` already refuses to have.
- It needs the age key, so it joins `check`, not `check-ci`.

This joins the six offline gates the repo already has (`leak-check`, `kustomize-check`, `validate`,
`secrets-placement`, `release-secrets`, `crd-check`), and it exists for the same reason they do:
the class of error it catches is one a normal schema validator waves through.

---

## 7. Certificates, DNS and ingress

- **DNS: nothing to do here, and that is not luck.** `../public-dns-tf/titan.arrieta.eu.tf` declares
  `ovh_domain_zone_record.titan_wildcard` — `subdomain = "*.titan"`, type `A`, ttl 300 — and that
  file's own comment says it plainly: *"the wildcard is not convenience, it is the certificate
  strategy."* This spec's §7 depends on a resource owned by another repo, so it is named as a
  dependency rather than treated as background. Consequences:
  - Any DNS change goes in **that repo, via PR**. The OVH console is not the source of truth; a
    record made by hand there is invisible to `terraform plan` and arrives as unexplained drift on
    whoever runs it next.
  - The ACME TXT records cert-manager's DNS-01 solver writes live in the same Terraform-managed
    zone. Terraform tracks only what it declares, so they do not read as drift — but a destructive
    plan over there pulls the A records out from under every certificate over here. One sentence in
    that repo's README would be worth writing; it is out of this spec's scope to write it.
  - If the wildcard is ever narrowed or removed, `coder.titan.arrieta.eu` and every workspace host
    stop resolving at once. §11.2 carries that as a standing condition, not a one-time check.
- **`coder-wildcard` Certificate** in namespace `certificates`: `commonName: coder.titan.arrieta.eu`,
  `dnsNames: [coder.titan.arrieta.eu, "*.coder.titan.arrieta.eu"]`, `issuerRef: le-prod-titan`,
  `secretName: coder-tls`, and a `secretTemplate` whose Reflector annotations allow-list **only**
  `coder`. This is the pattern `titan-wildcard.yaml` already uses; the allow-list is the mechanism
  and it is not to be bypassed by copying a Secret.
- **Ingress** in `coder`: host `coder.titan.arrieta.eu`, `ingressClassName: traefik`,
  `secretName: coder-tls`. A second rule (or a second Ingress) for `*.coder.titan.arrieta.eu`
  pointing at the same service, which is how coder's wildcard mode expects to be fronted.
- **Unverified, must be observed:** that the OVH DNS-01 solver issues a second wildcard without
  complaint. It should — same zone, same solver, and DNS-01 does not care about label depth — but
  "should" is what the plan is for.

Traefik's configuration remains unmanaged by this repo, as the bootstrap spec established.

---

## 8. Coder layer

### 8.1 Values

HelmRelease `coder` in namespace `coder`, chart `coder` version `2.37.4` from
`https://helm.coder.com/v2`. `coder.env` carries:

| Variable | Source |
|---|---|
| `CODER_ACCESS_URL` | literal `https://coder.titan.arrieta.eu` |
| `CODER_WILDCARD_ACCESS_URL` | literal `https://*.coder.titan.arrieta.eu` |
| `CODER_PG_CONNECTION_URL` | `secretKeyRef` → `coder-secrets/db-url` |
| `CODER_OIDC_ISSUER_URL` | literal `https://auth.titan.arrieta.eu/application/o/coder/` |
| `CODER_OIDC_CLIENT_ID` / `_CLIENT_SECRET` | `secretKeyRef` → `coder-secrets` |
| `CODER_OIDC_EMAIL_FIELD` / `USERNAME_FIELD` / `SCOPES` / `IGNORE_EMAIL_VERIFIED` | literals, per casa's working set |

Resources: requests 100m/512Mi, limits 2000m/1024Mi — same as casa, which is a known-good shape
rather than a guess.

### 8.2 The authentik side is declared in git (supersedes the A10 deferral)

This section previously said the Application and OAuth2/OIDC Provider are created by hand, because
authentik blueprints were deferred (authentik spec A10). **That is no longer true**, and the reason
it changed is worth keeping: the manual step was the single thing blocking every later task, and a
credential that exists only as a database row is invisible to every gate in this repo. See §8.5 for
the mechanism and what is still unproven about it. The authentik spec's A10 deferral stands for
everything except coder's client.

### 8.3 What OIDC-only means operationally

Coder's login will depend on authentik, and authentik depends on the same CNPG `Cluster` coder
does. One database outage takes both. On a single-node cluster that coupling is unavoidable and is
accepted here, not discovered later.

### 8.4 The lockout question, answered from source

With no local admin, a misconfigured OIDC client could lock every human out of coder. This was left
unverified when the spec was written; it is now checked against `coder/coder` at `main`, read on
2026-10-06.

**The escape hatch is `coder server create-admin-user`, and it needs neither OIDC, nor the API, nor
an existing user.** `cli/server_createadminuser.go` registers it as a child of `coder server` with
`Use: "create-admin-user"`, takes `--postgres-url` (env `CODER_PG_CONNECTION_URL`), and writes the
new user with `LoginType: database.LoginTypePassword`. That last detail is what makes it the
break-glass rather than a curiosity: it creates a genuinely password-based admin even when every
existing account is OIDC-provisioned and has no usable password.

`coder reset-password <username>` (`cli/resetpassword.go`) is **not** the break-glass. It updates
`hashed_password` and nothing else, so for a user whose login type is `oauth` it does not
necessarily produce a working password login. Reaching for it under pressure would be the mistake.

There is also a built-in guard: `CODER_DISABLE_PASSWORD_AUTH` (`codersdk/deployment.go`) documents
that *"any user with the owner role will be able to sign in with their password regardless of this
setting to avoid potential lock out"*. Note that the docs string names the remedy as
`coder server create-admin` while the registered command is `create-admin-user`. Trust the code.

In practice, from inside the cluster:

```fish
kubectl -n coder exec deploy/coder -- coder server create-admin-user \
  --postgres-url (kubectl -n coder get secret coder-secrets -o jsonpath='{.data.db-url}' | base64 -d)
```

**Honest limit: this was read in source, not executed.** The environment this was verified in has
no container runtime, so no throwaway coder was started. The command, its flags, its registration
and its `LoginType` are cited from source; the end-to-end act of running it is not proven.

Consequence for C6: it stands unchanged. No break-glass local account is added to the HelmRelease,
because the recovery path is database-level and needs nothing that OIDC misconfiguration can break.
The residual risk is that the escape hatch needs the coder image and the DB URL — both of which are
in this cluster and neither of which depends on authentik.

---

### 8.5 The OIDC client is declared, not clicked (C12)

The plan originally had a human create the application and provider in authentik's UI and hand the
client to coder. That makes one credential exist in exactly one place — a database row — which is
invisible to `make check`, unreproducible after a restore, and was the manual step blocking Tasks 6
through 13.

**CRDs are not available and that was checked, not assumed.** `kubectl get crd | grep -i authentik`
returns nothing on this cluster, and the pinned chart `authentik-2026.8.3` ships no `crds/`
directory, no `installCRDs` value and no operator templates. There is no `applications.authentik.io`
waiting to be used, and installing a third-party operator to obtain one is a larger change than the
thing it would configure.

**Blueprints are the first-party path.** They are authentik's own infrastructure-as-code format —
YAML the worker applies against its own API — and the chart mounts them from a Secret
(`values.yaml:220`, `blueprints.secrets`). So `apply/50-apps/auth/blueprints/coder.yaml` is the
reviewed source, `scripts/setup-coder-secrets.sh` renders it with the generated client, and the
worker applies it.

The wrinkle is the one this cluster already knows: `OAuth2Provider.client_id` and `client_secret`
default to `generate_id` / `generate_client_secret` (`authentik/providers/oauth2/models.py:233-243`),
so authentik will happily invent them — and then coder cannot know them. They must be set explicitly,
which puts one credential in two files, exactly like the database password. Same treatment:
generated once, written to both, and `make oidc-check` proves the three copies — reviewed template,
applied Secret, coder's own env — still agree, including that the HelmRelease actually mounts the
Secret, because an unmounted blueprint is indistinguishable from one that was never written.

**Not proven, and named as such.** The flow slugs in the blueprint were probed against the live
instance — `default-authorization-flow` returns 404 here, which is why nothing was written from
memory — but `property_mappings: default-scopes` and the omission of `signing_key` are unverified.
Task 6's live step is what proves them, and a Secret applying is not the same fact as a blueprint
being applied by the worker.

## 9. Storage and quota

### 9.1 Sizes

| | Per workspace | Quota for `coder-workspaces` |
|---|---|---|
| CPU | 4 | **8** |
| Memory | 8 Gi | **16 Gi** |
| Home PVC | 40 Gi | **80 Gi** requests |

`vg0/pvc` is ~240 G shared with the Postgres PVCs, so 80 G of homes is roughly a third of the pool
and the quota is what keeps it that way. `allowVolumeExpansion: false` on local-path means a home
that fills cannot be grown through the PVC — that is a known limit of the StorageClass, not of this
design, and it is listed in §14 as something a future StorageClass change can fix.

A `LimitRange` gives containers without explicit requests a sane default, because the quota is only
enforced against requests and an unset request is a small one.

### 9.2 `local-path-retain`, and the proof it requires

A StorageClass with `provisioner: rancher.io/local-path`, the same `nodePath` config as the
default, and `reclaimPolicy: Retain`. Workspace PVCs use it; everything else keeps the default.

The claim "a deleted PVC keeps its bytes" is **not accepted on reasoning**. The plan must: create a
PVC on `local-path-retain`, write a marker file, delete the PVC and the released PV, show the
directory still exists on the node, and show it recoverable. If local-path's helper ignores
`Retain` — which is possible and is precisely the kind of thing a four-line manifest gets wrong —
then C3 is wrong and §13's override gets worse, which is exactly what the proof is for.

---

## 10. Templates in git

`coder/templates/dev/main.tf` — coder's Kubernetes provider, one container, one 40 Gi PVC on
`local-path-retain`, mounted at `/home/coder`, resource requests matching §9.1. Pushed by hand:

```
coder templates push dev -d coder/templates/dev
```

**Accepted gap, named:** git is the source of truth but nothing enforces it. A template edited in
the UI drifts from the file and no gate notices. The mitigation is that coder reports the template
version a workspace is running, so a build failure points at the discrepancy — which is a
*diagnostic*, not a prevention, and is written as such. Automatic push is §14's deferred item.

---

## 11. Secrets inventory and operator prerequisites

### 11.1 `apply/10-secrets/`

| File | Type | Keys |
|---|---|---|
| `coder-secrets.yaml` | `Opaque` | `db-url`, `oidc-client-id`, `oidc-client-secret` |
| `coder-db-credentials.yaml` | `kubernetes.io/basic-auth` | `username` (`coder`), `password`; label `cnpg.io/reload: "true"` |

Both must be listed in `apply/10-secrets/kustomization.yaml` — `secrets-placement` already fails
when one is not, because an unlisted Secret builds fine and is silently never applied.

### 11.2 Operator prerequisites before merge

1. Create the authentik Application + OAuth2/OIDC Provider for coder; note client ID and secret.
2. Create the DB password, then sops-encrypt both files. **The two files must carry the same
   password** — §6.3's gate enforces it, but only after it is written.
3. Nothing in DNS — **conditional on** `titan_wildcard` in `../public-dns-tf` remaining as
   declared (§7). If it is narrowed or removed, coder and every workspace host stop resolving
   together, and no amount of reconciliation in this repo will fix it.

The `db-url` value must never be pasted into a chat or an agent transcript. The rotation procedure
in `docs/authentik-runbook.md` §1 — read from the terminal, guard the shape, encrypt in place — is
the pattern to follow, and the reason it exists is in that section.

---

## 12. Verification

### 12.1 Offline

`make check` must pass with the age key, including the new `db-url-check`. `make check-ci` must
pass in CI, which does **not** run `db-url-check` (it needs the age key, which never goes in CI).

### 12.2 Against the cluster

1. `coder-wildcard` Ready; `coder-tls` present in `coder` and in no other namespace.
2. A workspace host resolves — `curl -s "https://dns.google/resolve?name=x.coder.titan.arrieta.eu&type=A"`
   returns an answer. That is the §7 dependency holding in practice, not merely present in a file
   another repo owns.
3. `Database coder` and `DatabaseRole coder` Synced (admin context — `k8s-reader` is Forbidden on
   `postgresql.cnpg.io`).
4. HelmRelease `coder` Ready; `https://coder.titan.arrieta.eu/` serves and offers authentik as a
   login method.
5. Login as `akadmin` through authentik succeeds.
6. Push the template; create a workspace; it reaches `running` with a Bound PVC on
   `local-path-retain` in `coder-workspaces`.
7. A workspace app on a secondary port is reachable at `*.coder.titan.arrieta.eu` with a valid TLS
   chain — this is C5's actual payoff and it must be observed, not inferred from config.
8. **The Retain proof** (§9.2).
9. Create a third workspace: it stays `Pending`, and `kubectl describe` says why.
10. Coder's database restores through the existing drill: seed a row coder wrote, back up, restore
    to a scratch `Cluster`, assert the named row — the form `docs/authentik-runbook.md` §2 already
    mandates, not a `count(*)`.
11. The §8.4 lockout finding, resolved before cutover.

---

## 13. Amendments to the existing specs

This is the second time titan takes data without a backup path, and the first time it was only
recorded after the fact. So:

- **authentik spec §12 / bootstrap spec §13b row for general PV backups:** the trigger
  ("any other workload with data that is not a Postgres database") has now fired **again**, and the
  second override is **uncompensated** — the first was compensated by the S3 backup path that
  later landed. Both specs get amended to say coder's homes are that workload, that no
  compensation exists, and that `local-path-retain` (§9.2) is a deletion-mitigation, not a backup.
- **AGENTS.md** backups paragraph: currently says the Postgres cluster "and nothing else does".
  Still true, and now needs the named accepted risk attached, so a future reader does not mistake
  an accepted override for an oversight.
- **The asymmetry is worth stating plainly:** coder's *configuration* — templates, users,
  workspace metadata — lives in the shared Postgres and is therefore backed up and restore-proven.
  Only the home directories are unprotected.

---

## 14. Deferred, with the trigger that promotes it

| Item | Why not now | Trigger |
|---|---|---|
| Backups of workspace homes (restic → object store, `30-backup`) | C2, recorded in §13 | First time a home holds work that would be missed — or the first time it actually hurts |
| Automatic template deployment | A Terraform-executing CI path against a live cluster is its own subsystem | Template drift actually bites once |
| Break-glass local coder admin | C6, and §8.4 found a database-level escape hatch that makes one redundant | The escape hatch is ever found not to work in practice |
| authentik blueprints as declarative config | Deferred in the authentik spec (A10); coder makes it the second manual-state gap | Third instance of hand-created identity state |
| `allowVolumeExpansion` / a growable StorageClass | local-path cannot expand; changing it is a StorageClass decision | A home fills up |
| A note in `../public-dns-tf` that `titan_wildcard` is load-bearing for cert-manager DNS-01 across this cluster | That repo is not this spec's to edit | Next time anyone narrows a wildcard there |
| Per-workspace NetworkPolicy | Not in scope; the quota is the containment chosen here | A workspace needs to be fenced from another tenant |

---

## 15. Decision record

| # | Subject | Decision |
|---|---|---|
| C1 | Workspace placement and persistence | In-cluster, persistent homes |
| C2 | Home backups | None; second uncompensated override, recorded |
| C3 | StorageClass | `local-path-retain`, `reclaimPolicy: Retain`, proven before reliance |
| C4 | Wildcard certificate | Separate `coder-wildcard` → `coder-tls`, reflected to `coder` only |
| C5 | Workspace app routing | Wildcard hostnames via `CODER_WILDCARD_ACCESS_URL` |
| C6 | Authentication | authentik OIDC only; escape hatch is `coder server create-admin-user`, read from source (§8.4) |
| C7 | Templates | In git at `coder/templates/`, pushed by hand; drift accepted and named |
| C8 | Capacity | 2 × (4 CPU / 8 Gi / 40 G); quota 8 CPU / 16 Gi / 80 Gi |
| C9 | Chart version | Pinned `2.37.4` |
| C10 | Namespaces | `coder` + `coder-workspaces`, both declared centrally |
| C11 | New offline gate | `make db-url-check`, reference-driven so it cannot pass vacuously |
| C12 | authentik configuration | Blueprint in git, rendered to a sops Secret, mounted into the worker; `make oidc-check` ties the three copies together |
