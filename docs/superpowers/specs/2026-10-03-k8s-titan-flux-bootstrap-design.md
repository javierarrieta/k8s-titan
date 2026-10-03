# k8s-titan — Flux bootstrap and certificate path

- **Date:** 2026-10-03
- **Status:** approved design — implementation plan to follow
- **Repo:** `javierarrieta/k8s-titan` (public, empty at time of writing)
- **Cluster:** `titan` — single-node k3s on OVH bare metal, NixOS-managed

---

## 0. This repo is public — read before editing

`javierarrieta/k8s-titan` is a **public** GitHub repo. Everything committed here is
published. Therefore:

- **Never commit credentials** — OVH API key/secret/consumer key, age private keys,
  k3s join tokens, MinIO credentials. Kubernetes Secrets in this repo are
  sops-encrypted (§5) and the plaintext never appears in a commit, a diff, or a log.
- **Never commit the concrete public IPv4 of `titan`.** Write it as
  `<OVH_PUBLIC_IP>`. The literal lives in
  `nixos-configurations`' gitignored `…-ovh-single-node-k3s-design.private.md`.
  RFC1918 (`10/8`, `172.16/12`, `192.168/16`) is fine and is used freely below.
- Age **public** keys are fine to commit — that is their purpose.

Before committing:

```bash
git diff --cached | grep -nE 'AGE-SECRET-KEY-|BEGIN [A-Z ]*PRIVATE KEY|ssh-ed25519 AAAA' \
  | grep -v 'grep -nE' && echo "CREDENTIAL LEAK"
git diff --cached | grep -noE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
  | grep -vE '(^|[^0-9])(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.0\.0\.0|1\.1\.1\.1|8\.8\.[48]\.4|213\.186\.33\.99|224\.)' \
  && echo "PUBLIC IPv4 IN DIFF"
```

---

## 1. Intent and success criteria

`titan` runs a k3s control plane but holds **no workloads and no GitOps agent**. This
repo becomes the single source of truth for what runs in that cluster, bootstrapped
from zero.

Success looks like:

1. Three `kubectl` commands from a machine holding titan's kubeconfig install Flux and
   start the sync loop. No `flux bootstrap`, no git write access from inside the cluster.
2. Every Flux object that defines the repo's own structure — including the stage
   `Kustomization`s — exists in git. Rebuilding the cluster from a bare metal reimage
   needs nothing but this repo plus two out-of-band secrets (`sops-age`, and the OVH
   credentials inside it).
3. `titan.arrieta.eu` and `*.titan.arrieta.eu` resolve to a real Let's Encrypt
   certificate obtained via OVH DNS-01, with no manual DNS work per service.
4. A compromised titan pod cannot read a single secret belonging to `k8s-casa` or
   `k8s-techdelivery`.

**Out of scope for this design** — listed in §9 so they are not forgotten.

---

## 2. Context this design inherits

Read rather than re-derived:

