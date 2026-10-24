# llm.titan.arrieta.eu — design

Date: 2026-10-24. Implements: a second public front door for the halogen-flash endpoint that has been
served as `llm.v.arrieta.eu` from the techdelivery VPS, now also served by titan at
`llm.titan.arrieta.eu`, with the **same bearer token**. A duplicate, not a migration — the VPS
endpoint stays up and nothing here turns it off.

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
| D5 | image `nginx:1.31.6-alpine@sha256:adad2ae9…`, the **root** image | The digest was read out of the running pod on the source cluster (`kubectl --context vps -n auth get pod -l app=bearer-auth-service -o jsonpath='{…imageID}'`), not from the tag: `nginx:1.31.6-alpine` has since been re-published and now resolves to `sha256:df221db8…`, so a tag-only pin would have silently moved this endpoint to different bytes from the one it duplicates. The `adad2ae9` digest was verified still pullable with `skopeo inspect`. Not the `nginxinc/nginx-unprivileged` variant `apply/60-tesla/wellknown.yaml` uses, because this container rewrites `/etc/nginx/conf.d/default.conf` at start and the unprivileged image's layout for that was not verifiable from here. Consequence in D6. |
| D6 | no `pod-security.kubernetes.io/warn` label on `llm` | Follows open-webui's precedent in `apply/00-bootstrap/namespaces.yaml`: the bearer-auth container runs as root (D5), so a `restricted` warn would fire on every pod in the namespace and train everyone to ignore the label. Not the `files` reasoning (capabilities) and not the `observability` case (a label the workload actually meets). |
| D7 | `llm` added to Reloader's namespace list | Reloader runs `watchGlobally: false`, so its `namespaces` list is the whole scope and an annotation outside it is inert. The nginx renders its config from `$BEARER_TOKEN` at container start and reads the token from a Secret env var, so without the list entry a rotated token sits unread in a running pod: Traefik keeps asking a forwardAuth server still matching the old token, every route stays up, and nothing looks wrong. That list has bitten four times (promtail, open-webui, grafana, mealie — the comments there record each). |
| D8 | bare `Endpoints` with no selector, kept as v1 | The backend is a host outside the cluster. v1 `Endpoints` is deprecated since v1.33 and kubectl warns on every `get`; it is still the supported way to hand a Service a fixed address, it is what the source has run for 221 days, and a hand-authored `EndpointSlice` (the `managed-by` label, the `service-name` link, per-slice ports) is more machinery for the same two facts. Parity with the file being duplicated. |
| D9 | the nginx comparison is copied verbatim, `~*` regex and all | `$http_authorization ~* "Bearer ${BEARER_TOKEN}"` is a case-insensitive **regex** match with the token interpolated into the pattern. That means a token containing regex metacharacters would not match literally, and `bearer` in any casing is accepted. Both are inherited on purpose: changing the comparison is how a working client gets locked out, and the token in use is alphanumeric. If it is ever rewritten, `=` exact-match is the form — and rotate the token in the same change so the new token cannot contain metacharacters. |
| D10 | no new `make` gate | Every other app here got a gate because one credential was written into two or more places (coder's `db-url-check`/`oidc-check`, Mealie's `mealie-check`, grafana's two OIDC checks). This endpoint has one credential in one file in this repo — there is no second copy inside the tree to drift from. The copy that *can* drift is in another repo, and no gate in this tree can read that. |

## 3. Files

| file | change |
|---|---|
| `apply/00-bootstrap/namespaces.yaml` | new `llm` Namespace, with the `kubernetes.io/metadata.name` label the newer entries carry, and the D6 note about the absent warn label |
| `apply/40-certificates/titan-wildcard.yaml` | `llm` added to both Reflector namespace lists (D2), plus a line saying these two lines are the mechanism |
| `apply/20-infra/reloader/reloader.yaml` | `llm` added to `spec.values.namespaces` (D7) |
| `apply/10-secrets/llm-bearer-token.yaml` | Secret `llm-bearer-token` in namespace `llm`, key `TOKEN`, sops-encrypted to titan's recipients |
| `apply/10-secrets/kustomization.yaml` | lists it — an unlisted Secret builds green and is silently never applied |
| `apply/50-apps/llm/llm.yaml` | `Endpoints` + selector-less `Service` `llm01`; the forwardAuth nginx `Deployment` + `Service` + two `ConfigMap`s; `Middleware bearer-auth`; `Ingress llm` |
| `apply/50-apps/kustomization.yaml` | lists it |

The Secret was produced by the documented staging flow, not by hand: decrypt the source file, write
the plaintext to the git-ignored `apply/10-secrets/.staging.llm.yaml` (sops picks recipients from the
file's own path, so the plaintext has to sit under `apply/10-secrets/` briefly), then
`sops --encrypt --in-place "$stage" && mv "$stage" apply/10-secrets/llm-bearer-token.yaml` as one
`&&` chain. `docs/ovh-dns-credential.md` is that flow.

## 4. What is proven

- **The token is the same value.** Decrypted on both sides and compared without printing it:
  `titan value == techdelivery value: True`, 184 base64 characters. The encrypted file carries
  titan's five recipients, first one `age1t5z4e…` — the `titan-k8s` cluster key — so the cluster can
  open it and the techdelivery key is not in the list.
- **The backend is reachable from titan.** `curl http://192.168.0.29:8731/health` → `200`, 83 ms.
- **The old endpoint is live and is doing what this duplicates.** `curl https://llm.v.arrieta.eu/` →
  `401`, resolved and answered by the techdelivery VPS rather than by titan, i.e. the bearer check is
  on there and rejecting unauthenticated requests.
- **`make check` passes** in the worktree: leak-check (staged diff + tracked tree + untracked), all
  nine kustomize builds, `kustomize-listing` 92 manifests / 0 unlisted, `validate` decrypting every
  Secret including the new one, `secrets-placement`, `crd-check` (which saw the `Middleware`),
  `namespace-check` over 187 objects and 17 namespaces including `llm`.
- **The image digest exists in the registry** (`skopeo inspect docker://…@sha256:adad2ae9…`).

## 5. Post-merge, in order

1. Watch the two stages go Ready: `kubectl --context titan -n flux-system get kustomization`, then
   `kubectl --context titan -n llm get pods,svc,endpoints,ingress,middleware`.
2. Confirm the Secret landed by reflection, not by hand:
   `kubectl --context titan -n llm get secret titan-tls` — needs an admin context; the `k8s-reader`
   identity in this workspace is Forbidden for Secrets.
3. **Prove the auth is actually on.** `curl -i https://llm.titan.arrieta.eu/health` with no header
   must be `401`. Anything else — including `200` — means the middleware reference did not resolve
   and the endpoint is public. This is the check that matters most in the whole change, and it is the
   one D3 exists to make unnecessary.
4. Then `curl -i -H "Authorization: Bearer <token>" https://llm.titan.arrieta.eu/health` must be
   `200` from halogen.
5. `make dry-run DRYRUN_CONTEXT=<admin context>` if the merge went in ahead of it. **It was not run
   here**: the `titan` context in the workspace that wrote this is the read-only `k8s-reader`
   identity — `auth can-i '*' '*'` answers `no` and a Secret read is Forbidden — and `dry-run` asks
   the live API server. Core-type validation rules live there, not in any vendored schema, which is
   exactly why AGENTS.md says this gate cannot be replaced offline.

## 6. Not proven, and what it costs

- **Nothing here proves the model works end to end from titan.** `/health` returning 200 proves the
  HTTP path; an actual completion on a 130 GiB model is a different request and has not been sent.
- **Two live endpoints, one token, two repos.** `../k8s-techdelivery` holds the identical token in
  `apply/10-secrets/bearer-auth-token.yaml`. Rotating means editing both, and no gate in either tree
  detects the halves disagreeing. Duplicating the endpoint also doubles the public surface that one
  bearer token protects: two clusters, two Traefiks, two nginx forwardAuth pods, one secret.
- **titan's path to `llm01` is one WireGuard peer.** `llm01` is explicitly not a mesh member
  (`../nixos-configurations hosts/llm01/configuration.nix`), so if the OPNsense peer drops, this
  hostname 502s with the pod still Ready and the Traefik still healthy. The VPS path has the same
  dependency by a different route, so this is not a new single point of failure — but it is now a
  second thing that breaks when that peer does.
- **The Reloader dependency is real but untested here.** D7 makes a token rotation take effect; that
  has not been exercised, because rotating the token would break the endpoint being duplicated.
  The proof is a rotation drill, and it belongs with the first real rotation.
- **No monitoring was added.** Gatus runs on titan (`apply/50-apps/gatus/`) and could probe
  `https://llm.titan.arrieta.eu/` expecting 401 — which is a useful check precisely because 401 is
  the healthy answer. Deliberately left out of this change rather than added unasked; if the endpoint
  matters enough to page on, that probe is the shape to add.
- **No NetworkPolicy.** The `llm` namespace is unsegmented like every other namespace here —
  spec D6 defers NetworkPolicy rather than scheduling it, and a policy that reads as protection
  without enforcement is what that deferral exists to avoid.
