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

### 0.1 The mechanical gate

Those greps are a **fallback**, not the control. A check a human has to remember is a
check that gets skipped under pressure, so the real gate is
`.github/workflows/gitguardian-scan.yml`: `GitGuardian/ggshield/actions/secret@v1.54.0`
on every `push` and `pull_request`, with `fetch-depth: 0` so whole-push diffs are
covered, plus `make scan` for the same engine locally before committing.

The greps above are themselves implemented as `make leak-check`, wired into `make check`,
so they run without being remembered. It runs two independent passes: the pending diff
(the index if something is staged, else the working tree), and — every run, regardless of
the first — the tracked tree at HEAD plus untracked non-ignored files. The second pass is
what makes it non-vacuous: a leak scan over an empty diff is the vacuous-pass pattern this
spec exists to prevent, and a tree scan is never empty.

Two facts shape that workflow:

- **The API key is per-repo, and there is nothing to inherit.** `javierarrieta` is a
  GitHub **user**, not an org, so org-level Actions secrets do not exist; and no
  GitGuardian GitHub App posts checks on these repos — the only `GitGuardian scan`
  check-run on `k8s-casa` is casa's own workflow job, and `k8s-techdelivery` has no
  check-runs at all. A fresh repo therefore starts with no `GITGUARDIAN_API_KEY`, and
  the action hard-fails without it. The workflow gates the scan on the key being
  present and emits a `::warning::` naming the fix when it is absent, so a
  configuration gap does not paint every push red while still being impossible to
  mistake for a passing scan.
- **No `.gitguardian.yaml` ships with this repo.** `k8s-casa` carries nine
  `ignored_matches` entries because SOPS `ENC[AES256_GCM,…]` ciphertext once tripped
  the Generic Password detector, and its own comment warns the SHAs must be re-added
  after every `sops` rewrite. Verified against the current engine (ggshield 1.54.0 /
  secrets engine 2.173.0): `k8s-techdelivery/apply/10-secrets` (15 files) and four of
  the exact casa files carrying those ignore SHAs, copied to a clean directory so no
  config applied, all scan **clean**. The engine no longer flags SOPS ciphertext, so
  pre-loading that ignore list would only import rot. Add a `.gitguardian.yaml` if and
  when a real false positive appears.

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

