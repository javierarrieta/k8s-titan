# Open WebUI on titan — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a fresh Open WebUI instance on titan at `open-webui.titan.arrieta.eu`, authenticating against authentik over OIDC with roles mapped from authentik groups, with its canonical data inside the shared CNPG Postgres cluster.

**Architecture:** One hand-written `Deployment` in a new `open-webui` namespace, inside the existing shared `apps` Flux stage. Its database is a CNPG `Database`/`DatabaseRole` pair in the `databases` namespace of the existing cluster; its OIDC client is declared in an authentik blueprint that is rendered by a script into two sops Secrets and mounted by the authentik `HelmRelease`. Two agreement gates keep the duplicated credentials from drifting.

**Tech Stack:** Kubernetes (k3s v1.35), Flux kustomize-controller, CloudNativePG, cert-manager + Reflector, authentik 2026.8 (blueprints, no CRDs), sops/age, Python 3 for the gates, GNU make.

**Spec:** `docs/superpowers/specs/2026-10-20-titan-open-webui-design.md` — every decision below is argued there; this plan is the order of operations and the content.

## Global Constraints

- Image pin: `ghcr.io/open-webui/open-webui:v0.12.3` (spec §2 — also the current upstream latest).
- Hostname: `open-webui.titan.arrieta.eu`. Authentik issuer base: `https://auth.titan.arrieta.eu/application/o/open-webui/`.
- Kubernetes object names use the hyphen (`open-webui`); **Postgres identifiers use the underscore** (`open_webui` for both the database and the role). Never mix them.
- Namespace `open-webui` carries **no** Pod Security label (spec §4 — the image is uid 0).
- Every Secret lives under `apply/10-secrets/`, sops-encrypted, and is listed in `apply/10-secrets/kustomization.yaml`. A plaintext Secret manifest anywhere else fails `make secrets-placement`.
- Never set a top-level `namespace:` in any `kustomization.yaml`.
- `open-webui` is **not** a Flux stage: no numbered directory, no `stage-*.yaml` (spec D6).
- Before every commit: `git add -A && make check`. Never push or open a PR without explicit operator confirmation per change.
- `make dry-run` needs an admin context that does not exist on this box; when it skips, say so rather than reporting the change as fully verified.

## Review Focus

The five ways this change breaks quietly. Each line gets its test in the task named.

1. **A redirect URI authentik will not accept.** Open WebUI derives its own callback path and registers it under the key `oidc`, not the display name; a mismatch is a `redirect_uri mismatch` that reads like a broken client secret. → Task 3 (template pins both candidate paths, strict) and Task 8 (the gate refuses anything else).
2. **The `groups` claim is absent, so role management denies instead of downgrading.** `profile` is the only reason the claim exists, and with `ENABLE_OAUTH_ROLE_MANAGEMENT=true` an unmatched or missing claim is a 403, not a fallback role. → Task 5 (env pins the scopes) and Task 8 (the gate fails if `profile` is missing on either side).
3. **The blueprint is applied but never mounted**, which is indistinguishable from a blueprint that was never written. → Task 6 (the mount) and Task 8 (the gate reads the `HelmRelease` list).
4. **The reloader annotation is inert** because `reloader.namespaces` does not include `open-webui`, so a rotated Secret never rolls the pod. → Task 1 (the list) and Task 5 (the annotation), verified by the live check in Task 10.
5. **The DB password is committed twice and drifts**, or the gate that should catch it reports zero references and passes vacuously because its finder only walks `HelmRelease` env. → Task 4 (one script mints both halves) and Task 7 (the finder is widened, with a fixture that proves it fires).

---

### Task 1: Namespace and the two cluster-wide allow-lists

**Files:**
- Modify: `apply/00-bootstrap/namespaces.yaml` (append a `Namespace` document)
- Modify: `apply/40-certificates/titan-wildcard.yaml` (`secretTemplate.annotations`, both reflector lists)
- Modify: `apply/20-infra/reloader/reloader.yaml` (`spec.values.reloader.namespaces`)

**Interfaces:**
- Consumes: nothing.
- Produces: namespace `open-webui` existing before anything lands in it; `titan-tls` reflected into it; Reloader watching it. Tasks 2 and 5 create objects that assume all three.

- [ ] **Step 1: Append the namespace**

Append to `apply/00-bootstrap/namespaces.yaml`:

```yaml
---
# Open WebUI. Its own namespace because it fails the admission test in
# docs/superpowers/specs/2026-10-19-titan-app-scale-out-design.md §3.1 on three axes — own Secret
# set, own database, own public hostname — and coder is the precedent for what that means here:
# own namespace, shared `apps` stage (spec D6 of the open-webui spec).
#
# NO pod-security label, deliberately. coder and monitoring carry
# `pod-security.kubernetes.io/warn: restricted`; open-webui cannot satisfy it — the image's own
# Dockerfile is `ARG UID=0`, so the container runs as root. A warn-only label on a workload that
# can never meet it is a signal that reads better than it is. If a non-root build is ever wanted,
# the label goes on in that change, not this one.
apiVersion: v1
kind: Namespace
metadata:
  name: open-webui
  labels:
    name: open-webui
  annotations:
    kubernetes.io/description: "Open WebUI - OIDC sign-in through authentik, data in the shared CNPG cluster"
```

- [ ] **Step 2: Widen both reflector lists**

In `apply/40-certificates/titan-wildcard.yaml`, change the two annotation values from `"apps,auth"` to `"apps,auth,open-webui"`. **Both**, not one: `reflection-allowed-namespaces` is the permission and `reflection-auto-namespaces` is the act of pushing, and editing only the first produces a Secret that never appears while the `Certificate` stays `Ready`.

```yaml
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps,auth,open-webui"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "apps,auth,open-webui"
```

- [ ] **Step 3: Add the namespace to Reloader's watch list**

In `apply/20-infra/reloader/reloader.yaml`, under `spec.values.reloader.namespaces`, append after `- monitoring`:

```yaml
        # open-webui carries `reloader.stakater.com/auto: "true"` and reads its whole config
        # through envFrom, so a rotated WEBUI_SECRET_KEY or OIDC client would otherwise sit
        # unread in a running pod — the same inert-annotation defect the monitoring entry above
        # records for promtail. `watchGlobally: false` means this list is the whole scope.
        - open-webui
```

- [ ] **Step 4: Verify the three edits built and are listed**

```bash
cd /home/coder/k8s-titan
kubectl kustomize apply/00-bootstrap >/dev/null && kubectl kustomize apply/20-infra >/dev/null && echo BUILD-OK
make kustomize-listing kustomize-check crd-check
grep -c 'open-webui' apply/40-certificates/titan-wildcard.yaml
```

Expected: `BUILD-OK`, all three gates green, and `2` from the grep (one per annotation — a `1` means half the change).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "open-webui: namespace, the reflector allow-list, and Reloader's watch list"
```

---

### Task 2: The CNPG `Database` and `DatabaseRole`

**Files:**
- Create: `apply/50-apps/open-webui/open-webui-db.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: `Cluster postgres` in `databases` (already live), and the Secret `databases/open-webui-db-credentials` created in Task 4. Until Task 4 lands the `DatabaseRole` references a Secret that does not exist; CNPG retries and the object reports `Reconciling`, which is the expected state, not a failure.
- Produces: role and database `open_webui` for Task 4's `DATABASE_URL` and Task 5's pod to connect as.

- [ ] **Step 1: Write the manifest**

Create `apply/50-apps/open-webui/open-webui-db.yaml`:

