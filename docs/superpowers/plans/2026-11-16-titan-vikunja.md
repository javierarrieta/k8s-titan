# Vikunja on titan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Vikunja 2.8.0 at `tasks.titan.arrieta.eu` on the titan k3s cluster, with its data in the shared CNPG Postgres, sign-in through authentik OIDC, and outbound mail relayed through `mail.techdelivery.es`.

**Architecture:** One hand-written `Deployment` (single container, API + frontend in one process) plus a `PersistentVolumeClaim`, `Service` and `Ingress` in a new `vikunja` namespace, living in the shared `apps` Flux stage. Its database is a CNPG `Database`/`DatabaseRole` pair in the existing `databases` namespace. Its OIDC client is declared as an authentik blueprint template, rendered into a sops-encrypted Secret, and mounted by the existing authentik `HelmRelease`. A new offline gate, `make vikunja-check`, ties the five copies of the wiring together.

**Tech Stack:** Kubernetes (k3s), Flux CD kustomize, CloudNativePG, SOPS/age, authentik 2026.8.5, Traefik, Reflector, Python 3 + PyYAML for the gate, bash for the secrets script.

**Spec:** `docs/superpowers/specs/2026-11-16-titan-vikunja-design.md` — read it alongside this plan. Every decision below cites a `D<n>` from it; §9 of the spec is the list of what is not proven.

## Global Constraints

- Image pin: `docker.io/vikunja/vikunja:2.8.0`. Never `:latest` (fleet rule, D4).
- Hostname: `tasks.titan.arrieta.eu`. Namespace: `vikunja`. CNPG database, role and object name: `vikunja` (no hyphen — D2).
- Postgres host: `postgres-rw.databases.svc.cluster.local:5432`. **The port goes inside `VIKUNJA_DATABASE_HOST`.** There is no `database.port` config key — `pkg/db/db.go:239` parses `host:port` out of `database.host` via `parsePostgreSQLHostPort`, defaulting to 5432. A `VIKUNJA_DATABASE_PORT` would be a dead variable that reads as configured.
- Secrets live only in `apply/10-secrets/`, sops-encrypted, using `stringData` and never `data:` (`secrets-placement` rejects `data:` there — a sops ciphertext is not base64 and the API server refuses the tree at dry-run).
- Never set a top-level `namespace:` in any `kustomization.yaml`.
- No attribution trailers in commit messages. No `Co-Authored-By:`, nothing naming a model or agent.
- This repo is public: no credentials and no concrete public IPv4 in any committed file. Cluster-internal addresses (`10.62.0.0/16`) are fine; the VPS and titan public addresses are not.
- Stage rule: `apply/50-apps/vikunja/` is a subdirectory of the existing stage and gets **no** `kustomization.yaml` of its own (spec §3, and the hard rule in the scale-out spec).
- Every manifest must be listed by name in `apply/50-apps/kustomization.yaml`. An unlisted manifest is a manifest Flux never applies (`make kustomize-listing`).
- Mail: `VIKUNJA_MAILER_FROMEMAIL` must equal the mailbox address in `VIKUNJA_MAILER_USERNAME`, because the relay runs `SPOOF_PROTECTION=1` (D12).
- Timezone: `VIKUNJA_SERVICE_TIMEZONE=GMT`, which is a pin of the existing default, not a behaviour change (D13).
- Pool: `VIKUNJA_DATABASE_MAXOPENCONNECTIONS=10`, `VIKUNJA_DATABASE_MAXIDLECONNECTIONS=2` (D10).

## Review Focus

These are the failure modes no task's happy-path check exercises, most likely first. Each line gets a pinning test in the task that owns the code — Task 4 writes the gate, Task 7 proves the gate actually fires.

- **A credential duplicated across two namespaces drifts apart.** `vikunja-secrets` and `vikunja-db-credentials` hold the same Postgres password; `db-url-check` never looks at this app because it is reference-driven on `DATABASE_URL`/`*PG_CONNECTION_URL` and Vikunja takes split `VIKUNJA_DATABASE_*` keys. Expected: the gate fails naming both files. A silent split reads as `password authentication failed` in the pod while the `Database` reports Ready.
- **The blueprint is committed and mounted but never applied, or mounted but absent from the worker's reloader annotation.** Expected: the gate fails on the mount list and `blueprint-mount-check` fails on the annotation. Both read as "my change did nothing".
- **`VIKUNJA_SERVICE_SECRET` is absent.** Expected: the gate fails. Without it Vikunja mints a random secret per boot and every `Recreate` logs every session out, with no error anywhere (D8).
- **`VIKUNJA_MAILER_FROMEMAIL` stops matching the mailbox.** Expected: the gate fails. The relay refuses at `MAIL FROM` while the pod reports healthy (D12).
- **A dead config key is set.** `VIKUNJA_DATABASE_PORT` in particular, and any `VIKUNJA_*` key that is not a real config key. Expected: the gate fails. A dead key is worse than an absent one because it looks configured — the mailserver runbook's `DNS_SERVER: unbound.apps` is the precedent.

---

## Task 1: The database

**Files:**
- Create: `apply/50-apps/vikunja/vikunja-db.yaml`
- Modify: `apply/50-apps/kustomization.yaml` (append to `resources:`)

**Interfaces:**
- Consumes: the existing CNPG `Cluster postgres` in namespace `databases`.
- Produces: Postgres database `vikunja`, role `vikunja`, and a `kubernetes.io/basic-auth` Secret named `vikunja-db-credentials` in `databases` (created in Task 3, referenced here by name).

- [ ] **Step 1: Write the manifest**

Create `apply/50-apps/vikunja/vikunja-db.yaml`:

```yaml
# Vikunja's database and role, authored beside the app that owns them and living in `databases`,
# because a CNPG Database must share a namespace with its Cluster. Read mealie-db.yaml first;
# everything it records about DatabaseRole applies here verbatim.
#
# THE NAMING
# Kubernetes object names and the Postgres identifiers are all `vikunja`. open-webui had to translate
# `open-webui` to `open_webui` because a hyphenated identifier is a QUOTED identifier in Postgres, so
# every place that interpolates it becomes a quoting bug waiting to be found during an incident.
# Vikunja has no such translation to get wrong.
#
# WHAT IS IN HERE AND WHAT IS ON THE PVC, because it decides what a backup covers.
# Postgres holds users and their OIDC identities (issuer + subject), projects, tasks, checklists,
# labels, comments, shares, webhooks and the attachment ROWS. The PVC holds the attachment BYTES and
# avatars. Both are backed up, on two independent schedules with no shared point in time, so a restore
# can return a row whose bytes are not in the snapshot. Spec §4.
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: vikunja
  namespace: databases
spec:
  name: vikunja
  owner: vikunja
  cluster:
    name: postgres
---
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: vikunja
  namespace: databases
spec:
  name: vikunja
  cluster:
    name: postgres
  # Required and silent when missing: CNPG creates the role NOLOGIN by default, so without this the
  # Database reports Ready and every connection fails with a message pointing somewhere else.
  login: true
  # NOT superuser. Vikunja's migrations are ordinary DDL against its own schema and it creates no
  # extension. That is an argument from absence, so the first startup is the proof: if a migration
  # needs more, the pod fails loudly and the fix is a deliberate `superuser: true` with its own note,
  # not a silent widening. Same reasoning as mealie's and open-webui's roles.
  # `comment` is the only DatabaseRole field the CRD does not default, so it is the only one that
  # changes the stored spec and bumps `metadata.generation` — the lever that makes the instance
  # manager re-apply this role and clear a stale `status.message` it may carry alongside
  # `applied: true` (#154). `connectionLimit: -1` does nothing, because the API server already
  # writes that default in. It matters more here than elsewhere: `vikunja-db-credentials` arrives in
  # a later task, so this role is expected to fail on a missing Secret first and that denial has to
  # be clearable once the Secret lands.
  comment: managed by k8s-titan apply/50-apps/vikunja/vikunja-db.yaml
  passwordSecret:
    name: vikunja-db-credentials
```

- [ ] **Step 2: List it**

Append to the `resources:` list at the end of `apply/50-apps/kustomization.yaml`:

```yaml
  # Vikunja, the task manager at tasks.titan.arrieta.eu. Two files and the same split mealie and Sure
  # have: the CNPG Database and DatabaseRole live in `databases` beside their Cluster while the app
  # lives in `vikunja`. The third and fourth artifacts are not here — the OIDC blueprint and the app's
  # own Secrets are sops files in 10-secrets, and the blueprint is mounted by the authentik
  # HelmRelease below because authentik applies blueprints and Vikunja does not. Design:
  # docs/superpowers/specs/2026-11-16-titan-vikunja-design.md.
  - vikunja/vikunja-db.yaml
```

- [ ] **Step 3: Verify it builds and the schema is honest**

Run: `kubectl kustomize apply/50-apps | grep -A3 "kind: DatabaseRole"`
Expected: the `vikunja` role appears with `login: true`.

Run: `make kustomize-check && make crd-check && make kustomize-listing`
Expected: all three pass. `crd-check` is the one that matters — the CNPG CRDs declare no
`additionalProperties: false`, so a mis-nested field is caught here and nowhere else offline.

- [ ] **Step 4: Commit**

```bash
git add apply/50-apps/vikunja/vikunja-db.yaml apply/50-apps/kustomization.yaml
git commit -m "feat(vikunja): CNPG database and role in the shared cluster"
```

---

## Task 2: The authentik blueprint template

**Files:**
- Create: `authentik/blueprints-vikunja.yaml`

**Interfaces:**
- Consumes: managed authentik objects looked up with `!Find` (scope mappings, flows, signing key) and the group `titan-family`.
- Produces: an `oauth2provider` named `vikunja` whose `client_id`/`client_secret` are the `${...}` placeholders Task 3 substitutes, and an `application` slug `vikunja`. Task 4's gate reads this file and compares it to the rendered Secret.

