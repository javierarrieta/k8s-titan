# AGENTS.md — k8s-titan

Flux CD GitOps tree for a single-node k3s cluster. Read the spec in
`docs/superpowers/specs/` before changing structure; it records why each choice was
made and what was deliberately left out.

## Layout

    apply/00-bootstrap/     namespaces + the stage Kustomizations + Flux itself
    apply/10-secrets/       SOPS-encrypted Secrets (decrypted by kustomize-controller)
    apply/20-infra/         cert-manager + OVH DNS-01 webhook
    apply/40-certificates/  the titan.arrieta.eu wildcard
    apply/50-apps/          workloads (empty until the first one)

Stage order: `flux-system` → `secrets` → `infra` → `certificates` → `apps`, wired by
`dependsOn` in `apply/00-bootstrap/stage-*.yaml`. Add a stage as its own file there;
do not merge stage objects into one file.

## Rules

- Every stage directory has a `kustomization.yaml` listing its resources explicitly.
  Plain-directory fallback works at runtime but cannot be built offline, and offline
  validation is the only kind this repo can run.
- Never set a top-level `namespace:` in a `kustomization.yaml`. These trees span
  several namespaces and that field rewrites them all.
- Secrets go in `apply/10-secrets/` only, encrypted with `sops edit`. Never write a
  plaintext Secret manifest anywhere else; `make scan` and CI both check.
- The cluster key is `titan-k8s`, not the titan host key. Do not "simplify" the two
  into one: the separation is what caps a pod compromise at titan's own secrets.
- This repo is public. No credentials, and no concrete public IPv4 — write
  `<OVH_PUBLIC_IP>`.
- Ingress class is k3s' bundled `traefik`, and its configuration is **not** managed
  here. TLS for any Ingress is `secretName: titan-tls` in namespace `apps`.
- `make validate` deliberately fails when `apply/10-secrets` holds nothing. Do not
  soften that guard to make a check pass: a gate that passes vacuously is worse than
  no gate.

## Before committing

    make check
    git diff --cached | grep -cE 'AGE-SECRET-KEY-1[A-Z2-9]{40,}'

Both must be clean — the second must print `0`. Note the key *shape*, not the bare
word: this repo's own docs quote the pattern inside their leak checkers.

CI runs GitGuardian on every push and warns, rather than failing, when
`GITGUARDIAN_API_KEY` is absent from the repo.