**Every stage directory carries its own `kustomization.yaml`.** The siblings rely on
kustomize-controller's plain-directory fallback (no `kustomization.yaml` → apply every
YAML found), which works at runtime but cannot be built offline: `kubectl kustomize DIR`
refuses a directory with no `kustomization.yaml`, so the manifests in those repos are
only ever validated by a real cluster. Declaring resources explicitly costs one small
file per stage and buys the §8 offline gate — a malformed manifest fails on the laptop
instead of as a red `Kustomization` three time zones away.

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
├── .gitignore                          # .cache_ggshield, .gitguardian.yaml, age keys,
│                                       #   **/.decrypted*.yaml, and — load-bearing —
│                                       #   apply/10-secrets/.staging.*.yaml (§5.3)
├── .sops.yaml                          # §5
├── .github/workflows/gitguardian-scan.yml  # §0.1
├── .github/workflows/offline-gate.yml  # runs `make check-ci` on every push and PR
├── AGENTS.md                           # agent-facing repo conventions
├── Makefile                            # check / check-ci / leak-check / kustomize-check /
│                                       #   validate / update-keys / secrets-present /
│                                       #   secrets-placement / release-secrets / crd-check /
│                                       #   update-cnpg-crds / scan / secrets-list
├── README.md                           # the three-command runbook + follow-ups
├── docs/ovh-dns-credential.md          # issuing + rotating titan's OVH API application
├── docs/agent-read-access.md           # minting + verifying + rotating the read-only identity
├── docs/authentik-runbook.md           # backup topology, restore drill + recorded output,
│                                       #   first admin, what k8s-reader cannot prove
├── scripts/restore-drill.sh            # scratch-cluster restore from the object store
├── tools/crd-field-check.py            # the validator behind `make crd-check`
├── vendor/cnpg-crds/                   # CNPG CRDs pinned to the operator version, so the
│                                       #   gate can run offline
├── docs/superpowers/specs/             # this file, and the authentik/CNPG spec that amends it
├── docs/superpowers/plans/             # the bootstrap plan, with its supersession
│                                       #   banners, and the authentik/CNPG plan
└── apply/
    ├── 00-bootstrap/
    │   ├── kustomization.yaml              # namespaces + stages + flux-system/
    │   ├── flux-system/
    │   │   ├── kustomization.yaml          # gotk-components + gotk-sync
    │   │   ├── gotk-components.yaml        # flux install output, DO NOT EDIT
    │   │   └── gotk-sync.yaml              # GitRepository + flux-system Kustomization
    │   ├── namespaces.yaml                 # apps, auth, cert-manager, certificates,
    │   │                                   #   cnpg-system, databases
    │   ├── stage-secrets.yaml
    │   ├── stage-infra.yaml
    │   ├── stage-certificates.yaml
    │   └── stage-apps.yaml
    ├── 10-secrets/
    │   ├── kustomization.yaml
    │   ├── ovh-domain-secrets.yaml         # sops-encrypted, namespace: cert-manager
    │   ├── s3-backup-secrets.yaml          # sops-encrypted, ns databases: the IAM pair +
    │   │                                   #   AWS_REGION that open the backup bucket
    │   └── authentik-secrets.yaml          # sops-encrypted: authentik's own Secret and the
    │                                       #   `authentik` role's basic-auth credentials
    ├── 20-infra/
    │   ├── kustomization.yaml
    │   ├── cert-manager/
    │   │   ├── cert-manager.yaml           # OCIRepository + HelmRelease
    │   │   └── ovh-webhook.yaml            # HelmRepository + HelmRelease + ClusterIssuers
    │   ├── k8s-reader/                     # read-only investigation identity, its own ns
    │   ├── reflector/
    │   │   └── reflector.yaml              # HelmRepository + HelmRelease, ns apps
    │   └── cnpg/
    │       └── operator.yaml               # OCIRepository + HelmRelease, ns cnpg-system
    ├── 40-certificates/
    │   ├── kustomization.yaml
    │   └── titan-wildcard.yaml             # Certificate in ns/certificates → Secret
    │                                       #   titan-tls, + Reflector's reflection
    │                                       #   annotations under secretTemplate (§7)
    └── 50-apps/
        ├── kustomization.yaml
        ├── databases/
        │   ├── postgres.yaml               # the shared CNPG Cluster, ns databases,
        │   │                               #   carrying prune: disabled (§9's override)
        │   └── postgres-backup.yaml        # ScheduledBackup: the daily base backup; WAL
        │                                   #   archiving is continuous and implicit
        └── auth/
            ├── authentik-db.yaml           # Database + DatabaseRole for authentik, ns databases
            └── authentik.yaml              # HelmRepository + HelmRelease, ns auth
