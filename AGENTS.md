# AGENTS.md — k8s-titan

Flux CD GitOps tree for a single-node k3s cluster. Read the spec in
`docs/superpowers/specs/` before changing structure; it records why each choice was
made and what was deliberately left out.

## Layout

    apply/00-bootstrap/     namespaces + the stage Kustomizations + Flux itself
    apply/10-secrets/       SOPS-encrypted Secrets (decrypted by kustomize-controller)
    apply/20-infra/         cert-manager + OVH DNS-01 webhook + Reflector + the
                            CloudNativePG operator + the read-only agent identity
    apply/30-databases/     the shared Postgres `Cluster` and its daily `ScheduledBackup`,
                            in namespace `databases`
    apply/40-certificates/  the titan.arrieta.eu wildcard, in namespace `certificates`
    apply/50-apps/          authentik with its declarative `Database`/`DatabaseRole` in
                            namespace `auth`, coder with its own, open-webui with its own in
                            namespace `open-webui`, grafana with its own in namespace
                            `observability`, the `llm` front door for the halogen endpoint on
                            llm01 with its bearer token, and any future app that passes the
                            admission test below
    apply/60-tesla/         TeslaMate with its own `Database`/`DatabaseRole`, Grafana and the
                            Tesla Fleet Telemetry intake, in namespace `apps`
    apply/70-backup/        restic PV backups to casa's MinIO: one discovery CronJob per
                            participating namespace, repo-wide retention and integrity, and the
                            RBAC Reflector cannot mirror. A volume is in scope only if its PVC
                            carries `backup.titan.arrieta.eu/class` — there is no volume list in
                            this directory, and `make backup-coverage` is what proves the
                            annotation, the runner, the Reflector mirror lists and the RBAC agree.

**One numbered directory is one stage is one Flux `Kustomization`.** That is the layout
convention: a stage is a top-level numbered directory under `apply/`, never a subdirectory of
another stage. It matters because Flux applies a `Kustomization` atomically — one object failing
server-side dry-run means nothing in that unit is applied — so the directory boundary is the
failure boundary, and nesting stages would collapse separate failure domains back into one.

Stage order: `flux-system` → `secrets` → `infra` → `databases` → `certificates` → `apps` →
`tesla` → `backup`, wired by `dependsOn` in `apply/00-bootstrap/stage-*.yaml`. The numbers are build and
reading order; `dependsOn` is what actually orders reconciles. Add a stage as its own file there;
do not merge stage objects into one file.

**Adding a small app means one new subdirectory under `apply/50-apps/` and one line in
`apply/50-apps/kustomization.yaml`** — the same shape `auth/` and `coder/` already have. It is not a
new stage, so it gets no numbered directory and no `stage-*.yaml`. Whether a workload belongs in the
shared `apps` stage at all is decided by the admission test in
`docs/superpowers/specs/2026-10-19-titan-app-scale-out-design.md` §3.1 — a stage name is not a policy,
and that test exists because Tesla landed in `apps` before anyone wrote one. A workload that earns
its own stage gets a numbered directory under `apply/`, a `stage-<name>.yaml` in `00-bootstrap`, and
that file listed in `00-bootstrap/kustomization.yaml`. Either way the manifest must be listed
somewhere: a manifest in a directory no `kustomization.yaml` names is a manifest Flux never applies,
and `make kustomize-listing` is what catches it.

Namespaces are declared centrally rather than inside the charts that need them:
`apply/00-bootstrap/namespaces.yaml` holds `apps`, `auth`, `cert-manager`,
`certificates`, `cnpg-system` and `databases`. `k8s-reader` is the one exception — its
own manifest under `20-infra` creates it, because the identity and the namespace are one
thing.