- [ ] **Step 1: Write the template**

Create `authentik/blueprints-vikunja.yaml`:

```yaml
# authentik blueprint: Vikunja's OIDC application and provider, for tasks.titan.arrieta.eu.
#
# WHY A BLUEPRINT
# authentik ships no CRDs, so this is the only declarative path: a rebuilt authentik gets Vikunja's
# client back from git instead of from someone's memory. Same argument as blueprints-mealie.yaml, and
# docs/authentik-runbook.md §5 is the record of what a blueprint that is never mounted looks like
# (nothing — it is indistinguishable from one never written).
#
# HOW THIS FILE BECOMES A SECRET
# Nothing here is applied directly. scripts/setup-vikunja-secrets.sh substitutes the two `${...}`
# placeholders and writes the result, sops-encrypted, to
# apply/10-secrets/authentik-vikunja-blueprint.yaml. `make vikunja-check` proves the rendered
# artifact, this template, Vikunja's own copy of the client, the host it is for, and the mount agree.
#
# THE ENDPOINTS ARE NOT COMPOSED, THEY ARE READ
# authorize/token/userinfo are GLOBAL paths with no slug; issuer and jwks are per-provider — see
# blueprints-grafana.yaml. Building `.../o/<slug>/authorize/` returns 404, measured.
version: 1
metadata:
  name: titan-vikunja
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: vikunja-provider
    identifiers:
      name: vikunja
    state: present
    attrs:
      name: vikunja
      # confidential. Vikunja speaks the standard Authorization Code flow and holds a client secret;
      # its own docs require a confidential client.
      client_type: confidential
      client_id: "${VIKUNJA_OIDC_CLIENT_ID}"
      client_secret: "${VIKUNJA_OIDC_CLIENT_SECRET}"
      # ONE strict URI. The path is /auth/openid/<provider-id>, where the provider id is the key
      # Vikunja is configured under — `authentik`, from
      # VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_* in apply/50-apps/vikunja/vikunja.yaml. Strict,
      # because a prefix match is a redirect bypass.
      #
      # This URI and that env-var key are one fact kept in two files, which is what vikunja-check
      # compares. Change the provider key and this line must move with it.
      redirect_uris:
        - url: https://tasks.titan.arrieta.eu/auth/openid/authentik
          matching_mode: strict
      # authorization_code only. Vikunja does not refresh the authentik token — it exchanges the code
      # once and then issues its own JWT — and there is no offline_access scope below, so a
      # refresh_token grant would be a capability nothing uses.
      grant_types:
        - authorization_code
      # openid + email + profile. `email` is not optional here: mergeClaims() in
      # pkg/modules/auth/openid/openid.go returns ErrNoOpenIDEmailProvided when the ID token has no
      # email and the userinfo lookup cannot supply one, so a missing email claim is a refused login.
      #
      # `profile` is what carries preferred_username. Without it Vikunja falls back to `nickname` and
      # then to a generated pet-name, so the login SUCCEEDS with a nonsense username and nothing
      # errors anywhere. That is the silent failure this scope prevents.
      #
      # NO `groups` scope, deliberately: from Vikunja 2.8.0 a `groups` scope switches on team sync,
      # where every group name becomes a Vikunja team. Nothing here needs that (spec D20). Adding
      # `groups` to this list is a behaviour change, not a scope tidy-up.
      property_mappings:
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
      # implicit consent: an app this cluster owns and configures does not need a click that adds no
      # security. Same reasoning as coder's, Grafana's, open-webui's and Mealie's providers.
      authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      invalidation_flow: !Find [authentik_flows.flow, [slug, default-invalidation-flow]]
      signing_key: !Find [authentik_crypto.certificatekeypair, [managed, goauthentik.io/crypto/jwt-managed]]
      # per_provider makes the issuer https://auth.titan.arrieta.eu/application/o/vikunja/, which is
      # what vikunja.yaml's ..._AUTHENTIK_AUTHURL names. If the slug moves and that URL does not, the
      # two disagree and the failure looks like a bad token.
      issuer_mode: per_provider
      # hashed_user_id: stable across renames and it does not leak the username into every token.
      #
      # READ THIS BEFORE CHANGING IT. Vikunja keys a user on (issuer, sub) — getOrCreateUser() looks
      # the user up by exactly those two columns and nothing else. Changing sub_mode here changes
      # every user's sub, and the next login therefore creates a brand-new Vikunja user with an empty
      # task list. Mealie keys on the email claim and would survive this; Vikunja does not.
      sub_mode: hashed_user_id

  - model: authentik_core.application
    identifiers:
      slug: vikunja
    state: present
    attrs:
      name: Vikunja
      slug: vikunja
      provider: !KeyOf vikunja-provider
      meta_launch_url: https://tasks.titan.arrieta.eu/
      # Written out rather than inherited: the default is `any`, which is what is wanted, but a
      # security decision should not live in a default a future release is free to change.
      policy_engine_mode: any

  # --- who may reach Vikunja at all ---------------------------------------------------------------
  # The same shape as the gate in blueprints-mealie.yaml. Short version: the IdP refuses before a
  # token exists, and a binding naming a group that does not exist DENIES rather than allows.
  #
  # Vikunja has no admin-group concept fed from the token, so this is the whole authorization story:
  # who may sign in at all. There is no second group to bind.
  - model: authentik_policies.policybinding
    identifiers:
      target: !Find [authentik_core.application, [slug, vikunja]]
      order: 0
    state: present
    attrs:
      group: !Find [authentik_core.group, [name, titan-family]]
```

- [ ] **Step 2: Verify it parses with authentik's YAML tags tolerated**

Run:

```bash
python3 -c '
import sys; sys.path.insert(0,"tools")
from sopsload import load_tolerating_tags
b = load_tolerating_tags(open("authentik/blueprints-vikunja.yaml").read())
prov = [e for e in b["entries"] if e["model"].endswith("oauth2provider")][0]
assert prov["attrs"]["issuer_mode"] == "per_provider"
assert [u["url"] for u in prov["attrs"]["redirect_uris"]] == ["https://tasks.titan.arrieta.eu/auth/openid/authentik"]
assert "${VIKUNJA_OIDC_CLIENT_ID}" in prov["attrs"]["client_id"]
print("ok:", len(b["entries"]), "entries")
'
```

Expected: `ok: 3 entries`. If it raises, the tags are not being tolerated and Task 4's gate will not be able to read this file either.

- [ ] **Step 3: Commit**

```bash
git add authentik/blueprints-vikunja.yaml
git commit -m "feat(vikunja): authentik OIDC blueprint template"
```

---

## Task 3: The secrets script and the three Secrets

**Files:**
- Create: `scripts/setup-vikunja-secrets.sh`
- Create (by running it): `apply/10-secrets/authentik-vikunja-blueprint.yaml`, `apply/10-secrets/vikunja-db-credentials.yaml`, `apply/10-secrets/vikunja-secrets.yaml`
- Modify: `apply/10-secrets/kustomization.yaml`

**Interfaces:**
- Consumes: the blueprint template from Task 2; the age key (`SOPS_AGE_KEY_FILE`); the SMTP mailbox as a two-line file (address, then password).
- Produces: Secret `authentik-vikunja-blueprint` (ns `auth`, key `vikunja.yaml`), Secret `vikunja-db-credentials` (ns `databases`, keys `username`/`password`, `kubernetes.io/basic-auth`, labelled `cnpg.io/reload`), Secret `vikunja-secrets` (ns `vikunja`, six keys named exactly as Vikunja reads them). Task 4's gate reads all three; Task 5's Deployment `envFrom`s the app one.

- [ ] **Step 1: Write the script**

Create `scripts/setup-vikunja-secrets.sh`. It is `scripts/setup-mealie-secrets.sh` with a fourth minted value and one supplied one:

