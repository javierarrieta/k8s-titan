# k8s-titan

Flux-managed manifests for `titan`, a single-node k3s cluster on OVH bare metal.
Design: `docs/superpowers/specs/2026-10-03-k8s-titan-flux-bootstrap-design.md`, as
amended by `docs/superpowers/specs/2026-10-03-titan-authentik-cnpg-design.md`

The cluster is public-internet-facing. SSH is on 13491, the API server on 6443 is
reachable only over WireGuard, and ingress is k3s' bundled Traefik + ServiceLB on
80/443.

Namespaces are declared in one place — `apply/00-bootstrap/namespaces.yaml` — rather
than inside the charts that need them: `cert-manager` (cert-manager, its OVH DNS-01
webhook, the OVH credentials), `certificates` (the wildcard `Certificate`, and therefore
the source of `titan-tls`), `apps` (workloads, plus Reflector's copy of `titan-tls`),
`databases` (the shared Postgres `Cluster`), `auth` (for the identity provider, which is
not in this tree yet), `cnpg-system` (the CloudNativePG operator). Reflector mirrors
`titan-tls` into `apps` and `auth` and nothing else; the allow-list lives on the
`Certificate`.

## Before the first bootstrap

You need the `flux` and `kubectl` binaries and a checkout of this repo — `flux check
--pre` is not something a bare shell has.

Two things git cannot deliver, because git is encrypted with one of them:

1. **`sops-age`** — the `titan-k8s` age private key. It is minted with `age-keygen` on
   the operator's machine (spec §5.1), never committed; only the Secret built from it
   lands in the cluster's `flux-system` namespace (step 2 below).
2. **`ovh-domain-secrets`** — OVH API credentials that can write `arrieta.eu` DNS.
   Issue and encrypt them per [`docs/ovh-dns-credential.md`](docs/ovh-dns-credential.md).

**Where sops looks for that key.** sops reads age identities from
`~/.config/sops/age/keys.txt`; it does not scan the directory. If your titan key lives
at `~/.config/sops/age/titan-k8s-key.txt` instead, export
`SOPS_AGE_KEY_FILE=~/.config/sops/age/titan-k8s-key.txt` before running any target that
decrypts, or `make validate` prints a bare `FAILED:` that reads exactly like a broken
secret when the real problem is that sops never had the key.

## Bootstrap (three commands, run once)

Merge this tree to `main` first — the `GitRepository` syncs `main`, and until the tree
exists there, a bootstrapped Flux has nothing to reconcile.

Preflight, from a machine with titan's kubeconfig — over the mesh, or on the host with
`sudo k3s kubectl`:

    flux check --pre

Then the three commands:

    kubectl apply -f apply/00-bootstrap/flux-system/gotk-components.yaml
    kubectl -n flux-system create secret generic sops-age \
      --from-file=age.agekey=$HOME/.config/sops/age/titan-k8s-key.txt
    kubectl apply -f apply/00-bootstrap/flux-system/gotk-sync.yaml

`$HOME`, not `~`. Bash expands a tilde only at the start of a word or after `=` in
something that looks like a variable assignment, and `--from-file=age.agekey=~/...` is
neither — kubectl is handed a literal `~` and reports the key file is missing. The same
`~/` is fine in `export SOPS_AGE_KEY_FILE=~/...`, which *is* an assignment, so this is not
a style preference.

Order matters. `sops-age` before the sync object means the `secrets` stage finds
its key on the first attempt; on a bootstrap a red object is indistinguishable
from a broken one.

No `flux bootstrap`, and no git credentials in the cluster: the repo is public, so
the source-controller clones anonymously. If this repo ever goes private, that
anonymous clone is the first thing to break — add a deploy key as a `secretRef` on
the `GitRepository` in `apply/00-bootstrap/flux-system/gotk-sync.yaml` at the same
moment you flip visibility, or every stage stops reconciling in silence. Update the
`gitrepository auth` assertion in `make kustomize-check` in the same change; it
asserts no `secretRef` exists and would otherwise fail permanently.

## Verifying a bootstrap

    kubectl get kustomization -A          # all five Ready=True
    kubectl get helmrelease -A            # four: cert-manager and its OVH webhook in
                                          # cert-manager, reflector in apps,
                                          # cloudnative-pg in cnpg-system
    kubectl -n cert-manager get clusterissuer    # both Ready=True
    kubectl -n certificates get certificate titan-wildcard   # Ready=True
    kubectl get secret titan-tls -A       # certificates holds the source; apps and
                                          # auth hold Reflector's copies

Then prove the whole path with a throwaway Ingress on `whoami.titan.arrieta.eu`
and `openssl s_client -connect <OVH_PUBLIC_IP>:443 -servername
whoami.titan.arrieta.eu`. Delete the Ingress afterwards.

The `titan-tls` copies are worth checking on a fresh bootstrap: the `Certificate` can be
`Ready` while a namespace that is missing from its allow-list silently has no Secret, and
an Ingress then fails on a missing Secret rather than on a broken certificate.

Reading a failure:

- `secrets` red with a decryption error → the `sops-age` secret is missing or holds
  a different key. Delete and recreate it, then
  `kubectl -n flux-system annotate kustomization secrets -s reconcile.fluxcd.io/requestedAt=`.
- `certificates` red with `dependency 'flux-system/infra' is not Ready` → `infra` has
  not gone Ready yet. That is `dependsOn` plus `wait: true` working, not a fault.
- `Certificate` stuck `NotReady` with an ACME challenge error → the OVH credentials
  lack write access to `arrieta.eu`, or DNS has not propagated. Check the challenge
  Order's events before assuming DNS: a challenge that was presented but never seen is
  DNS or credentials, while an issuer that is not Ready is a dependency that has not
  landed.

## Day-to-day

Everything is a `git push`. **`prune: true` is on for every stage**, and it does the
opposite of what the name suggests: kustomize-controller garbage-collects only the
objects in a stage's own inventory. Something you `kubectl apply` by hand was never in
that inventory, so it **survives** — indefinitely, invisible to Git, quietly diverging
from what the repo says. What prune does guarantee is that anything Git owns gets put
back: edit a live object and the next reconcile reverts it. So fix things in git, and
if you hand-apply something to debug, delete it yourself — Flux will not do it for you.

    make check            # leak scan + stage builds + stage paths + secrets decrypt
                          #   + placement + release-secrets
    make check-ci         # the same without `validate` (it needs the age key): CI's set
    make leak-check       # credential/public-IPv4 shapes: the pending diff AND the whole tree
    make release-secrets  # every Secret a HelmRelease reaches for is in apply/10-secrets
    make update-keys      # after rotating the age key group
    make secrets-list

`make check` fails until the OVH credential in step 2 of *Before the first bootstrap*
exists. That is deliberate — a gate that passes on zero secrets is not a gate.

CI runs `make check-ci` on every push and PR: the gates provable from the tree alone.
It deliberately excludes `validate`, because that needs the age private key and that key
must never be placed in CI. This is the one control here that `--no-verify` cannot skip.
`make leak-check` scans the staged diff (or the working tree) *and*, on every run
regardless, the whole tracked tree plus untracked non-ignored files — so it is never
vacuous and never red on a clean checkout. Stage first anyway: the diff pass is the one
that points at the change you are about to publish.

## Not here (yet)

PV restic backups, monitoring, external-dns, and tuning of the bundled Traefik — which
k3s owns and re-applies on restart, so its values are set from `nixos-configurations`,
not from this repo. Each has its trigger recorded in the spec's deferred table.

Reflector is no longer on that list: it landed with the authentik/CloudNativePG slice,
which also moved the `Certificate` into `certificates`. What that slice has *not* landed
here yet — authentik itself, and the `Cluster`'s backup path to an object store — is
recorded in `docs/superpowers/specs/2026-10-03-titan-authentik-cnpg-design.md`, not here.