| Source | What it settles |
|---|---|
| `nixos-configurations` spec `2026-10-01-ovh-single-node-k3s-design.md` §13 | This repo is the cluster-side tree; it mirrors `k8s-techdelivery`, not `k8s-casa` (k3s, `local-path`, bundled Traefik, OVH DNS-01). |
| `hosts/titan/vars.nix` | k3s server with `--cluster-init` (embedded etcd), cluster CIDR `10.62.0.0/16`, service CIDR `10.63.0.0/16`, `disable = []` so **bundled Traefik + ServiceLB stay** (decision D4), `--flannel-iface=eno1`. |
| `hosts/titan/README.md` | Host is live: 443 and 13491 open, 6443 reachable only over WireGuard. Residual risk noted there: "titan's age key is the repo-wide admin key". |
| live `k8s-techdelivery` cluster | The real stage graph — see §3. |
| `../public-dns-tf` | `titan.arrieta.eu` + `*.titan.arrieta.eu` A records are Terraform-managed in the `arrieta.eu` OVH zone; cert-manager and Terraform share the zone safely (the webhook's `_acme-challenge` TXT records are not Terraform-managed, so `apply` will not delete them). |

**The gap in the siblings.** In `k8s-techdelivery` the `secrets`, `infra` and `apps`
`Kustomization` objects exist **only in the live cluster** — a branch
(`fix/flux-stage-kustomizations`) was meant to land them in git and did not. Only
`backup-stage.yaml` was committed. So the repo does not, on its own, describe the
cluster. For a from-scratch cluster that is unacceptable, and titan commits its stages
(§4).

**The chicken-and-egg step.** Flux's sops decryption is native to kustomize-controller
(there is no sops-operator anywhere in the siblings), but it needs a `sops-age` Secret
in `flux-system` that git cannot deliver, because git is encrypted with it. It is
created by hand, once (§6).

---

## 3. Stage graph

```
flux-system  →  ./apply/00-bootstrap     interval 10m  prune: true
    │
    ├─ secrets        → ./apply/10-secrets        dependsOn flux-system   + sops decryption
    ├─ infra          → ./apply/20-infra          dependsOn secrets       wait: true, timeout 10m
    ├─ certificates   → ./apply/40-certificates   dependsOn infra
    └─ apps           → ./apply/50-apps           dependsOn certificates
```

All four stage objects live in `./apply/00-bootstrap/stage-*.yaml`, one per file, so
two branches adding stages cannot collide inside one shared file — the hazard
`k8s-techdelivery/apply/00-bootstrap/backup-stage.yaml` documents at length.
`./apply/00-bootstrap` has **no root `kustomization.yaml`**, so the `flux-system`
Kustomization loads it in plain-directory mode and picks the stage files up the same
way it picks up the namespace manifests sitting beside them.

`infra` carries `wait: true, timeout: 10m`. Without it, `certificates` is applied the
moment `infra` is *applied* — before cert-manager and its OVH webhook have actually
installed — and the first `Certificate` sits in `issuer not found` for a reconcile
cycle, which on a fresh cluster reads as breakage. HelmRelease reports `Ready`, so
`wait` makes the dependency real rather than nominal. The cost is honest and accepted:
if cert-manager fails to become Ready, `certificates` and `apps` stay blocked and fail
loudly instead of applying into a half-built cluster.

`prune: true` on every stage. A backup stage (`prune: false`, `deletionPolicy: Orphan`)
is deliberately **not** in this scope (§9).

---

## 4. Repository layout

```
k8s-titan/
├── .gitignore                          # **/.decrypted*.yaml, age keys
├── .sops.yaml                          # §5
├── AGENTS.md                           # agent-facing repo conventions
├── Makefile                            # update-keys / validate / secrets-list
├── README.md                           # the three-command runbook + follow-ups
├── docs/superpowers/specs/             # this file
└── apply/
    ├── 00-bootstrap/
    │   ├── flux-system/
    │   │   ├── gotk-components.yaml    # flux install output, DO NOT EDIT
    │   │   ├── gotk-sync.yaml          # GitRepository + flux-system Kustomization
    │   │   └── kustomization.yaml
    │   ├── namespaces.yaml             # apps, cert-manager, certificates
    │   ├── stage-secrets.yaml
    │   ├── stage-infra.yaml
    │   ├── stage-certificates.yaml
    │   └── stage-apps.yaml
    ├── 10-secrets/
    │   └── ovh-domain-secrets.yaml     # sops-encrypted, namespace: cert-manager
    ├── 20-infra/
    │   └── cert-manager/
    │       ├── cert-manager.yaml       # OCIRepository + HelmRelease
    │       ├── ovh-webhook.yaml        # HelmRepository + HelmRelease + ClusterIssuers
    │       └── rbac.yaml               # webhook SA secret-reader Role
    ├── 40-certificates/
    │   └── titan-wildcard.yaml         # Certificate → Secret titan-tls
    └── 50-apps/
        └── .gitkeep                    # empty until the first workload
```

Namespaces are created in `00-bootstrap` rather than inside the charts that need them,
matching both siblings: `apps`, `cert-manager`, `certificates`.

The stage numbering skips `30-*` on purpose: `30-backup` is reserved for the deferred
backup stage (§9) so titan keeps the siblings' numbering rather than inventing its own.

`age1<titan-k8s>` in §5.2 and `<path-to-titan-k8s.key>` in §6.3 are the only deliberate
placeholders in this document: the keypair is minted during implementation (§5.1), so
its public key cannot be written down before then.

---

## 5. Secrets and the age key

### 5.1 A dedicated `titan-k8s` keypair

A **new** age keypair, minted for this cluster and used by nothing else.

The obvious shortcut — reusing the existing `titan host key`
(`age1vrsm5d9a4gd7wugem8lskq93n5hc7yxvdms77a76xcrqu7eunylscvh48e`, already in
`nixos-configurations/.sops.yaml`) — was considered and rejected. That key decrypts
`secrets/titan.yaml`, which holds host SSH keys, the k3s join token, WireGuard keys
and MinIO credentials. Planting it in the `sops-age` Secret copies it into etcd, where
anything that can read that Secret from a pod can decrypt the host's entire secret set.
A separate key caps a pod compromise at titan's own Kubernetes secrets.

This also closes, on the Kubernetes side, the risk `hosts/titan/README.md` records as
open ("titan's age key is the repo-wide admin key").

**Key custody.** The private key is created once, printed once, and must land in:

1. `~/.config/sops/age/titan-k8s-key.txt` on the operator's machines (mode `0600`), and
2. the password manager, as the off-machine copy.

It is **never** committed here, and never pasted into a terminal that logs it. Losing
both copies makes `apply/10-secrets/*.yaml` unrecoverable; the OVH triple can be
re-issued, so the damage is bounded but real.

### 5.2 `.sops.yaml`

```yaml
creation_rules:
  - path_regex: apply/10-secrets/.*\.ya?ml$
    key_groups:
      - age:
        - age1<titan-k8s>                        # titan cluster (private key: cluster only)
        - age1m5w6y8mh0cq00w8k3du5fk3ct92pyr5z3kdy9ww5w7avgwycgdtq2ezmt3  # Coder workspace
        - age1wynx7pnkg8z6n20zxg2krecmgyy5gdlj6xrs2tmfjctefy2xwv3qa2v24g  # MacBook Air
        - age1ewq0v3rjm0y4m86xq9z555weuspsklz4sz07emhx4awqttjd9sjqnf2t3u  # MacBook Pro
    encrypted_regex: "^(data|stringData)$"
```

The cluster holds only the `titan-k8s` private key; the operator's three keys stay in
the group so they can decrypt, edit, and `sops updatekeys` without the cluster key.
`encrypted_regex` keeps `metadata`, `apiVersion` and `kind` in plaintext so
`kubectl describe` and review stay readable.

### 5.3 `ovh-domain-secrets`

`Secret ovh-domain-secrets` in namespace `cert-manager`, keys `OVH_APPLICATION_KEY`,
`OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY` — the same OVH API application that
already writes `arrieta.eu` DNS for `k8s-techdelivery`, since `titan.arrieta.eu` lives
in that same zone. Implementation decrypts the techdelivery copy with the Coder
workspace key and re-encrypts for titan in one step, so no plaintext reaches a file, a
shell history entry, or a transcript.

---

## 6. Flux installation

### 6.1 Why not `flux bootstrap`

Both siblings were created with `flux bootstrap`. It does not fit here: it demands git
**write** access from the operator's machine, rewrites `gotk-sync.yaml` itself, and
provisions a deploy key this cluster does not need. The repo is authored first and
applied second, which is the declarative path Flux documents.

### 6.2 The artifacts

- `gotk-components.yaml` — output of
  `flux install --version v2.9.6 --components=source-controller,kustomize-controller,helm-controller,notification-controller`,
  committed verbatim. `notification-controller` is inert today (no `Alert`/`Provider`
  objects exist) and is included for parity with the siblings and to avoid a manual
  install the day notifications are wanted.
- `gotk-sync.yaml` — written by hand in Flux's exact generated shape, carrying the
  `# This manifest was generated by flux. DO NOT EDIT.` banner the siblings carry so
  nobody treats it as machine-owned:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  url: https://github.com/javierarrieta/k8s-titan
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./apply/00-bootstrap
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

No `secretRef`: the repo is public, so the source-controller clones anonymously.
Nothing git-related lives in the cluster, so there is nothing to rotate and nothing to
steal. Write access stays entirely on the operator's side. If the repo is ever made
private, this is the one object that changes (§9).

### 6.3 The runbook

Three commands, from a machine with titan's kubeconfig (the mesh is the only path to
6443, so in practice: over WireGuard, or on the host with `sudo k3s kubectl`):

