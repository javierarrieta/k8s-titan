# AGENTS.md — k8s-titan

Flux CD GitOps tree for a single-node k3s cluster. Read the spec in
`docs/superpowers/specs/` before changing structure; it records why each choice was
made and what was deliberately left out.

## Layout

    apply/00-bootstrap/     namespaces + the stage Kustomizations + Flux itself
    apply/10-secrets/       SOPS-encrypted Secrets (decrypted by kustomize-controller)
    apply/20-infra/         cert-manager + OVH DNS-01 webhook + Reflector + the
                            CloudNativePG operator + the read-only agent identity
    apply/40-certificates/  the titan.arrieta.eu wildcard, in namespace `certificates`
    apply/50-apps/          workloads — the shared Postgres `Cluster` and its daily
                            `ScheduledBackup` in namespace `databases`, and authentik with
                            its declarative `Database`/`DatabaseRole` in namespace `auth`

Stage order: `flux-system` → `secrets` → `infra` → `certificates` → `apps`, wired by
`dependsOn` in `apply/00-bootstrap/stage-*.yaml`. Add a stage as its own file there;
do not merge stage objects into one file.

Namespaces are declared centrally rather than inside the charts that need them:
`apply/00-bootstrap/namespaces.yaml` holds `apps`, `auth`, `cert-manager`,
`certificates`, `cnpg-system` and `databases`. `k8s-reader` is the one exception — its
own manifest under `20-infra` creates it, because the identity and the namespace are one
thing.

For cluster investigation, use the `k8s-reader` ServiceAccount rather than an admin
kubeconfig — read-only, and it cannot read Secrets. Minting, verification and
rotation are in `docs/agent-read-access.md`. That identity is also Forbidden on
`postgresql.cnpg.io`, so `get cluster`/`get database`/`get backup` need an admin context;
`docs/authentik-runbook.md` §5 records what the read-only identity can prove by effect
instead.

Backups: the Postgres cluster ships base backups and continuous WAL to S3 and **nothing
else does** — the generic PV stream is still deferred, so a PVC that is not that database
has no backup. The same runbook records what has actually been drilled (a scratch-cluster
restore and a point-in-time recovery, both passing), and the two credentials with special
rules: `AUTHENTIK_SECRET_KEY` (never rotate casually — it signs sessions and derives user IDs,
and the sops file is its only copy) and the S3 backup key (the one exposed in a chat transcript
was replaced on 2026-10-05, the cluster archives on the replacement, and the superseded key was
deleted in IAM on 2026-10-06 — that deletion is the proof the rotation took, since anything still
using the old key would have stopped archiving).

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
  else. `make secrets-placement` enforces three halves: no `kind: Secret` outside
  `apply/10-secrets/`, every file there actually carrying `ENC[`, and every file there
  actually listed in that directory's `kustomization.yaml` — an unlisted Secret builds
  fine and is silently never applied.
- The cluster key is `titan-k8s`, not the titan host key. Do not "simplify" the two
  into one: the separation is what caps a pod compromise at titan's own secrets.
- This repo is public. No credentials, and no concrete public IPv4 — write
  `<OVH_PUBLIC_IP>`.
- Ingress class is k3s' bundled `traefik`, and its configuration is **not** managed
  here. `titan-tls` is produced in namespace `certificates` by the wildcard
  `Certificate` and reflected into `apps` and `auth` by Reflector; reference it as
  `secretName: titan-tls` from the namespace your Ingress lives in. Nothing else
  receives it — the allow-list is the `secretTemplate` annotations on
  `apply/40-certificates/titan-wildcard.yaml`, so a new consuming namespace means
  editing that file, never copying the Secret by hand.
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
secrets-placement, release-secrets and crd-check, the gates provable from the tree alone,
and the only control here that `--no-verify` cannot skip. `release-secrets` fails when a
`HelmRelease` reaches for a Secret that is not in `apply/10-secrets` with a matching
namespace, so a typo'd name surfaces on the laptop instead of as a red release three
time zones away; its honest limit is that it proves a name and a namespace exist in the
tree, not that the keys inside are what the chart wants. `crd-check` walks every built
object against the CRDs vendored in `vendor/cnpg-crds/` and rejects any field the schema
does not declare at that position — which is the class of error a normal schema validator
waves through, because the CNPG CRDs set no `additionalProperties: false` anywhere, and
the reason a mis-nested `retentionPolicy` once blocked the whole `apps` stage on the live
cluster after a green build. Refresh those CRDs with `make update-cnpg-crds CNPG=vX.Y.Z`
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

`make kustomize-listing` is in both, and it is not stylistic: `apply/50-apps/coder/coder-db.yaml` was
committed, built green, reviewed green, and named by no kustomization, so Flux would never have
applied it. A manifest nobody lists is a manifest that does not exist.

`make dry-run DRYRUN_CONTEXT=<admin context>` is the only check that asks the live API server, and it
is the one `make check` cannot do: core-type validation rules live in the API server, not in any
schema vendored here. A `PersistentVolumeClaim` LimitRange carrying `default` and no `max` is the
true story — it passed every offline gate and took the `apps` stage down on merge. It skips out loud
without an admin context; the read-only `k8s-reader` identity is Forbidden for it, which was checked
rather than assumed.