```yaml
# open-webui's database and role, authored beside the app that owns them and living in `databases`,
# because a CNPG Database must share a namespace with its Cluster. Read auth/authentik-db.yaml and
# coder/coder-db.yaml first; everything they record about DatabaseRole applies here verbatim.
#
# THE NAMING, BECAUSE IT WILL BE ASKED
# Kubernetes object names carry the hyphen (`open-webui`) like every other object in this repo. The
# Postgres identifiers inside them are `open_webui` with an underscore: a hyphenated identifier is a
# QUOTED identifier in Postgres, so every place that interpolates it — psql, pg_dump, a WHERE clause
# in a restore drill — becomes a quoting bug waiting to be found during an incident.
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: open-webui
  namespace: databases
spec:
  name: open_webui
  owner: open_webui
  cluster:
    name: postgres
---
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: open-webui
  namespace: databases
spec:
  name: open_webui
  cluster:
    name: postgres
  # Required and silent when missing: CNPG creates the role NOLOGIN by default, so without this the
  # Database reports Ready and every connection fails with a message pointing somewhere else.
  # Observed live with the authentik role before it was understood.
  login: true
  # NOT superuser, unlike teslamate-db-credentials. TeslaMate needs elevation for `earthdistance`
  # and its file lists the migrations that force it. open-webui's default vector store is chroma on
  # the filesystem (config.py:509,512 at v0.12.3), not pgvector, so nothing here should need an
  # extension. That is an argument from absence, so the first startup is the proof: if a migration
  # needs more, the pod fails loudly at Alembic and the fix is a deliberate `superuser: true` with
  # its own note — not a silent widening. Spec §5.1 and §9.
  passwordSecret:
    name: open-webui-db-credentials
```

- [ ] **Step 2: List it**

In `apply/50-apps/kustomization.yaml`, add to `resources:` after `- coder/workspaces.yaml`:

```yaml
  # open-webui's Database and DatabaseRole, in `databases` for the same reason as the two above.
  # Listed before the Deployment that connects as this role, which is intent rather than mechanism:
  # Flux sorts by kind and applies concurrently, and the pod retries until the role exists.
  - open-webui/open-webui-db.yaml
```

- [ ] **Step 3: Verify**

```bash
kubectl kustomize apply/50-apps | grep -A6 'kind: DatabaseRole'
make kustomize-listing crd-check
```

Expected: `name: open_webui` and `login: true` in the output — **not** `open-webui` in the `spec:` block; `crd-check` green, which is the gate that catches a mis-nested CNPG field (the class of error that once took the whole `apps` stage down).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "open-webui: CNPG Database and DatabaseRole in the shared cluster"
```

---

### Task 3: The authentik blueprint template

**Files:**
- Create: `authentik/blueprints-open-webui.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: the exact text Task 4 renders into `apply/10-secrets/authentik-open-webui-blueprint.yaml`, and the file Task 8's gate re-derives that artifact from. The two placeholders are a contract: `${OPEN_WEBUI_OIDC_CLIENT_ID}` and `${OPEN_WEBUI_OIDC_CLIENT_SECRET}`, spelled identically in the script and the gate.

- [ ] **Step 1: Write the template**

Create `authentik/blueprints-open-webui.yaml`:

```yaml
# authentik blueprint: Open WebUI's OIDC application and provider, for open-webui.titan.arrieta.eu.
#
# WHY A BLUEPRINT
# authentik ships no CRDs, so this is the only declarative path: a rebuilt authentik gets open-webui's
# client back from git instead of from someone's memory. Same argument as blueprints-coder.yaml and
# blueprints-grafana.yaml, and docs/authentik-runbook.md §5 is the record of what a blueprint that is
# never mounted looks like (nothing — it is indistinguishable from one never written).
#
# HOW THIS FILE BECOMES A SECRET
# Nothing here is applied directly. scripts/setup-open-webui-secrets.sh substitutes the two `${...}`
# placeholders and writes the result, sops-encrypted, to
# apply/10-secrets/authentik-open-webui-blueprint.yaml. `make open-webui-oidc-check` proves the
# rendered artifact, this template, open-webui's own copy of the client, and the host it is for all
# still agree.
#
# WHAT THIS MUST NOT DO
# The OIDC provider is deliberately NOT added to the embedded outpost's `providers` list in
# apply/50-apps/auth/tesla-outpost-blueprint.yaml. That list is proxy-only, validate_providers
# dispatches on provider type (outposts/api/outposts.py:69-88), and that blueprint OWNS the list —
# it sets it rather than appending. A second reason not to touch it: open-webui is not a Tesla app.
#
# THE ENDPOINTS ARE NOT COMPOSED, THEY ARE READ
# From the live discovery document, as blueprints-grafana.yaml records: authorize/token/userinfo are
# GLOBAL paths with no slug; issuer and jwks are per-provider. Building `.../o/<slug>/authorize/`
# returns 404 — measured, not assumed.
version: 1
metadata:
  name: titan-open-webui
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: open-webui-provider
    identifiers:
      name: open-webui
    state: present
    attrs:
      name: open-webui
      client_type: confidential
      client_id: "${OPEN_WEBUI_OIDC_CLIENT_ID}"
      client_secret: "${OPEN_WEBUI_OIDC_CLIENT_SECRET}"
      # BOTH candidate callback paths, each strict. Open WebUI computes its own redirect URI with
      # request.url_for('oauth_login_callback', provider='oidc') (utils/oauth.py:1919 at v0.12.3),
      # and main.py:2932-2933 binds TWO routes to that one handler name:
      #   /oauth/{provider}/login/callback   (current)
      #   /oauth/{provider}/callback         (legacy, registered first — decorator order applies
      #                                      bottom-up, so Starlette's url_for finds this one)
      # Which one the app actually sends is not decidable from source, so both are registered and the
      # first real login narrows this list to the one on the wire. Note the segment is `oidc` — the
      # registry key at config.py:2812 — and NOT `authentik`, which is only OAUTH_PROVIDER_NAME, the
      # display label. A prefix match would be a redirect bypass, hence strict on both.
      redirect_uris:
        - url: https://open-webui.titan.arrieta.eu/oauth/oidc/callback
          matching_mode: strict
        - url: https://open-webui.titan.arrieta.eu/oauth/oidc/login/callback
          matching_mode: strict
      grant_types:
        - authorization_code
        - refresh_token
      # 'profile' is load-bearing, not decoration: the `groups` claim that open-webui's role mapping
      # reads exists only because the default profile scope mapping emits it. Drop it and, with
      # ENABLE_OAUTH_ROLE_MANAGEMENT=true on the app side, every non-admin login is a 403 — a denial,
      # not a downgrade (utils/oauth.py:1645-1670).
      property_mappings:
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-offline_access]]
      # implicit consent: an app this cluster owns and configures does not need a click that adds no
      # security. Same reasoning as coder's and Grafana's providers.
      authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      invalidation_flow: !Find [authentik_flows.flow, [slug, default-invalidation-flow]]
      signing_key: !Find [authentik_crypto.certificatekeypair, [managed, goauthentik.io/crypto/jwt-managed]]
      # per_provider makes the issuer https://auth.titan.arrieta.eu/application/o/open-webui/, which
      # is what open-webui's OPENID_PROVIDER_URL names. If the slug moves and that URL does not, the
      # two disagree and the failure looks like a bad token.
      issuer_mode: per_provider
      # hashed_user_id: stable across renames and it does not leak the username into every token.
      # open-webui reads it as the `sub` claim (OAUTH_SUB_CLAIM=sub), which is its identity key.
      sub_mode: hashed_user_id

  - model: authentik_core.application
    identifiers:
      slug: open-webui
    state: present
    attrs:
      name: Open WebUI
      slug: open-webui
      provider: !KeyOf open-webui-provider
      meta_launch_url: https://open-webui.titan.arrieta.eu/
      # The Application is not decoration. A provider with no owning Application is invisible to the
      # consumer that needs it — the recorded 404-for-every-host lesson in tesla-outpost-blueprint.yaml
      # — and it is also what makes open-webui appear in the authentik user dashboard.
```

