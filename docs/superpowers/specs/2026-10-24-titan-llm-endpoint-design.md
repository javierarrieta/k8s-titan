# llm.titan.arrieta.eu — design

Date: 2026-10-24. Implements: a second public front door for the halogen-flash endpoint that has been
served as `llm.v.arrieta.eu` from the techdelivery VPS, now also served by titan at
`llm.titan.arrieta.eu`, accepting the **same two keys**. A duplicate, not a migration — the VPS
endpoint stays up and nothing here turns it off.

> **Corrected the same day it shipped.** The first two revisions of this spec, and the manifest that
> went with them, treated the credential as one literal bearer token. It is not one: it is a PCRE
> alternation holding two real keys. D9 is the correction and §4 is the measurement behind it. The
> live endpoint answered `401` to every credential any client had ever sent between the merge of
> `afd0cbc` and this change.

## 1. Why a second one, and why here

`../k8s-techdelivery apply/50-apps/apps/llm-chiclana.yaml` has served `llm.v.arrieta.eu` for 221 days:
an unselected `Endpoints` at `192.168.0.29:8731`, a Service in front of it, and a bearer-token
forwardAuth in front of that. The techdelivery VPS is being emptied into titan — that repo's own
`apply/20-infra/vps-to-titan-migration.md` already lists `llm-chiclana` among the "good
path-builders" — so this is the migration's shape for this workload: build the titan side first, prove
it, leave the old name alone until the decision to retire it is actually taken.

Two things made titan the obvious place, and both were measured rather than assumed:

- **titan already has a path to the backend.** `curl http://192.168.0.29:8731/health` from this
  cluster returned `200` in 83 ms. The route is the OPNsense WireGuard peer in
  `../nixos-configurations hosts/titan/configuration.nix`, whose `allowedIPs` carry
  `192.168.0.0/24` — a range that was added for MinIO backups and the Attic cache and that this now
  depends on for a fourth thing. Mealie's AI importer (spec
  `2026-10-22-titan-mealie-design.md` §5) already points at the same address from inside this cluster,
  so the path is not new here.
- **the hostname was free already.** `llm.titan.arrieta.eu` resolves to titan's own public address
  today (the concrete IPv4 is deliberately not written down here — AGENTS.md forbids it in this
  public repo), through the `titan` wildcard record in `../public-dns-tf records_public.tf`, and
  `apply/40-certificates/titan-wildcard.yaml` already signs `*.titan.arrieta.eu`. One label deep,
  which is exactly the depth `llm.titan` sits at (RFC 6125 6.4.3). **No DNS change and no new
  Certificate were needed**, which is the whole reason this is a small change.

The alternative reading of "duplicate it" — keep the name `llm.v.arrieta.eu` and point it at titan —
was rejected before design. That name is not its own record: it resolves through the `*.v` CNAME to
`v.arrieta.eu`, which is an A at the VPS. Moving it means either repointing the `v` apex, which moves
every other `*.v` name with it, or adding an explicit `llm.v` A and a second Certificate for a name
whose apex still belongs to a different cluster. The operator chose the titan hostname.

## 2. Decisions