For cluster investigation, use the `k8s-reader` ServiceAccount rather than an admin
kubeconfig — read-only, and it cannot read Secrets. Minting, verification and
rotation are in `docs/agent-read-access.md`. That identity can read `postgresql.cnpg.io`
(`clusters`, `databases`, `databaseroles`, `backups`, `scheduledbackups`, `poolers`) as of
2026-10-19, so `get cluster`/`get database`/`get backup` no longer need an admin context — CNPG
CRs reference Secrets by name only, so this discloses topology, never credential values. It still
cannot read Secrets, and `docs/authentik-runbook.md` §5 remains the record of what the identity
could prove by effect before that grant, which is still the stronger evidence when it is available.

Backups: two independent paths, and the split is the thing to get straight. The Postgres cluster
ships base backups and continuous WAL to S3, drilled for both a scratch-cluster restore and a
point-in-time recovery (`docs/authentik-runbook.md`). Everything else on a PVC goes through
`apply/70-backup/` — restic to `titan-pv-backups` on casa's MinIO — and **a volume is only in
scope if its PVC carries `backup.titan.arrieta.eu/class: daily`**. Ask the cluster, not this
file: `kubectl get pvc -A -L backup.titan.arrieta.eu/class`. Two deliberate exclusions, both
argued in `docs/superpowers/specs/2026-10-22-titan-restic-pv-backups-design.md`: `postgres-1`,
because a file copy of a live datadir can restore corrupt and CNPG owns that path; and
`files/opencloud-data`, because OpenCloud's state is a metadata tree plus a blob bucket and
restoring one without the other is a restore that looks healthy and is corrupt — so with no
capacity to mirror the bucket, **files uploaded to `files.titan.arrieta.eu` have no backup of any
kind**; `coder-workspaces`, by operator decision — a coder workspace must be reproducible
from its image and from git, so **anything in a workspace home that is neither is not
recoverable**; and both Grafana volumes, because every provider sets `allowUiUpdates: false`, the
datasources and the admin credentials are in git, and a wiped PVC rebuilds itself — what it loses
is anything built by hand in the UI. Neither path is monitored yet: casa owns the Prometheus that would alert on a stale
snapshot and no such alert exists for titan, so a week of failed backups currently looks exactly
like a week of successful ones. The restic side has also never been restored — the spec's §10 is
that list.

That covers TeslaMate's driving history and TeslaMate's settings,
which are rows in that same cluster and are not in git. The runbook at
`docs/authentik-runbook.md` records what has actually been drilled (a scratch-cluster
restore and a point-in-time recovery, both passing), and the two credentials with special
rules: `AUTHENTIK_SECRET_KEY` (never rotate casually — it signs sessions and derives user IDs,
and the sops file is its only copy) and the S3 backup key (the one exposed in a chat transcript
was replaced on 2026-10-05, the cluster archives on the replacement, and the superseded key was
deleted in IAM on 2026-10-06 — that deletion is the proof the rotation took, since anything still
using the old key would have stopped archiving). TeslaMate's own runbook is
`docs/teslamate-runbook.md`, and its §10 is the list of what has NOT been proven yet — read that
before trusting anything else in that file.

Metrics: this cluster runs no Prometheus. k8s-casa's central Prometheus pulls node, control-plane,
kubelet, cAdvisor and kube-state-metrics metrics over the WireGuard mesh from `192.168.133.1`, and
`docs/titan-metrics-scrape.md` is the runbook. **The consumer of all of it now lives on titan**:
`apply/50-apps/grafana/` runs a Grafana in namespace `observability` whose Prometheus datasource is
casa's, reached over the mesh at `https://prometheus.local.arrieta.eu`. It is a whole-homelab view by
decision, not misconfiguration — that Prometheus holds casa, titan and techdelivery, and `cluster` is
absent on titan's own node_exporter and comin scrapes, so it is not a usable filter. Both
datasources are unauthenticated and Grafana proxies them server-side, so casa putting
`prometheus.local` behind authentik empties every panel at once with the pod still healthy.
`docs/grafana-runbook.md` is that runbook. Two things there are load-bearing and easy to undo by
accident: node metrics come from the NixOS `node_exporter` and never from a DaemonSet (the host owns
`:9100`, and the `k3s_etcd_snapshot_*` gauges a broken backup depends on cannot be produced by a pod),
and kube-state-metrics leaves the cluster through the kube-apiserver service proxy rather than a
NodePort, because `publicHost.meshTCPPortExtraSources` opens mesh ports to the whole home LAN and KSM
is unauthenticated. etcd is **not** scraped and no rule will ever report it unhealthy.

