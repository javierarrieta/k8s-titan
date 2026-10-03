# k8s-titan

Flux-managed manifests for `titan`, a single-node k3s cluster on OVH bare metal.
Design: `docs/superpowers/specs/2026-10-03-k8s-titan-flux-bootstrap-design.md`

The cluster is public-internet-facing. SSH is on 13491, the API server on 6443 is
reachable only over WireGuard, and ingress is k3s' bundled Traefik + ServiceLB on
80/443.

## Before the first bootstrap

Two things git cannot deliver, because git is encrypted with one of them:

1. **`sops-age`** — the `titan-k8s` age private key, created in the cluster's own
   `flux-system` namespace (step 2 below).
2. **`ovh-domain-secrets`** — OVH API credentials that can write `arrieta.eu` DNS.
   Issue and encrypt them per [`docs/ovh-dns-credential.md`](docs/ovh-dns-credential.md).

## Bootstrap (three commands, run once)

From a machine with titan's kubeconfig — over the mesh, or on the host with
`sudo k3s kubectl`:

    kubectl apply -f apply/00-bootstrap/flux-system/gotk-components.yaml
    kubectl -n flux-system create secret generic sops-age \
      --from-file=age.agekey=~/.config/sops/age/titan-k8s-key.txt
    kubectl apply -f apply/00-bootstrap/flux-system/gotk-sync.yaml

Order matters. `sops-age` before the sync object means the `secrets` stage finds
its key on the first attempt; on a bootstrap a red object is indistinguishable
from a broken one.

No `flux bootstrap`, and no git credentials in the cluster: the repo is public, so
the source-controller clones anonymously.

## Verifying a bootstrap

    flux check --pre
    kubectl get kustomization -A          # all five Ready=True
    kubectl -n cert-manager get helmrelease,clusterissuer
    kubectl -n apps get certificate titan-wildcard   # Ready=True

Then prove the whole path with a throwaway Ingress on `whoami.titan.arrieta.eu`
and `openssl s_client -connect <OVH_PUBLIC_IP>:443 -servername
whoami.titan.arrieta.eu`. Delete the Ingress afterwards.

Reading a failure:

- `secrets` red with a decryption error → the `sops-age` secret is missing or holds
  a different key. Delete and recreate it, then
  `kubectl -n flux-system annotate kustomization secrets -s reconcile.fluxcd.io/requestedAt=`.
- `certificates` red with `le-prod-titan not found` → `infra` has not gone Ready yet;
  that is `dependsOn` working, not a fault.
- `Certificate` stuck `NotReady` with an ACME challenge error → the OVH credentials
  lack write access to `arrieta.eu`, or DNS has not propagated. Check the challenge
  Order's events before assuming DNS. Distinguish the two: `issuer not found` is a
  dependency that has not landed, while a presented-but-unseen challenge is DNS or
  credentials.

## Day-to-day

Everything is a `git push`. **`prune: true` is on for every stage**: anything you
`kubectl apply` into a stage-managed path is deleted within ten minutes. Fix it in
git.

    make check            # kustomize build every stage + decrypt every secret + secret scan
    make update-keys      # after rotating the age key group
    make secrets-list

## Not here (yet)

PV restic backups, monitoring, external-dns, Reflector, and tuning of the bundled
Traefik — which k3s owns and re-applies on restart, so its values are set from
`nixos-configurations`, not from this repo. Each has its trigger recorded in the
spec's deferred table.
