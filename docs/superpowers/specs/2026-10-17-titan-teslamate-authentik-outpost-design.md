# TeslaMate and Grafana behind authentik — design

Date 2026-10-17. Status: **design, not yet implemented.** Written after the database migration
(`docs/teslamate-runbook.md` §7) landed, because the same host that now serves restored trip history
serves it to anyone who finds the URL.

Read `2026-10-16-titan-teslamate-fleet-telemetry-design.md` first for what the Tesla stack is. This
spec only covers putting two of its HTTP front doors behind authentik, and what must deliberately
stay in front of them.

## 0. How to read this

Every claim is one of three things, and says which:

- **measured** — a command run on this cluster, quoted with its output;
- **read** — a file in the pinned authentik release, cited by path and line;
- **not proven** — listed in §8 with the test that retires it.

Nothing here was written from memory of how authentik works. Two things were written that way during
the conversation that produced this spec, and both turned out wrong; they are corrected in §2.

## 1. Goal

`https://tesla.titan.arrieta.eu` (TeslaMate) and `https://grafana.titan.arrieta.eu` (Grafana) require
an authentik session. Everything that must stay reachable by machines that have no browser session
stays reachable:

| host | who calls it | after this change |
|---|---|---|
| `tesla.titan.arrieta.eu/` | a human | authentik |
| `tesla.titan.arrieta.eu/.well-known/appspecific/com.tesla.3p.public-key.pem` | **Tesla's servers** | public, unchanged |
| `grafana.titan.arrieta.eu/` | a human, and TeslaMate's iframe | authentik |
| `authorize.titan.arrieta.eu/callback` | Tesla's redirect, the owner's browser | public, unchanged |
| `telemetry.titan.arrieta.eu` | the car, mTLS | untouched — it is an `IngressRouteTCP`, no HTTP layer to authenticate |

The last row is the one that matters most: **the car's data path must not gain a dependency on
authentik.** If authentik is down, the owner cannot read TeslaMate. The car keeps uploading, the
forwarder keeps decoding, and the frames keep landing in Redis. That is a design constraint, not an
observation — §7 says how it is checked.

## 2. Two corrections to what was assumed earlier

Both were said out loud before being checked, and both were wrong in the direction of doing too much.

**There is no separate outpost workload to deploy, and no outpost token to encrypt.**
`OutpostType` in the pinned release is the *protocol*, not the deployment mode:

```python
# authentik/outposts/models.py:99-105 @ version/2026.8.3
class OutpostType(models.TextChoices):
    PROXY = "proxy"
    LDAP = "ldap"
    RADIUS = "radius"
    RAC = "rac"
```

The deployment mode lives on the service connection instead:

```python
# authentik/outposts/models.py:127-134
local = models.BooleanField(
    default=False,
    help_text=_("If enabled, use the local connection. Required Docker socket/Kubernetes Integration"),
)
```

`local: true` means the outpost is served by the `authentik-server` process itself — the embedded
outpost. `authentik-server` is already running and already fronted by a Service:

```
$ kubectl --context titan -n auth get svc
NAME               PORTS    TARGET
authentik-server   80,443   9000,9443
```

So the forward-auth endpoint is `http://authentik-server.auth.svc.cluster.local/outpost.goauthentik.io/auth/traefik`
and there is no new Deployment, no new image pin, and no new Secret. The outpost token
(`object_naming_template: ak-outpost-%(name)s`, `models.py:64`) is only needed by a process that
authenticates to authentik over the websocket to receive its configuration; the embedded outpost is
already inside that process.

**`SameSite=None` is not needed, and coder is not at risk.** `tesla.titan.arrieta.eu`,
`grafana.titan.arrieta.eu` and `auth.titan.arrieta.eu` all share the registrable domain
`arrieta.eu`, so they are *same-site*. A `SameSite=Lax` session cookie is sent on a same-site iframe
navigation. The earlier warning about cross-site iframes and a cluster-wide cookie change was wrong,
and nothing global has to be touched. §8 still keeps this as a test rather than a conclusion, because
"they are same-site" is reasoning, not measurement.

## 3. What exists today

**measured** — no outpost anywhere. `grep -riE "outpost|proxyprovider|forwardAuth" apply/ docs/` is
empty, and namespace `auth` runs exactly two workloads:

```
deployment.apps/authentik-server   1/1  12d
deployment.apps/authentik-worker   1/1  12d
```

Coder is connected to authentik as an **OIDC provider**
(`apply/50-apps/coder/coder.yaml`, "Sign in with authentik"), which is a different mechanism and is
not touched by this change.