Logs: pod logs are **pushed** to k8s-casa's Loki by the promtail DaemonSet in
`apply/20-infra/monitoring/promtail.yaml`, while metrics are pulled — opposite directions,
and `docs/titan-logs-loki.md` is the runbook. Two things there are load-bearing: titan's host
journald is already in that same Loki via the host's own `rsyslog.enable` in nixos-configurations,
so a `journal` job here would ship it twice; and casa's Loki caps `max_label_names_per_series` at
18, so the `labeldrop` list in that ConfigMap is a hard limit and not cleanup — over the line and
the stream is rejected per-pod, silently, with promtail reporting healthy.

## Rules

- Every stage directory has a `kustomization.yaml` listing its resources explicitly.
  Plain-directory fallback works at runtime but cannot be built offline, and offline
  validation is the only kind this repo can run.
- Never set a top-level `namespace:` in a `kustomization.yaml`. These trees span
  several namespaces and that field rewrites them all.
- Secrets go in `apply/10-secrets/` only, encrypted with sops — see
  `docs/ovh-dns-credential.md` for the staging flow (`sops --encrypt --in-place` on a
  git-ignored name under `apply/10-secrets/`), which exists because sops picks its
  recipients from the file's own path. Never write a plaintext Secret manifest anywhere
  else. `make secrets-placement` enforces four halves: no `kind: Secret` outside
  `apply/10-secrets/`, every file there actually carrying `ENC[`, every file there actually
  listed in that directory's `kustomization.yaml` — an unlisted Secret builds fine and is
  silently never applied — and no `data:` in a file there. That last one is not stylistic: a
  Secret's `data:` values are base64 by contract, a sops ciphertext is not base64, and the API
  server refuses the undecrypted tree on server-side dry-run, so `make dry-run` stops at
  `10-secrets` and never reaches the stage you changed. Use `stringData`.
- The cluster key is `titan-k8s`, not the titan host key. Do not "simplify" the two
  into one: the separation is what caps a pod compromise at titan's own secrets.
- **sops matches creation rules against the path you hand it, not the path the output lands at.** So
  `sops --encrypt /tmp/x.yaml > apply/10-secrets/y.yaml` dies with `no matching creation rules found`
  *after* the shell redirect has already truncated `y.yaml` to zero bytes — the damage reads like the
  encrypt failed, not like the redirect ate the file. Stage the plaintext inside `apply/10-secrets/`,
  encrypt to a temp file, confirm it is non-empty, then move it into place. To change one key, the quiet
  path is `sops set <file> '["stringData"]["KEY"]' --value-stdin` with the value JSON-encoded — file
  before index, and `--value-file` errors with `Invalid set index format` in sops 3.13.3. Neither form
  prints the secret, which is the point.
- This repo is public. No credentials, and no concrete public IPv4 — write
  `<OVH_PUBLIC_IP>`.
- Ingress class is k3s' bundled `traefik`, and its configuration is **not** managed
  here. `titan-tls` is produced in namespace `certificates` by the wildcard
  `Certificate` and reflected into `apps` and `auth` by Reflector; reference it as
  `secretName: titan-tls` from the namespace your Ingress lives in. Nothing else
  receives it — the allow-list is the `secretTemplate` annotations on
  `apply/40-certificates/titan-wildcard.yaml`, so a new consuming namespace means
  editing that file, never copying the Secret by hand. **The one deliberate exception is
  `streaming.titan.arrieta.eu`, which points at `tesla-streaming-tls` from
  `apply/40-certificates/tesla-streaming.yaml`. That is not duplication to collapse back into the
  wildcard: TeslaMate's Erlang stream client rejects wildcard SANs and crash-loops every time a car
  comes online. Read that file's header before changing it.**