```bash
#!/usr/bin/env bash
# Mint everything Vikunja needs and write it to the places it has to appear.
#
# RUN IT, DON'T READ IT INTO A SHELL. The operator's login shell is fish, which has no heredocs and no
# `read -rs -p`; this file's bash-isms are deliberate and the shebang is the interpreter.
#
# WHY ONE SCRIPT FOR FOUR VALUES
# The DB password exists twice (CNPG's DatabaseRole in `databases`, and Vikunja's
# VIKUNJA_DATABASE_PASSWORD in namespace `vikunja`) and the OIDC client exists twice (authentik's
# blueprint, Vikunja's env). Minting all of it in one process is the only way "they agree" is a
# property of the code rather than of the operator's attention. `make vikunja-check` then proves it
# from the tree — and it has to, because Vikunja takes split VIKUNJA_DATABASE_* keys rather than a
# single DATABASE_URL, so the generic `make db-url-check` never looks at this app at all.
#
# WHY A FIFTH VALUE MEALIE DID NOT NEED
# VIKUNJA_SERVICE_SECRET signs every issued token. Unset, generateServiceSecretIfEmpty() in
# pkg/config/config.go mints a random one per boot and every already-issued token dies with the old
# process — with strategy: Recreate that is every deploy logging everyone out. Mealie signs its own
# tokens with keys held in Postgres and has no equivalent to pre-seed.
#
# WHY THE SMTP PAIR IS SUPPLIED AND NOT MINTED
# The mailbox already exists on mail.techdelivery.es and this script cannot create it — it lives in
# that box's config PVC, not in git. Passing a wrong password in here is worse than passing none:
# ENABLE_FAIL2BAN=1 on that box means a wrong credential from titan gets titan's address banned, and
# the symptom is "mail stopped working", not "auth failed". So the script takes the file, refuses a
# malformed one, and never prints what is in it.
#
# NOTHING PRINTS A VALUE. What you see is a truncated SHA-256 per file.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

TEMPLATE=authentik/blueprints-vikunja.yaml
BP_SECRET=apply/10-secrets/authentik-vikunja-blueprint.yaml
DB_SECRET=apply/10-secrets/vikunja-db-credentials.yaml
APP_SECRET=apply/10-secrets/vikunja-secrets.yaml
STAGE_BP=apply/10-secrets/.staging.authentik-vikunja-blueprint.yaml
STAGE_DB=apply/10-secrets/.staging.vikunja-db-credentials.yaml
STAGE_APP=apply/10-secrets/.staging.vikunja-secrets.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}

# Never leave plaintext behind, whatever fails. The staging paths are git-ignored by name
# (apply/10-secrets/.staging.*.yaml) and sit under apply/10-secrets/ because sops picks its
# recipients from the file's own path, not from your intent.
trap 'rm -f "$STAGE_BP" "$STAGE_DB" "$STAGE_APP"' EXIT

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE to the file holding the titan-k8s private key"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"
[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE missing - nothing to render"; exit 1; }

# The mailbox. Two lines: address, then password. Blank lines and trailing whitespace are tolerated;
# anything else is a hard stop, because a mangled address is a MAIL FROM refusal later.
SMTP_FILE=${SMTP_FILE:?FAIL: set SMTP_FILE=/path/to/two-line-file (address on line 1, password on line 2)}
[ -f "$SMTP_FILE" ] || { echo "FAIL: SMTP_FILE=$SMTP_FILE does not exist"; exit 1; }
SMTP_USER=$(sed -n '1s/[[:space:]]*$//p' "$SMTP_FILE")
SMTP_PASS=$(sed -n '2s/[[:space:]]*$//p' "$SMTP_FILE")
[ -n "$SMTP_USER" ] && case "$SMTP_USER" in *@*) ;; *) echo "FAIL: line 1 of $SMTP_FILE is not an address"; exit 1;; esac
[ -n "$SMTP_PASS" ] || { echo "FAIL: line 2 of $SMTP_FILE is empty - no password"; exit 1; }
echo "smtp user: $SMTP_USER"

existing=()
for f in "$BP_SECRET" "$DB_SECRET" "$APP_SECRET"; do
  [ -f "$f" ] && existing+=("$f")
done
if [ ${#existing[@]} -gt 0 ]; then
  echo "FAIL: these already exist and would be replaced with NEW values:"
  printf '  %s\n' "${existing[@]}"
  echo "Vikunja would then present a client and a password authentik and CNPG do not recognise. If that"
  echo "is what you want, re-run with FORCE=1 and rotate the OIDC client in the same change."
  [ "${FORCE:-0}" = "1" ] || exit 1
fi

CID=$(python3 -c 'import uuid; print(uuid.uuid4())')
CSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
DBPW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
SVSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')

TEMPLATE="$TEMPLATE" STAGE_BP="$STAGE_BP" STAGE_DB="$STAGE_DB" STAGE_APP="$STAGE_APP" \
CID="$CID" CSEC="$CSEC" DBPW="$DBPW" SVSEC="$SVSEC" \
SMTP_USER="$SMTP_USER" SMTP_PASS="$SMTP_PASS" python3 - <<'PY'
import os, re, sys, yaml

env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${VIKUNJA_OIDC_CLIENT_ID}", "${VIKUNJA_OIDC_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - template and script disagree")

# Exact string substitution and nothing else: what a reviewer reads in the template is byte-for-byte
# what authentik applies, apart from these two values.
rendered = (tpl.replace("${VIKUNJA_OIDC_CLIENT_ID}", env["CID"])
              .replace("${VIKUNJA_OIDC_CLIENT_SECRET}", env["CSEC"]))
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s) remain: {leftover}")

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=100)

dump(env["STAGE_BP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "authentik-vikunja-blueprint", "namespace": "auth"},
    "type": "Opaque",
    # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
    "stringData": {"vikunja.yaml": rendered},
})

# CNPG's DatabaseRole reads a kubernetes.io/basic-auth Secret whose `username` MUST equal the role
# name, and the cnpg.io/reload label belongs on THIS Secret, not on the DatabaseRole, where it would
# do nothing.
dump(env["STAGE_DB"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {
        "name": "vikunja-db-credentials", "namespace": "databases",
        "labels": {"cnpg.io/reload": "true"},
    },
    "type": "kubernetes.io/basic-auth",
    "stringData": {"username": "vikunja", "password": env["DBPW"]},
})

# Vikunja's own copy. Every key is named EXACTLY as Vikunja reads it, so the Deployment uses a plain
# envFrom with no aliasing — a typo'd key here is a dead variable, not a startup error, which is why
# the names are written out once, here, rather than mapped in two places.
#
# The provider key in those names is `authentik`: setConfigFromEnv() lowercases every underscore-
# separated segment, so AUTHENTIK in the env var becomes the provider id `authentik`, which is also
# the segment in the blueprint's redirect URI. A key containing an underscore would not survive that
# split at all.
dump(env["STAGE_APP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "vikunja-secrets", "namespace": "vikunja"},
    "type": "Opaque",
    "stringData": {
        "VIKUNJA_SERVICE_SECRET": env["SVSEC"],
        "VIKUNJA_DATABASE_PASSWORD": env["DBPW"],
        "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTID": env["CID"],
        "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTSECRET": env["CSEC"],
        "VIKUNJA_MAILER_USERNAME": env["SMTP_USER"],
        "VIKUNJA_MAILER_PASSWORD": env["SMTP_PASS"],
    },
})
PY

for f in "$STAGE_BP" "$STAGE_DB" "$STAGE_APP"; do
  sops --encrypt --in-place "$f"
  if [ "$f" = "$STAGE_BP" ]; then dest=$BP_SECRET
  elif [ "$f" = "$STAGE_DB" ]; then dest=$DB_SECRET
  else dest=$APP_SECRET; fi
  mv "$f" "$dest"
  echo "wrote $dest  (fingerprint $(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$dest"))"
done

cat <<'DONE'

Done. Three files, five values, all encrypted.

Still to do, in order:
  1. make vikunja-check            proves the copies agree and the blueprint is mounted.
  2. Merge, then force the blueprint with `ak apply_blueprint` rather than waiting on the worker's
     hourly discovery pass. Mounting is not applying - docs/authentik-runbook.md §5.
  3. Prove the SMTP credential ONCE. ENABLE_FAIL2BAN=1 on mail.techdelivery.es bans the source
     address after repeated failures, so this is one deliberate test, not a retry loop.
  4. The first authentik user to sign in is the one who sets up the task lists. There is no
     registration and no local password, so there is no second way in.
DONE
```

- [ ] **Step 2: Syntax-check it before anything runs it**

Run: `bash -n scripts/setup-vikunja-secrets.sh && chmod +x scripts/setup-vikunja-secrets.sh && echo ok`
Expected: `ok`.

- [ ] **Step 3: Run it**

This needs the age key and the mailbox file, so it is an operator-present step.

Run: `SMTP_FILE=/tmp/vijunya-mail.txt scripts/setup-vikunja-secrets.sh`
Expected: three `wrote …` lines with fingerprints, and no value printed anywhere. If it prints `FAIL: SMTP_FILE=… is not an address`, the supplied file is malformed — fix the file, not the script.

- [ ] **Step 4: Verify the rendered blueprint carries no placeholder and the keys are the ones Task 4 expects**

Run:

```bash
python3 -c '
import sys; sys.path.insert(0,"tools")
from sopsload import load_docs, secret_key
d = load_docs("apply")
bp,_ = secret_key(d,"authentik-vikunja-blueprint","auth","vikunja.yaml")
assert bp and "${VIKUNJA_OIDC_CLIENT_ID}" not in bp, "blueprint not rendered"
for k in ("VIKUNJA_SERVICE_SECRET","VIKUNJA_DATABASE_PASSWORD",
          "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTID",
          "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTSECRET",
          "VIKUNJA_MAILER_USERNAME","VIKUNJA_MAILER_PASSWORD"):
    v,_ = secret_key(d,"vikunja-secrets","vikunja",k)
    assert v, "vikunja-secrets missing key " + k
print("ok: 6 keys, blueprint rendered")
'
```

Expected: `ok: 6 keys, blueprint rendered`.

- [ ] **Step 5: List the Secrets and commit**

Append to `apply/10-secrets/kustomization.yaml`:

```yaml
  # Vikunja: its own Secret set, CNPG's copy of the same DB password, and the rendered authentik
  # blueprint. All three are written by scripts/setup-vikunja-secrets.sh; an unlisted one builds fine
  # and is silently never applied, which is the coder-db.yaml story.
  - vikunja-secrets.yaml
  - vikunja-db-credentials.yaml
  - authentik-vikunja-blueprint.yaml
```

```bash
git add scripts/setup-vikunja-secrets.sh apply/10-secrets/vikunja-secrets.yaml \
        apply/10-secrets/vikunja-db-credentials.yaml apply/10-secrets/authentik-vikunja-blueprint.yaml \
        apply/10-secrets/kustomization.yaml
git commit -m "feat(vikunja): mint OIDC client, DB password, service secret and SMTP credential"
```

---

## Task 4: The gate, written to fail

**Files:**
- Create: `tools/vikunja-check.py`
- Modify: `Makefile` (`.PHONY` on line 16, the `check:` list on line 21, and a new target near `mealie-check` around line 792)

**Interfaces:**
- Consumes: `tools/sopsload.py` — `load_docs(root)`, `find(docs, kind, name, namespace)`, `secret_key(docs, name, namespace, key)`, `load_tolerating_tags(text)`, `declared_groups(docs)`. The blueprint template at `../authentik/blueprints-vikunja.yaml` relative to the script.
- Produces: exit 0 with a one-line summary, or exit 1 with `FAIL:` lines. `make vikunja-check` is the entry point Task 7 and Task 8 call.

- [ ] **Step 1: Write the gate**