**measured** — the two front doors are plain core `Ingress` objects, `ingressClassName: traefik`,
TLS from `titan-tls`:

- `apply/50-apps/tesla/teslamate.yaml:145-166`, host `tesla.titan.arrieta.eu`, `path: /`, `Prefix`.
- `apply/50-apps/tesla/grafana.yaml:118-137`, host `grafana.titan.arrieta.eu`, `path: /`, `Prefix`.
- `apply/50-apps/tesla/wellknown.yaml` serves the public key on the same host at a more specific
  path, which is why the TeslaMate rule is `/` and not `/*`.

**measured** — Traefik 3.7.8 with its CRDs installed:

```
$ kubectl --context titan -n kube-system get pod -l app.kubernetes.io/name=traefik \
    -o jsonpath='{.items[0].spec.containers[0].image}'
rancher/mirrored-library-traefik:3.7.8
$ kubectl --context titan get crd | grep -c traefik
25
```

This is the first time this repo ships Traefik CRD objects. `make crd-check` validates against
`vendor/cnpg-crds/` only, so `IngressRoute` and `Middleware` get **no offline schema validation** —
`make dry-run` against the live API server is the only gate that will catch a mis-nested field, which
is exactly the class of error that once took the `apps` stage down (AGENTS.md, `crd-check` paragraph).

## 4. The provider, and the fields that decide it

**read** — `authentik/providers/proxy/models.py @ version/2026.8.3`, the fields that matter here,
quoted exactly:

| field | line | why it is the one |
|---|---|---|
| `external_host` | 81 | required; the host the user sees |
| `internal_host` | 77 | blank allowed; "Exclusive with" forward-auth mode, so it stays empty |
| `mode` | 87 | choices `proxy`, `forward_single`, `forward_domain`; help text: *"Enable support for forwardAuth in traefik and nginx auth_request. Exclusive with internal_host."* |
| `skip_path_regex` | 96 | *"Regular expressions for which authentication is not required. Each new line is interpreted as a new Regular Expression."* |
| `cookie_domain` | 141 | default `""` |
| `intercept_header_auth` | 105 | left at its default; nothing here authenticates by header |

`mode` is the decision this spec has to make, and it is a real fork:

- **`forward_single`** — one provider per host. Two providers (TeslaMate, Grafana), two cookies, and
  the Grafana iframe has to authenticate itself independently.
- **`forward_domain`** — one provider covering `titan.arrieta.eu`, one cookie for both hosts, so the
  iframe is already authenticated when TeslaMate embeds it.

**Chosen: `forward_domain`, one provider, `cookie_domain: titan.arrieta.eu`.** The iframe is the
reason. With per-host cookies the iframe's first request would 302 into `auth.titan.arrieta.eu`
*inside the frame*, and whether that completes silently depends on headers this repo does not control.
One cookie removes the question instead of answering it. The cost is honest and should be stated: the
provider now authorises by URL prefix, so a path that should not be protected must be excluded by
regex rather than by simply not being in the provider's host list.

**Chosen: `skip_path_regex` for the public-key bypass**, one line, in the provider:

```
^/\.well-known
```

The alternative is a Traefik route that matches `PathPrefix(\`/.well-known\`)` without the
`forwardAuth` middleware. That works too and is more visible in the routing, but it puts a
security-relevant exception in a second place; one place, one test, is preferred. §8 keeps the
unauthenticated curl as the proof either way.

## 5. How the objects get into authentik

**read** — the chart's only two blueprint sources, from `helm show values authentik/authentik --version 2026.8.3`:

```yaml
# chart authentik-2026.8.3, values.yaml:220-226
blueprints:
  # -- List of config maps to mount blueprints from.
  configMaps: []
  # -- List of secrets to mount blueprints from.
  secrets: []
```

There is no inline `blueprints.entries`. The existing coder and Google blueprints are Secrets because
they carry credentials; **this one carries none**, so it is a plain ConfigMap:

- `apply/50-apps/auth/tesla-outpost-blueprint.yaml` — a `ConfigMap` named
  `authentik-tesla-blueprint` in namespace `auth`, key `tesla.yaml`, holding the blueprint.
- `blueprints.configMaps: [authentik-tesla-blueprint]` added to the HelmRelease values.
- `configmap.reloader.stakater.com/reload: authentik-tesla-blueprint` on the server and worker pod
  templates, matching the existing `secret.reloader.stakater.com/reload` at
  `apply/50-apps/auth/authentik.yaml:135`. Without it the worker's hourly discovery is the only path
  and an edit silently sits unread for an hour — the exact failure the existing annotation exists for.

No sops, no setup script, no new Secret: `make secrets-placement` stays green because a ConfigMap is
not a Secret, and nothing encrypted is involved.