```bash
kubectl apply -f apply/00-bootstrap/flux-system/gotk-components.yaml
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=<path-to-titan-k8s.key>
kubectl apply -f apply/00-bootstrap/flux-system/gotk-sync.yaml
```

The order is load-bearing. `sops-age` before the sync object means the `secrets` stage
finds its key on the first attempt instead of failing one cycle and retrying — and on a
bootstrap, a red object is indistinguishable from a broken one.

---

## 7. cert-manager, OVH DNS-01, the wildcard certificate

Ported from `k8s-techdelivery/apply/20-infra/cert-manager/` with titan values.

| Piece | Value |
|---|---|
| cert-manager | `1.21.1` from `oci://quay.io/jetstack/charts/cert-manager` via `OCIRepository` + `ref.semver`; `replicaCount: 1`; `crds.enabled: true, keep: true`; drift detection enabled; `RetryOnFailure` on install and upgrade, `crds: CreateReplace` |
| OVH webhook | `cert-manager-webhook-ovh` `0.6.0` from `https://aureq.github.io/cert-manager-webhook-ovh/` |
| `groupName` | `acme.titan.arrieta.eu` — **must differ from techdelivery's `acme.techdelivery.es`**; two clusters sharing a ACME group against one zone is how challenges collide |
| ClusterIssuers | `le-prod-titan` (real LE) + `le-staging-titan` (staging), `cnameStrategy: None`, `ovhEndpointName: ovh-eu`, email `javier@techdelivery.es`, creds from `ovh-domain-secrets` |
| RBAC | `Role` + `RoleBinding` granting the webhook SA `get`/`watch` on `ovh-domain-secrets` **by resource name only**. techdelivery's equivalent also names `kanghuru-ovh-secrets`, which titan has no use for; that name is dropped. |
| Certificate | `titan-wildcard` in namespace `certificates` → Secret `titan-tls`; DNS names `titan.arrieta.eu`, `*.titan.arrieta.eu`; issuer `le-prod-titan` |