- [ ] **Step 2: Verify it parses with blueprint tags intact**

```bash
python3 -c "import sys;sys.path.insert(0,'tools');from sopsload import load_tolerating_tags as L;d=L(open('authentik/blueprints-open-webui.yaml').read());print(len(d['entries']), d['metadata']['name'])"
grep -c 'matching_mode: strict' authentik/blueprints-open-webui.yaml
```

Expected: `2 titan-open-webui` and `2`.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "authentik: blueprint template for open-webui's OIDC client"
```

---

### Task 4: Mint the credentials — one script, three sops files

**Files:**
- Create: `scripts/setup-open-webui-secrets.sh`
- Create (by running it): `apply/10-secrets/authentik-open-webui-blueprint.yaml`, `apply/10-secrets/open-webui-db-credentials.yaml`, `apply/10-secrets/open-webui-secrets.yaml`
- Modify: `apply/10-secrets/kustomization.yaml`

**Interfaces:**
- Consumes: `authentik/blueprints-open-webui.yaml` (Task 3), the age key at `$HOME/.config/sops/age/keys.txt`, and `.sops.yaml`'s `path_regex: apply/10-secrets/.*\.ya?ml$` recipient rule.
- Produces: `open-webui/open-webui-secrets` with exactly `DATABASE_URL`, `WEBUI_SECRET_KEY`, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`; `databases/open-webui-db-credentials` (`kubernetes.io/basic-auth`, `username: open_webui`); `auth/authentik-open-webui-blueprint` with key `open-webui.yaml`. Task 5 mounts the first, Task 7 compares the first two, Task 8 compares all three.

- [ ] **Step 1: Write the script**

Create `scripts/setup-open-webui-secrets.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Mint everything open-webui needs and write it to the three places it has to appear.
#
# RUN IT, DON'T READ IT INTO A SHELL. The operator's login shell is fish, which has no heredocs and no
# `read -rs -p`; this file's bash-isms are deliberate and the shebang is the interpreter.
#
# WHY ONE SCRIPT FOR FOUR VALUES
# The DB password exists twice (CNPG's DatabaseRole in `databases`, and open-webui's DATABASE_URL in
# `open-webui`) and the OIDC client exists twice (authentik's blueprint, open-webui's env). Minting all
# of it in one process is the only way "they agree" is a property of the code rather than of the
# operator's attention. `make db-url-check` and `make open-webui-oidc-check` then prove it from the
# tree instead of trusting it.
#
# WEBUI_SECRET_KEY IS HERE TOO, and it is the one with a rule attached: v0.12.3 refuses to boot
# without it (env.py:786), and start.sh otherwise generates one into /app/backend/.webui_secret_key —
# container-local, so it dies with every pod and orphans every stored OAuth token. Casa lives with that
# bug; see spec §6. Rotating this value invalidates every session and every stored token, so it is
# rotated deliberately and never as a side effect of touching the OIDC client.
#
# Nothing prints a value. What you see is a truncated SHA-256 per file.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

TEMPLATE=authentik/blueprints-open-webui.yaml
BP_SECRET=apply/10-secrets/authentik-open-webui-blueprint.yaml
DB_SECRET=apply/10-secrets/open-webui-db-credentials.yaml
APP_SECRET=apply/10-secrets/open-webui-secrets.yaml
STAGE_BP=apply/10-secrets/.staging.authentik-open-webui-blueprint.yaml
STAGE_DB=apply/10-secrets/.staging.open-webui-db-credentials.yaml
STAGE_APP=apply/10-secrets/.staging.open-webui-secrets.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}

trap 'rm -f "$STAGE_BP" "$STAGE_DB" "$STAGE_APP"' EXIT

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE to the file holding the titan-k8s private key"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"
[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE missing - nothing to render"; exit 1; }

existing=()
for f in "$BP_SECRET" "$DB_SECRET" "$APP_SECRET"; do
  [ -f "$f" ] && existing+=("$f")
done
if [ ${#existing[@]} -gt 0 ]; then
  echo "FAIL: these already exist and would be replaced with NEW values:"
  printf '  %s\n' "${existing[@]}"
  echo "open-webui would then present a client and a password authentik and CNPG do not recognise, and"
  echo "rotating WEBUI_SECRET_KEY would orphan every session and stored OAuth token. If that is what"
  echo "you want, re-run with FORCE=1."
  [ "${FORCE:-0}" = "1" ] || exit 1
fi

CID=$(python3 -c 'import uuid; print(uuid.uuid4())')
CSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
DBPW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
WEBKEY=$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')

TEMPLATE="$TEMPLATE" STAGE_BP="$STAGE_BP" STAGE_DB="$STAGE_DB" STAGE_APP="$STAGE_APP" \
CID="$CID" CSEC="$CSEC" DBPW="$DBPW" WEBKEY="$WEBKEY" python3 - <<'PY'
import os, re, sys, yaml

env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${OPEN_WEBUI_OIDC_CLIENT_ID}", "${OPEN_WEBUI_OIDC_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - template and script disagree")

rendered = (tpl.replace("${OPEN_WEBUI_OIDC_CLIENT_ID}", env["CID"])
              .replace("${OPEN_WEBUI_OIDC_CLIENT_SECRET}", env["CSEC"]))
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s) remain: {leftover}")

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=100)

dump(env["STAGE_BP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "authentik-open-webui-blueprint", "namespace": "auth"},
    "type": "Opaque",
    # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
    "stringData": {"open-webui.yaml": rendered},
})

# CNPG's DatabaseRole reads a kubernetes.io/basic-auth Secret whose `username` MUST equal the role
# name, and the cnpg.io/reload label belongs on THIS Secret, not on the DatabaseRole.
dump(env["STAGE_DB"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {
        "name": "open-webui-db-credentials", "namespace": "databases",
        "labels": {"cnpg.io/reload": "true"},
    },
    "type": "kubernetes.io/basic-auth",
    "stringData": {"username": "open_webui", "password": env["DBPW"]},
})

# open-webui's own copy. token_urlsafe/token_hex are URL-safe by construction, so DATABASE_URL needs
# no percent-encoding step - which is the usual way an inline password breaks.
dump(env["STAGE_APP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "open-webui-secrets", "namespace": "open-webui"},
    "type": "Opaque",
    "stringData": {
        "DATABASE_URL": f"postgresql://open_webui:{env['DBPW']}@postgres-rw.databases.svc.cluster.local:5432/open_webui",
        "WEBUI_SECRET_KEY": env["WEBKEY"],
        "OAUTH_CLIENT_ID": env["CID"],
        "OAUTH_CLIENT_SECRET": env["CSEC"],
    },
})
PY

for f in "$STAGE_BP" "$STAGE_DB" "$STAGE_APP"; do
  sops --encrypt --in-place "$f"
  dest=$([ "$f" = "$STAGE_BP" ] && echo "$BP_SECRET" || { [ "$f" = "$STAGE_DB" ] && echo "$DB_SECRET" || echo "$APP_SECRET"; })
  mv "$f" "$dest"
  echo "wrote $dest  (fingerprint $(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$dest"))"
done

cat <<'DONE'

Done. Three files, four values, all encrypted.

Still to do, in order:
  1. make db-url-check open-webui-oidc-check   (once their gates exist) proves the copies agree.
  2. Merge, then force the blueprint from the UI or wait for the worker's hourly discovery.
     Mounting is not applying - docs/authentik-runbook.md §5.
  3. The FIRST authentik user to sign in becomes open-webui admin, whatever the env says
     (utils/oauth.py:1598-1607). Do that deliberately, and record which /oauth/oidc/... callback
     path appears on the wire so the blueprint can be narrowed to it.
DONE
```