Create `tools/vikunja-check.py`:

```python
#!/usr/bin/env python3
"""Fail if Vikunja's wiring has drifted apart — OIDC, the database, the mail, and the mount.

Seven things have to agree and nothing else ties them together:

  1. authentik/blueprints-vikunja.yaml                     - the reviewed template, ${...} placeholders
  2. apply/10-secrets/authentik-vikunja-blueprint.yaml     - the rendered artifact authentik applies
  3. apply/50-apps/vikunja/vikunja.yaml                    - the app's own copy of the client, and the
                                                             host it builds its redirect URI from
  4. the authentik HelmRelease actually mounting the blueprint
  5. apply/10-secrets/vikunja-secrets.yaml                 - Vikunja's VIKUNJA_DATABASE_PASSWORD
  6. apply/10-secrets/vikunja-db-credentials.yaml          - CNPG's copy of the same password
  7. the mailer's FROM address and the mailbox it authenticates as

Item 4 is the failure this cluster has been burned by twice (docs/authentik-runbook.md §5): a blueprint
committed, reviewed and green, and never mounted — indistinguishable from one never written.

Items 5 and 6 are why this file exists at all rather than being folded into the OIDC checks.
`make db-url-check` is reference-driven and looks for a DATABASE_URL or a *PG_CONNECTION_URL; Vikunja
takes split VIKUNJA_DATABASE_* keys, so the generic gate reports zero references and passes vacuously
on this app. The password is still duplicated across two namespaces, which is exactly the split
db-url-check was written to catch. Sure's gate was written for the same gap from the other direction.

Item 7 is structural, not cosmetic: the relay runs SPOOF_PROTECTION=1, which restricts an authenticated
user to its own address and aliases. A FROM that does not match the mailbox is refused at MAIL FROM
while the pod reports healthy.

It also checks the settings whose ABSENCE is a silent failure:

  - VIKUNJA_SERVICE_SECRET. Unset, generateServiceSecretIfEmpty() in pkg/config/config.go mints a
    random one per boot, and every already-issued token dies with the process. With strategy: Recreate
    that is every deploy logging every session out, with no error anywhere.
  - VIKUNJA_AUTH_LOCAL_ENABLED. Defaults to true, which leaves a local password door beside SSO — the
    same call mealie's ALLOW_PASSWORD_LOGIN=false and open-webui's ENABLE_LOGIN_FORM=false record.
  - VIKUNJA_MAILER_ENABLED. Defaults to false, and reminders are already switched on behind it, so the
    mailer is the only switch and leaving it off is a silently decorative feature.
  - VIKUNJA_DATABASE_PORT must NOT be set. There is no database.port config key: pkg/db/db.go parses
    host:port out of database.host. A VIKUNJA_DATABASE_PORT is a dead variable that reads as
    configured — the mailserver runbook's `DNS_SERVER: unbound.apps` is the precedent for how
    expensive that shape is.

There is deliberately NO email_verified check here, which will read as an omission to anyone who has
seen coder or mealie. Vikunja keys identity on (issuer, sub) and reads email_verified only in the
deprecated emailfallback path that auth.local.enabled=false makes unreachable. Spec D6 has the source
evidence. If a future Vikunja changes that, the fix is a check here, not a guess in the manifest.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that looks encrypted but does not
decrypt is reported, never silently skipped.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import find, load_docs, load_tolerating_tags, secret_key  # noqa: E402

HOST = "tasks.titan.arrieta.eu"
PROVIDER = "authentik"
# /auth/openid/<provider-id>. The provider id is the YAML key Vikunja is configured under, which is
# the env-var segment lowercased — setConfigFromEnv() splits on "_" and lowercases every segment.
REDIRECT = f"https://{HOST}/auth/openid/{PROVIDER}"
ISSUER_URL = "https://auth.titan.arrieta.eu/application/o/vikunja/"
PLACEHOLDERS = ("${VIKUNJA_OIDC_CLIENT_ID}", "${VIKUNJA_OIDC_CLIENT_SECRET}")
PREFIX = "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_"
# Config keys that exist, so a VIKUNJA_* env var naming nothing is caught rather than ignored.
# Trimmed to what this app sets; extend it when a new key is introduced, do not let it rot.
KNOWN_KEYS = {
    "VIKUNJA_SERVICE_PUBLICURL", "VIKUNJA_SERVICE_SECRET", "VIKUNJA_SERVICE_ENABLEREGISTRATION",
    "VIKUNJA_SERVICE_TIMEZONE", "VIKUNJA_SERVICE_IPEXTRACTIONMETHOD", "VIKUNJA_SERVICE_TRUSTEDPROXIES",
    "VIKUNJA_SENTRY_ENABLED", "VIKUNJA_AUTH_LOCAL_ENABLED", "VIKUNJA_AUTH_OPENID_ENABLED",
    "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_NAME", "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_AUTHURL",
    "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_SCOPE", "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_LOGOUTURL",
    "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTID",
    "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTSECRET",
    "VIKUNJA_DATABASE_TYPE", "VIKUNJA_DATABASE_HOST", "VIKUNJA_DATABASE_DATABASE",
    "VIKUNJA_DATABASE_USER", "VIKUNJA_DATABASE_PASSWORD", "VIKUNJA_DATABASE_MAXOPENCONNECTIONS",
    "VIKUNJA_DATABASE_MAXIDLECONNECTIONS", "VIKUNJA_FILES_BASEPATH",
    "VIKUNJA_MAILER_ENABLED", "VIKUNJA_MAILER_HOST", "VIKUNJA_MAILER_PORT", "VIKUNJA_MAILER_FORCESSL",
    "VIKUNJA_MAILER_FROMEMAIL", "VIKUNJA_MAILER_USERNAME", "VIKUNJA_MAILER_PASSWORD",
}
DEAD_KEYS = {"VIKUNJA_DATABASE_PORT"}


def provider_of(entries, name="vikunja"):
    for e in entries or []:
        if e.get("model", "").endswith("oauth2provider") and e.get("identifiers", {}).get("name") == name:
            return e.get("attrs", {})
    return None


def env_of(deploy, name):
    for c in (((deploy.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers", []):
        for env in c.get("env") or []:
            if env.get("name") == name:
                return env.get("value")
    return None


def all_env_names(dep):
    names = set()
    for c in (((dep.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers", []):
        for env in c.get("env") or []:
            names.add(env.get("name"))
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="apply", help="tree to scan (a fixture root for tests)")
    args = ap.parse_args()

    docs = load_docs(args.root)
    failures = []

    def fail(msg):
        failures.append(msg)
        print("FAIL:", msg)

    # --- the blueprint: template, rendered artifact, and the mount ---------------------------
    tpl_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "authentik", "blueprints-vikunja.yaml")
    if not os.path.exists(tpl_path):
        fail(f"no reviewed template at {tpl_path}")
        tpl = None
    else:
        tpl = load_tolerating_tags(open(tpl_path).read())

    prov = provider_of(tpl["entries"]) if tpl else None
    if prov is None:
        fail("blueprints-vikunja.yaml declares no oauth2provider named vikunja")

    bp = find(docs, "Secret", "authentik-vikunja-blueprint", "auth")
    if bp is None:
        fail("no Secret authentik-vikunja-blueprint in namespace auth - the blueprint is not in the tree")
        rendered = None
    else:
        rendered, _ = secret_key(docs, "authentik-vikunja-blueprint", "auth", "vikunja.yaml")
        if rendered is None:
            fail("Secret authentik-vikunja-blueprint has no key vikunja.yaml - the worker only picks "
                 "up keys ending in .yaml")

    rprov = None
    if rendered is not None:
        rprov = provider_of(load_tolerating_tags(rendered)["entries"])
        if rprov is None:
            fail("the rendered blueprint has no oauth2provider named vikunja")
        else:
            for ph, key in (("${VIKUNJA_OIDC_CLIENT_ID}", "client_id"),
                            ("${VIKUNJA_OIDC_CLIENT_SECRET}", "client_secret")):
                if ph in rendered:
                    fail(f"the rendered blueprint still carries {ph} - it was committed before "
                         "scripts/setup-vikunja-secrets.sh substituted it")
            if tpl is not None:
                # The rendered artifact must be the template with ONLY the two placeholders filled.
                # Anything else means someone edited one file and not the other, and the template is
                # the reviewed artifact — the Secret is generated, so the template wins the argument.
                want = open(tpl_path).read()
                want = want.replace("${VIKUNJA_OIDC_CLIENT_ID}", rprov.get("client_id") or "")
                want = want.replace("${VIKUNJA_OIDC_CLIENT_SECRET}", rprov.get("client_secret") or "")
                if want != rendered:
                    fail("the rendered blueprint is not the reviewed template plus the credentials - "
                         "someone edited one file and not the other")
            uris = sorted(u.get("url") for u in (rprov.get("redirect_uris") or []))
            if uris != [REDIRECT]:
                fail(f"redirect_uris are {uris}, expected ['{REDIRECT}'] - the path is "
                     "/auth/openid/<provider-id> and the provider id is the env-var segment lowercased")
            if any((u.get("matching_mode") or "strict") != "strict" for u in (rprov.get("redirect_uris") or [])):
                fail("a redirect_uri is not matching_mode: strict - a prefix match is a redirect bypass")
            mappings = " ".join(str(m) for m in (rprov.get("property_mappings") or []))
            if "scope-profile" not in mappings:
                fail("the provider's property_mappings do not include the profile scope, so "
                     "preferred_username is not in the token and Vikunja mints a pet-name username "
                     "for every user while the login succeeds")
            if "scope-email" not in mappings:
                fail("the provider's property_mappings do not include the email scope. mergeClaims() "
                     "returns ErrNoOpenIDEmailProvided when there is no email claim, so this is a "
                     "refused login, not a cosmetic gap")
            if "groups" in mappings:
                fail("the provider carries a groups scope. From Vikunja 2.8.0 that switches on team "
                     "sync, where every group name becomes a Vikunja team (spec D20). If that is now "
                     "wanted, update the spec as well as this gate.")

    hr = find(docs, "HelmRelease", "authentik", "auth")
    if hr is None:
        fail("no HelmRelease authentik/auth")
    else:
        values = ((hr.get("spec") or {}).get("values") or {})
        mounted = ((values.get("blueprints") or {}).get("secrets") or [])
        if "authentik-vikunja-blueprint" not in mounted:
            fail("the HelmRelease does not mount authentik-vikunja-blueprint, so authentik never reads "
                 "it - mounting is not applying, but not mounting is definitely not applying")

    # --- Vikunja's own copy -------------------------------------------------------------------
    dep = find(docs, "Deployment", "vikunja", "vikunja")
    if dep is None:
        fail("no Deployment vikunja/vikunja")
    else:
        # PUBLICURL is what Vikunja builds its own redirect URI from, so it and the blueprint URI are
        # one fact. A mismatch is refused by authentik and the error names authentik, not Vikunja.
        if env_of(dep, "VIKUNJA_SERVICE_PUBLICURL") not in (f"https://{HOST}", f"https://{HOST}/"):
            fail(f"VIKUNJA_SERVICE_PUBLICURL must be https://{HOST} (with or without the trailing "
                 "slash) - Vikunja builds its redirect URI from it")
        if env_of(dep, "VIKUNJA_AUTH_OPENID_ENABLED") != "true":
            fail("VIKUNJA_AUTH_OPENID_ENABLED is not true")
        if env_of(dep, "VIKUNJA_AUTH_LOCAL_ENABLED") != "false":
            fail("VIKUNJA_AUTH_LOCAL_ENABLED is not false - a local password door beside SSO is a "
                 "second, unbacked door. It defaults to true.")
        if env_of(dep, "VIKUNJA_SERVICE_ENABLEREGISTRATION") != "false":
            fail("VIKUNJA_SERVICE_ENABLEREGISTRATION is not false - it defaults to true")
        if env_of(dep, PREFIX + "AUTHURL") != ISSUER_URL:
            fail(f"{PREFIX}AUTHURL is not {ISSUER_URL} - it must name the per-provider issuer, which "
                 "is what issuer_mode: per_provider produces")
        if env_of(dep, PREFIX + "SCOPE") != "openid profile email":
            fail(f"{PREFIX}SCOPE must be 'openid profile email'. Adding `groups` switches on team "
                 "sync (spec D20); dropping `email` makes every login fail.")
        dead = sorted(DEAD_KEYS & all_env_names(dep))
        if dead:
            fail(f"{dead} is not a Vikunja config key - it reads as configured and does nothing. "
                 "The Postgres port belongs inside VIKUNJA_DATABASE_HOST (pkg/db/db.go "
                 "parsePostgreSQLHostPort).")
        unknown = sorted(k for k in all_env_names(dep)
                         if k.startswith("VIKUNJA_") and k not in KNOWN_KEYS)
        if unknown:
            fail(f"VIKUNJA_* env vars that are not in this gate's known-key list: {unknown}. Either "
                 "the key is real and the list is stale, or it is a dead variable. Check which before "
                 "editing the list.")

        # --- database ---
        if env_of(dep, "VIKUNJA_DATABASE_TYPE") != "postgres":
            fail("VIKUNJA_DATABASE_TYPE is not postgres - Vikunja would use sqlite on the PVC, which "
                 "is a different backup path from the Database in `databases`")
        if env_of(dep, "VIKUNJA_DATABASE_HOST") != "postgres-rw.databases.svc.cluster.local:5432":
            fail("VIKUNJA_DATABASE_HOST must be postgres-rw.databases.svc.cluster.local:5432 - the "
                 "port is parsed out of this value, there is no separate port key")
        if env_of(dep, "VIKUNJA_DATABASE_MAXOPENCONNECTIONS") != "10":
            fail("VIKUNJA_DATABASE_MAXOPENCONNECTIONS is not 10 (spec D10). The default of 100 is the "
                 "stall bound, not a reservation; going much lower makes pool exhaustion block "
                 "requests silently.")
        if env_of(dep, "VIKUNJA_DATABASE_MAXIDLECONNECTIONS") != "2":
            fail("VIKUNJA_DATABASE_MAXIDLECONNECTIONS is not 2 (spec D10). The default of 50 is "
                 "backends parked while idle.")

        # --- mail ---
        if env_of(dep, "VIKUNJA_MAILER_ENABLED") != "true":
            fail("VIKUNJA_MAILER_ENABLED is not true. Reminders are already on behind it "
                 "(service.enableemailreminders and defaultsettings.overdue_tasks_reminders_enabled "
                 "both default true), so this is the only switch and the feature is decorative.")
        if env_of(dep, "VIKUNJA_MAILER_HOST") != "mail.techdelivery.es":
            fail("VIKUNJA_MAILER_HOST is not mail.techdelivery.es (spec D12)")
        if env_of(dep, "VIKUNJA_MAILER_PORT") != "465" or env_of(dep, "VIKUNJA_MAILER_FORCESSL") != "true":
            fail("the mailer must use 465 with VIKUNJA_MAILER_FORCESSL=true - that is implicit TLS "
                 "and it refuses a downgrade instead of falling back to plaintext")
        if env_of(dep, "VIKUNJA_SERVICE_TIMEZONE") != "GMT":
            fail("VIKUNJA_SERVICE_TIMEZONE is not GMT. It is already the default; the line is a pin "
                 "that documents intent (spec D13), so deleting it is a silent un-pinning.")

        # --- the Secret, and the two copies of one password ---
        containers = (((dep.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []
        names = [s.get("secretRef", {}).get("name")
                 for s in ((containers[0].get("envFrom") or []) if containers else [])]
        sec_name = None
        for n in names:
            cand = find(docs, "Secret", n, "vikunja")
            if cand is not None:
                for k in (PREFIX + "CLIENTID", "VIKUNJA_DATABASE_PASSWORD", "VIKUNJA_SERVICE_SECRET"):
                    if (cand.get("stringData") or {}).get(k) is not None or (cand.get("data") or {}).get(k) is not None:
                        sec_name = n
        if sec_name is None:
            fail(f"no Secret reachable from vikunja/vikunja by envFrom carries the OIDC client, the "
                 f"DB password and the service secret (envFrom names: {names})")
        else:
            for key, bp_key in ((PREFIX + "CLIENTID", "client_id"),
                                (PREFIX + "CLIENTSECRET", "client_secret")):
                app_val, _ = secret_key(docs, sec_name, "vikunja", key)
                if app_val is None:
                    fail(f"{sec_name} has no {key}")
                elif rprov and app_val != rprov.get(bp_key):
                    fail(f"Vikunja's {key} does not match the blueprint's {bp_key} - the login will "
                         "fail with invalid_client, and the two files are edited apart")
            if secret_key(docs, sec_name, "vikunja", "VIKUNJA_SERVICE_SECRET")[0] in (None, ""):
                fail(f"{sec_name} has no VIKUNJA_SERVICE_SECRET. Without it Vikunja mints a random "
                     "one per boot and every Recreate logs every session out, with no error anywhere.")

            pw, _ = secret_key(docs, sec_name, "vikunja", "VIKUNJA_DATABASE_PASSWORD")
            if pw is None:
                fail(f"{sec_name} has no VIKUNJA_DATABASE_PASSWORD")
            dbsec = find(docs, "Secret", "vikunja-db-credentials", "databases")
            if dbsec is None:
                fail("no Secret vikunja-db-credentials in namespace databases - CNPG's DatabaseRole "
                     "has no credential to install")
            elif pw is not None:
                cnpg_pw, _ = secret_key(docs, "vikunja-db-credentials", "databases", "password")
                cnpg_user, _ = secret_key(docs, "vikunja-db-credentials", "databases", "username")
                if cnpg_pw is None:
                    fail("vikunja-db-credentials has no password key")
                elif cnpg_pw != pw:
                    fail("vikunja-secrets VIKUNJA_DATABASE_PASSWORD and vikunja-db-credentials "
                         "password differ - Vikunja gets password authentication failed and the "
                         "Database still reports Ready. Re-run scripts/setup-vikunja-secrets.sh with "
                         "FORCE=1 and rotate both.")
                if cnpg_user is None:
                    fail("vikunja-db-credentials has no username key - CNPG's basic-auth Secret needs "
                         "one and it must equal the role name")
                elif cnpg_user != env_of(dep, "VIKUNJA_DATABASE_USER"):
                    fail(f"vikunja-db-credentials username {cnpg_user!r} is not the Deployment's "
                         f"VIKUNJA_DATABASE_USER {env_of(dep, 'VIKUNJA_DATABASE_USER')!r}")

            # The mail half: SPOOF_PROTECTION=1 makes this structural, not cosmetic.
            from_email = env_of(dep, "VIKUNJA_MAILER_FROMEMAIL")
            user, _ = secret_key(docs, sec_name, "vikunja", "VIKUNJA_MAILER_USERNAME")
            if user is None:
                fail(f"{sec_name} has no VIKUNJA_MAILER_USERNAME")
            elif from_email != user:
                fail(f"VIKUNJA_MAILER_FROMEMAIL is {from_email!r} but the mailbox is {user!r}. The "
                     "relay runs SPOOF_PROTECTION=1, so an authenticated user may only send as its own "
                     "address - this is refused at MAIL FROM while the pod reports healthy.")
            if secret_key(docs, sec_name, "vikunja", "VIKUNJA_MAILER_PASSWORD")[0] in (None, ""):
                fail(f"{sec_name} has no VIKUNJA_MAILER_PASSWORD")

    ing = find(docs, "Ingress", "vikunja", "vikunja")
    if ing is None:
        fail("no Ingress vikunja/vikunja")
    else:
        # Why the Ingress gets its own structural check and the Deployment does not: a mis-nested
        # Ingress key is a CORE-type violation, and no offline gate here can see core types.
        # crd-check walks vendored CRDs only, namespace-check walks namespaces only, and
        # `make dry-run` — the one gate that asks the API server — needs an admin context this
        # identity does not have. mealie/mealie.yaml records the same trap biting on 2026-10-22.
        leaked = sorted(k for k in ("rules", "tls", "ingressClassName", "defaultBackend")
                        if k in (ing.get("metadata") or {}))
        if leaked:
            fail(f"Ingress vikunja/vikunja carries {leaked} under metadata instead of spec - the API "
                 "server rejects it and no offline gate but make dry-run will tell you")
        spec = ing.get("spec") or {}
        hosts = [r.get("host") for r in (spec.get("rules") or [])]
        if hosts != [HOST]:
            fail(f"Ingress vikunja/vikunja serves {hosts}, expected ['{HOST}'] - PUBLICURL, the "
                 "blueprint redirect URI and the wildcard certificate all key off this host")
        if not spec.get("tls"):
            fail("Ingress vikunja/vikunja has no tls block - titan-tls has to terminate TLS for this host")

    db = find(docs, "Database", "vikunja", "databases")
    if db is None:
        fail("no Database vikunja in namespace databases")
    elif dep is not None and (db.get("spec") or {}).get("name") != env_of(dep, "VIKUNJA_DATABASE_DATABASE"):
        fail(f"Database vikunja creates {db['spec'].get('name')!r} but the Deployment connects to "
             f"{env_of(dep, 'VIKUNJA_DATABASE_DATABASE')!r}")
    role = find(docs, "DatabaseRole", "vikunja", "databases")
    if role is None:
        fail("no DatabaseRole vikunja in namespace databases")
    else:
        if not (role.get("spec") or {}).get("login"):
            fail("DatabaseRole vikunja is not login: true - CNPG creates roles NOLOGIN by default, "
                 "the Database reports Ready and every connection fails pointing somewhere else")
        if ((role.get("spec") or {}).get("passwordSecret") or {}).get("name") != "vikunja-db-credentials":
            fail("DatabaseRole vikunja does not point at vikunja-db-credentials")

    if failures:
        print(f"vikunja-check: {len(failures)} problem(s)")
        return 1
    print("vikunja-check: blueprint, mount, app config, OIDC client, DB credential and mail FROM all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Wire it into the Makefile**

Add `vikunja-check` to the `.PHONY` list on line 16 (after `mealie-check sure-check`) and to the `check:` prerequisite list on line 21 (after `sure-check`). Then add the target after the `sure-check` target:

```makefile
# vikunja-check: Vikunja's OIDC client lives in the reviewed template, the rendered blueprint and the
# app's own Secret, and the mount is a fourth place nothing else reads. It also compares the database
# password across two namespaces, which no existing gate does: `db-url-check` is reference-driven on
# DATABASE_URL / *PG_CONNECTION_URL and Vikunja takes split VIKUNJA_DATABASE_* keys, so the generic
# gate reports zero references and passes vacuously on this app. And it is the only place that knows
# the mail FROM must equal the mailbox, because SPOOF_PROTECTION on the relay makes that structural.
# Reads sops-encrypted values, so it is in `check` and not `check-ci` — same rule as `validate`.
vikunja-check:
	@python3 tools/vikunja-check.py --root apply