Staging issuer ships alongside production deliberately: the first DNS-01 attempt
against a new zone is the one worth burning rate limits on.

`secretTemplate` carries the annotation that keeps renewal from requiring a pod restart
where the consumer supports it, matching current cert-manager guidance.

---

## 8. Verification

No cluster access is needed for most of it, which matters because 6443 is mesh-only.

**Offline, in CI and via `make validate`:**

1. `kubectl kustomize` each stage directory — catches a malformed manifest or a bad
   `kustomization.yaml` before it reaches a cluster.
2. `sops --decrypt` every file under `apply/10-secrets` — catches a secret encrypted to
   the wrong key group, the failure mode that surfaces only as a red `secrets` stage.
3. The §0 credential and public-IPv4 greps against the staged diff.

**Against the cluster, post-bootstrap:**

4. `flux check --pre`.
5. `kubectl get kustomization -A` — all five `Ready=True`.
6. `kubectl -n cert-manager get helmrelease` — both `Ready=True`;
   `kubectl -n cert-manager get clusterissuer` — both `Ready=True`.
7. `kubectl -n certificates get certificate titan-wildcard` → `Ready=True`, and
   `openssl s_client -connect <OVH_PUBLIC_IP>:443 -servername anything.titan.arrieta.eu`
   presents a Let's Encrypt chain.
8. End-to-end: a throwaway Ingress on `whoami.titan.arrieta.eu` serves HTTPS with a real
   certificate, proving wildcard DNS + DNS-01 + bundled Traefik + ServiceLB all line up.
   Deleted after the check.

---

## 9. Deferred, with the trigger that promotes it

| Item | Why not now | Trigger |
|---|---|---|
| PV backups (restic CronJobs → MinIO `titan-pvc`) | Spec §13b's second stream; needs `backup-minio-secrets` and a `30-backup` stage with `prune: false` + `deletionPolicy: Orphan` | Before any workload with data lands on titan |
| Bundled Traefik tuning (dashboard/API off, 80/443 only) | k3s owns the bundled `HelmChart` in `kube-system` and re-applies it from `/var/lib/rancher/k3s/server/manifests/` on restart, so a Flux patch is reverted. The supported lever is `--helm-chart-configdir`, which is `nixos-configurations` territory. Exposure is already bounded by the OVH Edge Network Firewall (80/443/13491/51820) and the host's default-deny. | Any change to what the dashboard/API binds, or a finding from a scan |
| Monitoring (kube-prometheus-stack, promtail, federation) | Not in scope B | titan holds something worth alerting on |
| `external-dns` | The wildcard A record already resolves every service name | A service needing a record outside the wildcard |
| Making the repo private | Would force a `secretRef` on the `GitRepository` and a deploy key on a public-internet node — decision D3 | Any secret-shaped reason to lock it down |
| Apps under `50-apps` | Nothing to deploy yet | First workload |

---

## 10. Decision record

| # | Decision | Choice |
|---|---|---|
| D1 | v1 scope | Skeleton + certificate path (cert-manager, OVH issuers, wildcard `Certificate`). No backups, no monitoring, no apps. |
| D2 | Cluster key | Dedicated `titan-k8s` age keypair, not the existing titan host key — caps pod compromise at titan's own secrets. |
| D3 | Git transport | Anonymous HTTPS, no `secretRef`. Repo is public; nothing git-shaped lives in the cluster. |
| D4 | Bootstrap mechanics | Committed `flux install` output + hand-written `gotk-sync.yaml`, applied with `kubectl`. No `flux bootstrap`. |
| D5 | Execution | Assistant authors and commits; operator runs the three commands. No cluster-admin credential in the authoring session. |
| D6 | Ingress | Bundled k3s Traefik + ServiceLB stay (inherits `nixos-configurations` D4); tuning deferred to `nixos-configurations`. |
| D7 | Stage objects | Committed to git, one file per stage, `wait: true` on `infra`. Fixes the siblings' gap. |
| D8 | Layout | Mirrors `k8s-techdelivery` numbering (`00-bootstrap`, `10-secrets`, `20-infra`, `40-certificates`, `50-apps`), not `k8s-casa`. |