- [ ] **Step 2: Run it**

```bash
cd /home/coder/k8s-titan
chmod +x scripts/setup-open-webui-secrets.sh
./scripts/setup-open-webui-secrets.sh
```

Expected: three `wrote …` lines with fingerprints, and no value on screen. If it prints `FAIL: … already exist`, stop — something is half-applied.

- [ ] **Step 3: List all three**

Append to `resources:` in `apply/10-secrets/kustomization.yaml`:

```yaml
  # open-webui. Three files, four values, all minted by scripts/setup-open-webui-secrets.sh in one
  # process so the duplicated halves cannot be authored apart: the DB password appears in CNPG's
  # basic-auth Secret (namespace databases) and inside open-webui's DATABASE_URL (namespace
  # open-webui), and the OIDC client appears in authentik's blueprint (namespace auth) and in
  # open-webui's own env. make db-url-check and make open-webui-oidc-check are what prove the pairs
  # agree; an unlisted file here would build green and be silently never applied, which is the lie
  # `make secrets-placement` exists to catch.
  - authentik-open-webui-blueprint.yaml
  - open-webui-db-credentials.yaml
  - open-webui-secrets.yaml
```

- [ ] **Step 4: Verify**

```bash
make secrets-placement secrets-present
SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt python3 tools/db-url-check.py --root apply
grep -l 'sops:' apply/10-secrets/open-webui-*.yaml | wc -l
```

Expected: placement and present green; `db-url-check` prints `0 PG URL reference(s) checked` — **that zero is the blind spot Task 7 closes**, not a pass over open-webui's URL; `2` from the grep (the third file is `authentik-*`).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "open-webui: mint the DB password, the OIDC client and WEBUI_SECRET_KEY"
```

---

### Task 5: The workload

**Files:**
- Create: `apply/50-apps/open-webui/open-webui.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: `open-webui/open-webui-secrets` (Task 4), role `open_webui` (Task 2), namespace + reflected `titan-tls` + Reloader watch (Task 1).
- Produces: `Deployment open-webui/open-webui` reading `open-webui-secrets` through `envFrom` — Task 8's gate reads this object's env to prove the OIDC wiring is actually wired.

- [ ] **Step 1: Write the manifest**

Create `apply/50-apps/open-webui/open-webui.yaml`:

```yaml
# Open WebUI on titan: fresh instance, data in the shared CNPG cluster, sign-in through authentik.
# Design and evidence: docs/superpowers/specs/2026-10-20-titan-open-webui-design.md.
#
# WHAT IS IN POSTGRES AND WHAT IS ON THE PVC, because it decides what a backup covers.
# Postgres (open_webui, in the cluster that ships base backups and WAL to S3) holds users, roles,
# chats, prompts, knowledge metadata, API keys, the admin's model connection and the encrypted OAuth
# session tokens. The PVC holds DATA_DIR/uploads and DATA_DIR/vector_db (config.py:180,512 at
# v0.12.3 — chroma is the default vector store in the standard image). The vector index is derived and
# rebuildable; uploads are neither in a backup nor rebuildable. That is a named exposure, not a
# surprise: spec §5.3 and §9.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: open-webui-data
  namespace: open-webui
spec:
  accessModes:
  - ReadWriteOnce
  # local-path-retain, not the default local-path: Retain is the only deletion mitigation this cluster
  # has for a PVC (see apply/20-infra/storage-retain.yaml). It is a deletion mitigation and NOT a
  # backup — a Retain PV that survives `kubectl delete pvc` does not survive the disk.
  storageClassName: local-path-retain
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: open-webui
  # Meaningless without the namespace also being in reloader.namespaces in
  # apply/20-infra/reloader/reloader.yaml — watchGlobally is false, so Reloader does not look here
  # at all. Both halves are in this branch for exactly that reason.
  annotations:
    reloader.stakater.com/auto: "true"
spec:
  replicas: 1
  # RWO PVC: a RollingUpdate schedules pod 2 while pod 1 still holds the volume and the new pod sits
  # Pending on a volume conflict forever. Recreate also avoids two pods running Alembic at once.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: open-webui
  template:
    metadata:
      labels:
        app: open-webui
    spec:
      # No pod/container securityContext, deliberately, and do not "harden" it without testing it:
      # the image is built with ARG UID=0 and runs as root, so runAsNonRoot is a lie the kubelet
      # rejects at start and dropping capabilities is unverified against an app that installs
      # Python packages at runtime for optional features. Casa runs the same image unconfined.
      containers:
      - name: open-webui
        image: ghcr.io/open-webui/open-webui:v0.12.3
        ports:
        - name: http
          containerPort: 8080
        envFrom:
        # DATABASE_URL, WEBUI_SECRET_KEY, OAUTH_CLIENT_ID, OAUTH_CLIENT_SECRET. The keys are the
        # names open-webui reads, so envFrom needs no aliasing and there is no typo'd mapping
        # between Secret and Deployment.
        - secretRef:
            name: open-webui-secrets
        env:
        - name: DATA_DIR
          value: /app/backend/data
        - name: WEBUI_URL
          value: https://open-webui.titan.arrieta.eu
        # --- single sign-on: authentik decides who you are; there is no local password form -------
        # OAUTH_PROVIDER_NAME is a DISPLAY label only. The env-configured OIDC provider is registered
        # under the key `oidc` (config.py:2812 at v0.12.3), which is why the callback path and the
        # redirect URIs in the blueprint say /oauth/oidc/... and not /oauth/authentik/....
        - name: OAUTH_PROVIDER_NAME
          value: authentik
        - name: OPENID_PROVIDER_URL
          value: https://auth.titan.arrieta.eu/application/o/open-webui/.well-known/openid-configuration
        - name: ENABLE_OAUTH_SIGNUP
          value: "true"
        - name: ENABLE_LOGIN_FORM
          value: "false"
        - name: OAUTH_MERGE_ACCOUNTS_BY_EMAIL
          value: "true"
        # `profile` is what puts `groups` in the token. Drop it and, with role management on below,
        # every non-admin login is a 403 rather than a fallback role (utils/oauth.py:1645-1670).
        - name: OAUTH_SCOPES
          value: openid email profile
        - name: OAUTH_SUB_CLAIM
          value: sub
        - name: OAUTH_TOKEN_ENDPOINT_AUTH_METHOD
          value: client_secret_basic
        - name: OPENID_END_SESSION_ENDPOINT
          value: https://auth.titan.arrieta.eu/application/o/open-webui/end-session/
        - name: ENABLE_OAUTH_ID_TOKEN_COOKIE
          value: "true"
        - name: OAUTH_UPDATE_PICTURE_ON_LOGIN
          value: "true"
        - name: OAUTH_UPDATE_NAME_ON_LOGIN
          value: "true"
        - name: ENABLE_WEBUI_LOG
          value: "true"
        # --- roles come from authentik groups, the way this cluster already does for Grafana -----
        # (apply/60-tesla/grafana.yaml:143 maps the same `authentik Admins` group.) Without role
        # management the default role is `pending` (config.py:1748,2660), i.e. the second person
        # through the door can log in and do nothing until an admin approves them in open-webui's UI.
        #
        # OAUTH_ALLOWED_ROLES must NOT be left at its default `user,admin`: with the claim set to
        # authentik group names, that default matches nothing and 403s every non-admin. `*` means any
        # authentik-authenticated user gets `user`; `authentik Admins` gets `admin`.
        - name: ENABLE_OAUTH_ROLE_MANAGEMENT
          value: "true"
        - name: OAUTH_ROLES_CLAIM
          value: groups
        - name: OAUTH_ADMIN_ROLES
          value: authentik Admins
        - name: OAUTH_ALLOWED_ROLES
          value: "*"
        # The first user to sign in becomes admin regardless of all of the above
        # (utils/oauth.py:1598-1607). Do that on purpose and record it in the runbook.
        # --- probes ---------------------------------------------------------------------------
        # startupProbe rather than a big initialDelay: startup runs Alembic migrations against
        # Postgres and initialises chroma, which is slow on a cold start and unbounded on a slow one.
        # 30 x 10s = five minutes before liveness is even asked about.
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
        # /ready gates on app.state.startup_complete; /health/db pings Postgres. Readiness on /ready
        # keeps a slow migration from pulling the endpoint out of the Service while it is still fine.
        readinessProbe:
          httpGet:
            path: /ready
            port: http
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 500Mi
          limits:
            cpu: "1"
            memory: 2Gi
        volumeMounts:
        - name: data
          mountPath: /app/backend/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: open-webui-data
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: open-webui
spec:
  type: ClusterIP
  selector:
    app: open-webui
  ports:
  - name: http
    port: 80
    targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: open-webui
  namespace: open-webui
  # No forward-auth middleware on this host: open-webui decides who may in, through authentik OIDC
  # (spec D3). Adding a proxy provider here would mean editing the Tesla-owned outpost blueprint that
  # OWNS that provider list, and putting a middleware in the path of open-webui's streaming traffic.
  # The host is reachable from the public internet either way, exactly like coder. and auth.
  spec:
  ingressClassName: traefik
  rules:
  - host: open-webui.titan.arrieta.eu
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: open-webui
            port:
              number: 80
  tls:
  - hosts:
    - open-webui.titan.arrieta.eu
    # Reflected from `certificates` by the wildcard. Reaching THIS namespace required adding
    # `open-webui` to both reflector annotations on apply/40-certificates/titan-wildcard.yaml; with
    # only one of the two edited, the Certificate stays Ready and the Secret never appears.
    secretName: titan-tls
```