- Live drift is **not** corrected here. The HelmReleases run `driftDetection.mode: enabled`, which is
  notify-only, and Helm's new-vs-old patching lets an out-of-band env var survive every later upgrade
  indefinitely — so `kubectl edit` on a Helm-managed Deployment makes a permanent change that git never
  sees and `make dry-run` cannot detect. Prefer a commit; if you must poke live, remove it explicitly
  afterwards (`kubectl -n <ns> set env deploy/<name> FOO-`) and say so. Forcing a sync does not undo
  drift, and the `requestedAt` annotation only fires when its value changes — `docs/flux-manual-sync.md`.
  See `docs/authentik-runbook.md` §9, which is written because this was assumed false once.
- `make validate` deliberately fails when `apply/10-secrets` holds nothing. Do not
  soften that guard to make a check pass: a gate that passes vacuously is worse than
  no gate.

## Before committing

    git add -A
    make check

`make check` runs `leak-check` first, and `leak-check` reads the **index** — so stage
first, because the diff pass is what names the change you are about to publish. With
nothing staged it falls back to the working tree, and independently of both it re-scans
the whole tracked tree at HEAD plus untracked non-ignored files on every run, so it can
never pass vacuously and never goes red just because there is nothing to commit. It
greps for the credential shapes spec §0 names (age key, PEM private key, OpenSSH key
prefix) plus the concrete public IPv4 check spec §0 mandates, and it always scans
untracked non-ignored files on top — a key dropped next to a manifest is what this gate
is for. It is assembled so it can never match its own source. Note the key *shape*, not
the bare word: this repo's own docs quote the pattern inside their leak checkers.

`make scan` runs ggshield when it is installed and `GITGUARDIAN_API_KEY` is set, and
says `SKIPPED` out loud when either is missing — it no longer reports a found secret as
a skip. CI runs GitGuardian on every push and warns, rather than failing, when
`GITGUARDIAN_API_KEY` is absent from the repo.

What runs automatically is `make check-ci` — leak-check, kustomize-check, kustomize-listing,
secrets-placement, release-secrets, secret-refs, backup-coverage, crd-check and namespace-check,
the gates provable from the tree alone,
and the only control here that `--no-verify` cannot skip. `release-secrets` fails when a
`HelmRelease` reaches for a Secret that is not in `apply/10-secrets` with a matching
namespace, so a typo'd name surfaces on the laptop instead of as a red release three
time zones away; its honest limit is that it proves a name and a namespace exist in the
tree, not that the keys inside are what the chart wants. `secret-refs` is that gate for the
hand-written half of the tree, because `release-secrets` walks `HelmRelease` objects and
nothing else and `secrets-placement` never asks who consumes a Secret file: it fails when a
built `Deployment`/`StatefulSet`/`DaemonSet`/`CronJob`/`Job` names a Secret — `envFrom`,
`secretKeyRef`, a `secret` volume, a projected source, an `imagePullSecret` — that no `Secret`
in the same namespace declares. Secrets the cluster itself produces are the one hole, listed by
name and namespace with a producer in `PRODUCED_IN_CLUSTER` (today: `apps/titan-tls`, reflected in
by Reflector); an entry there is a deliberate gap, not a fix. Same honest limit as
`release-secrets`: a name and a namespace, never the keys inside. It was written because the
investing-agent migration had to hand-check its `envFrom` name and nothing in the tree would
have caught a typo. `crd-check` walks every built
object against the CRDs vendored in `vendor/cnpg-crds/` and rejects any field the schema
does not declare at that position — which is the class of error a normal schema validator
waves through, because the CNPG CRDs set no `additionalProperties: false` anywhere, and
the reason a mis-nested `retentionPolicy` once blocked the whole `apps` stage on the live
cluster after a green build. `namespace-check` rejects any built object naming a namespace no
`Namespace` object in this tree declares, and any namespaced object that omits
`metadata.namespace` and would land in `default`, which exists, so nothing downstream ever
notices. It was written because a dashboard ConfigMap copied from k8s-casa carried
`namespace: casa` into the `apps` stage on 2026-10-21: the build and `crd-check` were both
green, the API server answered `namespaces "casa" not found` at apply time, and since Flux
applies a stage atomically that one line held the whole stage red for three hours and took an
exporter down with it. Its honest limit is existence, not intent — `namespace: apps` on a
Grafana dashboard passes, because `apps` exists. It also enforces the Flux-side half of the
no-top-level-`namespace` rule: no `Kustomization` may set `spec.targetNamespace`. Refresh those CRDs with `make update-cnpg-crds CNPG=vX.Y.Z`
whenever the operator pin moves: a stale schema answers confidently and wrongly. It
deliberately excludes
`validate`, which needs the age private key; that key must never be placed in CI. So
`make check` locally is still the full gate, and still yours to run.