| # | decision | why |
|---|---|---|
| D1 | own namespace `llm`, stays in the shared `apps` stage | Fails the §3.1 admission test of `2026-10-19-titan-app-scale-out-design.md` on own public hostname and own Secret set, so it gets a namespace; §3.2 keeps it in `apps` — one hand-written manifest, no bulk authored here, so the freeze-a-neighbour risk is the accepted one rather than a new one. |
| D2 | **no new Certificate**; reuse `titan-tls` | `*.titan.arrieta.eu` covers `llm.titan.arrieta.eu` at exactly one label. Getting the Secret into `llm` is the Reflector allow-list on `titan-wildcard.yaml` — `llm` added to both the `-allowed-` and `-auto-` lists, which AGENTS.md names as the controlled mechanism. A hand-copied Secret is the thing that file exists to prevent. |
| D3 | the `Middleware` lives in `llm`, not in the Traefik namespace | The source references `traefik-system-bearer-auth@kubernetescrd` across a namespace boundary, and its own comment records that this works only because Traefik's `crossProviderNamespaces` is left unset, which is permissive by upstream default. Titan's Traefik is k3s-bundled and **not managed in this repo**, so that permissiveness cannot be proved from the tree — and the failure mode if it were ever tightened is an unauthenticated LLM endpoint that still reports healthy. Same-namespace is provable and already used here: `apply/50-apps/grafana/grafana.yaml` references `observability-grafana-auth@kubernetescrd` from an Ingress in `observability`. The forwardAuth *address* still crosses namespaces by plain URL, which grafana also proves works (its address is authentik's Service in `auth`). |
| D4 | nginx forwardAuth, not a Traefik-native middleware | Traefik has no bearer matcher: `basicAuth` wants an htpasswd and a `Basic` scheme, and the clients send `Authorization: Bearer <token>`. "Same key" therefore means the same header has to pass here, and the only way to do that without a new dependency is the same throwaway nginx that answers 200 or 401. |
| D5 | image `nginxinc/nginx-unprivileged:1.31.7-alpine@sha256:378d0c32…`, the **non-root** image | The first draft pinned `nginx:1.31.6-alpine@sha256:adad2ae9…`, the root image the source pod runs, read out of `kubectl --context vps -n auth get pod -l app=bearer-auth-service -o jsonpath='{…imageID}'` rather than from the tag — a tag-only pin would have moved it, since that tag now resolves to `sha256:df221db8…`. The reason given for the root image was that the unprivileged variant's layout for `/etc/nginx/conf.d` was "not verifiable from here". It was verifiable, and it was: opening the digest's layers with `skopeo copy` plus `tar` shows `User=101` in the image config, `/etc/nginx/conf.d` owned `drwxrwxr-x 101/0`, `/usr/bin/envsubst` present, `pid /tmp/nginx.pid`, and no `user` directive in the overlay's `nginx.conf`. That last one is load-bearing — the stock alpine `nginx.conf` in an earlier layer does carry `user nginx;`, which is an emerg error when the master is not root, so the overlay's version has to be the one that wins. Parity with the source is about the config and the comparison, not about the uid or the nginx point release. The digest is the one `apply/60-tesla/wellknown.yaml` already runs, so the cluster pulls one unprivileged nginx; the tag has since been re-published to `sha256:b5047b9b…` with a different layer set, which is why the pin is a digest and not a tag. Consequence in D6. |
| D6 | `pod-security.kubernetes.io/warn: restricted` on `llm` | The first draft left the label off because the container ran as root, and a warn a workload can never satisfy trains everyone to ignore it — the open-webui reasoning. Once D5 changed, the pod satisfies `restricted`: `runAsNonRoot`, uid 101, `allowPrivilegeEscalation: false`, every capability dropped, `RuntimeDefault` seccomp, the same shape `wellknown.yaml` runs. That makes it the `observability` case rather than the open-webui or files case: a warn the workload meets is a signal. The label is coupled to the image, not to the pod's `securityContext` — if the image ever goes back to root nginx, the label comes off. |
| D7 | `llm` added to Reloader's namespace list | Reloader runs `watchGlobally: false`, so its `namespaces` list is the whole scope and an annotation outside it is inert. The nginx renders its config from `$BEARER_TOKEN_A`/`${BEARER_TOKEN_B}` at container start and reads each key from a Secret env var, so without the list entry a rotated key sits unread in a running pod: Traefik keeps asking a forwardAuth server still matching the old key, every route stays up, and nothing looks wrong. That list has bitten four times (promtail, open-webui, grafana, mealie — the comments there record each). |
| D8 | bare `Endpoints` with no selector, kept as v1 | The backend is a host outside the cluster. v1 `Endpoints` is deprecated since v1.33 and kubectl warns on every `get`; it is still the supported way to hand a Service a fixed address, it is what the source has run for 221 days, and a hand-authored `EndpointSlice` (the `managed-by` label, the `service-name` link, per-slice ports) is more machinery for the same two facts. Parity with the file being duplicated. |
| D9 | the Secret holds **two literal keys** (`TOKEN_A`, `TOKEN_B`) and nginx compares each with `=` | The credential copied from the source repo is one 137-character string, and it is not a bearer token: it is `(sk_…67…|sk_…67…)`, a PCRE alternation group around two real 67-character `sk_` keys. The source's `~*` compiles it as a group, so the source accepts either key and rejects its own literal value. The first two revisions of this change read the `(`, `|` and `)` as an accident in a literal token and "fixed" the operator to `=` while still storing the alternation — which made titan accept only the wrapper string, a string no client has ever sent, and answer `401` to both real keys. §4 has the measurements; they are the exact inverse on the two endpoints. The fix is the **Secret shape**, not the operator alone: two keys, two env vars, two `=` compares, so no regex is ever compiled out of a secret again. That is what the `=` change was reaching for and did not achieve — it removed the regex while still storing one. Cost, unchanged from the first version: `=` is case-sensitive on the scheme word, so a client sending lowercase `bearer` fails where `~*` passed it. Repairing the source is a separate change in the other repo (§6). |
| D10 | no new `make` gate | Every other app here got a gate because one credential was written into two or more places (coder's `db-url-check`/`oidc-check`, Mealie's `mealie-check`, grafana's two OIDC checks). This endpoint has one credential in one file in this repo — there is no second copy inside the tree to drift from. The copy that *can* drift is in another repo, and no gate in this tree can read that. |
| D11 | the Ingress router is pinned to the `websecure` entry point | Titan runs no HTTP-to-HTTPS redirect: the traefik pod's args carry `--entryPoints.web.address=:8000/tcp`, `--entryPoints.websecure.address=:8443/tcp` and `--entryPoints.websecure.http.tls=true` with no `web.redirect`, read out of the running pod in `kube-system` rather than from the matching record in `apply/60-tesla/wellknown.yaml`. So an Ingress left on both entry points serves cleartext — `http://tesla.titan.arrieta.eu/.well-known/...` answering `200` is that, proven — which is harmless for a static public key and not harmless for a static bearer credential. The source does not have this problem because it redirects: `http://llm.v.arrieta.eu/health` answers `301`. Pinning refuses cleartext outright; a `redirectScheme` middleware was rejected because clients that follow redirects re-send `Authorization` to the https URL, which makes a wrong-scheme config succeed and stay wrong. Honest limit: nothing can stop a client pointed at `http://` from putting the token on the wire once — the request must arrive before anything can judge it. Pinning makes that request fail loudly instead of working. |
| D12 | `tcpSocket` probes, not `httpGet` | Every path on this container answers `401` unless the header carries the token and a probe sends no header, so an `httpGet` probe fails on a healthy pod and kubelet crashloops its own auth server — a liveness check cannot assert a credential. The readiness half is what makes a Reloader-triggered rotation invisible: without it the replacement pod is Ready before nginx has bound 8080, Traefik forwards an auth check into a closed port, forwardAuth errors, Traefik fails closed, and every route 502s for that window with both pods reporting healthy. |

## 3. Files

| file | change |
|---|---|
| `apply/00-bootstrap/namespaces.yaml` | new `llm` Namespace, with the `pod-security.kubernetes.io/warn` label D6 now argues for, and the `kubernetes.io/metadata.name` annotation the newer entries carry — the API server stamps that name onto every Namespace as a label by itself, so as an annotation it is decoration, kept to match `mealie` and `files` rather than to do anything |
| `apply/40-certificates/titan-wildcard.yaml` | `llm` added to both Reflector namespace lists (D2), plus a line saying these two lines are the mechanism |
| `apply/20-infra/reloader/reloader.yaml` | `llm` added to `spec.values.namespaces` (D7) |
| `apply/10-secrets/llm-bearer-token.yaml` | Secret `llm-bearer-token` in namespace `llm`, keys `TOKEN_A` and `TOKEN_B` — one literal key each, D9 — sops-encrypted to titan's recipients |
| `apply/10-secrets/kustomization.yaml` | lists it — an unlisted Secret builds green and is silently never applied |
| `apply/50-apps/llm/llm.yaml` | `Endpoints` + selector-less `Service` `llm01`; the forwardAuth nginx `Deployment` + `Service` + two `ConfigMap`s; `Middleware bearer-auth`; `Ingress llm` |
| `apply/50-apps/kustomization.yaml` | lists it |

The Secret was produced by the documented staging flow, not by hand: decrypt the source file, write
the plaintext to the git-ignored `apply/10-secrets/.staging.llm.yaml` (sops picks recipients from the
file's own path, so the plaintext has to sit under `apply/10-secrets/` briefly), then
`sops --encrypt --in-place "$stage" && mv "$stage" apply/10-secrets/llm-bearer-token.yaml` as one
`&&` chain. `docs/ovh-dns-credential.md` is that flow.

## 4. What is proven

- **The two keys are the same credentials the source accepts.** Decrypted on both sides and compared
  without printing them: titan's old `TOKEN` and techdelivery's `TOKEN` are the same 137 characters,
  and that string splits into exactly two 67-character `sk_` keys, `TOKEN_A` and `TOKEN_B`, both of
  which are now stored here on their own. The encrypted file carries titan's five recipients, first one
  `age1t5z4e…` — the `titan-k8s` cluster key — so the cluster can open it and the techdelivery key is
  not in the list.
- **The credential is a set of two keys, and that was measured on both endpoints, not reasoned about.**
  Against `https://llm.v.arrieta.eu/health` (source, `~*`) and `https://llm.titan.arrieta.eu/health`
  (titan, the first `=` version), 2026-10-24:

  | credential | source | titan, first `=` version | titan, after D9 |
  |---|---|---|---|
  | key A (the one the operator's client is configured with) | `200` | `401` | `200` |
  | key B (unattributed) | `200` | `401` | `200` |
  | the 137-char `(A\|B)` wrapper string | `401` | `200` | `401` |
  | no header | `401` | `401` | `401` |

  The middle two columns are the exact inverse, which is the whole bug in one row: the wrapper string
  authenticated on the cluster where nobody holds it and failed on the cluster where everybody does.
  The first revision's claim that "the recorded credential has never authenticated anything" was true
  only of the wrapper and was read as a statement about the keys, and D9's premise that the
  metacharacters were accidental was false — they are the structure that makes the two keys work.

  The last column was a prediction when PR #156 was opened and is now measured. Post-merge, against
  the live titan endpoint at 17:48, six calls, all as wanted: key A `/health` `200`, key A `/v1/models`
  `200` returning the real halogen payload, key B `/health` `200`, no header `401`, a nonsense token
  `401`, the wrapper string `401`, and `http://` with a valid key `404`. It took about three minutes
  for the `10m0s` Flux interval to pick the merge up, so a check run too early reads as still broken.
  Not done, and still open: an actual completion on the model. `/v1/models` is a catalog read.

  The last column was a prediction when PR #156 was opened and is now measured. Post-merge, against
  the live titan endpoint at 17:48, six calls, all as wanted: key A `/health` `200`, key A `/v1/models`
  `200` returning the real halogen payload, key B `/health` `200`, no header `401`, a nonsense token
  `401`, the wrapper string `401`, and `http://` with a valid key `404`. It took about three minutes
  for the `10m0s` Flux interval to pick the merge up, so a check run too early reads as still broken.
- **The source has a second defect this file does not repeat, and does not fix either.** Its `~*` is
  unanchored, so `Authorization: Bearer <key> <anything after it>` returns `200` there; measured.
  Anchoring it is a change in the other repo and is the one that can lock out whoever holds key B.
- **The bearer check is on and fails closed.** No header → `401` on both endpoints; `http://` on titan
  → `404`, so D11 took.
- **The backend is reachable from titan.** `curl http://192.168.0.29:8731/health` → `200`, 83 ms.
- **The old endpoint is live and is doing what this duplicates.** `curl https://llm.v.arrieta.eu/` →
  `401`, resolved and answered by the techdelivery VPS rather than by titan, i.e. the bearer check is
  on there and rejecting unauthenticated requests.
- **`make check` passes** in the worktree: leak-check (staged diff + tracked tree + untracked), all
  nine kustomize builds, `kustomize-listing` 92 manifests / 0 unlisted, `validate` decrypting every
  Secret including the new one, `secrets-placement`, `crd-check` (which saw the `Middleware`),
  `namespace-check` over 187 objects and 17 namespaces including `llm`.
- **The unprivileged image can run this config, as far as an offline check reaches.** Verified by
  opening the pinned digest's layers with `skopeo copy` and `tar`, not by running it: image config
  `User=101`, `/etc/nginx/conf.d` owned `drwxrwxr-x 101/0` so the uid-101 entrypoint can write
  `default.conf` there, `/usr/bin/envsubst` present, `pid /tmp/nginx.pid`, and no `user` directive in
  the overlay's `nginx.conf`. The digest is pullable and is the one `wellknown.yaml` already runs.

## 5. Post-merge, in order

1. Watch the two stages go Ready: `kubectl --context titan -n flux-system get kustomization`, then
   `kubectl --context titan -n llm get pods,svc,endpoints,ingress,middleware`.
2. Confirm the Secret landed by reflection, not by hand:
   `kubectl --context titan -n llm get secret titan-tls` — needs an admin context; the `k8s-reader`
   identity in this workspace is Forbidden for Secrets.
3. **Prove the auth accepts a credential a client actually has.** `curl -i -H "Authorization: Bearer
   <key A or B>" https://llm.titan.arrieta.eu/health` must be `200` from halogen. **This is the check
   that matters most in the whole change**, and it is the one the first draft of this section put second
   and described as a follow-up to the unauthenticated call. That ordering was wrong, and the shipped
   result was worse than the ordering: an unauthenticated-only check passed on an endpoint that had just
   closed for every real client.
4. Then `curl -i https://llm.titan.arrieta.eu/health` with no header must be `401`. Necessary, but
   not sufficient on its own and not proof that auth is on.

   The reason both are needed is that three different states exist and no single call tells them
   apart:

   | no header | with a real key | state |
   |---|---|---|
   | `200` | `200` | middleware reference did not resolve — the endpoint is **public** |
   | `401` | `200` | correct — this is the only acceptable pair of answers |
   | `401` | `401` | middleware resolved and rejects everything — endpoint is closed but **unusable** |

   The bottom row is where titan sat between `afd0cbc` and D9, and it is what an unauthenticated-only
   check reads as a pass. D3 exists to rule out the top row; only step 3 rules out the bottom one.
5. **Confirm cleartext is closed.** `curl -i http://llm.titan.arrieta.eu/health` must be `404`. A
   `401` here means the router is on the `web` entry point after all and is answering bearer checks
   over plaintext — D11 did not take. A `200` would be worse than either.
6. `make dry-run DRYRUN_CONTEXT=<admin context>` — **before merge, not after.** It was not run in the
   workspace that wrote this and there is no admin context there to run it with: `auth can-i '*' '*'`
   answers `no` for the read-only `k8s-reader` identity, as does the `casa` context, and `dry-run` is
   a server-side apply, so a read-only identity is Forbidden. This matters more here than in most
   changes: the unselected `Service` and the hand-authored `Endpoints` are core types, core validation
   rules live in the API server rather than in any vendored schema, and `crd-check` walks only the nine
   vendored CRDs — so the two objects most likely to draw a server-side objection are the two no
   offline gate looks at at all.

## 6. Not proven, and what it costs

- **The non-root switch is proven from the image, not from a running pod.** There is no container
  runtime in the workspace that wrote this — no docker, podman or nerdctl, and no `envsubst` on the
  host either — so nothing here has actually executed the entrypoint script as uid 101. The writability
  of `/etc/nginx/conf.d` is read off the layer's directory mode, which is the right evidence and is
  still not the same as a pod that did it. `wellknown.yaml` running the same image is supporting
  evidence, not proof: it mounts a Secret and never writes to `conf.d`. The first `kubectl -n llm
  get pod` after merge is the real check, and a `CreateContainerConfigError` or an emerg about `user`
  in the pod's logs is this bullet's failure mode.
- **Nothing here proves the model works end to end from titan.** `/health` returning 200 proves the
  HTTP path; an actual completion on a 130 GiB model is a different request and has not been sent.
- **Two live endpoints, the same two keys, two repos, two *forms*.** `../k8s-techdelivery`
  `apply/10-secrets/bearer-auth-token.yaml` still holds the `(A|B)` alternation in one `TOKEN` key;
  titan now holds `TOKEN_A` and `TOKEN_B` separately. Same accepted set, different shape, and nothing
  in either tree notices if they stop agreeing — D10's honest limit. Rotating a key means editing the
  right value in both repos, and a rotation that changes only one of the two alternatives on the source
  side means the `(A|B)` string there no longer splits cleanly. Duplicating the endpoint also doubles
  the public surface that the keys protect: two clusters, two Traefiks, two nginx forwardAuth pods.
- **Key B is unattributed.** Both keys are live on the source and both are kept here, and nobody has
  established what holds key B. Dropping either one is therefore a lockout waiting to happen, which is
  why neither was dropped when the credential got its shape fixed.
- **titan's path to `llm01` is one WireGuard peer.** `llm01` is explicitly not a mesh member
  (`../nixos-configurations hosts/llm01/configuration.nix`), so if the OPNsense peer drops, this
  hostname 502s with the pod still Ready and the Traefik still healthy. The VPS path has the same
  dependency by a different route, so this is not a new single point of failure — but it is now a
  second thing that breaks when that peer does.
- **The Reloader dependency is real but untested here.** D7 makes a token rotation take effect; that
  has not been exercised, because rotating the token would break the endpoint being duplicated.
  The proof is a rotation drill, and it belongs with the first real rotation.
- **No monitoring was added.** Gatus runs on titan (`apply/50-apps/gatus/`) and could probe
  `https://llm.titan.arrieta.eu/`. The shape has to be the §5 pair, not one check expecting `401`:
  `401` is also what a closed-but-unusable endpoint answers, so a lone 401 probe pages green on the
  exact failure this change shipped with in its first draft. Deliberately left out rather than added
  unasked. If the endpoint matters enough to page on it needs an unauthenticated endpoint expecting
  `401` **and** an authenticated one expecting `200` — and the second one puts the token in Gatus's
  own config, which is a second copy inside this tree and therefore earns a `*-check` gate by D10's
  own rule, not a bare probe.
- **No NetworkPolicy.** The `llm` namespace is unsegmented like every other namespace here —
  spec D6 defers NetworkPolicy rather than scheduling it, and a policy that reads as protection
  without enforcement is what that deferral exists to avoid.
