# VPS → titan auth cutover — one named mechanism per host

Issue **#103**. Its *Done when* is *"each VPS-protected host has a named auth mechanism on titan, and
`bearer-auth-service` is either reproduced or explicitly retired."* This file is that record: a host
list with an answer against each row, rather than a decision inherited by silence.

Two sources, and neither one alone is enough:

- **`docs/superpowers/specs/2026-10-30-vps-auth-probe.md`** (T0a) — unauthenticated `curl` against every
  hostname the live VPS cluster routes. This is the only thing that ever established what is actually
  gated, because the gate lives in authentik's database and not in git.
- **`kubectl --context vps get ingress -A`** — ten Ingress objects. Nine of the gated hosts appear on
  exactly one of them: `auth/ak-outpost-reverse-proxy-outpost`, which authentik generates from
  UI-created state. **Git shows no Ingress for those nine**, which is why three separate migration
  tickets (#107, #110, and the original read of #103) each concluded from the tree that the app was
  unpublished. It was. Read the probe before trusting any git-only claim about publication.

## The answer, per host

| VPS host | VPS mechanism | titan host | mechanism on titan | named where |
|---|---|---|---|---|
| `tesla.v.arrieta.eu` | outpost | `tesla.titan` | forwardAuth `apps-teslamate-auth` → tesla outpost, group-gated | `apply/60-tesla/teslamate.yaml`, `apply/50-apps/auth/tesla-outpost-blueprint.yaml` |
| `vert.v.arrieta.eu` | outpost | `vert.titan` | same shared outpost | `apply/50-apps/vert-sh/vert-sh.yaml` |
| `bentopdf.v.arrieta.eu` | outpost | `bentopdf.titan` | same shared outpost | `apply/50-apps/bentopdf/bentopdf.yaml` |
| `investment-agent.v.arrieta.eu` | outpost | `investing-agent.titan` | same shared outpost | `apply/50-apps/investing-agent/investing-agent.yaml` |
| `auth.v.arrieta.eu` | the IdP | `auth.titan` | authentik itself | `apply/50-apps/auth/authentik.yaml` |
| `grafana.v.arrieta.eu` | Grafana's own login | `grafana.titan` | forwardAuth, `observability` application | `apply/50-apps/grafana/grafana.yaml` |
| `openwebui.v.arrieta.eu` | **none — answered 200** | `open-webui.titan` | OIDC via authentik, app-native | `apply/50-apps/open-webui/open-webui.yaml` |
| `llm.v.arrieta.eu` | bearer forwardAuth | `llm.titan` | bearer forwardAuth, **stricter than the VPS's** | `apply/50-apps/llm/llm.yaml` |
| `hass.v.arrieta.eu` | outpost, but **answered 400 on every path** | `hass.titan` | **deliberately open**, HA authenticates natively | `NOT_PROXY_GATED` in `tools/ingress-auth-check.py` |
| `chiclana-hass.v.arrieta.eu` | **none — answered 200** | `chiclana-hass.titan` | **deliberately open**, same reason | same `NOT_PROXY_GATED` |
| `prometheus.v.arrieta.eu` | outpost | — | **no destination.** Titan runs no Prometheus; casa is the alerting brain | `AGENTS.md`, `docs/titan-metrics-scrape.md` |
| `traefik.v.arrieta.eu` | Traefik dashboard auth | — | **no destination.** The dashboard is not published on titan | — |
| `databasus.v.arrieta.eu` | **none — 200** | — | retired, #113 | — |
| `tr.v.arrieta.eu` | **none — 200** | — | retired, #106 | — |
| `kanghuru.v.arrieta.eu`, `kanghuru.es` | **none — public product** | — | parked, #111 — the domain is the blocker | #111 |
| `uptime.v.arrieta.eu` | outpost | **?** | **UNKNOWN — see below** | nothing |
| `llm-chat.v.arrieta.eu` | outpost | **?** | **UNKNOWN — see below** | nothing |
| `agent0.v.arrieta.eu` | outpost | **?** | **UNKNOWN — see below** | `../k8s-techdelivery unused/agent-zero.yaml`, not applied |
| `q1.v.arrieta.eu` | outpost | **?** | **UNKNOWN — see below** | nothing |

Every row that has a titan host has a named mechanism, and every row that is deliberately open is
enforced by a gate rather than by prose. **That half of #103's done-when is met.**

## The four hosts nobody has an answer for

`uptime`, `llm-chat`, `agent0` and `q1` are gated by authentik on the VPS and appear **nowhere in
either repo** — `agent0` excepted, whose workload sits in `unused/agent-zero.yaml` and is not applied.
Re-probed 2026-11-06, all four still answer:

```
uptime.v.arrieta.eu     302 -> /outpost.goauthentik.io/start
llm-chat.v.arrieta.eu   302 -> /outpost.goauthentik.io/start
agent0.v.arrieta.eu     302 -> /outpost.goauthentik.io/start
q1.v.arrieta.eu         302 -> /outpost.goauthentik.io/start
```

**What the 302 proves, and what it does not.** It proves authentik holds an Application whose ingress
covers that host — the outpost will not claim a host it does not own. It does **not** prove a backend
exists: the outpost gates first and only then proxies to the provider's internal host, so a host whose
application is alive and whose workload died months ago looks identical from outside. `postgresus`
(#114) is the precedent for exactly that shape — app gone, configuration still dutifully running.

So these are not four migrations to plan. They are **four questions to answer before the box is
released**, and the only place the answer lives is authentik's database:

```sql
select a.name, a.slug, p.internal_hosts
  from authentik_core_application a
  left join authentik_providers_proxy_proxyprovider p on p.id = a.provider_id
 where a.slug in ('uptime','llm-chat','agent0','q1')
    or p.internal_hosts ~ 'uptime|llm-chat|agent0|q1';
```

If `internal_hosts` names a workload that is not deployed, the row is dead config and the Application
gets deleted. If it names something live, it is a workload with no ticket and it needs one. **Nothing
in this epic currently accounts for these four**, and switching the box off takes them with it silently
— which is the failure mode §9 of the migration plan warns about, arriving through the auth side
instead of the traffic side.

## `bearer-auth-service`: reproduced, and the open question about it was based on a false premise

Titan has its own at `apply/50-apps/llm/llm.yaml` — a throwaway nginx answering 200/401 behind a
Traefik `forwardAuth`, same shape, same token.

The migration plan's R2 asked to *"settle the `X-Auth-User` / `X-Auth-Email` response headers the VPS
one emits and titan's does not: either they are needed, in which case titan gains them, or they are
not."*

**Neither is emitted, on either cluster.** The VPS auth endpoint is the whole of it:

```nginx
location / {
  if ($http_authorization ~* "Bearer ${BEARER_TOKEN}") {
    return 200;
  }
  return 401;
}
```

No `add_header`, no `proxy_set_header` — a bare 200 or 401. The VPS `Middleware` does declare
`authResponseHeaders: [X-Auth-User, X-Auth-Email]`, but that field names headers to *copy from the auth
response into the forwarded request*, and the auth response carries neither. **It is decoration that
has never done anything.** Titan omitting it is not a regression and titan gains nothing; spec §2.1's
`llm` row stays "none".

**Titan's check is also strictly stronger, which matters for retiring the VPS one.** The VPS matches
with `~*` — case-insensitive, unanchored, and with the token interpolated into a regex, so any regex
metacharacter in the token changes what matches. That is techdelivery#166: *"llm.v.arrieta.eu's bearer
check cannot accept the token it stores."* Titan compares with nginx `=` — exact, case-sensitive,
anchored — and its file records the measured truth table, including that a `Bearer <key> <trailing
garbage>` request passes on the VPS and does not pass here. **Retiring the VPS frontend loses nothing
and closes a known defect.**

## The authentik retirement gate — checked 2026-11-06, and it needed checking

R2 — retiring the VPS authentik, its outpost and `bearer-auth-service` — was gated on one claim: the
operator's statement that the VPS authentik *"was never wired to groups or apps correctly — only the
operator had an account."* Load-bearing, because retiring an identity provider takes every account on
it with it. **It has now been run**, by the operator, against the VPS authentik database. It cannot be
run from a workspace: the `vps` kube context here is the read-only `k8s-reader` identity — no
`pods/exec`, no `services/proxy`.

**The SQL as originally written in this file did not run.** Neither `uid` nor `is_superuser` exists on
`authentik_core_user`. That is worth stating rather than quietly fixing: the query was written into the
migration plan and executed by nobody until now. What actually works:

```sql
select type, count(*) as n,
       count(*) filter (where last_login is null) as never_logged_in
  from authentik_core_user group by 1 order by 1;

select name from authentik_core_group order by 1;

select username, path, last_login from authentik_core_user
 where type = 'internal' order by last_login nulls first;
```

### Result

| type | n | never logged in |
|---|---|---|
| `internal` | 3 | 2 |
| `internal_service_account` | 2 | 2 |

Groups: `Users`, `authentik Admins`, `authentik Agent-Users`, `authentik Read-only`.

The three `internal` accounts are `AnonymousUser` (Django/authentik's placeholder for unauthenticated
policy evaluation — a real row, never logs in by design), `javierarrieta` (the operator) and `akadmin`
(authentik's bootstrap admin, created when `AUTHENTIK_BOOTSTRAP_PASSWORD` is set). **No third human.
The claim holds and R2's identity gate is clear.**

### The enum, because the obvious reading is the wrong one

`internal` does **not** mean "authentik's own system user". From `authentik/core/models.py`:

```python
class UserTypes(models.TextChoices):
    INTERNAL = "internal"                                  # locally-managed users — humans
    EXTERNAL = "external"                                  # federated
    SERVICE_ACCOUNT = "service_account"                    # user-created
    INTERNAL_SERVICE_ACCOUNT = "internal_service_account"  # "such as outpost users"
```

authentik's own docs put it as *"Internal users: typically workforce identities... employees and
partners"*. So **`internal` is the human-type bucket**, and reading it as "the system user" — which is
the natural guess — turns a real finding into a false all-clear. The `ak` user is one of the two
`internal_service_account` rows, alongside the outpost's token owner; both have null `last_login`,
which is expected, since service accounts authenticate by token and never run a login flow.

### The gate in this file was miscalibrated, and would have blocked a correct retirement

The rule as first written was *"1–2 users and ~0 groups means the claim holds."* **The VPS came back
with 5 users and 4 groups** — which under that rule is a refusal.

But 5 and 4 are **exactly what a clean, single-human authentik contains**: `AnonymousUser` + one human
+ `akadmin` + 2 internal service accounts, and three shipped groups (`authentik Admins`,
`authentik Agent-Users`, `authentik Read-only`) plus one. Only `Users` is not shipped. The raw counts
were noise; the `type` breakdown was the answer. **So the gate is now type-based, not count-based:**

> Retire when `select type, count(*) from authentik_core_user group by 1` shows `internal` rows only
> for people who have a named destination on titan's authentik. `internal_service_account` rows are
> authentik's own machinery and retire with it. A count, on its own, proves nothing either way.

Anyone re-running this on another box and seeing 5/4 should not treat that as a finding.

### `akadmin` is the working admin, on both clusters — which is a live risk, not history

The one account on the VPS authentik with a real `last_login` is **`akadmin`** (2026-10-28). The
operator's own `javierarrieta` has **never logged in** — the Google identity source was never bound
successfully, so the bootstrap admin is what got used instead. That is the concrete shape of "never
wired correctly", and it is also why the personal account exists at all: something created it, nothing
used it.

**The consequence reaches titan.** `docs/authentik-runbook.md` records that titan's authentik also has
an `akadmin`, created through the browser flow on 2026-10-05, and titan's Google login is a sops
blueprint (`apply/10-secrets/authentik-google-blueprint.yaml`) that is mounted and checked by
`blueprint-mount-check` — but **mounted is not working**, and the only place this failure mode has ever
been observed is the box where it silently never worked. So before the VPS is released:

> **Prove you can log into titan's authentik with Google, not just with `akadmin`.** Several apps —
> Grafana, open-webui, Sure — map roles from a `groups` claim that originates in that source's group
> mapping. If the source cannot actually authenticate, those mappings have nothing to map, and the
> evidence would be a 403 on an app that looks healthy rather than a red release.

R2 remains gated on R1, because the VPS authentik's own database lives on the Postgres that R1 retires.
