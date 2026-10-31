# VPS → titan workload migration — design

**Date:** 2026-10-30. **Tracks:** [javierarrieta/k8s-techdelivery#153](https://github.com/javierarrieta/k8s-techdelivery/issues/153).
**Builds on:** `k8s-techdelivery/apply/20-infra/vps-to-titan-migration.md`, which is the measured
pre-flight for #153. This spec does not repeat its measurements; it cites them as F-A … F-I and
supersedes it only where §1 says so.
**Base:** `k8s-titan origin/main@22c5e06` (last-fetched state — no fetch was possible from this
workspace, see §9).
**Repos cited:** `td/` = `k8s-techdelivery` (the VPS), `titan/` = `k8s-titan` (the destination),
`tf/` = `public-dns-tf`. A bare `apply/…` path is ambiguous between the two Kubernetes trees, so
every citation below carries its repo prefix.

## Goals

What this plan delivers on its own, before the box is released:

- **Blast radius moves off a dying host.** Thirteen workloads stop depending on a VPS that is
  scheduled for release, without waiting for the one thing (mail) that actually gates the release.
- **Auth is net-new on titan.** Most of these apps reach the internet with no proxy gate today; on
  titan they get an authentik forwardAuth gate that `ingress-auth` enforces mechanically.
- **It unblocks the mail move** by proving the migration path — secrets re-encryption, CNPG
  consolidation, one-shot PVC sizing, the DNS-01 issuer move — on cheap workloads first.

Non-goals are in §8.

## 0. What this decides

Five decisions, recorded in §1. The pre-flight left exactly **two** decisions open, and said nothing
downstream was worth starting until both were made. This spec closes **one** of them — which authentik
is authoritative (D3). The other, the mail destination, **stays open** and is still the thing gating
#153's release (§8).

This spec also **adds two decisions of its own**. D5 settles traefik ownership, which F-B demanded be
chosen before any Ingress-bearing workload moved and which the first draft left inside a ticket. And D1
declines the DNS question rather than answering it: by not re-pointing `*.v.arrieta.eu`, it takes DNS off
the critical path for every app except kanghuru. That is a decision with a cost (§1), not an absence of
one.

It also corrects one finding in the pre-flight (§3), and it does **not** make the VPS releasable.
Mail stays, and mail is the reason the box exists after this plan completes. §8 is the out-of-scope
list; §9 is what is not proven.

The tickets themselves are not in this document, and **this spec does not open new ones**. The
workload tickets already exist on `javierarrieta/k8s-titan` as **#99–#116**, all open, all labelled
`migration`, tracked by **#116**. An earlier draft of this spec invented its own T-numbered ticket set
and that was wrong — the existing issues are more measured than the draft was, and in three places they
contradict it (below). Ticket identifiers here are the issue numbers; the plan keeps a short internal
shorthand and maps it in its §0.

What this spec adds on top of #99–#116 is small and named: the T0a probe and the identity-parity exit
criterion (§3, §3.3, posted to #103), the strix `hostPath` finding (§ posted to #115), and D5's answer
to #100 with a correction #100 itself supplies.

**Three places the existing issues proved this spec wrong**, corrected here rather than left in:

- **`unbound` is not a non-ticket.** This spec said it is mailserver's and stays put. #108's point is
  that the pinned `clusterIP` is an immutable hard dependency, so unbound must move **before**
  mailserver and blocks that move. Being mailserver's dependency is the reason it has a ticket, not the
  reason it lacks one.
- **`investing-agent` and `gatus` are not done.** #105 records a 10 Gi PVC holding "state nothing else
  has" and a running two-process pod; #109 records that gatus's entire probe list is assertions about
  the *VPS's* network view and cannot be copied. Both were marked done here on `replicas: 0`, which is
  evidence about a Deployment and not about a volume.
- **D5 was too strong.** #100 notes the VPS's middleware annotation is
  `traefik-system-bearer-auth@kubernetescrd` — coupled to the VPS's `traefik-system` namespace, where
  titan's traefik does not live. So migrated middlewares are **rewritten, not copied**. D5's claim that
  no ownership change is needed survives; "changes nothing traefik-side" did not. See D5.

### Why the plan is smaller than the pre-flight implies

Seven of the VPS workloads are already running on titan. Two of them are provably finished —
`teslamate` and `investing-agent` are `replicas: 0` in the VPS tree (`apply/50-apps/apps/teslamate.yaml:26`,
`investing-agent.yaml:34`). The other five (`grafana`, `gatus`, `llm`, `open-webui`, `promtail`) are
live in both clusters. Per D4 below they are **done**, so they generate no migration tickets.

That removes an entire wave from #153's shape and is the single largest reduction here.

## 1. The decisions

D1–D4 were made by the operator on 2026-10-30. D5 is decided here on measured evidence and needs the
operator's sign-off (§9). Each row carries both what the decision buys and what it costs, because a
consequence column written only in the currency of deleted work is how a decision becomes
indistinguishable from a restatement.

| # | decision | what it buys | what it costs |
|---|---|---|
| **D1** | **No DNS cutover.** `*.v.arrieta.eu` is not re-pointed at titan. Clients of migrated apps adopt a new `*.titan.arrieta.eu` URL. | Deletes pre-flight item F-I from the critical path, and deletes the coordinated-cutover window from every ticket. Also means **zero DNS work and zero new certificates** for every migrated app except kanghuru: `tf/records_public.tf:13` already declares `titan = { type = "A", target = local.titan_ip, wildcard = true }` → `<OVH_PUBLIC_IP>`, and `titan/apply/40-certificates/titan-wildcard.yaml` already issues `*.titan.arrieta.eu` as `titan-tls`. A new host served by that wildcard is a new Ingress rule and nothing else. | 13 app URLs change, and §2.2 shows the client list is not fully known. There is **no forcing function**: the old names keep working until the box dies, so a missed consumer breaks silently much later with no visible link to this migration. Rollback is trivial (point clients back), which is the strongest argument for D1 and the reason its cost is survivable. |
| **D2** | **`kanghuru.es` is the one exception to D1, and it migrates last.** It is a public product domain with its own OVH credential, its own DNS-01 issuer and its own wildcard cert. | One ticket carries a `public-dns-tf` change: re-point `kanghuru.es` / `www.kanghuru.es` at `<OVH_PUBLIC_IP>`, and move the `le-prod-kanghuru` issuer, `kanghuru-es-cert` and `kanghuru-ovh-secrets` to titan. Sequenced last so the path is proven before the only public-facing name change. | The one ticket that needs a second repo, `terraform` state, and OVH write access — and the only one where a stale DNS-01 challenge node can actually bite, because kanghuru has its own `Certificate` rather than sharing the wildcard (§5). |
| **D3** | **titan's authentik is the authority.** Migrated apps are enrolled there; the VPS instance retires. Default pattern is an authentik **proxy provider + Traefik `forwardAuth` Middleware**, per app. | No user-directory lift-and-shift, and no imported authentik objects. Per-app auth is net-new hardening on titan, not a migration. See §3, which is where the correction to the pre-flight lives. | Groups and policies are **re-authored in titan blueprints from the T0 inventory** — that is a policy migration under a different name, and it is mandatory work, not a free pass. It also presumes identity parity (§3.3), which is not yet proven. |
| **D4** | **The seven already-replicated workloads are done**, with two accepted losses. | Deletes an entire decommission wave from #153's shape — the single largest reduction here. | No standalone decommission *wave*; teardown is folded into whichever ticket replaces each workload (T7, T9, T10) or into a retirement ticket (R1–R3). Accepted losses are in §2.1, and three of them are `unmeasured` rather than none. |
| **D5** | **titan keeps k3s's bundled traefik; the migration changes no traefik *ownership*.** The VPS's Flux traefik manifests are not copied. Closes #100's choice. | Deletes #100 / pre-flight F-B from the critical path. The migration needs only `Middleware` CRs plus Ingress annotations, and titan already runs that surface in production: `apps/teslamate-auth`, `observability/observability-grafana-auth` and `llm/llm-bearer-auth` are live `traefik.io/v1alpha1` `Middleware` objects, and five Ingresses already use `router.middlewares` with a `websecure` entrypoint pin. `ingress-auth` already enforces correct use of that surface. | **Not a no-op.** Per #100: the VPS annotates `traefik-system-bearer-auth@kubernetescrd`, coupled to a namespace titan does not have, so every migrated `router.middlewares` annotation is **rewritten, not copied**. Titan's own convention is a `Middleware` in the *app's* namespace — adopt that layout, do not port the VPS one. The bundled chart also stays two versions behind the release that fixed F19 (F-B): a titan platform risk with no owner here, recorded in §9 rather than gating nine tickets. |
| **D1b** | **The hostname scheme (#99) is `*.titan.arrieta.eu`, adopted, not re-pointed.** | Closes #99, which was P1 and blocked every Ingress-bearing issue in the epic, and which #99 itself noted is "operator only, nothing here is fixable from a workspace". D1 is the answer; #99 can close with a pointer here. | Every migrated app's FQDN changes, which is D1's cost paid once. |

**D5 is the answer to F-B, not a dodge of it.** F-B's real warning is *do not copy the VPS's traefik
manifests*, because that yields two ingress controllers — the regression #122/#123/#19 exist to
avoid. The spec already honours that. F-B then framed the choice as (a) manage the bundled chart via
`HelmChartConfig` or (b) disable it and let Flux own traefik, but both options assume the migration
must touch traefik's ownership. It does not: the apps consume CRDs k3s already owns and already
works. `HelmChartConfig` appears nowhere in `titan/`, so (a) would itself be net-new platform work
with no precedent in the repo. Choosing (a) or (b) would add unscoped work to unblock nothing.

D3 resolves the pre-flight's open decision *"Which authentik is authoritative"* (§ "The two
decisions, with their inputs"). D1 resolves the other half of F-I. **The mail destination decision
stays open** — it is out of scope (§8) and it is still the thing gating #153's release.

### 1.1 Alternatives considered

**For D1 (no DNS cutover).** Three options were rejected, in descending order of how close they are:

- **Re-point `*.v.arrieta.eu` at titan** — the pre-flight's own default, and the only option that
  preserves every client URL with no client work at all. Rejected because it keeps the VPS in the
  critical path for as long as the cutover is staged, and it makes every migrated app's availability
  contingent on a DNS change to a zone shared with mail. D1's cost (13 URLs change) is paid once and
  then the VPS is out of the picture; this option pays a coordination window to keep a host we are
  trying to delete load-bearing.
- **A VPS-side L7 transition proxy** (Traefik or nginx on the VPS forwarding `*.v.arrieta.eu` →
  `titan.arrieta.eu`). Free to clients, and the VPS survives for mail anyway so the box is available.
  Rejected because it re-couples every release to a proxy on the machine being decommissioned, and it
  keeps the VPS in the request path indefinitely — the opposite of the plan's purpose. It is the right
  fallback if §2.2 shows a client that cannot be migrated.
- **Split-horizon DNS.** Rejected: the clients here are phones, cars and family browsers off-network,
  which split-horizon does not reach.

**For D5.** See the note under the table — (a) and (b) are both rejected in favour of changing
nothing, with the evidence in D5's row.

**For D3.** Keeping the VPS authentik as the authority was rejected: it would keep every migrated app
permanently coupled to a host scheduled for release, and would require titan's apps to reach
cross-site for auth.

## 2. Inventory and disposition

Mailserver and everything mail-coupled is excluded by operator instruction. Three findings changed
this table relative to the pre-flight's inventory:

- **`unbound` is mailserver's dependency — and therefore a ticket (#108), not a non-ticket.** Its only
  consumer in the tree is `td/apply/50-apps/apps/mailserver.yaml:217` (`dnsConfig` →
  `10.43.22.122 # unbound.apps`), and its `Service` **pins** `clusterIP: 10.43.22.122`, which is
  immutable. So the two files must change together and unbound must be running on titan **before**
  mailserver can move. Mail itself is out of scope (§8); the dependency that gates it is not.
- **`bentopdf`, `vert-sh` and `strix` have no Ingress at all** — ConfigMaps, Deployments, ClusterIP
  Services, a CronJob, and no host, no NodePort. They are unreachable from outside the cluster
  today. For those, "auth" is a *reachability* decision, not an auth decision. (#107, #110, #115.)
- **Secrets cannot be copied.** §4.

The **Auth column is provisional until T0 lands.** §3 explains why: the VPS's per-app auth state is
not in git, so no row here can be stated as fact before that inventory exists. Treat each cell as the
expected pattern, to be confirmed or corrected by T0.

| Workload | VPS state | Target on titan | Auth (provisional, see §3) |
|---|---|---|---|
| `home-hass` | Endpoints → external HA | `hass.titan.arrieta.eu`, ns `apps` | forwardAuth |
| `chiclana-hass` | Endpoints → external HA | `chiclana-hass.titan.arrieta.eu`, ns `apps` | forwardAuth |
| `strix-scans` | CronJob + SA + ClusterRole | port the CronJob; close the second-copy question first (plan T6) | n/a — no host |
| `bentopdf` | none, **no Ingress** | host it or retire it — decision is step 1 of its ticket | forwardAuth *if* hosted |
| `vert-sh` | none, **no Ingress** | same question, same ticket | forwardAuth *if* hosted |
| `trading-reports` | 1 Gi PVC | `tr.titan.arrieta.eu`, ns `apps` | forwardAuth |
| `databasus` | 10 Gi PVC + DB creds | `databasus.titan.arrieta.eu` — **or retire**; two DB admin UIs is one too many | forwardAuth |
| `postgres` (bare Deployment) | 6 Gi + 3 Gi backup | merge into titan CNPG as a `Database`/`DatabaseRole` per consumer, then retire | n/a |
| `postgresus-pvc-only` | 1 Gi orphan stub | retire inside the Postgres ticket | n/a |
| `authentik` + `ak-outpost-reverse-proxy-outpost` + `bearer-auth-service` | **imperative DB state** | export (§3) → titan blueprints; retire VPS instance | *is* the auth |
| `kube-prometheus-stack` | 343 days on the VPS | **retire, do not migrate** — titan's Grafana already reads casa's Prometheus over the mesh (`docs/titan-metrics-scrape.md`); re-point casa's scrape targets off the VPS first | n/a |
| `v-arrieta-eu` Certificate | — | dies with the VPS; nothing to do | n/a |
| `kanghuru` | stateless + public domain | **last ticket.** `kanghuru.titan.arrieta.eu` *plus* the D2 DNS/issuer/cert move | forwardAuth |

### 2.1 Marked done, and what that accepts

`replicas: 0` proves a Deployment is stopped. **It says nothing about the PVC behind it**, and three
of these rows were recorded as lossless on that evidence alone. They are now `unmeasured`: the VPS
volume contents have never been inspected, and an unmeasured loss is not a zero loss.

| Workload | VPS state | Titan home | Accepted loss |
|---|---|---|---|
| `teslamate` | `replicas: 0` | `60-tesla/` + own CNPG `Database` | **unmeasured.** The VPS instance accumulated charge/drive history before it was stopped, and that history is rows in the VPS Postgres — the same cluster T10 consolidates. T10 must confirm its DSN before this can be called none. |
| `investing-agent` | **not done — #105.** 10 Gi PVC, own Secret set, a running two-process pod (`hermes gateway` + `hermes dashboard`) | `50-apps/investing-agent/` (app already on titan) | **the 10 Gi volume.** #105 calls it "state nothing else has". The app being replicated does not make the volume replicated; `replicas: 0` on the VPS says nothing about it. |
| `gatus` | **not done — #109.** Stateless, but its whole config is a probe list | `50-apps/gatus/` | **the probe list is not portable.** Every entry is an assertion about the VPS's network view (`icmp://192.168.0.1`, `http://192.168.133.3:8123`, …). Copying it produces a monitor that is confidently wrong about titan. |
| `llm` | Endpoints, serving | `50-apps/llm/`, same two bearer keys | **see plan R2**: the VPS's `bearer-auth-service` also emits `X-Auth-User` / `X-Auth-Email` response headers that titan's does not. If that difference is real it is an accepted loss, not none. |
| `promtail` | DaemonSet | `20-infra/monitoring/` → casa Loki | none — stateless shipper. |
| `grafana` | `replicas: 1` | `50-apps/grafana/`, casa Prometheus datasource | **anything hand-built in the VPS UI.** titan provisions from git with `allowUiUpdates: false`. The imperative surface is wider than dashboards: alerting contact points and notification policies, service accounts and API keys, folders and permissions, dashboard versions. T2 retires the VPS Prometheus, so any alert rules living in VPS Grafana die with it — which compounds F-C rather than sitting beside it. |
| `open-webui` | `replicas: 1`, 5 Gi PVC | `50-apps/open-webui/` + own CNPG `Database` | **the VPS chats and user rows.** titan's instance has its own fresh DB; nothing has been migrated and per D4 nothing will be imported. "Accept the loss" and "do not archive" are different decisions — T10 is already building a dump path, so an archive is nearly free. |

Both explicit losses were put to the operator and accepted on 2026-10-30. They are recorded here so
that a future reader does not "discover" them as an omission during a restore drill. The
`unmeasured` rows are not accepted losses; they are an open question with a capture step in the plan.

### 2.2 Who has to be told — D1's real cost

D1's price is paid by whoever reads the old URL. That list is the load-bearing claim of the whole
plan and it is **not fully known**; the rows marked `unknown` are what T0's inventory and a VPS access
log are for.

| App | Clients | URL change |
|---|---|---|
| `home-hass`, `chiclana-hass` | operator + family phones, and Home Assistant's own configured integrations and automations | needs the family told; **HA companion apps do not follow a 302 to an external IdP** (§3.2) |
| `trading-reports` | operator, plus any outbound webhook the app has been configured with | operator; webhooks must be re-pointed in the source system, not here |
| `databasus` | operator | free |
| `bentopdf`, `vert-sh` | **unknown** — no Ingress, no consumer found in either tree | T7 answers this before any URL exists |
| `strix-scans` | none — no host | free |
| `kanghuru` | **public product users** | cannot be told anything — which is exactly why D2 exists and why it migrates by DNS re-point instead |

Two consequences follow. First, a client that genuinely cannot be migrated is a client that must be
re-pointed, which is F-I work and not zero DNS work — if §2.2 turns up such a client, the transition
proxy in §1.1 comes back from the rejected pile. Second, there is no forcing function: nothing breaks
loudly when a consumer is missed. The plan therefore needs a program-level acceptance step — confirm
near-zero hits per VPS host for a stated window **before** any retirement ticket runs.

## 3. Auth — the mechanism, and the correction this forced

The pre-flight's inventory says the VPS's authentik-coupled objects "move with the authentik
decision", and #153's decision text notes both clusters run `authentik@2026.8.3` so it is "a config
export/import, not a version jump". The first half of that is right and the framing is wrong in a
way that would have made every auth ticket fiction.

**The VPS's per-app auth configuration is not in git.** That half is measured, 2026-10-30, and it is
the only half that is:

- The VPS `HelmRelease` (`td/apply/50-apps/auth/authentik.yaml`, 75 lines) carries **no outpost block
  and no blueprints**. Its only non-default values are `error_reporting`, `server.ingress` for
  `auth.v.arrieta.eu`, and `postgresql.enabled: false` / `redis.enabled: false`.
- `ak-outpost-reverse-proxy-outpost` — Deployment, Service, **Ingress**, and a `-metrics` Service —
  is created by authentik itself from UI-created state. `td/apply/20-infra/cluster-ownership.md:78`
  already records it as bucket 2, `goauthentik.io` holding `spec.*`.
- Of the **eight** `kind: Ingress` objects in `td/apply/` (all under `50-apps/apps/`), exactly one
  carries a proxy-side annotation: `td/apply/50-apps/apps/llm-chiclana.yaml:31` →
  `traefik-system-bearer-auth@kubernetescrd`, and that is a bearer token, not authentik. The other
  seven have no `router.middlewares`. Grafana's authentik block is **commented out**
  (`td/apply/50-apps/apps/grafana.yaml:25-35`).

**What is a hypothesis, not a measurement.** The inference "not in git ⇒ it lives in authentik's
database" has not been tested, and three alternatives are consistent with the evidence above:

1. **Nothing is protected.** An initial read of that evidence says "nothing on the VPS is
   authenticated". That read is probably **wrong** — authentik's embedded outpost generates its own
   Ingresses for each proxy provider's `ingressUrls`, so protection is enforced without ever touching
   the app's own Ingress, and the operator's statement (*"vps uses imperative defined authentik apps.
   most would be reverse proxy protected"*, 2026-10-30) points at exactly that mechanism. But the
   statement is testimony, not measurement.
2. **The gating is imperative cluster state that is not authentik's.** Traefik `Middleware` CRs or
   patched Ingress annotations applied from a shell are cluster state, not authentik-DB state, and a
   DB export would miss them entirely. This is not hypothetical: `td/apply/20-infra/auth/bearer-auth-middleware.yaml:98`
   contains a `forwardAuth` **in git**, so "not in git" was too strong as written.
3. **The gating is network-layer** (ufw, mesh-only) — the mechanism this spec itself invokes for T2.

**Consequence, and it is load-bearing for the ticket set:** if the hypothesis holds, the authoritative
list of which VPS hosts are protected, by which provider, with which groups, lives in the VPS
authentik database, and no ticket can state its auth half accurately without reading it. That is
ticket **T0**, and it is first for that reason. But T0 must be able to *falsify* this, which is why the
plan opens with **T0a**: a per-host unauthenticated `curl -si https://<host>/` recording status and
`Location`. That one read-only table distinguishes all three hypotheses, is cheaper than a DB export,
and is the only thing that can prove the section it gates.

### 3.1 OIDC-by-config, as the operator asked

The instruction was to detect in-app OIDC from each app's own config rather than assume forwardAuth.
Scan run 2026-10-30 over every `env` and `envFrom` key in `td/apply/50-apps/` and
`td/apply/10-secrets/`, matching `oidc|oauth|openid|sso|idp|cas|saml|auth|password`. Denominator:
the thirteen workloads in §2, excluding the seven §2.1 done-rows and mailserver.

| App | auth-shaped config found | pattern |
|---|---|---|
| `open-webui` | `OPENID_REDIRECT_URI=https://openwebui.v.arrieta.eu/oauth/oidc/callback`, `ENABLE_OAUTH_SIGNUP=true`, `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true`, plus `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET` / `OPENID_PROVIDER_URL` in `td/apply/10-secrets/open-webui-secrets.yaml` | **in-app OIDC** — and already on titan that way, so it is a §2.1 done-row, not an enrolment. Titan's own redirect host is not stated anywhere in this spec, so the done-row's SSO is unverified post-D1. |
| `grafana` | nothing live; the `GF_AUTH_GENERIC_OAUTH_*` block is commented out | forwardAuth on titan (already is: `observability-grafana-auth`) |
| `databasus` | matched `password` — but those are **database** credentials, not identity credentials | forwardAuth. Recorded here so the scan is reproducible rather than curated after the fact. |
| everything else (`home-hass`, `chiclana-hass`, `trading-reports`, `bentopdf`, `vert-sh`, `kanghuru`, `strix`) | no auth-shaped env | **forwardAuth** |

So exactly one app speaks OIDC in its own config, which corroborates "most would be reverse proxy
protected". forwardAuth is the default because it gates without touching the app — which is what a
migration wants — and because titan already runs that shape.

### 3.2 The per-app auth shape, and why no ticket can skip it

Every migrated app's auth half is the same four objects, and titan enforces them with two gates:

1. authentik `Provider` (proxy) + `Application` + group binding, in a blueprint `ConfigMap`.
2. A Traefik `Middleware` with `forwardAuth` pointing at the outpost.
3. `traefik.ingress.kubernetes.io/router.middlewares` on the app's Ingress.
4. The app's group in `titan/apply/50-apps/auth/identity-blueprint.yaml` — which is where the four
   per-app admin groups already live, and whose header records why group *parentage* does not work
   for claim-based mapping (authentik's `groups` claim is the flat M2M; upstream
   `blueprints/models/core/models.py`, unpinned here — §9).

`titan/tools/ingress-auth-check.py` fails any built `*.titan.arrieta.eu` Ingress with no
`router.middlewares` unless it is named in `NOT_PROXY_GATED` **with a citation**; an entry with no
citation is treated as a hole. `titan/tools/blueprint-mount-check.py` fails a blueprint `ConfigMap`
that is unlisted under `blueprints.configMaps`, that has no parseable `.yaml` body, or that is missing
from the worker's reloader annotation — the last case is the one that reads as "my change did
nothing", and that gate caught a live bug the day it was written. **A ticket that skips auth does not
merge.**

Shape choice inside forwardAuth: keep the existing **provider + middleware pair per app**
(`observability-grafana-auth`, `apps-teslamate-auth`) rather than one shared outpost with per-app
providers, for consistency with the two blueprints and the gate as they stand.

**Two things this shape does not cover, and both are in this migration.**

- **Home Assistant.** Two of the migration tickets are HA, which has its own auth system, long-lived
  websockets, and a companion mobile app that does not follow a 302 to an external IdP. §3.1 finds no
  in-app OIDC for it, so there is no in-app escape hatch either. Each HA ticket needs an explicit
  sub-decision: browser-only SSO with a documented companion-app path, or an allow-listed bypass path
  for the API/websocket surface. Deciding this in the ticket, after the Ingress is live, is how the
  family finds out the phones stopped working.
- **Exposure class changes.** Under D1 these hosts become reachable at titan's public IP
  (`local.titan_ip`). `home-hass` and `chiclana-hass` are currently reached from a different network
  than the VPS's; T4/T5's "re-verify reachability" step is a *reachability* note, not an *exposure*
  note, and the two are different questions. Each ticket states current reachability (LAN / mesh /
  public) and intended reachability, and the delta is the thing being decided.

### 3.3 Identity parity — the precondition every auth half assumes

D3 declares titan's authentik authoritative and asserts no user-directory lift-and-shift. That
presumes every person who currently reaches `hass`, `chiclana-hass`, `trading-reports`, `databasus`
or `kanghuru` on the VPS already exists in titan's authentik **and is in the group the app binds**.
Nothing in this spec establishes that, and §2.1 records the opposite as an accepted loss for one app:
open-webui's "VPS chats and **user rows**" are abandoned because titan's instance has its own fresh
DB. At least one identity divergence is proven and was accepted — which makes the unexamined
assumption for the forwardAuth apps more dangerous, not less, because a group binding naming an empty
group is a lockout that includes the operator.

So identity parity is an explicit **exit criterion of T0**: user count, group list, and per-provider
group binding on both instances, diffed. Until that diff exists it stays in §9 as unproven, and no
auth half may be flipped from the VPS instance to titan's without it.

## 4. Secrets cannot be copied

`.sops.yaml` in the two repos share four of five recipients, but **the cluster key differs**:

| repo | cluster key |
|---|---|
| k8s-techdelivery | `age1yfepn…` (VPS k8s key) |
| k8s-titan | `age1t5z4e…` (`titan-k8s`) |

A VPS-encrypted Secret will not decrypt on titan. Two further mismatches, both from the two repos'
opposite conventions:

- titan's creation rule sets `encrypted_regex: "^(data|stringData)$"` and its AGENTS.md **forbids
  `data:`** in `apply/10-secrets/` — a sops ciphertext is not base64, so an unconverted file makes
  server-side dry-run refuse the whole `10-secrets` stage and `make dry-run` never reaches the stage
  you changed. The VPS convention is base64 `data:`. **Every migrated Secret is converted to
  `stringData`.**
- sops picks recipients from the file's own path, and titan's `path_regex` is
  `apply/10-secrets/.*\.ya?ml$`. Stage the plaintext inside `apply/10-secrets/`, encrypt to a temp
  file, confirm non-empty, then move it — the `--encrypt` + shell-redirect failure mode truncates
  the destination to zero bytes before the error surfaces.

Per-ticket step, then: decrypt on the VPS side, re-author as `stringData`, encrypt under titan's
path, verify recipient count is 5 and `ENC[` present, and let `make check`'s `secrets-placement`,
`release-secrets` and `secret-refs` gates prove the name and namespace.

The staging mechanics are **not duplicated here** — they are in `titan/docs/ovh-dns-credential.md`,
which is the documented staging flow and the one AGENTS.md points at for exactly this dance. Two
things this spec must add to it, because both are migration-specific:

- **The plaintext must never be reachable from `git add -A`.** Every ticket's first step is
  `git add -A`, `leak-check` greps credential *shapes* (age key, PEM, OpenSSH prefix, public IPv4)
  and will not notice a plaintext `DATABASE_URL`, and `secrets-placement` only fires after the commit.
  So stage under the repo's git-ignored staging name, never as a bare file in `apply/10-secrets/`, and
  delete the plaintext before staging. This is the half of the existing flow that is easy to drop while
  copying the path rule.
- **Recipient count is the exit criterion**, not a nicety: 4 shared + 1 distinct = 5. A re-encrypted
  file with 4 recipients silently carries the VPS key and not the titan key, or the reverse, and
  decrypts on the wrong cluster.

All of this needs the **VPS cluster age key and read access to VPS Secrets**, which is a credential
this plan does not provision — see the prerequisites ticket in the plan.

## 5. Storage — sizing is one-shot

Pre-flight F-D, cited rather than restated, because it changes ticket content and not just ordering:
titan's storage classes cannot be expanded after creation. **A PVC sized too small at creation cannot
be grown.** So each stateful ticket sizes its PVC from the VPS PVC's *request*, not its current usage
(the pre-flight's own correction: usage and request are very different numbers here), and binds to
`local-path-retain` — the default class is `Delete`, which is the hazard #145 flagged.

Because sizing is one-shot and the failure is silent, size is `max(request, 2 × current usage, 2 Gi)`,
not `request` alone. The `postgresus` 3 Gi backup volume is the obvious candidate to fill at exactly
3 Gi with no warning.

Backup scope is opt-in by annotation: a volume is backed up only if its PVC carries
`backup.titan.arrieta.eu/class: daily`. Every migrated PVC that should be backed up carries it, and
`make backup-coverage` is what proves the annotation, the discovery CronJob, the Reflector mirror
lists and the RBAC agree. Note the honest limit in titan's AGENTS.md: neither backup path is
monitored, and the restic side has never been restored.

**Destination capacity is not proven.** The plan knows the source side precisely and knows that T3
reclaims a large block of `Released` PVs, but nothing here states that titan has the compute, memory
or GPU headroom to absorb the arriving workloads — including `llm` and `open-webui`, which are the
reason anyone would care. A headroom check is therefore an exit condition of T3, before any stateful
wave starts.

Namespace: the small single-purpose apps land in `apps`, matching `investing-agent`. If any ticket
instead gives an app its own namespace, **three** things change in the same commit, not one: both
reflector annotations on `titan-wildcard.yaml` (`reflection-allowed-namespaces` **and**
`reflection-auto-namespaces` — the file's own comment says "these two lines"), and a `namespaces.yaml`
entry. Miss the first pair and Reflector stops mirroring into the new namespace; miss the last and
`namespace-check` fails for a cause the plan never listed. AGENTS.md forbids copying `titan-tls` by
hand, so those annotations *are* the mechanism.

**One DNS caveat that only bites the exception.** A host served by the shared `titan-wildcard` needs
no DNS record at all — that is D1, and it holds. But cert-manager leaves a stale challenge node behind
after every DNS-01 challenge, and per RFC 4592 a wildcard cannot match a name that already exists, so
the stale node shadows `*.titan` and the name answers NODATA. `tf/records_public.tf:15-45` documents
this twice: `coder.titan` and `streaming.titan` each need an explicit A record, and `streaming.titan`
went dark on 2026-10-19 from exactly this, with the node reappearing at every renewal. Both names that
were bitten have their **own** `Certificate` — which is why the migrated apps, served by the shared
wildcard, cast no per-host challenge and no shadow. The exception is `kanghuru.es`, which has its own
issuer and certificate, and that is the host D2 already carves out: T12 carries a post-renewal NODATA
probe as a precondition, not a Wave 0 sweep of every migrated host.

## 6. Sequencing constraints

The tickets are #99–#116, tracked by #116. What follows is the constraint graph the plan may not
violate; the wave numbers it mentions are the plan's reading order, and the dependency list in the plan
is the authority.

- **#103 precedes every auth half**, and the T0a probe (§3) precedes #103. No ticket may state its auth
  half as fact before both land, which is why §2's Auth column is provisional.
- **#99 is closed by D1/D1b** and gates every Ingress-bearing issue; it should close first, with a
  pointer here rather than a new decision.
- **#100 is closed by D5** and gates every Ingress-bearing ticket — but per D5 it is a confirmation plus
  a middleware rewrite, not an ownership project.
- **#101 gates every stateful ticket.** Pre-flight F-G gated a working backup path before any data copy,
  and #101 is that gate; the first draft of this spec invented a copy ticket without finding it.
  #101 measured "no generic volume backup on titan" on 2026-10-20 and is now partly satisfied by
  `apply/70-backup/` — but its own done-conditions (a drilled restore, a failure visible from outside
  the cluster) are still unmet, so it stays open.
- **The storage-preconditions ticket gates every stateful ticket**, and its exit includes a
  destination-capacity verdict, not only disk reclamation. It has no existing issue — see the plan's §1.
- **#102 and #113 have a genuine ordering tension, and it is not resolved here.** This plan says #102
  (merge the Postgres) precedes #113 (databasus), because databasus re-issues credentials against CNPG.
  #102 says the opposite: its prerequisite is "the databasus/postgresus retire-or-move decisions — they
  are this database's remaining consumers". Both are right about their own half. The resolution is
  probably to split #113's *decision* ahead of #102 and its *move* after it; that is a call for the
  issue, not for this spec.
- **Retirement never shares a ticket with replacement.** The rollback for a bad auth migration needs
  the VPS Postgres, so if the same ticket copies and retires it, the rollback graph is a cycle.
  Retirement is a separate ticket behind an observation window.
- **kanghuru (#111) is last** (D2), and its retirement is gated behind its own two halves.

## 7. Gates

Every ticket passes `make check` in `k8s-titan` where the age key and network are available, or
`make check-ci` where they are not, and the PR records which. The full gate list is in
`titan/Makefile` and in `titan/AGENTS.md`, which are the files that cannot lie; this section names
only the three that will decide whether these tickets merge.

| gate | why it bites here |
|---|---|
| `ingress-auth` | every Ingress-bearing ticket adds a gated `*.titan.arrieta.eu` host; §3.2 |
| `secrets-placement` / `secret-refs` | every ticket re-encrypts Secrets into `10-secrets`; §4 |
| `backup-coverage` | every stateful ticket annotates a PVC; §5 |

Two things reviewers caught in the first draft of this section, recorded so they are not reintroduced:
`dry-run` is **not** part of `check` and must be run explicitly with an admin context, and
`make check` cannot complete in a workspace without the age key and network — `check-ci` is the
fallback. Both are spelled out in the plan's §6.

Structural rule from titan's AGENTS.md: **one numbered directory is one stage is one Flux
`Kustomization`.** These apps are not new stages — they are subdirectories under
`titan/apply/50-apps/`, one kustomization line per manifest, and a stateful app contributes two:
`<app>/<app>-db.yaml` in namespace `databases` (a CNPG `Database` must share a namespace with its
`Cluster`) plus `<app>/<app>.yaml` in the app's own namespace. That is the `mealie/` and `sure/`
shape; `coder/` contributes three lines and `auth/` five, so "one line per app" is not the rule.
Whether an app earns the shared `apps` stage at all is decided by the admission test in
`docs/superpowers/specs/2026-10-19-titan-app-scale-out-design.md` §3.1, not by the directory name.

## 7.1 Pre-flight disposition

The header promises this spec cites F-A … F-I. It now accounts for all nine; this is where each one
lands.

| finding | disposition |
|---|---|
| F-A | live-cluster state drifts; plan §8 re-measures before any retirement |
| F-B | **closed by D5 / #100** — keep k3s's bundled traefik, copy nothing; but per #100 the middleware annotations are rewritten, not copied |
| F-C | T2; the alerting gap is the honest residual and stays in §9 |
| F-D | §5 (one-shot sizing) and T3 (reclamation) |
| F-E | **k3s version inversion — titan is older than the VPS.** Every manifest in T4–T12 is copied from the newer tree. Not closed: recorded in §9 as an unmitigated risk with no owner in this plan |
| F-F | **this workspace runs on titan**, so cutover must not be driven from the destination. Recorded in §9 |
| F-G | backup path before data copy — **#101**, which the first draft of this spec reinvented as its own ticket before finding it |
| F-H | mail-only, out of scope (§8) |
| F-I | the DNS half is **closed by D1**; the mail half stays open (§8) |

## 8. Out of scope

- **Mailserver and everything mail-coupled**: the mailserver workload, `unbound`, the PTR/HELO work
  in F-H/F-I, MX/SPF/DMARC, and the mail ports. #153's mail-destination decision stays open and
  still gates releasing the box.
- **Releasing the VPS.** This plan empties it of everything except mail.
- **`*.v.arrieta.eu` re-pointing.** Per D1 those names keep naming `<VPS_PUBLIC_IP>`. Accepted — but not
  for the reason the first draft gave, which was wrong. It said they "stop resolving when the box
  goes". They do not: `*.v.arrieta.eu` is a wildcard inheriting the apex record, so it keeps resolving
  to whatever the apex points at. After the box is released that is a dead IP the provider will
  **reassign to a third party**, and every stale bookmark, HA automation, webhook and mobile shortcut
  for `*.v.arrieta.eu` lands on a stranger's server. So the accepted consequence is not a dead name, it
  is a name that eventually belongs to someone else. **Releasing the box therefore carries a required
  step, owned by whoever releases it: delete the `*.v.arrieta.eu` wildcard or repoint the apex to a
  sink.** It is outside this plan's tickets and must not be lost in the gap between them.
- **`v.arrieta.eu` Certificate** — dies with the VPS.
- **`kube-prometheus-stack` migration** — retired, not moved (T2).
- **titan's own traefik implementation** — T1 decides it; implementing it is its own change.

## 9. Not proven, and where this spec is weak

Listed as an uncertainty register, not a risk register: several rows below have **no mitigation and no
owner in this plan**, and that is stated rather than papered over.

- **D5 needs the operator's sign-off.** It is decided here on measured evidence (three live `Middleware`
  objects, five gated Ingresses, no `HelmChartConfig` anywhere in `titan/`), but F-B framed it as a
  decision to be made and this spec makes it by argument rather than by instruction.
- **Identity parity between the two authentik instances is unproven** (§3.3). Until T0's parity diff
  exists, every auth half in this plan carries a lockout risk that includes the operator.
- **Destination capacity is unverified** (§5). T3's exit includes the headroom verdict; nothing before
  it can promise titan can absorb the arriving set.
- **F-E is unmitigated: titan's k3s is older than the VPS's**, and every manifest in T4–T12 is copied
  from the newer tree. No ticket owns this and no gate in §7 can see it. The honest statement is that
  the migration moves manifests from a newer cluster to an older one and nothing here proves that is
  safe.
- **F-F: this workspace runs on titan.** Cutover and retirement work must not be driven from the
  destination, and the plan does not say where it is driven from instead.
- **The client list in §2.2 is incomplete.** `bentopdf` and `vert-sh` are `unknown`, and D1 has no
  forcing function, so completeness is only provable from traffic on the old names (plan §8).
- **No fetch was possible from this workspace.** Coder external auth brokers GitHub here; there is
  no stored PAT and no usable SSH key, and unauthenticated networked git hangs rather than failing
  fast. Everything is measured against the **last-fetched** `origin/main@22c5e06`. Anyone executing
  these tickets re-verifies the base before the first commit.
- **T0's output does not exist yet**, and neither does T0a's probe. Every auth half is a shape, not a
  filled-in provider list. That is honest sequencing, not a finished design.
- **Nothing here was measured against the live clusters.** All facts are read from the two git trees
  plus `public-dns-tf`, and the pre-flight's measurements are cited rather than re-taken. The
  `k8s-reader` ServiceAccount can read both clusters and cannot read Secrets — so T0's authentik
  export and T10's DSN check both need more than `k8s-reader`, and TP provisions that.
- **`bentopdf` and `vert-sh` may be dead.** No Ingress, no host, no consumer found in either tree.
  T7 exists because "port it and find out" is the wrong order.
- **`teslamate`'s DSN is unread from a workspace** (SOPS secret, and `k8s-reader` cannot read
  Secrets), so the pre-flight's "unconfirmed" survives into T10 as a step, not a footnote.
- **The auth halves are net-new hardening, so they can lock someone out.** `ingress-auth` proves a
  gate resolves; it does not prove the policy behind it is the policy you meant. The gate's own
  documented limit is that an authentik provider with `access_group` unset gates a host open to
  every authenticated account, and that is a row in authentik's database, not in this tree.
- **Neither titan backup path is monitored and the restic side has never been restored.** §5 moves
  data behind that statement rather than in spite of it.
- **Upstream citations are unpinned.** The authentik `groups`-claim claim (§3.2) cites a source path
  with no repo or version pin, so a later authentik upgrade invalidates it silently. The behavioural
  claim is what matters; the location is a pointer, not evidence.