The blueprint declares three objects: a `ServiceConnection` with `local: true`, a `ProxyProvider`
(mode `forward_domain`, `external_host` `titan.arrieta.eu`, `cookie_domain`, `skip_path_regex`), and
an `Outpost` of type `proxy` tying them together. **The exact `model:` strings are a Task 0 probe,
not an assumption** — see the plan. The coder blueprint's header records why that rule exists:
authentik ships no CRDs, and a wrong model name fails validation in the worker's log, not in git.

## 6. Traefik objects

Per host, replacing the existing `Ingress` in the same commit:

- a `Middleware` of type `forwardAuth`: `address` the embedded outpost endpoint,
  `trustForwardHeader: true`, and `authResponseHeaders` limited to what TeslaMate and Grafana
  actually consume — forwarding an `Authorization` header that the outpost hands back is how an
  upstream app ends up trusting a header a client could have set itself.
- an `IngressRoute` with the same host, `tls.secretName: titan-tls`, one route with the middleware
  attached.

The `Ingress` and the `IngressRoute` must not both exist: Traefik would build two routers for the same
host and prefix, and which wins is a priority calculation nobody wants to reason about at 40% battery
while locked out of the car app. Delete and add in one commit, and the rollback is `git revert` of
that commit, which Flux reconciles back to the working state.

## 7. Failure modes, and the check that catches each

| failure | how it shows | check |
|---|---|---|
| public key stops being public | Tesla pairing fails with "application has not registered" — a misleading message, already recorded in the runbook | unauthenticated `curl` of the key returns 200 with the same body hash as before |
| blueprint model name wrong | nothing changes; the worker logs a validation error | worker log read after apply, not a `kubectl get` that shows nothing |
| outpost endpoint 404 | every request to TeslaMate fails closed | `curl` from inside the cluster to the outpost path returns an auth challenge, not 404 |
| websocket blocked | TeslaMate loads but never updates | authenticated browser session, watch for a 401 loop on `/ws` |
| Grafana iframe loops | TeslaMate page shows a login frame or a blank panel | authenticated browser, open a drive's Grafana link |
| authentik down | TeslaMate and Grafana unreachable | accepted; the telemetry path is `IngressRouteTCP` and is not in the middleware's scope — verified by a frame still landing in fleet-telemetry while the HTTP front door is challenged |
| lockout | owner cannot reach TeslaMate | `git revert` the route commit; Flux restores the plain `Ingress` |

## 8. Not proven, and what proves it

| claim | test that retires it |
|---|---|
| the blueprint `model:` strings are `authentik_providers_proxy.proxyprovider`, `authentik_outposts.outpost`, `authentik_outposts.outpostserviceconnection` | read them out of the running container with `ak shell`, before writing the blueprint |
| `forward_domain` + `cookie_domain: titan.arrieta.eu` produces one cookie that both hosts accept | authenticated curl: `GET /` on TeslaMate, then `GET /` on Grafana with that cookie jar and no second login |
| the iframe is same-site in practice, not just by registrable-domain arithmetic | open a drive in TeslaMate and watch Grafana render inside it, network tab open |
| `skip_path_regex` is evaluated against the original URI, since Traefik's forward-subrequest carries it in `X-Forwarded-Uri` | unauthenticated curl of the public key returns 200 while an unauthenticated curl of `/` returns a redirect to authentik |
| `mode: forward_domain` is the right mode for two hosts under one provider, not `forward_single` × 2 | the cookie test above; if it fails, the fallback is two providers and accepting the iframe redirect |
| TeslaMate's websocket survives forward auth | authenticated browser session, no 401 loop |
| the outpost path is `/outpost.goauthentik.io/auth/traefik` on the embedded outpost | curl it from inside the cluster and read the response code |

## 9. Deliberately not done

- **No separate outpost Deployment.** The embedded outpost is one less workload, one less image pin
  and one less Secret. The cost is that auth decisions go down when `authentik-server` restarts;
  that is already true of login itself.
- **No new Secret, no setup script, no sops.** A credential-free blueprint belongs in a ConfigMap.
- **No OIDC for Grafana.** Forward auth is the whole requirement; Grafana's own login stays as a
  second gate for anyone who reaches it by other means.
- **No step-up or per-app authorisation policy.** Everyone with an authentik session sees both apps.
  An `access_group` on the provider is the knob and is left at its default.
- **No protection of `authorize.` or `telemetry.`** — one is Tesla's redirect target, the other is
  mTLS. Neither has a browser session to check.
- **No change to coder's OIDC connection.** It is a different mechanism and is out of scope.