```

Namespaces are created in `00-bootstrap` rather than inside the charts that need them,
matching both siblings. `namespaces.yaml` now declares six — `apps`, `auth`,
`cert-manager`, `certificates`, `cnpg-system`, `databases` — because the
authentik/CNPG spec (`2026-10-03-titan-authentik-cnpg-design.md` §5.1) added four of
them. That slice also
reversed this section's original "there is no `certificates` namespace": §7 and D10
carry the supersession and the reason. `k8s-reader` is the one namespace
`00-bootstrap` does not create — its own manifest under `20-infra` does, because the
identity and the namespace are a single object.

No `rbac.yaml` ships under `20-infra`: the webhook chart generates the Role it needs,
and §7 explains why the sibling's hand-written Role is not ported.

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

sops reads age identities from `~/.config/sops/age/keys.txt` and does not scan the
directory, so a key stored under a different name is invisible to it: anywhere sops must
decrypt for titan, `SOPS_AGE_KEY_FILE` has to point at the file. Both the README and
`docs/ovh-dns-credential.md` say so, because the failure mode — `make validate` printing
a bare `FAILED:` — looks exactly like a corrupt secret.

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
`OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`.

**Superseded during implementation, recorded so nobody re-shares the credential:** this
section originally specified that titan reuse the OVH API application that already
writes `arrieta.eu` for `k8s-techdelivery`, decrypting that copy and re-encrypting it
for titan in one chain. Two things ended that:

- The techdelivery copy would not decrypt. sops reported a MAC mismatch on that single
  file while every sibling secret in the same directory decrypted cleanly, so the
  one-chain re-encryption had no source to read.
- Reuse would have placed a credential able to rewrite the entire `arrieta.eu` zone
  inside a public-internet cluster, where one compromised pod can edit both clusters'
  DNS. §5.1 rejects precisely that argument for the age key; it applies identically
  here, and sharing was never the safer option — only the quicker one.

titan therefore holds **its own** OVH API application, issued and rotated per
`docs/ovh-dns-credential.md`. The techdelivery credential is unaffected by this repo and
remains a rotation hazard tracked outside it.

---

## 6. Flux installation

### 6.1 Why not `flux bootstrap`

Both siblings were created with `flux bootstrap`. It does not fit here: it demands git
**write** access from the operator's machine, rewrites `gotk-sync.yaml` itself, and
provisions a deploy key this cluster does not need. The repo is authored first and
applied second, which is the declarative path Flux documents.

### 6.2 The artifacts

- `gotk-components.yaml` — output of
  `flux install --components=source-controller,kustomize-controller,helm-controller,notification-controller`
  run with the Flux **v2.9.6** CLI, committed verbatim. The version comes from the
  installed binary — `flux install` has no version flag of its own — so the binary is
  pinned, not the command line, and the generated header (`# Flux Version: v2.9.6`)
  is what proves it. `notification-controller` is inert today (no `Alert`/`Provider`
  objects exist) and is included for parity with the siblings and to avoid a manual
  install the day notifications are wanted.
- `gotk-sync.yaml` — written by hand in Flux's exact generated shape, but carrying its
  own header that says it is hand-written and why there is no `secretRef`, rather than
  the `# This manifest was generated by flux. DO NOT EDIT.` banner the siblings carry:
  this file is edited by hand on purpose, and a do-not-edit banner would invite someone
  to regenerate it and lose the anonymous-clone decision.

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
| `groupName` | `acme.titan.arrieta.eu` — **must differ from techdelivery's `acme.techdelivery.es`**; see the APIService note below |
| ClusterIssuers | `le-prod-titan` (real LE) + `le-staging-titan` (staging), `cnameStrategy: None`, `ovhEndpointName: ovh-eu`, email `javier@techdelivery.es`, creds from `ovh-domain-secrets` |
| RBAC | None hand-written — the chart's own `Role <release>:secret-reader` already names `ovh-domain-secrets` from the issuer refs. techdelivery's extra Role exists only because two webhooks share its `cert-manager` namespace. |
| Certificate | `titan-wildcard` in namespace **`certificates`** → Secret `titan-tls`, reflected into `apps` and `auth` by Reflector; DNS names `titan.arrieta.eu`, `*.titan.arrieta.eu`; issuer `le-prod-titan` |