```

- [ ] **Step 3: Run it and confirm it fails for the right reason**

Run: `make vikunja-check`
Expected: exit 1, with `FAIL: no Deployment vikunja/vikunja` and `FAIL: no Ingress vikunja/vikunja` among the output. If it passes here, the gate is vacuous and must be fixed before going on — a gate that passes with the app missing is worse than no gate.

- [ ] **Step 4: Commit**

```bash
git add tools/vikunja-check.py Makefile
git commit -m "feat(vikunja): vikunja-check gate, failing until the app exists"
```

---

## Task 5: The app

**Files:**
- Create: `apply/50-apps/vikunja/vikunja.yaml`
- Create: `apply/00-bootstrap/namespaces.yaml` entry for `vikunja`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: Secret `vikunja-secrets` (Task 3), the `vikunja` role and database (Task 1), `titan-tls` reflected into `vikunja` (Task 6).
- Produces: Deployment/Service `vikunja` in ns `vikunja` on container port `http` (3456), Ingress on `tasks.titan.arrieta.eu`, PVC `vikunja-data`. Task 6's TLS and proxy-gate wiring and Task 8's live checks read these objects.

- [ ] **Step 1: Declare the namespace**

Append to `apply/00-bootstrap/namespaces.yaml`, following the mealie block's shape exactly:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: vikunja
  labels:
    name: vikunja
  annotations:
    kubernetes.io/metadata.name: vikunja
    kubernetes.io/description: "Vikunja task manager, authenticated by authentik, data in the shared CNPG cluster"
```

