# Mealie on titan — design

Date: 2026-10-22. Implements: Mealie (recipe manager) in namespace `mealie`, Postgres in the shared
CNPG cluster, sign-in through authentik, AI recipe import pointed at the existing LAN model server.

## 1. Why it moved here from casa

Casa already has a Mealie (`apply/50-apps/casa/mealie.yaml` in k8s-casa) and it was scaled back to 1
replica on 2026-10-22 to use the AI importer. Two things came out of that work and both point here.

**Casa's Mealie has never authenticated against authentik.** The ConfigMap sets
`OIDC_AUTH_ENABLED: "true"`, and the startup log says:

```
--------==OIDC==--------
Enabled: False
Reason: Missing required values for ['OIDC_CLIENT_SECRET']
```

`git log --all -p -- apply/01-secrets/casa/mealie-secrets.yaml | grep -c OIDC_CLIENT_SECRET` returns
**0** across the entire history: `OIDC_CLIENT_ID`, `OIDC_CONFIGURATION_URL` and the ConfigMap flags all
arrived together in `3a04fb9 "Add mealie"` and the secret half was never written. So the casa instance
has only ever used its own password table, and nobody had that password. Titan is where the fleet's
identity provider lives and where every other SSO'd app already is, so the app goes here.

**The AI importer cannot be configured from git on either cluster.** Mealie reads its AI provider
(`base_url`, `api_key`, model) from rows in its own Postgres, created in Group Settings → AI. There is
no env var: `mealie/core/settings/settings.py` on `mealie-next` has no AI or OpenAI settings at all.
That is a named GitOps gap, recorded in §5 rather than papered over.

## 2. Decisions

| # | decision | why |
|---|---|---|
| D1 | own namespace `mealie`, stays in the shared `apps` stage | Fails the §3.1 admission test of `2026-10-19-titan-app-scale-out-design.md` on three counts at once — own public hostname, own Secret set, own database — so it gets a namespace. §3.2 keeps it in `apps`: two hand-written manifests, no bulk authored here, so the freeze-a-neighbour risk is the accepted one, not a new one. |
| D2 | Postgres in the shared CNPG cluster, not sqlite | sqlite lives on the PVC, and **the PVC is not backed up** — the generic PV stream is still deferred. Mealie's own instance in casa holds ~116 KiB of user data, which is exactly the size of the loss that goes unnoticed until a restore is needed. `Database`/`DatabaseRole` in `databases`, same shape as open-webui's. |
| D3 | authentik OIDC via a blueprint Secret, mounted by the HelmRelease | authentik ships no CRDs; a blueprint is the only declarative path. Same shape as open-webui's, including the Secret-not-ConfigMap rule (it carries a client secret) and the mount list, because a blueprint that is never mounted is indistinguishable from one never written (`docs/authentik-runbook.md` §5). |
| D4 | `OIDC_REQUIRES_EMAIL_VERIFICATION: "false"` | Not defensive — load-bearing. Mealie v3.21.0 turned this on by default (`OIDC_REQUIRES_EMAIL_VERIFICATION: bool = True`) and authentik's managed email scope mapping returns `"email_verified": False`, which is already why coder carries `CODER_OIDC_IGNORE_EMAIL_VERIFIED` (`authentik/blueprints-coder.yaml`, `docs/authentik-runbook.md`). Left at the default, every login is refused and the reason appears only in Mealie's log. Defensible because the issuer is this cluster's own authentik, whose addresses an admin sets rather than users self-asserting. |
| D5 | `ALLOW_PASSWORD_LOGIN: "false"`, `ALLOW_SIGNUP: "false"`, `OIDC_SIGNUP_ENABLED: "true"` | The Mealie equivalent of open-webui's `ENABLE_LOGIN_FORM=false`: one door, and it is authentik's. The first authentik user to sign in becomes Mealie's owner. |
| D6 | `OIDC_ADMIN_GROUP: authentik Admins`, `OIDC_USER_GROUP` unset | Matches the fleet posture — grafana and open-webui both map that same group, and open-webui's `OAUTH_ALLOWED_ROLES="*"` is the same "any authenticated user, admins from the admin group" decision. Setting `OIDC_USER_GROUP` to a group that does not exist in authentik locks everyone out while the login page still looks healthy. |
| D7 | image pinned `v3.29.0` | Fleet rule, never `:latest`. Import with AI landed in v3.23.0; v3.21.0 is the release that introduced the D4 requirement. |
| D8 | a new gate, `make mealie-check` | The OIDC client exists in three places and the mount in a fourth — the coder and open-webui lesson. It also compares the database password across two namespaces, which **no existing gate does**: `db-url-check` is reference-driven on `DATABASE_URL`/`PG_CONNECTION_URL` and Mealie takes `POSTGRES_*`, so the generic gate never looks at this app. |
| D9 | probes on `/g/home` | Casa's Mealie has been liveness-probing that path on the same major version, Ready, zero restarts — a known-good unauthenticated 200 rather than a guessed one. Budgeted as a startupProbe because Mealie runs Alembic against Postgres at start. |