**Superseded on this point by
`2026-10-03-titan-authentik-cnpg-design.md` §5.3 ("The certificate move, and why now is
the only free moment"). The reasoning that put the `Certificate` in `apps` is kept below,
in the past tense, because it was correct for the cluster titan had then; what changed is
the number of consuming namespaces, not the logic.**

The `Certificate` lived in `apps`, not a dedicated `certificates` namespace, because a
`Certificate` can only produce its Secret in its **own** namespace and the Ingresses
that were to consume `titan-tls` lived in `apps`. `k8s-techdelivery` solves this with a
`certificates` namespace plus the **Reflector** operator mirroring secrets into
consumers — a second cluster-wide component, unjustified while titan had one
certificate and one consuming namespace.

That condition expired: `auth` is now a declared second consumer of `titan-tls` — it sits
in the `Certificate`'s reflection allow-list, and the identity provider designed for it
(the authentik spec's §8) is the second namespace §9 was waiting for. So Reflector is installed
(`apply/20-infra/reflector/reflector.yaml`) and the `Certificate` moved to
`certificates` in the same change rather than half-promoted. Moving it is free **only**
because no Ingress consumes `titan-tls` yet: Flux creates the new object and prunes the
old, deleting the old `Certificate` deletes `apps/titan-tls`, and Reflector repopulates
it from the new source inside the same reconcile. The identical move performed after ten
services sit behind that Secret is a live TLS cutover with a real breakage window, which
is why the moment was taken when it was cheap. Reflector's scope is deliberately narrow —
it replicates TLS material and nothing else, so it cannot quietly become a general
secret-sync path.

The chart's own RBAC is sufficient here: templating `cert-manager-webhook-ovh` `0.6.0`
with titan's values confirms it creates `Role <release>:secret-reader` with
`resourceNames` derived from `issuers[].ovhAuthenticationRef`, plus the `domain-solver`
and `flowcontrol-solver` ClusterRoles and the `APIService v1alpha1.acme.titan.arrieta.eu`.
No hand-written `rbac.yaml` is needed — techdelivery's exists only to widen that Role
for a **second** webhook sharing the `cert-manager` namespace, which titan does not have.

The `groupName` uniqueness requirement is sharper than "avoid challenge collisions": the
chart creates a cluster-scoped `APIService` named `v1alpha1.<groupName>`, so reusing
`acme.techdelivery.es` inside one cluster is a hard conflict, not a soft one.

Staging issuer ships alongside production deliberately: the first DNS-01 attempt
against a new zone is the one worth burning rate limits on.

**Superseded: a `secretTemplate` now ships with titan's `Certificate`, and it is the
mechanism, not an oversight.** Same authority as above
(`2026-10-03-titan-authentik-cnpg-design.md` §5.3).

The original reasoning was that `reflector.v1.k8s.emberstack.com/*` annotations exist
purely to drive the Reflector operator — meaningless on a cluster without it, and part of
why titan's certificate was simply placed in `apps` instead. With Reflector installed,
`titan-wildcard` carries exactly those annotations, naming `apps` and `auth` as the
allowed and auto-reflected namespaces. They have to sit under `secretTemplate` and not on
the `Certificate`'s own `metadata.annotations`: cert-manager copies the template's
annotations onto the `Secret` it produces, and the `Secret` is the object Reflector
reads. Annotations on the `Certificate` itself never reach the `Secret`, and the
`Certificate` reads `Ready` either way, so a misplacement is invisible in status — which is
why the placement is written down rather than left to be rediscovered.

---

## 8. Verification

No cluster access is needed for most of it, which matters because 6443 is mesh-only.

**Offline, in CI and via `make validate`:**

1. `make kustomize-check` — `kubectl kustomize` on every stage directory, which works
   only because each carries a `kustomization.yaml` (§3). Catches a malformed manifest
   or a bad resource reference before it reaches a cluster.
2. `sops --decrypt` every file under `apply/10-secrets` — catches a secret encrypted to
   the wrong key group, the failure mode that surfaces only as a red `secrets` stage.
3. `ggshield secret scan path -r -y .` (`make scan`) on the working tree, and the same
   engine in CI on every push (§0.1). The §0 greps remain as a fallback for a machine
   without ggshield configured.

**Against the cluster, post-bootstrap:**

4. `flux check --pre`.
5. `kubectl get kustomization -A` — all five `Ready=True`.
6. `kubectl -n cert-manager get helmrelease` — both `Ready=True`;
   `kubectl -n cert-manager get clusterissuer` — both `Ready=True`. `kubectl get
   helmrelease -A` shows five in total: those two, Reflector in `apps`, the
   CloudNativePG operator in `cnpg-system`, and authentik in `auth`.
7. `kubectl -n certificates get certificate titan-wildcard` → `Ready=True`, and
   `kubectl get secret titan-tls -A` → the source in `certificates` plus Reflector's
   copies in `apps` and `auth`, and
   `openssl s_client -connect <OVH_PUBLIC_IP>:443 -servername anything.titan.arrieta.eu`
   presents a Let's Encrypt chain.
8. End-to-end: a throwaway Ingress on `whoami.titan.arrieta.eu` serves HTTPS with a real
   certificate, proving wildcard DNS + DNS-01 + bundled Traefik + ServiceLB all line up.
   Deleted after the check.

---

## 9. Deferred, with the trigger that promotes it

| Item | Why not now | Trigger |
|---|---|---|
| PV backups (restic CronJobs → MinIO `titan-pvc`) | Spec §13b's second stream; needs `backup-minio-secrets` and a `30-backup` stage with `prune: false` + `deletionPolicy: Orphan` | Before any workload with data lands on titan — **that trigger has fired and the override was taken consciously**: the Postgres `Cluster` (§6 of the authentik/CNPG spec) is data and it landed without this stream. The compensation the design names is that the database carries its own backup path; that path **has since landed and was verified on titan** — a base backup and continuous WAL in `s3://k8s-titan-pg-562256260016-eu-west-1-an` (`postgres/base/…`, `postgres/wals/…`, both observed as objects, not inferred from a `ContinuousArchiving` condition that predates the configuration) — so the override is **compensated**, not merely accepted. The restore side is proven too, which is the half a written backup never demonstrates: `scripts/restore-drill.sh` recovered a scratch `Cluster` from that bucket and returned a value seeded seconds before the backup, and a paired run to an earlier `recoveryTarget` proved point-in-time recovery is honoured rather than ignored. Both runs are recorded verbatim in `docs/authentik-runbook.md` §2. The restic stream itself stays deferred, with this trigger intact, until a workload with data that is not that database arrives |
| Bundled Traefik tuning (dashboard/API off, 80/443 only) | k3s owns the bundled `HelmChart` in `kube-system` and re-applies it from `/var/lib/rancher/k3s/server/manifests/` on restart, so a Flux patch is reverted. The supported lever is `--helm-chart-configdir`, which is `nixos-configurations` territory. Exposure is already bounded by the OVH Edge Network Firewall (80/443/13491/51820) and the host's default-deny. | Any change to what the dashboard/API binds, or a finding from a scan |
| Monitoring (kube-prometheus-stack, promtail, federation) | Not in scope B, and titan runs no Prometheus at all | **Trigger met.** "Something worth alerting on" is now a real `Cluster` with a real PVC on a shared filesystem. The two metrics that matter are free space on `/var/lib/rancher/k3s/storage` — the actual ceiling for every PVC, because `local-path` ignores the size a PVC asks for — and WAL-archive failure, **which is live now** that the `Cluster` ships base backups and WAL to S3: a failed archive raises no error and accumulates WAL on exactly the filesystem that is going unwatched. Neither is covered today; both are accepted risk until this row is promoted, and together they are what makes this the most overdue row in the table |
| `external-dns` | The wildcard A record already resolves every service name | A service needing a record outside the wildcard |
| Making the repo private | Would force a `secretRef` on the `GitRepository` and a deploy key on a public-internet node — decision D3 | Any secret-shaped reason to lock it down |
| `GITGUARDIAN_API_KEY` repo secret | The scan skips with a visible `::warning::` until it is set (§0.1) | Whenever the operator locates/reissues an API key with `scan` scope |
| `.gitguardian.yaml` ignore list | Nothing to ignore: the current engine does not flag SOPS ciphertext (§0.1) | First real false positive reported by CI |

One row that used to sit here has been promoted and removed rather than quietly left
beside the thing it became: **Reflector + a `certificates` namespace**, whose stated
trigger — a second namespace needing `titan-tls` — fired, and whose move is argued in §7
and D10. A second row has gone the same way since: **apps under `50-apps`**, promoted by
the first workload after the database, which is exactly the trigger that row named. The
stage now carries the shared Postgres `Cluster` and its `ScheduledBackup` in `databases`,
and authentik with its declarative `Database`/`DatabaseRole` in `auth` (§4). Deleting a
row from this table before its trigger fires is the failure mode the table exists to
prevent, which is why each removal is called out instead of left silent.

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
| D9 | Secret scanning | GitGuardian CI action + `make scan`, no ignore list, scan gated on a per-repo API key that is not yet set. Casa's stale SOPS ignores are not copied. |
| D10 | Certificate placement | **Superseded** by D8 of `2026-10-03-titan-authentik-cnpg-design.md`: the `Certificate` now lives in namespace `certificates` and `titan-tls` is reflected into `apps` and `auth` by Reflector. The original choice — `Certificate` in `apps` so `titan-tls` lands where the Ingresses are, no `certificates` namespace, no Reflector in v1 — was right while titan had one certificate and one consuming namespace. §9's trigger fired when `auth` arrived, and §7 explains why moving while zero Ingresses consume the Secret is the only free moment to do it. |