- [ ] **Step 2: Write the app manifest**

Create `apply/50-apps/vikunja/vikunja.yaml`:

```yaml
# Vikunja on titan: fresh instance, data in the shared CNPG cluster, sign-in through authentik,
# reminders by mail through the existing relay.
# Design and evidence: docs/superpowers/specs/2026-11-16-titan-vikunja-design.md.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vikunja-data
  namespace: vikunja
  annotations:
    # Opted in to restic PV backup. This annotation IS the scope decision -- apply/70-backup/
    # discovers annotated PVCs at runtime rather than enumerating them in git. Unlike the Grafana
    # volumes, this one holds user-created bytes (attachments and avatars) that exist nowhere else,
    # so the opt-in is not optional. What a restore returns is spec §4: the attachment ROWS are in
    # Postgres and the BYTES are here, on two schedules with no shared point in time.
    backup.titan.arrieta.eu/class: daily
spec:
  accessModes:
  - ReadWriteOnce
  # local-path-retain, not the default local-path: Retain is the only deletion mitigation this cluster
  # has for a PVC. It is a deletion mitigation and NOT a backup.
  storageClassName: local-path-retain
  resources:
    requests:
      # 5Gi, thin-provisioned — local-path reserves a directory, not disk. Vikunja's own footprint is
      # the attachment store, and files.maxsize defaults to 20MB per file.
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vikunja
  namespace: vikunja
  # Meaningless without the namespace also being in reloader.namespaces in
  # apply/20-infra/reloader/reloader.yaml — watchGlobally is false, so Reloader does not look here at
  # all. Both halves are in this change for exactly that reason: Vikunja takes its service secret, DB
  # password, OIDC client and SMTP credential through envFrom, so a rotation would otherwise sit
  # unread in a running pod.
  annotations:
    reloader.stakater.com/auto: "true"
spec:
  replicas: 1
  # RWO PVC: a RollingUpdate schedules pod 2 while pod 1 still holds the volume and the new pod sits
  # Pending on a volume conflict forever. Recreate also means only one pod ever runs migrations.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: vikunja
  template:
    metadata:
      labels:
        app: vikunja
    spec:
      securityContext:
        # uid 1000 is the user the image is built with (upstream: "runs as user 1000 and no group",
        # i.e. gid 0). Running the group as 1000 rather than 0 is a deliberate narrowing; fsGroup is
        # what makes the mounted PVC writable by it. grafana is the live proof fsGroup is honoured
        # against local-path-retain on this cluster and mealie the proof for a non-root uid, but this
        # exact combination is first-boot-verified (spec §9.6).
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: vikunja
        # Pinned to a specific release, never :latest (the fleet rule). 2.8.0 is current; it is also
        # the release the `groups` claim team sync and the tk_-token CalDAV auth both landed by.
        image: docker.io/vikunja/vikunja:2.8.0
        ports:
        - name: http
          containerPort: 3456
        envFrom:
        # Every key here is named exactly as Vikunja reads it, so there is no aliasing between the
        # Secret and the Deployment and no typo'd mapping to find during an incident.
        - secretRef:
            name: vikunja-secrets
        env:
        # --- the one URL everything else is derived from ---------------------------------------
        # PUBLICURL is what Vikunja puts in generated links AND what it builds its OIDC redirect URI
        # from. Change the host here and the URI stops matching the strict entry in
        # authentik/blueprints-vikunja.yaml, which reads as an authentik error rather than a Vikunja
        # one. `make vikunja-check` ties the two together.
        - name: VIKUNJA_SERVICE_PUBLICURL
          value: https://tasks.titan.arrieta.eu/
        # THE LINE THAT KEEPS EVERYONE LOGGED IN. Unset, generateServiceSecretIfEmpty() in
        # pkg/config/config.go mints a random secret per boot and every already-issued token dies
        # with the process — with strategy: Recreate above, that is every deploy logging every
        # session out, with no error anywhere. service.JWTSecret is the deprecated alias; do not
        # "simplify" it back.
        - name: VIKUNJA_SERVICE_TIMEZONE
          # GMT is already the default (ServiceTimeZone.setDefault("GMT")). This line is a PIN that
          # documents intent and survives a future default change; it moves no behaviour by itself.
          # Spec D13, and §9.4 for what is still unverified about reminder timing.
          value: GMT
        # --- client IP, so the session list and the logs mean something -------------------------
        # Default is `direct`, which reads the TCP peer: behind Traefik that is the Traefik pod, so
        # every log line and every entry in a user's session list says the proxy instead of the
        # client. 10.62.0.0/16 is the measured pod CIDR (2026-11-16).
        #
        # THE HONEST LIMIT: trusting the pod CIDR means any pod in the cluster can forge
        # X-Forwarded-For. Acceptable today only because ratelimit.enabled and audit.enabled are both
        # off, so the sole consumer of client address is attribution. If either is switched on this
        # line stops being cosmetic and the forgeability becomes the finding. Spec D9.
        - name: VIKUNJA_SERVICE_IPEXTRACTIONMETHOD
          value: xff
        - name: VIKUNJA_SERVICE_TRUSTEDPROXIES
          value: 10.62.0.0/16
        # Already the default. The Sentry DSN is compiled into the binary, so this is a pin against a
        # future default flip, not a fix for anything (spec D19).
        - name: VIKUNJA_SENTRY_ENABLED
          value: "false"
        # --- single sign-on: authentik decides who you are; there is no local password door ------
        # The Vikunja equivalent of mealie's ALLOW_PASSWORD_LOGIN=false and open-webui's
        # ENABLE_LOGIN_FORM=false: a local password form next to SSO is a second, unbacked door.
        # auth.local.enabled defaults to true, so this line is load-bearing, not tidy-up.
        - name: VIKUNJA_AUTH_LOCAL_ENABLED
          value: "false"
        - name: VIKUNJA_SERVICE_ENABLEREGISTRATION
          value: "false"
        - name: VIKUNJA_AUTH_OPENID_ENABLED
          value: "true"
        # The provider key is `authentik`. setConfigFromEnv() splits the env var on "_" and
        # lowercases every segment, so AUTHENTIK here becomes the provider id `authentik`, which is
        # also the last segment of the redirect URI registered in the blueprint. One fact, two files,
        # and vikunja-check compares them.
        - name: VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_NAME
          value: authentik
        - name: VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_AUTHURL
          value: https://auth.titan.arrieta.eu/application/o/vikunja/
        # openid + email + profile, and NOT `groups`. email is required — mergeClaims() returns
        # ErrNoOpenIDEmailProvided without it — and profile is what carries preferred_username,
        # without which Vikunja mints a pet-name username and the login still succeeds.
        # Adding `groups` switches on team sync from 2.8.0 (spec D20).
        - name: VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_SCOPE
          value: openid profile email
        # RP-Initiated Logout, so logging out of Vikunja does not leave the authentik session standing.
        - name: VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_LOGOUTURL
          value: https://auth.titan.arrieta.eu/application/o/vikunja/end-session/
        # NO email_verified opt-out, deliberately, unlike coder and mealie. Read at 2.8.0,
        # pkg/modules/auth/openid/openid.go keys identity on (issuer, sub) and consults
        # email_verified only in the deprecated emailfallback path that auth.local.enabled=false
        # makes unreachable. authentik's managed email mapping returns "email_verified": False and
        # Vikunja ignores it here. Spec D6 has the evidence; do not "fix" this by copying mealie's
        # OIDC_REQUIRES_EMAIL_VERIFICATION=false, which would be a dead variable here.
        # --- database: the shared CNPG cluster, not a database of its own -----------------------
        - name: VIKUNJA_DATABASE_TYPE
          value: postgres
        # THE PORT IS PART OF THIS VALUE. There is no database.port config key — pkg/db/db.go's
        # parsePostgreSQLHostPort splits host:port out of database.host. A VIKUNJA_DATABASE_PORT would
        # read as configured and do nothing; vikunja-check fails if one appears.
        - name: VIKUNJA_DATABASE_HOST
          value: postgres-rw.databases.svc.cluster.local:5432
        - name: VIKUNJA_DATABASE_DATABASE
          value: vikunja
        - name: VIKUNJA_DATABASE_USER
          value: vikunja
        # sslmode is left at its default `disable`, matching mealie, open-webui and Sure on the same
        # postgres-rw path; the connection never leaves the node. Not a regression to "fix".
        # 10 open / 2 idle, against defaults of 100 / 50. Idle is the steady-state footprint; open is
        # the bound on how many backends one Vikunja can pile onto the shared cluster if Postgres
        # stalls. Not lower: an exhausted pool BLOCKS requests rather than erroring, so one slow
        # query would queue everything behind it and read as a hang with nothing in the log. Spec D10.
        - name: VIKUNJA_DATABASE_MAXOPENCONNECTIONS
          value: "10"
        - name: VIKUNJA_DATABASE_MAXIDLECONNECTIONS
          value: "2"
        # --- attachments and avatars ------------------------------------------------------------
        # The default is relative to service.rootpath, which is the WORKDIR. Made absolute because
        # that is what the PVC mounts, so there is no chance of the two disagreeing.
        - name: VIKUNJA_FILES_BASEPATH
          value: /app/vikunja/files
        # --- outbound mail ----------------------------------------------------------------------
        # Reminders are already switched on behind this (service.enableemailreminders and
        # defaultsettings.overdue_tasks_reminders_enabled both default true), so the mailer is the
        # only switch and leaving it off makes the feature decorative rather than absent.
        - name: VIKUNJA_MAILER_ENABLED
          value: "true"
        - name: VIKUNJA_MAILER_HOST
          value: mail.techdelivery.es
        # 465 with implicit TLS: it refuses a downgrade instead of falling back to plaintext, and it is
        # the port with a recorded end-to-end authenticated submission on this box.
        - name: VIKUNJA_MAILER_PORT
          value: "465"
        - name: VIKUNJA_MAILER_FORCESSL
          value: "true"
        # MUST equal VIKUNJA_MAILER_USERNAME. The relay runs SPOOF_PROTECTION=1, which restricts an
        # authenticated user to its own address and aliases; a FROM that does not match is refused at
        # MAIL FROM while the pod reports healthy. techdelivery.es is also the one domain of the six
        # this box signs where DMARC passes on SPF as well as DKIM, because SRS rewrites the envelope
        # to that domain. Spec §6.
        - name: VIKUNJA_MAILER_FROMEMAIL
          value: tasks@techdelivery.es
        # --- probes -----------------------------------------------------------------------------
        # /health is registered at pkg/routes/routes.go:252 and is public unless health.username /
        # health.password are set, which they are not. Budgeted as a startupProbe because migrations
        # run against Postgres at boot and are unbounded on a slow node.
        startupProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 10
          failureThreshold: 30
        livenessProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 10
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: "1"
            memory: 512Mi
        volumeMounts:
        - name: data
          mountPath: /app/vikunja/files
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: vikunja-data
---
apiVersion: v1
kind: Service
metadata:
  name: vikunja
  namespace: vikunja
spec:
  type: ClusterIP
  selector:
    app: vikunja
  ports:
  - name: http
    port: 80
    targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vikunja
  namespace: vikunja
  # No forward-auth middleware on this host: Vikunja decides who may in, through its own OIDC client.
  # That is a real difference from a proxy-outposted app rather than an omission — Vikunja holds the
  # client secret and needs the Authorization Code exchange to complete inside its own process, and
  # putting a proxy provider in front would mean editing the Tesla-owned outpost blueprint that OWNS
  # that provider list. The host is reachable from the public internet either way, exactly like coder,
  # auth, open-webui and meals. Recorded in tools/ingress-auth-check.py's NOT_PROXY_GATED.
  #
  # Note the CalDAV path is on this host too and authenticates with HTTP Basic using a `tk_` API
  # token carrying the caldav permission — these users have no password, so that is the only route.
spec:
  ingressClassName: traefik
  rules:
  - host: tasks.titan.arrieta.eu
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vikunja
            port:
              number: 80
  tls:
  - hosts:
    - tasks.titan.arrieta.eu
    # Reflected from `certificates` by the wildcard. Reaching THIS namespace required adding `vikunja`
    # to BOTH reflector annotations on apply/40-certificates/titan-wildcard.yaml; with only one of the
    # two edited, the Certificate stays Ready and the Secret never appears.
    secretName: titan-tls
```