Two gates exist because coder stores one credential in files nothing else ties together.
`db-url-check` fails when the Postgres URL in `coder-secrets` and the password CNPG owns in
`coder-db-credentials` disagree — one password kept twice is one rotation away from a silent split.
`oidc-check` goes further: coder's copy, the authentik blueprint's copy, the reviewed template, and
whether the HelmRelease actually mounts that blueprint all have to agree, because an unmounted
blueprint is indistinguishable from one never written. Both read sops-encrypted values, so both are
in `check` and not `check-ci` — the same rule that keeps `validate` out. `db-url-check` is
reference-driven, so a tree with no references reports zero instead of passing vacuously.

`open-webui-oidc-check` is the same shape one app further on, with one extra failure mode: open-webui's
role mapping reads a `groups` claim, and with role management enabled a missing or unmatched claim is a
403 rather than a fallback role — so a dropped `profile` scope or `OAUTH_ALLOWED_ROLES` left at its
default locks every non-admin out of a login page that still looks healthy. `db-url-check` is
reference-driven across both `HelmRelease` and `Deployment` env — including a `DATABASE_URL` that
arrives through `envFrom` rather than a named `secretKeyRef` — so a tree with no references reports
zero instead of passing vacuously.

`sure-check` is that class one app further on, and it exists because every older gate is shape-bound in a
way that misses Sure: `db-url-check` walks a `HelmRelease` env named `*PG_CONNECTION_URL` or a
`Deployment`'s `DATABASE_URL`, and Sure is a `HelmRelease` carrying `DATABASE_URL`, so that gate reports
zero references and passes. `sure-check` reads the `values` block instead and ties the OIDC client across
blueprint, mount and `sure-secrets`, the DB password across both files that hold it, the Redis password
across the two keys and the pod that reads them, and the chart defaults that fail silently at
`health=ok` — including the one where `rails.existingSecret` makes the chart emit only `SECRET_KEY_BASE`
and the three Active Record encryption keys, so anything else in that Secret has to be named in
`rails.extraEnvVars` or the Secret has it, the pod does not, and the feature stays off at `health=ok`. Its
honest limit is written in its docstring: it proves `ALLOWED_OIDC_DOMAINS` is non-empty and cannot prove
it contains the domain of the identity that will sign in, and a non-empty list is exclusive — a miss
refuses that identity after a successful IdP login, with every gate green.

`make kustomize-listing` is in both, and it is not stylistic: `apply/50-apps/coder/coder-db.yaml` was
committed, built green, reviewed green, and named by no kustomization, so Flux would never have
applied it. A manifest nobody lists is a manifest that does not exist.

`make dry-run DRYRUN_CONTEXT=<admin context>` is the only check that asks the live API server, and it
is the one `make check` cannot do: core-type validation rules live in the API server, not in any
schema vendored here. A `PersistentVolumeClaim` LimitRange carrying `default` and no `max` is the
true story — it passed every offline gate and took the `apps` stage down on merge. It skips out loud
without an admin context; the read-only `k8s-reader` identity is Forbidden for it, which was checked
rather than assumed.
