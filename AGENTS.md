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
    apply/50-apps/          workloads — today the shared Postgres `Cluster`, in
                            namespace `databases`

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
rotation are in `docs/agent-read-access.md`.

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

What runs automatically is `make check-ci` — leak-check, kustomize-check,
secrets-placement and release-secrets, the gates provable from the tree alone, and the
only control here that `--no-verify` cannot skip. `release-secrets` fails when a
`HelmRelease` reaches for a Secret that is not in `apply/10-secrets` with a matching
namespace, so a typo'd name surfaces on the laptop instead of as a red release three
time zones away; its honest limit is that it proves a name and a namespace exist in the
tree, not that the keys inside are what the chart wants. It deliberately excludes
`validate`, which needs the age private key; that key must never be placed in CI. So
`make check` locally is still the full gate, and still yours to run.