## 3. Files

    authentik/blueprints-mealie.yaml              reviewed template, ${...} placeholders
    scripts/setup-mealie-secrets.sh               mints 3 values, writes 3 encrypted Secrets
    apply/10-secrets/authentik-mealie-blueprint.yaml   rendered blueprint (ns auth)
    apply/10-secrets/mealie-db-credentials.yaml        CNPG role credential (ns databases)
    apply/10-secrets/mealie-secrets.yaml               Mealie's env (ns mealie)
    apply/50-apps/mealie/mealie-db.yaml           Database + DatabaseRole (ns databases)
    apply/50-apps/mealie/mealie.yaml              PVC + Deployment + Service + Ingress (ns mealie)
    tools/mealie-check.py                         the agreement gate

Plus the four wiring edits every new app needs and every one of which is silently inert if missed:
`00-bootstrap/namespaces.yaml`, `40-certificates/titan-wildcard.yaml` (BOTH reflector annotations),
`20-infra/reloader/reloader.yaml` (`watchGlobally: false` makes that list the whole scope), and the
`authentik` HelmRelease's blueprint mount plus its worker reload annotation.

## 4. What is in Postgres and what is on the PVC

Postgres (`mealie`, base backups + WAL to S3): users, groups, recipes, the AI provider rows, the
OIDC-linked identities. The PVC (`local-path-retain`, 5Gi): recipe photos and uploads, Mealie's own
backups, and log rotation. Casa's instance oscillates between 29 and 38 MiB and cannot exceed it —
`mealie.log` plus `.1`–`.3` at ~9.6 MiB each is a ~38 MiB ceiling — so the growth term here is photos,
not the app's own footprint. **Photos are not backed up.** Named exposure.

## 5. The AI importer — what to type, and why the endpoint is reachable

After the first login, Group Settings → AI, add a provider:

| field | value |
|---|---|
| Base URL | `http://192.168.0.29:8731/v1` — the `/v1` is required, Mealie does not append it |
| API key | any non-empty string; Mealie refuses to save without one and the endpoint ignores it |
| Model | `halogen-qwen3.8-flash-next` |
| Set as | both the default provider and the image provider (the model is text+image → text) |

No audio provider, so importing a recipe from a video URL stays unavailable.

**Reachability from titan.** `192.168.0.29` is on casa's LAN, not titan's. It is reachable from titan
pods because the OPNsense WireGuard peer advertises `192.168.0.0/24` — the same route that makes
`192.168.0.42` (casa's Loki) reachable from a titan pod, measured and recorded in
`apply/20-infra/monitoring/promtail.yaml`. That is an argument by analogy with a measured neighbour,
**not a measurement of `:8731` from titan** — see §7.

**Reasoning, measured on that endpoint.** The model is a reasoning model: it emits `reasoning_content`
alongside `content`, and with a small `max_tokens` it returns `finish_reason: length` with **empty
content** because every token went to reasoning. Two parameters disable it, both verified to return
`reasoning_tokens: 0`:

```json
"chat_template_kwargs": {"enable_thinking": false}
"reasoning_effort": "none"
```

Mealie sends neither — it has no way to attach extra body parameters to a provider — so disabling
reasoning is a server-side decision, not a Mealie one. It is not required: with reasoning left on, the
endpoint answered correctly for `response_format: json_object` **and** for `json_schema` with
`strict: true`, which is the failure mode that usually kills local models in Mealie and Tandoor.

## 6. Post-merge, in order

1. Force the blueprint (authentik UI, or `ak apply_blueprint` in the worker) rather than waiting for
   the worker's hourly discovery. Mounting is not applying — `docs/authentik-runbook.md` §5.
2. Confirm `titan-tls` was reflected into the `mealie` namespace. Both wildcard annotations were
   edited; with only one of the two changed, the Certificate stays Ready and the Secret never appears.
3. Sign in as the first authentik user. That user becomes Mealie's owner — do it deliberately.
4. Add the AI provider from §5, then import one recipe from a URL and one from pasted text.
5. Narrow nothing in the blueprint: both redirect URIs are documented, unlike open-webui's two
   candidate callback paths.

## 7. Not proven

- **`192.168.0.29:8731` has not been measured from a titan pod.** The LAN route is documented and a
  neighbouring address on it was measured; this port was not. If the import fails with a connection
  error, this is the first suspect, and the fix is a mesh route, not a Mealie change.
- **`/g/home` as a probe path** is copied from casa's working Deployment, not from Mealie's docs.
- **The first-startup Alembic run against CNPG** with a non-superuser role is an argument from absence,
  as open-webui's records. If a migration needs more, the pod fails loudly and the fix is a deliberate
  `superuser: true` with its own note.
- **`authentik Admins` is assumed to be the group name** because grafana and open-webui already map it.
  If it has been renamed in the UI, admins land in the ordinary-user seat and nothing complains.
- Casa's public Mealie host (`meals.home.arrieta.eu`) returns a 404 for every path from this workspace,
  including `/`. Not investigated; it does not affect titan, but it means casa's instance could not be
  probed from here and the in-cluster pod was healthy instead.