- [ ] **Step 3: List it**

Append to `resources:` in `apply/50-apps/kustomization.yaml`, after the `vikunja/vikunja-db.yaml` line:

```yaml
  # The app itself: PVC + Deployment + Service + Ingress in namespace `vikunja`. It reads
  # vikunja-secrets (envFrom) and titan-tls (reflected in), and connects as the role above. A pod that
  # starts before its Secret exists sits crash-looping, which reads like an app bug rather than a
  # missing file — the ordering note at the top of this file applies.
  - vikunja/vikunja.yaml
```

- [ ] **Step 4: Verify the gate now passes and the offline gates agree**

Run: `make vikunja-check`
Expected: `vikunja-check: blueprint, mount, app config, OIDC client, DB credential and mail FROM all agree` — **unless** Task 6 has not run, in which case the only remaining failure must be the HelmRelease mount line. If anything else fails, fix it before continuing.

Run: `make kustomize-check && make kustomize-listing && make secret-refs && make crd-check`
Expected: all pass. `secret-refs` is the one that proves `vikunja-secrets` actually exists in namespace `vikunja`.

- [ ] **Step 5: Commit**

```bash
git add apply/50-apps/vikunja/vikunja.yaml apply/00-bootstrap/namespaces.yaml apply/50-apps/kustomization.yaml
git commit -m "feat(vikunja): the app — PVC, Deployment, Service and Ingress"
```

---

## Task 6: TLS reflection, the proxy-gate row, and the reloader wiring