- [ ] **Step 2: List it**

In `apply/50-apps/kustomization.yaml`, add after the line added in Task 2:

```yaml
  # The app itself: PVC + Deployment + Service + Ingress in namespace `open-webui`. It reads
  # open-webui-secrets (envFrom) and titan-tls (reflected into its own namespace), and connects as the
  # role above. A pod that starts before its Secret exists sits crash-looping, which reads like an app
  # bug rather than a missing file — the ordering note at the top of this file applies.
  - open-webui/open-webui.yaml
```

- [ ] **Step 3: Verify**

```bash
kubectl kustomize apply/50-apps >/dev/null && echo BUILD-OK
make kustomize-listing kustomize-check crd-check
kubectl kustomize apply/50-apps | grep -E 'storageClassName|ENABLE_OAUTH_ROLE_MANAGEMENT|reloader.stakater' 
```

Expected: `BUILD-OK`, gates green, and `local-path-retain` / `ENABLE_OAUTH_ROLE_MANAGEMENT` / `reloader.stakater.com/auto` all present.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "open-webui: the workload — Postgres-backed, OIDC-only sign-in, roles from groups"
```

---

### Task 6: Mount the blueprint on authentik

**Files:**
- Modify: `apply/50-apps/auth/authentik.yaml` (`spec.values.blueprints.secrets`)

**Interfaces:**
- Consumes: `auth/authentik-open-webui-blueprint` (Task 4).
- Produces: authentik's worker actually seeing the blueprint. Without this the client is valid, applied to the cluster, and invisible.

- [ ] **Step 1: Add it to the mount list**

In `apply/50-apps/auth/authentik.yaml`, under `blueprints.secrets`, after `- authentik-grafana-blueprint`:

```yaml
        # open-webui's OIDC client. A Secret, not a ConfigMap, because it carries the client_secret —
        # the same line the tesla outpost blueprint sits on the other side of. It is NOT in the
        # embedded outpost's provider list: that list is proxy-only and belongs to
        # apply/50-apps/auth/tesla-outpost-blueprint.yaml.
        - authentik-open-webui-blueprint
```

- [ ] **Step 2: Verify the mount and the Secret exist together**

```bash
make kustomize-check
python3 - <<'PY'
import sys; sys.path.insert(0,'tools')
from sopsload import load_docs, find
d = load_docs('apply')
hr = find(d,'HelmRelease','authentik','auth')
mounted = ((hr['spec']['values'].get('blueprints') or {}).get('secrets') or [])
assert 'authentik-open-webui-blueprint' in mounted, mounted
assert find(d,'Secret','authentik-open-webui-blueprint','auth') is not None
print("MOUNT-OK", mounted)
PY
```

Expected: `MOUNT-OK [...]` listing four Secrets. This is the check `make oidc-check` performs for coder and `make grafana-oidc-check` performs for Grafana; Task 8 adds the open-webui version so it is enforced rather than remembered.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "authentik: mount open-webui's blueprint — mounting is not applying, but it is a precondition"
```

---

### Task 7: Widen `db-url-check` so it can see a `Deployment`

**Files:**
- Modify: `tools/db-url-check.py` (`pg_url_refs`, the docstring, and the namespace default in `main`)

**Interfaces:**
- Consumes: `open-webui/open-webui-secrets` `DATABASE_URL` and `databases/open-webui-db-credentials` (Task 4), `DatabaseRole open_webui` (Task 2).
- Produces: a gate that reports **two** references instead of one, so the open-webui password pair is actually compared.

- [ ] **Step 1: Write the failing fixture**

```bash
mkdir -p /tmp/dbfix/apply/{ns,db}
cat > /tmp/dbfix/apply/ns/app.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: open-webui, namespace: open-webui}
spec:
  template:
    spec:
      containers:
      - name: open-webui
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef: {name: open-webui-secrets, key: DATABASE_URL}
YAML
cat > /tmp/dbfix/apply/ns/sec.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata: {name: open-webui-secrets, namespace: open-webui}
stringData:
  DATABASE_URL: postgresql://open_webui:goodpw@postgres-rw.databases.svc.cluster.local:5432/open_webui
YAML
cat > /tmp/dbfix/apply/db/role.yaml <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata: {name: open-webui, namespace: databases}
spec:
  name: open_webui
  login: true
  passwordSecret: {name: open-webui-db-credentials}
YAML
cat > /tmp/dbfix/apply/db/cred.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata: {name: open-webui-db-credentials, namespace: databases}
type: kubernetes.io/basic-auth
stringData: {username: open_webui, password: goodpw}
YAML
python3 tools/db-url-check.py --root /tmp/dbfix; echo "exit=$?"
```

Expected **before** the change: `db-url-check: 0 PG URL reference(s) checked, 0 mismatch(es)` with `exit=0` — the vacuous pass, which is the bug being fixed.

- [ ] **Step 2: Widen the finder**

Replace `pg_url_refs` in `tools/db-url-check.py` with:

```python
def pg_url_refs(docs):
    """(workload-name, namespace, secret-name, key) for every Postgres URL env ref.

    Two shapes, because this cluster has both. Coder takes one knob, CODER_PG_CONNECTION_URL, in a
    HelmRelease's values; open-webui takes DATABASE_URL as plain env on a Deployment. A finder that
    walks only the first reports zero references for the second and passes vacuously — which is the
    one failure mode a reference-driven gate must never have.
    """
    refs = []
    for d in docs:
        kind = d.get("kind")
        md = d.get("metadata") or {}
        if kind == "HelmRelease":
            values = ((d.get("spec") or {}).get("values") or {})
            for env in ((values.get("coder") or {}).get("env") or []):
                if not re.search(r"PG_CONNECTION_URL$", env.get("name", "")):
                    continue
                ref = (env.get("valueFrom") or {}).get("secretKeyRef")
                if ref:
                    refs.append((md.get("name"), md.get("namespace"), ref.get("name"), ref.get("key")))
        elif kind == "Deployment":
            for c in (((d.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers", []):
                for env in c.get("env") or []:
                    if not re.search(r"(PG_CONNECTION_URL|DATABASE_URL)$", env.get("name", "")):
                        continue
                    ref = (env.get("valueFrom") or {}).get("secretKeyRef")
                    if ref:
                        refs.append((md.get("name"), md.get("namespace"), ref.get("name"), ref.get("key")))
    return refs
```

Also in `main`, change `secret_key(docs, sec_name, hr_ns or "coder", key)` to `secret_key(docs, sec_name, ns or "default", key)` and rename the loop variables `for wl_name, ns, sec_name, key in refs:` so a `Deployment` in no namespace is not silently read as coder's. Update the module docstring's third paragraph to name both shapes.

- [ ] **Step 3: Verify the fixture now fires, and fires on a mismatch**

```bash
python3 tools/db-url-check.py --root /tmp/dbfix; echo "exit=$?"
sed -i 's/goodpw/badpw/' /tmp/dbfix/apply/db/cred.yaml
python3 tools/db-url-check.py --root /tmp/dbfix; echo "exit=$?"
rm -rf /tmp/dbfix
```

Expected: first run `1 PG URL reference(s) checked, 0 mismatch(es)` / `exit=0`; second run a `FAIL: password in open-webui-secrets/DATABASE_URL does not match open-webui-db-credentials - rotate both or neither` / `exit=1`.

- [ ] **Step 4: Verify against the real tree**

```bash
make db-url-check
```

Expected: `2 PG URL reference(s) checked, 0 mismatch(es)` — coder's and open-webui's. A `1` means the open-webui reference is not being seen and the gate is lying again.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "tools: db-url-check sees a Deployment's DATABASE_URL, not only a HelmRelease's"
```

---

### Task 8: The open-webui OIDC agreement gate

**Files:**
- Create: `tools/open-webui-oidc-check.py`
- Modify: `Makefile` (`.PHONY`, `check`, new target)

**Interfaces:**
- Consumes: `authentik/blueprints-open-webui.yaml` (Task 3), the three Secrets (Task 4), the `Deployment` env (Task 5), the `HelmRelease` mount list (Task 6).
- Produces: `make open-webui-oidc-check`, and a `make check` that fails if any of the four copies of the credential or the wiring around them drifts.

- [ ] **Step 1: Write the gate**

Create `tools/open-webui-oidc-check.py`:

```python
#!/usr/bin/env python3
"""open-webui-oidc-check: the OIDC client, the blueprint that carries it, the mount, the app's env,
and the host it is for — all agreeing.

Modelled on grafana-oidc-check for the same reason: one credential written into several places, where
every disagreement presents as a different bug.

  * the rendered blueprint drifts from authentik/blueprints-open-webui.yaml — git says one thing,
    authentik applies another, and no reviewer ever sees the applied artifact;
  * open-webui's copy and authentik's copy disagree — every login fails with an OIDC error that reads
    like an open-webui bug;
  * nothing mounts the blueprint — valid, inert, and indistinguishable from never having been written;
  * the redirect URIs name a host other than WEBUI_URL — authentik refuses the callback with a
    mismatch that looks like a client-secret problem;
  * the role mapping is configured against a claim that will not be there. This one is specific to
    open-webui and worse than the others: with ENABLE_OAUTH_ROLE_MANAGEMENT=true, a missing or
    unmatched `groups` claim is a 403, not a fallback role, so a dropped `profile` scope locks every
    non-admin out while the login page looks fine.

It refuses to report clean when a Secret will not decrypt, and counts zero (honestly) when the
credentials do not exist yet.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import find, load_docs, load_text, load_tolerating_tags, secret_key  # noqa: E402

import yaml  # noqa: E402

TEMPLATE = "authentik/blueprints-open-webui.yaml"
PLACEHOLDERS = ("OPEN_WEBUI_OIDC_CLIENT_ID", "OPEN_WEBUI_OIDC_CLIENT_SECRET")
HOST = "open-webui.titan.arrieta.eu"
REDIRECTS = [f"https://{HOST}/oauth/oidc/callback", f"https://{HOST}/oauth/oidc/login/callback"]
BLUEPRINT_SECRET = "authentik-open-webui-blueprint"
BLUEPRINT_KEY = "open-webui.yaml"
APP_SECRET = "open-webui-secrets"
APP_NS = "open-webui"


def entry(bp, model):
    for e in bp.get("entries") or []:
        if e.get("model") == model:
            return e
    return None


def container_env(deploy):
    out, from_secrets = {}, set()
    for spec in ((deploy.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers", []):
        for e in spec.get("env") or []:
            out[e.get("name")] = e.get("value")
        for ef in spec.get("envFrom") or []:
            ref = (ef.get("secretKeyRef") or {}).get("name")
            if ref:
                from_secrets.add(ref)
    return out, from_secrets


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "apply"
    docs = load_docs(root)
    checked = bad = 0

    def fail(msg):
        nonlocal bad
        print(f"FAIL: {msg}")
        bad += 1

    # --- A. the reviewed template ----------------------------------------------------------
    tpl_text = load_text(TEMPLATE)
    if tpl_text is None:
        sys.exit(f"open-webui-oidc-check: {TEMPLATE} is missing - no source of truth to check "
                 f"against; refusing to report clean")
    try:
        tpl = load_tolerating_tags(tpl_text)
    except yaml.YAMLError as exc:
        sys.exit(f"open-webui-oidc-check: {TEMPLATE} is not valid YAML: {exc}")
    checked += 1

    pe = entry(tpl, "authentik_providers_oauth2.oauth2provider")
    ae = entry(tpl, "authentik_core.application")
    if pe is None:
        fail(f"{TEMPLATE} declares no oauth2provider entry")
    if ae is None:
        fail(f"{TEMPLATE} declares no authentik_core.application entry - a provider with no owning "
             f"Application is not visible to the consumers that need one")
    if pe and ae:
        checked += 1
        if (ae.get("attrs") or {}).get("slug") != "open-webui":
            fail("the application slug is not 'open-webui' - with issuer_mode per_provider the slug "
                 "IS the issuer path open-webui's OPENID_PROVIDER_URL names")
        uris = [u.get("url") for u in ((pe.get("attrs") or {}).get("redirect_uris") or [])]
        if sorted(uris) != sorted(REDIRECTS):
            fail(f"redirect_uris is {uris}, expected both {REDIRECTS} - open-webui derives its "
                 f"callback path with url_for over two same-name routes (main.py:2932-2933), so "
                 f"until a real login proves which one it sends, both must be registered")
        modes = [u.get("matching_mode") for u in ((pe.get("attrs") or {}).get("redirect_uris") or [])]
        if any(m != "strict" for m in modes):
            fail(f"redirect_uri matching_mode is {modes}; a prefix match here is a redirect bypass")
        scopes = [str(m) for m in ((pe.get("attrs") or {}).get("property_mappings") or [])]
        if not any("scope-profile" in s for s in scopes):
            fail("the provider has no scope-profile mapping - `groups` comes only from it, and with "
                 "role management on a missing claim is a denial, not a fallback role")
        checked += 1

    found = set(re.findall(r"\$\{([A-Z_]+)\}", tpl_text))
    if found != set(PLACEHOLDERS):
        fail(f"{TEMPLATE} placeholders are {sorted(found)}, expected {sorted(PLACEHOLDERS)} - the "
             f"setup script substitutes exactly these two and nothing else")
    checked += 1

    # --- B. open-webui's copy, and the rendered artifact ------------------------------------
    cid, cdata = secret_key(docs, APP_SECRET, APP_NS, "OAUTH_CLIENT_ID")
    if cdata is None:
        print(f"open-webui-oidc-check: {APP_SECRET} not present - 0 rendered artifacts to reconcile "
              f"(run scripts/setup-open-webui-secrets.sh)")
        print(f"open-webui-oidc-check: {checked} template check(s) run, {bad} mismatch(es)")
        sys.exit(1 if bad else 0)

    csec, _ = secret_key(docs, APP_SECRET, APP_NS, "OAUTH_CLIENT_SECRET")
    webkey, _ = secret_key(docs, APP_SECRET, APP_NS, "WEBUI_SECRET_KEY")
    dburl, _ = secret_key(docs, APP_SECRET, APP_NS, "DATABASE_URL")
    if not cid or not csec:
        fail(f"{APP_SECRET} is present but the client id or secret is empty")
    if not webkey:
        fail(f"{APP_SECRET} has no WEBUI_SECRET_KEY. Without it start.sh generates one into the "
             f"container layer on every boot, which orphans every stored OAuth token - the defect "
             f"this instance exists not to inherit (spec §6)")
    if not dburl or "open_webui" not in dburl:
        fail(f"{APP_SECRET} has no DATABASE_URL for open_webui - the app would fall back to SQLite "
             f"under DATA_DIR, i.e. data outside the only backup this cluster has")
    checked += 1

    bp_secret = find(docs, "Secret", BLUEPRINT_SECRET, "auth")
    if bp_secret is None:
        fail(f"open-webui has OIDC credentials but {BLUEPRINT_SECRET} (namespace auth) is not in the "
             f"tree - authentik has no such client, so every login fails")
    else:
        checked += 1
        rendered = (bp_secret.get("stringData") or {}).get(BLUEPRINT_KEY)
        if rendered is None:
            fail(f"{BLUEPRINT_SECRET} has no '{BLUEPRINT_KEY}' key - the worker only picks up keys "
                 f"ending in .yaml, so an empty Secret looks exactly like no blueprint")
        else:
            leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
            if leftover:
                fail(f"rendered blueprint still contains unsubstituted placeholders {leftover}")
            try:
                rbp = load_tolerating_tags(rendered) or {}
                rattrs = (entry(rbp, "authentik_providers_oauth2.oauth2provider") or {}).get("attrs") or {}
            except yaml.YAMLError as exc:
                rattrs = {}
                fail(f"rendered blueprint is not valid YAML: {exc}")
            if rattrs.get("client_id") != cid:
                fail(f"authentik's client_id is {rattrs.get('client_id')!r} but open-webui is "
                     f"configured with {cid!r} - the two copies of one credential disagree")
            elif rattrs.get("client_secret") != csec:
                fail("authentik's client_secret does not match open-webui's - every login fails with "
                     "an OIDC error that reads like an open-webui bug")
            else:
                checked += 1
            expected = (tpl_text.replace("${OPEN_WEBUI_OIDC_CLIENT_ID}", cid or "")
                              .replace("${OPEN_WEBUI_OIDC_CLIENT_SECRET}", csec or ""))
            try:
                if load_tolerating_tags(rendered) != load_tolerating_tags(expected):
                    fail(f"{BLUEPRINT_SECRET}:{BLUEPRINT_KEY} is not the committed template with the "
                         f"two credentials substituted - re-run scripts/setup-open-webui-secrets.sh")
                checked += 1
            except yaml.YAMLError as exc:
                fail(f"rendered blueprint is not valid YAML: {exc}")

    # --- C. mounted, and wired --------------------------------------------------------------
    hr = find(docs, "HelmRelease", "authentik", "auth")
    if hr is None:
        fail("no HelmRelease authentik/auth - cannot tell whether the blueprint is mounted")
    else:
        mounted = (((hr.get("spec") or {}).get("values") or {}).get("blueprints") or {}).get("secrets") or []
        if BLUEPRINT_SECRET in mounted:
            if bp_secret is None:
                fail(f"HelmRelease mounts {BLUEPRINT_SECRET} but that Secret is not in the tree")
        else:
            fail(f"nothing mounts {BLUEPRINT_SECRET}: the worker never sees it, so the blueprint "
                 f"cannot apply. Add it under spec.values.blueprints.secrets")
        checked += 1

    deploy = find(docs, "Deployment", "open-webui", APP_NS)
    if deploy is None:
        fail(f"no Deployment {APP_NS}/open-webui - cannot check how the app is configured")
    else:
        env, from_secrets = container_env(deploy)
        if APP_SECRET not in from_secrets:
            fail(f"the Deployment does not envFrom {APP_SECRET} - the client is in the tree and the "
                 f"app will never read it")
        if env.get("ENABLE_LOGIN_FORM") != "false":
            fail("ENABLE_LOGIN_FORM is not 'false' - a local password form beside OIDC is a second, "
                 "unmanaged way in")
        if env.get("ENABLE_OAUTH_SIGNUP") != "true":
            fail("ENABLE_OAUTH_SIGNUP is not 'true' - nobody can get an account, and with the login "
                 "form off there is no other way to create one")
        if env.get("ENABLE_OAUTH_ROLE_MANAGEMENT") != "true":
            fail("ENABLE_OAUTH_ROLE_MANAGEMENT is not 'true' - the default role is `pending`, so "
                 "every user but the first waits for manual approval in the app's own UI")
        if env.get("OAUTH_ROLES_CLAIM") != "groups":
            fail("OAUTH_ROLES_CLAIM is not 'groups' - authentik emits groups, not roles")
        if env.get("OAUTH_ADMIN_ROLES") != "authentik Admins":
            fail("OAUTH_ADMIN_ROLES is not 'authentik Admins' - the group this cluster already uses "
                 "for admin mapping (see apply/60-tesla/grafana.yaml)")
        if env.get("OAUTH_ALLOWED_ROLES") != "*":
            fail(f"OAUTH_ALLOWED_ROLES is {env.get('OAUTH_ALLOWED_ROLES')!r}. The default `user,admin` "
                 f"matches no authentik group name, so every non-admin gets a hard 403")
        scopes = env.get("OAUTH_SCOPES") or ""
        for want in ("openid", "email", "profile"):
            if want not in scopes:
                fail(f"OAUTH_SCOPES is {scopes!r} and omits {want} - without profile there is no "
                     f"groups claim and role management denies instead of downgrading")
        prov = env.get("OPENID_PROVIDER_URL") or ""
        if "auth.titan.arrieta.eu/application/o/open-webui/" not in prov:
            fail(f"OPENID_PROVIDER_URL is {prov!r}; with issuer_mode per_provider it must name "
                 f".../application/o/open-webui/, the application slug")
        webui = env.get("WEBUI_URL") or ""
        if webui != f"https://{HOST}":
            fail(f"WEBUI_URL is {webui!r} but the redirect URIs are built on {HOST} - authentik "
                 f"refuses the callback on a host mismatch")
        checked += 1

    print(f"open-webui-oidc-check: {checked} check(s) run, {bad} mismatch(es)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it and expect green**

```bash
python3 tools/open-webui-oidc-check.py apply; echo "exit=$?"
```

Expected: `open-webui-oidc-check: N check(s) run, 0 mismatch(es)`, `exit=0`. If it reports `0 rendered artifacts`, Task 4 did not run.

- [ ] **Step 3: Prove it fires**

```bash
cp apply/10-secrets/open-webui-secrets.yaml /tmp/owui.bak
python3 - <<'PY'
import subprocess
p="apply/10-secrets/open-webui-secrets.yaml"
t=subprocess.run(["sops","--decrypt",p],capture_output=True,text=True).stdout
open(p,"w").write(t.replace("value: '*'","value: 'user,admin'") if "value: '*'" in t else t.replace('OAUTH_ALLOWED_ROLES: "*"','OAUTH_ALLOWED_ROLES: "user,admin"'))
PY
python3 tools/open-webui-oidc-check.py apply; echo "exit=$?"
mv /tmp/owui.bak apply/10-secrets/open-webui-secrets.yaml
python3 tools/open-webui-oidc-check.py apply; echo "exit=$?"
```

Expected: a `FAIL: OAUTH_ALLOWED_ROLES is 'user,admin'…` with `exit=1`, then green again after the restore. (If the decrypt-rewrite step does not match the file's shape, make the edit by hand with `sops -e` and confirm the gate goes red — a gate never observed to fail is not evidence.)

- [ ] **Step 4: Wire it into the gates**

In the `Makefile`: append `open-webui-oidc-check` to the `.PHONY` list on line 16; append it to the `check` prerequisite list after `grafana-oidc-check`; and add the target after the `grafana-oidc-check` target:

```make
# open-webui-oidc-check: the same class of problem as grafana-oidc-check, with one failure mode the
# others do not have. open-webui's role mapping is configured against a `groups` claim, and with role
# management enabled a missing or unmatched claim is a 403 rather than a fallback role - so a dropped
# `profile` scope, or OAUTH_ALLOWED_ROLES left at its `user,admin` default, locks every non-admin out
# of a login page that still looks perfectly healthy. Reads Secrets, so a local gate, not a CI one.
open-webui-oidc-check:
	@python3 tools/open-webui-oidc-check.py apply
```

- [ ] **Step 5: Verify the whole local gate set**

```bash
make check
```

Expected: `check: all offline gates passed`, with `db-url-check: 2 PG URL reference(s) checked` and `open-webui-oidc-check: … 0 mismatch(es)` in the output.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "tools: open-webui-oidc-check — four copies of one client, and the wiring that reads them"
```

---

### Task 9: Runbook and the repo's own map

**Files:**
- Create: `docs/open-webui-runbook.md`
- Modify: `AGENTS.md` (layout line for `50-apps`, and the gate paragraph)

**Interfaces:**
- Consumes: everything above.
- Produces: the next person's answer to "where is the data", "can I rotate this", and "why is this user 403".

- [ ] **Step 1: Write the runbook**

Create `docs/open-webui-runbook.md` with these sections, each stated as fact with the file or line it comes from:

```markdown
# open-webui runbook

Design and evidence: docs/superpowers/specs/2026-10-20-titan-open-webui-design.md.

## 1. Where the data actually is
Postgres `open_webui` in the shared CNPG cluster (users, roles, chats, prompts, knowledge metadata,
API keys, the model connection, encrypted OAuth sessions) — covered by the ScheduledBackup and the
PITR drill in authentik-runbook §… . The PVC `open-webui-data` holds `uploads/` and `vector_db/`;
the vector index is rebuildable, uploads are not, and neither is in any backup.

## 2. WEBUI_SECRET_KEY — the one not to rotate casually
It signs session JWTs and is `OAUTH_SESSION_TOKEN_ENCRYPTION_KEY`. Rotating it orphans every stored
OAuth token and logs everyone out. It lives only in `apply/10-secrets/open-webui-secrets.yaml`.
The reason it is set at all: without it, start.sh generates one into the container layer on every
boot. Casa still has that bug; its log says so.

## 3. Who may sign in, and as what
authentik decides. First user ever = admin (utils/oauth.py:1598-1607), regardless of env.
`authentik Admins` → admin; any other authentik user → user (`OAUTH_ALLOWED_ROLES=*`). A user who is
in neither gets a 403, not a pending account — role management denies. Record who the first admin was
and when, here:
- (fill in at first sign-in)

## 4. The callback path, and narrowing the blueprint
Both `/oauth/oidc/callback` and `/oauth/oidc/login/callback` are registered because open-webui picks
one with url_for over two same-name routes. After the first real login, record which one appeared and
delete the other from authentik/blueprints-open-webui.yaml, then re-run the setup script with FORCE=1
and `make open-webui-oidc-check`.
- observed on the wire: (fill in)

## 5. Forcing the blueprint
Mounting is not applying. `ak apply_blueprint` from the worker, or the UI, or wait for the hourly
discovery. docs/authentik-runbook §5.

## 6. Verifying a change
make check; then: Database/Databaserole phase, pod Running, `titan-tls` present in `open-webui`,
`curl -sI https://open-webui.titan.arrieta.eu`, admin login lands, non-admin login lands, and
`kubectl -n open-webui delete pod` leaves the session and the stored token intact — that last one is
the proof §2 matters.

## 7. Not proven / not done
uploads unbacked; the non-superuser role proven only by a successful migration run; the llama.cpp
endpoint reachable from the LAN, not proven from a pod.
```

- [ ] **Step 2: Update `AGENTS.md`**

In the `## Layout` block, extend the `apply/50-apps/` line to name open-webui beside authentik and coder, and in `## Before committing` add one sentence after the `grafana-oidc-check` mention:

```markdown
`open-webui-oidc-check` is the same shape one app further on, with one extra failure mode: open-webui's
role mapping reads a `groups` claim, and with role management enabled a missing or unmatched claim is a
403 rather than a fallback role — so a dropped `profile` scope or `OAUTH_ALLOWED_ROLES` left at its
default locks every non-admin out of a login page that still looks healthy. `db-url-check` is
reference-driven across both `HelmRelease` and `Deployment` env, so a tree with no references reports
zero instead of passing vacuously.
```

- [ ] **Step 3: Verify and commit**

```bash
make leak-check
git add -A && git commit -m "docs: open-webui runbook, and the gate list catches up"
```

---

### Task 10: Full gate run, push, and the live checks

**Files:** none.

**Interfaces:**
- Consumes: the whole branch.
- Produces: an updated PR and a list of live checks only the operator can run.

- [ ] **Step 1: Full local gate set**

```bash
cd /home/coder/k8s-titan
git add -A
make check
make dry-run DRYRUN_CONTEXT=titan 2>&1 | tail -5
```

Expected: `check: all offline gates passed`. `dry-run` uses the read-only `titan` context and is expected to be Forbidden — the spec says so; report the skip rather than pretending the check ran.

- [ ] **Step 2: Push to the existing PR — only after explicit operator confirmation**

```bash
timeout 60 git push origin docs/open-webui-spec
```

- [ ] **Step 3: Live checks after merge (operator, needs admin where noted)**

```bash
kubectl -n databases get database,role postgresql.cnpg.io 2>/dev/null | grep open
kubectl -n open-webui get pvc,deploy,pod
kubectl -n open-webui logs deploy/open-webui | grep -iE 'alembic|migrat|error' | head
kubectl -n open-webui get secret titan-tls
curl -sI https://open-webui.titan.arrieta.eu | head -1
kubectl -n open-webui delete pod <pod>   # then: session survives, no InvalidToken in the new log
```

Record the results in the runbook §3 and §4 placeholders, and narrow the redirect URIs per §4.

## Self-review notes

- Spec coverage: §4 layout → Tasks 1, 2, 5, 6, 9. §5 database → Tasks 2, 4, 7. §6 `WEBUI_SECRET_KEY` → Tasks 4, 8, 9. §7 OIDC → Tasks 3, 4, 6, 8. §8 workload/reloader/reflector/storage → Tasks 1, 5. §9 accepted risks → runbook §7. §10 verification → Tasks 5, 8, 10.
- Placeholder scan: the only intentional blanks are the runbook's "fill in at first sign-in" fields, which are blanks the operator fills after a live event, not gaps in this plan.
- Type consistency: `open_webui` (Postgres) vs `open-webui` (Kubernetes) is used consistently; the Secret names `open-webui-secrets` / `open-webui-db-credentials` / `authentik-open-webui-blueprint` and the blueprint key `open-webui.yaml` appear identically in Tasks 3, 4, 6 and 8.