**Files:**
- Modify: `apply/40-certificates/titan-wildcard.yaml` (both `secretTemplate` annotations)
- Modify: `AGENTS.md` (the prose copy of the same allow-list)
- Modify: `tools/ingress-auth-check.py` (`NOT_PROXY_GATED`)
- Modify: `apply/20-infra/reloader/reloader.yaml` (`namespaces`)
- Modify: `apply/50-apps/auth/authentik.yaml` (the `blueprints.secrets` list and the worker's `secret.reloader.stakater.com/reload`)

**Interfaces:**
- Consumes: the `vikunja` namespace and Ingress from Task 5, the blueprint Secret from Task 3.
- Produces: `titan-tls` mirrored into `vikunja`; a passing `tls-reflection-check`, `ingress-auth`, `blueprint-mount-check` and `namespace-check`.

- [ ] **Step 1: Add the namespace to both Reflector annotations**

In `apply/40-certificates/titan-wildcard.yaml`, append `,vikunja` to **both** lines:

```yaml
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps,auth,open-webui,observability,files,mealie,llm,sure,gatus,vikunja"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "apps,auth,open-webui,observability,files,mealie,llm,sure,gatus,vikunja"
```

Extend the comment above them with one line, in the existing style: `vikunja` added 2026-11-16 for `tasks.titan.arrieta.eu`.

- [ ] **Step 2: Update the prose copy in AGENTS.md**

In `AGENTS.md`, the sentence beginning `Nothing else receives it — the allow-list is the secretTemplate annotations on ...` lists the namespaces inline. Add `vikunja` to that inline list. **This is not tidiness**: `make tls-reflection-check` fails when the file's prose copy drifts from the annotation it quotes.

- [ ] **Step 3: Add the proxy-gate row**

In `tools/ingress-auth-check.py`, add to `NOT_PROXY_GATED` alongside the mealie entry:

```python
    ("vikunja", "vikunja"): "Vikunja is OIDC-only with VIKUNJA_AUTH_LOCAL_ENABLED=false and "
                            "VIKUNJA_SERVICE_ENABLEREGISTRATION=false "
                            "(apply/50-apps/vikunja/vikunja.yaml). WHO may sign in is a policy "
                            "binding to titan-family on the vikunja Application "
                            "(authentik/blueprints-vikunja.yaml); this repo cannot see that binding "
                            "applied. A forwardAuth here would add a second IdP round trip per "
                            "session and put the outpost cookie's refresh behaviour (issue #243) in "
                            "the path of a host that does not need it.",
```

- [ ] **Step 4: Teach Reloader about the namespace**

In `apply/20-infra/reloader/reloader.yaml`, append `- vikunja` to the `namespaces:` list, with a comment in the style of the mealie entry: Vikunja carries `reloader.stakater.com/auto: "true"` and reads its whole config through `envFrom`, so a rotated service secret, DB password or SMTP credential would otherwise sit unread in a running pod.

- [ ] **Step 5: Mount the blueprint and add it to the worker's reload annotation**

In `apply/50-apps/auth/authentik.yaml`:

Append to the `blueprints.secrets` list (around line 74, after `authentik-portfolio-prism-blueprint`):

```yaml
        # Vikunja's OIDC client. A Secret for the same reason as the others above: it carries the
        # client_secret. Rendered from authentik/blueprints-vikunja.yaml by
        # scripts/setup-vikunja-secrets.sh.
        - authentik-vikunja-blueprint
```

Append `,authentik-vikunja-blueprint` to the **worker's** `secret.reloader.stakater.com/reload` value (line ~199). Not the server's (line ~175) — the server does not apply blueprints, and restarting it for a blueprint edit would be an auth outage for no behaviour.

- [ ] **Step 6: Verify the four gates that own these rules**

Run: `make tls-reflection-check && make ingress-auth && make blueprint-mount-check && make namespace-check && make vikunja-check`
Expected: all pass. `tls-reflection-check` is the one that catches a half-edited allow-list or a stale AGENTS.md sentence; `blueprint-mount-check` catches the mount without the reloader annotation, which is the "my edit landed an hour late" failure.

- [ ] **Step 7: Commit**

```bash
git add apply/40-certificates/titan-wildcard.yaml AGENTS.md tools/ingress-auth-check.py \
        apply/20-infra/reloader/reloader.yaml apply/50-apps/auth/authentik.yaml
git commit -m "feat(vikunja): reflect titan-tls, declare the proxy-gate decision, wire reloader and the mount"
```

---

## Task 7: Prove the gate actually fires

A gate that has only ever been seen passing is a gate nobody has tested. Each check below breaks one input, runs the gate, confirms the **named** failure, and restores. Nothing is committed in this task.

**Files:** none (all changes reverted)

**Interfaces:**
- Consumes: `make vikunja-check` from Task 4, the manifests from Tasks 1-6.
- Produces: evidence that each Review Focus line has a working pin.

- [ ] **Step 1: Split the DB password across the two namespaces**

Edit `apply/10-secrets/vikunja-db-credentials.yaml` with sops (not by hand — it is encrypted):

```bash
# printf-piped rather than a bash herestring, so this works in fish too.
printf '"deliberately-wrong"' | sops set apply/10-secrets/vikunja-db-credentials.yaml '["stringData"]["password"]' --value-stdin
make vikunja-check; git checkout apply/10-secrets/vikunja-db-credentials.yaml
```

Expected: `FAIL: vikunja-secrets VIKUNJA_DATABASE_PASSWORD and vikunja-db-credentials password differ`, and the gate returns to green after the checkout.

- [ ] **Step 2: Remove the mount**

Delete the `- authentik-vikunja-blueprint` line from `blueprints.secrets` in `apply/50-apps/auth/authentik.yaml`, run `make vikunja-check`, expect `FAIL: the HelmRelease does not mount authentik-vikunja-blueprint`, then restore.

- [ ] **Step 3: Drop the service secret**

Remove the `VIKUNJA_SERVICE_SECRET` key from `vikunja-secrets` (sops edit), run the gate, expect the `VIKUNJA_SERVICE_SECRET` failure naming the per-boot regeneration, then restore.

- [ ] **Step 4: Split the mail FROM from the mailbox**

Change `VIKUNJA_MAILER_FROMEMAIL` in the Deployment to any other address, run the gate, expect the `SPOOF_PROTECTION` failure, then restore.

- [ ] **Step 5: Add the dead variable**

Add `- name: VIKUNJA_DATABASE_PORT` with `value: "5432"` to the Deployment env, run the gate, expect the dead-key failure naming `parsePostgreSQLHostPort`, then restore.

- [ ] **Step 6: Confirm the tree is clean and the gate is green**

Run: `git status --porcelain && make vikunja-check`
Expected: no modified files, and the green one-liner.

---

## Task 8: Full gate, apply, and live verification

**Files:** none new

**Interfaces:**
- Consumes: everything above.
- Produces: a running Vikunja, and an honest record of which spec §9 items were closed.

- [ ] **Step 1: Run the full local gate set**

Run: `git add -A && make check`
Expected: every gate green. `make check` includes `validate`, which needs the age private key and is deliberately not in CI — so this step is operator-machine work, not agent work. If `chart-values-check` is slow it is fetching pinned charts over the network; that is expected.

- [ ] **Step 2: Prove the mail path once, from titan, before the app needs it**

Because `ENABLE_FAIL2BAN=1` on the relay, this is **one** attempt, not a loop. From titan:

```sh
# fish-safe: no heredoc, no VAR=value prefix
nix-shell -p swaks --run 'swaks --to javier@arrieta.eu --server mail.techdelivery.es:465 --tls --auth-user tasks@techdelivery.es --auth-password (cat /tmp/vijunya-mail.txt | sed -n 2p) --from tasks@techdelivery.es'
```

Expected: `250` at `MAIL FROM` and at `RCPT TO`. If it is refused at `MAIL FROM`, the mailbox and the FROM do not match (spec §6). If it is refused at `AUTH`, stop and fix the credential — do not retry.

- [ ] **Step 3: Push and open the PR**

Pushing a branch, opening a PR, and merging each need explicit operator confirmation, per the repo's own rules. Show `git log --oneline origin/main..HEAD` first.

- [ ] **Step 4: After merge, apply in dependency order and watch**

```sh
timeout 60 kubectl -n databases get databaseroles vikunja -o jsonpath='{.status.applied}{"\n"}'
```

Expected: `True`. Read `status.applied`, **not** `status.message` — AGENTS.md records that `message` is history, not state, and that a `DatabaseRole` carried a stale `forbidden` message for 28 days while healthy.

Then confirm the reflected certificate actually landed (the offline gate proves permission, never delivery):

```sh
timeout 30 kubectl -n vikunja get secret titan-tls
```

Expected: the Secret exists. If it does not, Reflector has not mirrored it yet — check the two annotations from Task 6, not the Ingress.

Then the pod:

```sh
timeout 60 kubectl -n vikunja rollout status deploy/vikunja --timeout=180s
timeout 30 kubectl -n vikunja get pod -l app=vikunja -o wide
```

Expected: `deployment "vikunja" successfully rolled out`. If it crash-loops, read the container log for a config-parse error before assuming the app is broken — a dead `VIKUNJA_*` key or a wrong DB host shows up here.

- [ ] **Step 5: Force the blueprint rather than waiting for discovery**

Mounting is not applying, and the startup pass can skip a newly added file (`docs/authentik-runbook.md` §5).

```sh
timeout 60 kubectl -n auth exec deploy/authentik-worker -- ak apply_blueprint titan-vikunja
```

Expected: it reports applying the blueprint. Then confirm the provider exists with the right redirect URI in authentik's own view, not git's.

- [ ] **Step 6: First login, and check the username**

Open `https://tasks.titan.arrieta.eu/`, sign in through authentik, and **read the resulting username**. If it is a pet-name rather than a real one, the `profile` scope mapping is not delivering `preferred_username` (spec §9.3) — that is a blueprint fix, not a Vikunja one, and it will not have produced any error.

- [ ] **Step 7: Prove a reminder actually arrives**

Create a task with a reminder one minute out, or use the daily-overdue path, and confirm the message lands. Then read its `Authentication-Results` header: `dkim=pass header.s=mail` is the proof the relay signed it, which is the mailserver runbook's own lesson that signing can only be proven by sending.

Record which of spec §9's ten items this closed, and update §9 in a follow-up commit rather than leaving it aspirationally stale.

- [ ] **Step 8: Update the spec's §9 with what was proven**

```bash
git add docs/superpowers/specs/2026-11-16-titan-vikunja-design.md
git commit -m "docs(vikunja): record which unproven items the rollout closed"
```
