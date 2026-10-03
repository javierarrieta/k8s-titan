# k8s-titan Flux Bootstrap and Certificate Path — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the empty `k8s-titan` repo into the Flux-managed source of truth for the single-node k3s cluster on `titan`, delivering the bootstrap tree, sops-encrypted secrets wiring, cert-manager with OVH DNS-01, and a `titan.arrieta.eu` wildcard certificate.

**Architecture:** A staged Flux tree (`flux-system` → `secrets` → `infra` → `certificates` → `apps`), every stage object committed to git rather than created by hand in the cluster. Flux is installed from committed `flux install` output applied with `kubectl` — no `flux bootstrap`, no git credentials in the cluster. Secrets are SOPS-encrypted with a dedicated `titan-k8s` age key and decrypted natively by kustomize-controller.

**Tech Stack:** Flux v2.9.6, kustomize (via `kubectl kustomize`), Helm via Flux `HelmRelease`/`OCIRepository`, cert-manager 1.21.1, cert-manager-webhook-ovh 0.6.0, sops 3.13.3 + age, GitHub Actions + ggshield.

**Spec:** `docs/superpowers/specs/2026-10-03-k8s-titan-flux-bootstrap-design.md` — every decision below is argued there; read it alongside this plan.

## Global Constraints

- Flux **v2.9.6**, components `source-controller,kustomize-controller,helm-controller,notification-controller` (spec §6.2).
- cert-manager **1.21.1** from `oci://quay.io/jetstack/charts/cert-manager`; `cert-manager-webhook-ovh` **0.6.0** from `https://aureq.github.io/cert-manager-webhook-ovh/`.
- ACME `groupName` is exactly `acme.titan.arrieta.eu`. ClusterIssuers are exactly `le-prod-titan` and `le-staging-titan`. Registration email `javier@techdelivery.es`. `ovhEndpointName: ovh-eu`. `cnameStrategy: None`.
- Certificate is exactly `titan-wildcard` in namespace `apps`, Secret `titan-tls`, DNS names `titan.arrieta.eu` and `*.titan.arrieta.eu`.
- Namespaces created by this repo: `apps`, `cert-manager`. No `certificates` namespace (spec §7).
- Every stage directory carries a `kustomization.yaml`, and **no** `kustomization.yaml` ever sets a top-level `namespace:` transformer — these trees span multiple namespaces and that field would rewrite them all.
- Stage `interval: 10m0s`, `prune: true`; `GitRepository` `interval: 1m0s`; `infra` additionally `wait: true` + `timeout: 10m0s`.
- sops `encrypted_regex` is exactly `^(data|stringData)$`; the only cluster-held key is the `titan-k8s` keypair.
- Never commit: plaintext secret values, age private keys, the concrete public IPv4 of titan (write `<OVH_PUBLIC_IP>`). Spec §0's greps run before every commit in this plan.
- Working directory for every command: the repo root, `/home/coder/k8s-titan`.

## Review Focus

These are the failure modes the spec implies that no manifest build catches, because they only manifest against a live cluster or a live ACME account. Each line gets a check in the task that owns the relevant file.

1. **`sops-age` absent or holding the wrong key.** The `secrets` stage fails decryption and every downstream stage blocks on it; the operator sees a red `Kustomization`, not a clear message. Expected: the README names this exact symptom and its one-line fix. → Task 8.
2. **`groupName` reused from another cluster.** The webhook chart creates a cluster-scoped `APIService v1alpha1.<groupName>`; a duplicate is a hard install failure, not a warning. Expected: the value is asserted, not eyeballed. → Task 5.
3. **OVH credentials without write access to `arrieta.eu`.** The `Certificate` sits `NotReady` with an ACME challenge error that looks like a DNS propagation problem. Expected: the README's verification section distinguishes "challenge not presented" from "issuer not found". → Task 8.
4. **The repo is later made private.** The anonymous `GitRepository` starts failing to clone and the whole cluster silently stops reconciling. Expected: the sync object is asserted to carry no `secretRef`, and the README states what changes if privacy is ever needed. → Tasks 3 and 8.
5. **`prune: true` garbage-collects a hand-created object.** ~~Anyone who `kubectl apply`s a fix into a stage-managed path has it deleted within 10 minutes.~~ **This item was wrong as written, and Task 8 shipped the correction rather than the claim.** Flux garbage-collects only objects recorded in the Kustomization's own inventory; a hand-applied object was never in it and is never pruned — it survives indefinitely and invisible to Git. What prune guarantees is the reverse: objects Git owns get reverted on the next reconcile. The README now states the true behaviour, and notes that a debugging object is yours to delete.

---

### Task 1: The `titan-k8s` age keypair and `.sops.yaml`

**Files:**
- Create: `~/.config/sops/age/titan-k8s-key.txt` (outside the repo, mode `0600`)
- Create: `.sops.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: the `titan-k8s` age **public** key, recorded in `.sops.yaml`; the **private** key at `~/.config/sops/age/titan-k8s-key.txt`, which Task 4 encrypts against and which the operator later plants in the cluster as the `sops-age` Secret.

- [ ] **Step 1: Confirm the key does not already exist**

Run:

```bash
test -e "$HOME/.config/sops/age/titan-k8s-key.txt" && echo "EXISTS — stop, do not overwrite" || echo "absent, safe to mint"
```

Expected: `absent, safe to mint`. If it prints `EXISTS`, stop: overwriting it would orphan every secret already encrypted to it.

- [ ] **Step 2: Mint the keypair**

```bash
umask 077
mkdir -p "$HOME/.config/sops/age"
age-keygen -o "$HOME/.config/sops/age/titan-k8s-key.txt"
chmod 600 "$HOME/.config/sops/age/titan-k8s-key.txt"
age-keygen -y "$HOME/.config/sops/age/titan-k8s-key.txt"
```

The last command prints the `age1…` public key. Copy it to the shell session; Step 3 reads it back itself.

- [ ] **Step 3: Write `.sops.yaml` with that public key**

The public key is interpolated, not typed, so it cannot drift from the private key on disk. `\$` produces a literal `$` in the unquoted heredoc.

```bash
PUB=$(age-keygen -y "$HOME/.config/sops/age/titan-k8s-key.txt")
cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: apply/10-secrets/.*\.ya?ml\$
    key_groups:
      - age:
        - $PUB  # titan-k8s cluster key (private key lives in the cluster only)
        - age1m5w6y8mh0cq00w8k3du5fk3ct92pyr5z3kdy9ww5w7avgwycgdtq2ezmt3  # Coder workspace (gray-sailfish-49)
        - age1wynx7pnkg8z6n20zxg2krecmgyy5gdlj6xrs2tmfjctefy2xwv3qa2v24g  # MacBook Air
        - age1ewq0v3rjm0y4m86xq9z555weuspsklz4sz07emhx4awqttjd9sjqnf2t3u  # MacBook Pro
    encrypted_regex: "^(data|stringData)\$"
EOF
```

- [ ] **Step 4: Verify the file is correct and holds no private key**

```bash
grep -c 'age1' .sops.yaml
grep -F "$(age-keygen -y "$HOME/.config/sops/age/titan-k8s-key.txt")" .sops.yaml
grep -rl 'AGE-SECRET-KEY' . && echo "PRIVATE KEY IN REPO" || echo "clean"
```

Expected: `4`, then the line echoing the public key, then `clean`.

- [ ] **Step 5: Record the custody obligation**

The private key now exists in exactly one place. Before committing, confirm you have a plan to copy it to the password manager and to any other operator machine — Task 8 writes this into the README, but the key is unrecoverable if it is lost before then.

- [ ] **Step 6: Commit**

```bash
git add .sops.yaml
git diff --cached | grep -nE 'AGE-SECRET-KEY-' && echo "CREDENTIAL LEAK" || git commit -m "secrets: add sops config with a dedicated titan-k8s age key

Reusing the existing titan host key would put a key that decrypts
secrets/titan.yaml inside etcd, reachable from any pod that can read the
sops-age secret. A separate key caps a pod compromise at titan's own
Kubernetes secrets."
```

Expected: the commit runs (the `grep` finds nothing, so the `||` branch fires).

---

### Task 2: Bootstrap stage — namespaces, four stage Kustomizations, and the offline gate

> **SUPERSEDED — do not execute as written.** The `Makefile` snippets below are the first
> draft of the offline gate, and review rewrote them three times since. `kustomize-check`
> now additionally asserts that every declared stage path carries its own
> `kustomization.yaml`, that exactly one `GitRepository` document exists and carries no
> `secretRef`, and that exactly one ACME `groupName` is in use; `check` gained
> `leak-check` and `secrets-placement` and runs `leak-check` first; `validate-serial` and
> `update-keys-serial` were deleted as redundant; and `check-ci` — the keyless subset CI
> runs — did not exist yet. Re-appending these snippets would append a second
> `kustomize-check` recipe, and make takes the last one, silently reverting all of it.
> The shipped `Makefile` is the authority.

**Files:**
- Create: `apply/00-bootstrap/kustomization.yaml`
- Create: `apply/00-bootstrap/namespaces.yaml`
- Create: `apply/00-bootstrap/stage-secrets.yaml`
- Create: `apply/00-bootstrap/stage-infra.yaml`
- Create: `apply/00-bootstrap/stage-certificates.yaml`
- Create: `apply/00-bootstrap/stage-apps.yaml`
- Modify: `Makefile` (append `kustomize-check` and `check`)

**Interfaces:**
- Consumes: nothing.
- Produces: Flux `Kustomization` objects named `secrets`, `infra`, `certificates`, `apps` in namespace `flux-system`, and the `make kustomize-check` target every later task uses as its test.

- [ ] **Step 1: Add the offline gate, and stop the sops targets from eating kustomization files**

The existing `validate` / `update-keys` / `secrets-list` targets came from the siblings,
whose secret directories contain no `kustomization.yaml`. This repo's do, so those
targets would try to `sops --decrypt` a kustomization file and report a false failure.
Patch the three `find` expressions, then append the new targets.

In each of `update-keys-serial`, `update-keys`, `validate-serial`, `validate` and
`secrets-list`, change:

```make
find apply/10-secrets -name "*.yaml"
```

to:

```make
find apply/10-secrets -name "*.yaml" ! -name kustomization.yaml
```

Then append to `Makefile`, and add `kustomize-check check` to the existing `.PHONY` line
at the top:

```make
# Build every stage directory that declares a kustomization.yaml. This is the
# offline gate: kustomize-controller will happily attempt a malformed tree and
# fail three time zones away, which is a worse place to learn it. The empty-tree
# case is a failure on purpose — a stage directory that forgets its
# kustomization.yaml would otherwise pass by being invisible.
kustomize-check:
	@dirs=$$(find apply -name kustomization.yaml -printf '%h\n' | sort); \
	if [ -z "$$dirs" ]; then \
	  echo "FAIL: no directory under apply/ declares a kustomization.yaml"; exit 1; \
	fi; \
	for d in $$dirs; do \
	  printf 'kustomize %s: ' "$$d"; \
	  if kubectl kustomize "$$d" > /dev/null; then echo OK; else echo " FAIL"; exit 1; \
	  fi; \
	done
	@echo "kustomize-check: all stage directories build"

# Everything that can be proven without a cluster. leak-check is FIRST: make has no
# -k, so it stops at the first failure, and validate needs the age key - a leak gate
# placed behind validate would never run for anyone who forgot SOPS_AGE_KEY_FILE.
check: leak-check kustomize-check validate secrets-placement
	@echo "check: all offline gates passed"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make kustomize-check`
Expected: `FAIL: no directory under apply/ declares a kustomization.yaml`, exit 1.

- [ ] **Step 3: Write the namespaces**

`apply/00-bootstrap/namespaces.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: apps
  labels:
    name: apps
  annotations:
    kubernetes.io/description: "Workloads on titan and the TLS secret they consume"
---
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
  labels:
    name: cert-manager
  annotations:
    kubernetes.io/description: "cert-manager, its OVH DNS-01 webhook, and the OVH API credentials"
```

- [ ] **Step 4: Write the four stage Kustomizations**

`apply/00-bootstrap/stage-secrets.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: secrets
  namespace: flux-system
spec:
  dependsOn:
    - name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  interval: 10m0s
  path: ./apply/10-secrets
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

`apply/00-bootstrap/stage-infra.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra
  namespace: flux-system
spec:
  dependsOn:
    - name: secrets
  interval: 10m0s
  path: ./apply/20-infra
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  # Real, not nominal: HelmRelease reports Ready, so this makes `certificates`
  # wait for cert-manager to actually be installed rather than merely applied.
  # Without it the first Certificate sits in "issuer not found" on a fresh
  # cluster, which reads as breakage. Cost: if cert-manager never goes Ready,
  # certificates and apps stay blocked and fail loudly.
  timeout: 10m0s
  wait: true
```

`apply/00-bootstrap/stage-certificates.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: certificates
  namespace: flux-system
spec:
  dependsOn:
    - name: infra
  interval: 10m0s
  path: ./apply/40-certificates
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

`apply/00-bootstrap/stage-apps.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  dependsOn:
    - name: certificates
  interval: 10m0s
  path: ./apply/50-apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

- [ ] **Step 5: Write the bootstrap kustomization**

`apply/00-bootstrap/kustomization.yaml` — note there is no `namespace:` key, deliberately (Global Constraints):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespaces.yaml
  - stage-secrets.yaml
  - stage-infra.yaml
  - stage-certificates.yaml
  - stage-apps.yaml
```

- [ ] **Step 6: Verify the gate passes and the graph is what was intended**

```bash
make kustomize-check
kubectl kustomize apply/00-bootstrap | grep -c '^kind: Kustomization'
kubectl kustomize apply/00-bootstrap | grep -c 'name: flux-system'
kubectl kustomize apply/00-bootstrap | grep -c 'provider: sops'
```

Expected: both stage directories build; `4` (the four stages — the `flux-system`
Kustomization itself arrives in Task 3); a non-zero count; `1`. The `^` anchor matters:
without it the Flux CRDs' `names.kind:` entries would be counted too.

- [ ] **Step 7: Commit**

```bash
git add apply/00-bootstrap Makefile
git diff --cached | grep -nE 'AGE-SECRET-KEY-|BEGIN [A-Z ]*PRIVATE KEY' && echo "LEAK" || git commit -m "feat: commit the stage graph that the sibling repos leave in the cluster

k8s-techdelivery keeps its secrets/infra/apps Kustomizations only in the
live cluster, so the repo alone cannot rebuild it. Here they are committed,
one file per stage, so two branches cannot collide in a shared file.

Adds make kustomize-check, which builds every stage directory: the siblings
rely on kustomize-controller's plain-directory fallback, which cannot be
built offline and so is only ever validated by a real cluster."
```

---

### Task 3: Flux itself — `gotk-components.yaml` and `gotk-sync.yaml`

**Files:**
- Create: `apply/00-bootstrap/flux-system/gotk-components.yaml` (generated)
- Create: `apply/00-bootstrap/flux-system/gotk-sync.yaml`
- Create: `apply/00-bootstrap/flux-system/kustomization.yaml`
- Modify: `apply/00-bootstrap/kustomization.yaml` (append `flux-system`)

**Interfaces:**
- Consumes: the `flux-system` namespace, created by `gotk-components.yaml` itself.
- Produces: the `GitRepository` named `flux-system` that every stage's `sourceRef` points at, and the `flux-system` `Kustomization` that Task 2's `stage-secrets.yaml` declares as its `dependsOn` target.

- [ ] **Step 1: Install the pinned Flux CLI**

`flux install` has no version flag — the generated manifests carry the CLI's own version, so the binary is what gets pinned.

```bash
curl -sL --fail -o /tmp/flux.tgz \
  https://github.com/fluxcd/flux2/releases/download/v2.9.6/flux_2.9.6_linux_amd64.tar.gz
tar -xzf /tmp/flux.tgz -C /tmp flux
/tmp/flux --version
```

Expected: output contains `2.9.6`.

- [ ] **Step 2: Write `gotk-sync.yaml`**

Hand-written in Flux's generated shape. The banner is kept so nobody treats it as machine-owned; it is not.

`apply/00-bootstrap/flux-system/gotk-sync.yaml`:

```yaml
# Hand-written in the shape `flux bootstrap` would generate. Deliberately has no
# secretRef: the repo is public, so the source-controller clones anonymously and
# nothing git-shaped lives in the cluster to rotate or to steal. If the repo ever
# goes private this is the one object that changes.
---
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

- [ ] **Step 3: Generate `gotk-components.yaml`**

```bash
mkdir -p apply/00-bootstrap/flux-system
/tmp/flux install \
  --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  > apply/00-bootstrap/flux-system/gotk-components.yaml
head -4 apply/00-bootstrap/flux-system/gotk-components.yaml
```

Expected header:

```
---
# This manifest was generated by flux. DO NOT EDIT.
# Flux Version: v2.9.6
# Components: source-controller,kustomize-controller,helm-controller,notification-controller
```

If the version line says anything other than `v2.9.6`, Step 1 did not install the pinned binary — fix that rather than editing the file.

- [ ] **Step 4: Write the flux-system kustomization and wire it into the bootstrap**

`apply/00-bootstrap/flux-system/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
```

Append to the `resources:` list in `apply/00-bootstrap/kustomization.yaml` so it ends as:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespaces.yaml
  - stage-secrets.yaml
  - stage-infra.yaml
  - stage-certificates.yaml
  - stage-apps.yaml
  - flux-system
```

- [ ] **Step 5: Verify**

```bash
make kustomize-check
kubectl kustomize apply/00-bootstrap | grep -c '^kind: Kustomization'
kubectl kustomize apply/00-bootstrap | grep -A12 '^kind: GitRepository' | grep -c 'secretRef'
kubectl kustomize apply/00-bootstrap | grep -c 'image: ghcr.io/fluxcd/'
```

Expected: three directories build; `5` (four stages + `flux-system`); `0` — **this is
Review Focus item 4, the assertion that nothing git-shaped lives in the cluster**; and a
count ≥ 4 for the controller images. The `^` anchors keep the Flux CRDs' own
`names.kind:` entries from being counted.

- [ ] **Step 6: Commit**

```bash
git add apply/00-bootstrap
git commit -m "feat: install Flux from committed manifests instead of flux bootstrap

flux bootstrap wants git write access and rewrites the sync object itself.
The repo is authored first and applied second here, so the generated
manifests are committed and applied with kubectl. Version comes from the
pinned v2.9.6 CLI, not a flag flux install does not have."
```

---

### Task 4: OVH DNS credentials, re-encrypted for titan

> **SUPERSEDED — do not execute as written.** Steps 3–5 assume the plaintext source is
> `k8s-techdelivery/apply/10-secrets/ovh-domain-secrets.yaml`. That file cannot be
> decrypted (sops MAC mismatch on that one file; every sibling decrypts cleanly), and
> reusing techdelivery's credential was rejected on blast-radius grounds anyway: a
> zone-wide DNS-write key inside a public-internet cluster lets one compromised pod
> edit every zone the account owns. titan holds its **own** OVH application, issued and
> encrypted per `docs/ovh-dns-credential.md`, and spec §5.3 records the decision. What
> shipped: `apply/10-secrets/kustomization.yaml` plus a titan-scoped encrypted
> `ovh-domain-secrets.yaml`. The supersession also covers the **Interfaces** line below,
> which names the techdelivery file as the plaintext source, and **Step 6**'s commit
> message, which claims "Same OVH application that already writes arrieta.eu for
> k8s-techdelivery" — both describe the rejected shared credential and are wrong. The
> verification steps below remain valid and were run.

**Files:**
- Create: `apply/10-secrets/kustomization.yaml`
- Create: `apply/10-secrets/ovh-domain-secrets.yaml` (sops-encrypted)

**Interfaces:**
- Consumes: the `titan-k8s` key from Task 1 via `.sops.yaml`; the OVH application key, secret and consumer key issued for titan alone, per `docs/ovh-dns-credential.md`. There is no plaintext source file to decrypt — the operator pastes the values straight into the staging file that document names.
- Produces: `Secret ovh-domain-secrets` in namespace `cert-manager` with keys `OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY` — consumed by Task 5's ClusterIssuers.

- [ ] **Step 1: Verify the target does not exist yet**

Run: `ls apply/10-secrets/ovh-domain-secrets.yaml`
Expected: `No such file or directory`.

- [ ] **Step 2: Write the stage kustomization**

`apply/10-secrets/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ovh-domain-secrets.yaml
```

- [ ] **Step 3: Re-encrypt the OVH triple for titan, in one chain**

`titan.arrieta.eu` lives in the same OVH zone `k8s-techdelivery` already writes, so the credentials are the same application. The decrypt and the encrypt are one `&&` chain so plaintext never sits in the working tree across an interactive step, and `sops --encrypt --in-place` matches the `apply/10-secrets/` path rule so `encrypted_regex` applies.

```bash
sops --decrypt /home/coder/k8s-techdelivery/apply/10-secrets/ovh-domain-secrets.yaml \
  > apply/10-secrets/ovh-domain-secrets.yaml \
  && sops --encrypt --in-place apply/10-secrets/ovh-domain-secrets.yaml
```

If this fails partway, run `shred -u apply/10-secrets/ovh-domain-secrets.yaml` before retrying, and confirm with `git status --porcelain` that no plaintext was staged.

- [ ] **Step 4: Verify it is encrypted, decryptable, and complete**

```bash
grep -c 'ENC\[' apply/10-secrets/ovh-domain-secrets.yaml
sops filestatus apply/10-secrets/ovh-domain-secrets.yaml
make validate
sops --decrypt apply/10-secrets/ovh-domain-secrets.yaml | grep -cE '^\s+(OVH_APPLICATION_KEY|OVH_APPLICATION_SECRET|OVH_CONSUMER_KEY):'
grep -c 'namespace: cert-manager' apply/10-secrets/ovh-domain-secrets.yaml
```

Expected: ≥ 3; `encrypted: true`; `OK: apply/10-secrets/ovh-domain-secrets.yaml`; `3`; `1`.

- [ ] **Step 5: Verify metadata stayed readable and no plaintext is staged**

```bash
grep -E '^(kind|apiVersion|  name):' apply/10-secrets/ovh-domain-secrets.yaml
git add apply/10-secrets
git diff --cached | grep -nE 'OVH_[A-Z_]+: [A-Za-z0-9]{8,}' && echo "PLAINTEXT STAGED" || echo "clean"
```

Expected: `apiVersion`, `kind: Secret`, `name: ovh-domain-secrets` visible in plaintext (that is what `encrypted_regex` buys), then `clean`.

- [ ] **Step 6: Commit**

```bash
git diff --cached | grep -nE 'AGE-SECRET-KEY-|BEGIN [A-Z ]*PRIVATE KEY' && echo "LEAK" || git commit -m "secrets: add OVH DNS credentials encrypted to the titan-k8s key

titan's own OVH application, scoped to DNS writes for arrieta.eu and encrypted so
titan's cluster key is the only cluster key that can read it. Decrypt and encrypt run
as one chain so no plaintext crosses an interactive step."
```

---

### Task 5: cert-manager and the OVH DNS-01 webhook

**Files:**
- Create: `apply/20-infra/kustomization.yaml`
- Create: `apply/20-infra/cert-manager/cert-manager.yaml`
- Create: `apply/20-infra/cert-manager/ovh-webhook.yaml`

**Interfaces:**
- Consumes: `Secret ovh-domain-secrets` in `cert-manager` (Task 4); the `cert-manager` namespace (Task 2).
- Produces: ClusterIssuers `le-prod-titan` and `le-staging-titan`, consumed by Task 6's `Certificate`.

- [ ] **Step 1: Verify the gate fails for this stage**

Run: `kubectl kustomize apply/20-infra`
Expected: error — the directory does not exist.

- [ ] **Step 2: Write cert-manager**

`apply/20-infra/cert-manager/cert-manager.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  interval: 5m
  url: oci://quay.io/jetstack/charts/cert-manager
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    operation: copy
  ref:
    semver: "1.21.1"
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  releaseName: cert-manager
  chartRef:
    kind: OCIRepository
    name: cert-manager
  interval: 30m
  driftDetection:
    mode: enabled
  install:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  upgrade:
    crds: CreateReplace
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  values:
    replicaCount: 1
    crds:
      enabled: true
      keep: true
```

- [ ] **Step 3: Write the OVH webhook and its issuers**

`apply/20-infra/cert-manager/ovh-webhook.yaml`. No hand-written RBAC: templating this chart with these values confirms it creates `Role <release>:secret-reader` naming `ovh-domain-secrets` from the issuer refs (spec §7).

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: cert-manager-webhook-ovh
  namespace: cert-manager
spec:
  interval: 1h0s
  url: https://aureq.github.io/cert-manager-webhook-ovh/
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager-webhook-ovh
  namespace: cert-manager
spec:
  chart:
    spec:
      chart: cert-manager-webhook-ovh
      sourceRef:
        kind: HelmRepository
        name: cert-manager-webhook-ovh
      version: "0.6.0"
  interval: 1h0s
  releaseName: cert-manager-webhook-ovh
  values:
    # The chart creates a cluster-scoped APIService named
    # v1alpha1.<groupName>. Reusing another cluster's groupName in one cluster
    # is a hard conflict, so this value is titan's own.
    groupName: acme.titan.arrieta.eu
    certManager:
      namespace: cert-manager
      serviceAccountName: cert-manager
    issuers:
      - name: le-prod-titan
        create: true
        kind: ClusterIssuer
        namespace: default
        cnameStrategy: None
        acmeServerUrl: https://acme-v02.api.letsencrypt.org/directory
        email: javier@techdelivery.es
        ovhEndpointName: ovh-eu
        ovhAuthenticationRef:
          applicationKeyRef:
            name: ovh-domain-secrets
            key: OVH_APPLICATION_KEY
          applicationSecretRef:
            name: ovh-domain-secrets
            key: OVH_APPLICATION_SECRET
          consumerKeyRef:
            name: ovh-domain-secrets
            key: OVH_CONSUMER_KEY
      - name: le-staging-titan
        create: true
        kind: ClusterIssuer
        namespace: default
        cnameStrategy: None
        acmeServerUrl: https://acme-staging-v02.api.letsencrypt.org/directory
        email: javier@techdelivery.es
        ovhEndpointName: ovh-eu
        ovhAuthenticationRef:
          applicationKeyRef:
            name: ovh-domain-secrets
            key: OVH_APPLICATION_KEY
          applicationSecretRef:
            name: ovh-domain-secrets
            key: OVH_APPLICATION_SECRET
          consumerKeyRef:
            name: ovh-domain-secrets
            key: OVH_CONSUMER_KEY
```

- [ ] **Step 4: Write the stage kustomization**

`apply/20-infra/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cert-manager/cert-manager.yaml
  - cert-manager/ovh-webhook.yaml
```

- [ ] **Step 5: Verify**

```bash
make kustomize-check
kubectl kustomize apply/20-infra | grep -c '^kind: HelmRelease'
kubectl kustomize apply/20-infra | grep -c 'name: le-prod-titan'
kubectl kustomize apply/20-infra | grep -c 'groupName: acme.titan.arrieta.eu'
kubectl kustomize apply/20-infra | grep -c 'semver: "1.21.1"'
ls apply/20-infra/cert-manager/
```

Expected: four directories build; `2`; `1`; `1` — **Review Focus item 2, the groupName assertion**; `1`; and exactly `cert-manager.yaml  ovh-webhook.yaml` (no `rbac.yaml`).

- [ ] **Step 6: Commit**

```bash
git add apply/20-infra
git commit -m "feat: cert-manager with OVH DNS-01 and titan's own ACME group

Ported from k8s-techdelivery with titan values. groupName is acme.titan.arrieta.eu
because the chart creates a cluster-scoped APIService named after it.
No hand-written webhook RBAC: the chart generates its own secret-reader
Role from the issuer refs, and techdelivery's extra Role exists only
because two webhooks share its namespace."
```

---

### Task 6: The wildcard certificate

**Files:**
- Create: `apply/40-certificates/kustomization.yaml`
- Create: `apply/40-certificates/titan-wildcard.yaml`

**Interfaces:**
- Consumes: ClusterIssuer `le-prod-titan` (Task 5); namespace `apps` (Task 2).
- Produces: `Secret titan-tls` in namespace `apps`, referenced by future Ingresses as `spec.tls[].secretName`.

- [ ] **Step 1: Verify the gate fails for this stage**

Run: `kubectl kustomize apply/40-certificates`
Expected: error — the directory does not exist.

- [ ] **Step 2: Write the Certificate**

`apply/40-certificates/titan-wildcard.yaml`. It lives in `apps` because a `Certificate` can only write its Secret to its own namespace, and the consuming Ingresses are in `apps` (spec §7). No `secretTemplate`: techdelivery's reflector annotations are meaningless without the Reflector operator, which titan does not run.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: titan-wildcard
  namespace: apps
spec:
  secretName: titan-tls
  issuerRef:
    kind: ClusterIssuer
    name: le-prod-titan
  commonName: titan.arrieta.eu
  dnsNames:
    - titan.arrieta.eu
    - "*.titan.arrieta.eu"
```

- [ ] **Step 3: Write the stage kustomization**

`apply/40-certificates/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - titan-wildcard.yaml
```

- [ ] **Step 4: Verify**

```bash
make kustomize-check
kubectl kustomize apply/40-certificates | grep -cE 'namespace: apps'
kubectl kustomize apply/40-certificates | grep -c 'name: le-prod-titan'
kubectl kustomize apply/40-certificates | grep -c '"\*.titan.arrieta.eu"'
```

Expected: five directories build; `1`; `1`; `1`.

- [ ] **Step 5: Commit**

```bash
git add apply/40-certificates
git commit -m "feat: wildcard certificate for titan.arrieta.eu

Placed in namespace apps so titan-tls lands where the Ingresses that
consume it are; a Certificate cannot write its Secret cross-namespace, and
adding Reflector for one certificate and one consumer would be a
cluster-wide operator in search of a reason."
```

---

### Task 7: The apps stage placeholder

**Files:**
- Create: `apply/50-apps/kustomization.yaml`
- Create: `apply/50-apps/.gitkeep`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable `./apply/50-apps` path, so the `apps` stage from Task 2 resolves instead of failing on a missing directory.

- [ ] **Step 1: Verify the gate fails for this stage**

Run: `kubectl kustomize apply/50-apps`
Expected: error — the directory does not exist.

- [ ] **Step 2: Create the placeholder**

```bash
mkdir -p apply/50-apps
touch apply/50-apps/.gitkeep
```

`apply/50-apps/kustomization.yaml`:

```yaml
# Empty on purpose: nothing runs on titan yet. The stage exists so the `apps`
# Kustomization in 00-bootstrap resolves to a real path; the first workload
# adds its manifest to this list.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

- [ ] **Step 3: Verify**

```bash
make kustomize-check
kubectl kustomize apply/50-apps | wc -l
```

Expected: five directories build (`apply/00-bootstrap`, `10-secrets`, `20-infra`,
`40-certificates`, `50-apps` — there is no `30-*`); `0` lines of output from the empty
`50-apps` build, which is valid, not an error.

- [ ] **Step 4: Commit**

```bash
git add apply/50-apps
git commit -m "feat: reserve the apps stage

Empty resources list so the apps stage resolves to a real path before the
first workload exists."
```

---

### Task 8: README runbook, AGENTS.md, and the full offline gate

> **SUPERSEDED in its embedded copies — do not execute them verbatim.** The README and
> AGENTS.md text below is what Task 8 first shipped, and review found four factual
> errors in it, all since corrected in the shipped files: `le-prod-titan not found` is
> not a message kustomize-controller emits (the real one is `dependency
> 'flux-system/infra' is not Ready`); `prune: true` does **not** delete hand-applied
> objects — it reverts objects Git owns and leaves a debugging object alive and
> unmanaged; `make scan` and CI do not check plaintext Secret placement
> (`make secrets-placement` does); and `make check` runs after `git add -A` because
> `leak-check` reads the index. The shipped files additionally document
> `SOPS_AGE_KEY_FILE`, which this task never mentioned. Corrections are applied inline
> below so re-executing this task cannot reintroduce them; where this task and the
> shipped file still differ, the shipped file is authoritative.

**Files:**
- Create: `README.md`
- Create: `AGENTS.md`
- Modify: none

**Interfaces:**
- Consumes: every file from Tasks 1–7.
- Produces: the operator-facing bootstrap procedure and the agent-facing repo conventions.

- [ ] **Step 1: Write `README.md`**

```markdown
# k8s-titan

Flux-managed manifests for `titan`, a single-node k3s cluster on OVH bare metal.
Design: `docs/superpowers/specs/2026-10-03-k8s-titan-flux-bootstrap-design.md`

The cluster is public-internet-facing. SSH is on 13491, the API server on 6443 is
reachable only over WireGuard, and ingress is k3s' bundled Traefik + ServiceLB on
80/443.

## Bootstrap (three commands, run once)

From a machine with titan's kubeconfig — over the mesh, or on the host with
`sudo k3s kubectl`:

    kubectl apply -f apply/00-bootstrap/flux-system/gotk-components.yaml
    kubectl -n flux-system create secret generic sops-age \
      --from-file=age.agekey=$HOME/.config/sops/age/titan-k8s-key.txt
    kubectl apply -f apply/00-bootstrap/flux-system/gotk-sync.yaml

Order matters. `sops-age` before the sync object means the `secrets` stage finds
its key on the first attempt; on a bootstrap a red object is indistinguishable
from a broken one.

No `flux bootstrap`, and no git credentials in the cluster: the repo is public, so
the source-controller clones anonymously.

## Verifying a bootstrap

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
- `certificates` red with `dependency 'flux-system/infra' is not Ready` → `infra` has
  not gone Ready yet; that is `dependsOn` working, not a fault. (An `issuer not found`
  style message cannot reach you here — `dependsOn` blocks the stage first.)
- `Certificate` stuck `NotReady` with an ACME challenge error → the OVH credentials
  lack write access to `arrieta.eu`, or DNS has not propagated. Check the challenge
  Order's events before assuming DNS.

## Day-to-day

Everything is a `git push`. **`prune: true` is on for every stage**, which means
objects Git owns get reverted on the next reconcile — fix it in git. It does **not**
mean a `kubectl apply` of something Git never owned gets deleted: Flux garbage-collects
only objects recorded in the Kustomization's own inventory, so a hand-created object
survives indefinitely and invisible to Git. Delete your debugging objects yourself.

    make check            # kustomize build every stage + decrypt every secret + secret scan
    make update-keys      # after rotating the age key group
    make secrets-list

## Not here (yet)

PV restic backups, monitoring, external-dns, Reflector, and tuning of the bundled
Traefik — which k3s owns and re-applies on restart, so its values are set from
`nixos-configurations`, not from this repo. Each has its trigger recorded in the
spec's deferred table.
```

- [ ] **Step 2: Write `AGENTS.md`**

```markdown
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
- Secrets go in `apply/10-secrets/` only, encrypted with sops — see
  `docs/ovh-dns-credential.md` for the staging flow (`sops --encrypt --in-place` on a
  git-ignored name under `apply/10-secrets/`), which exists because sops picks its
  recipients from the file's own path. Never write a plaintext Secret manifest anywhere
  else. `make secrets-placement` enforces both halves: no `kind: Secret` outside
  `apply/10-secrets/`, and every file there actually carrying `ENC[`, and `make
  validate` fails on a plaintext file because sops cannot decrypt one.
- The cluster key is `titan-k8s`, not the titan host key. Do not "simplify" the two
  into one: the separation is what caps a pod compromise at titan's own secrets.
- This repo is public. No credentials, and no concrete public IPv4 — write
  `<OVH_PUBLIC_IP>`.
- Ingress class is k3s' bundled `traefik`, and its configuration is **not** managed
  here. TLS for any Ingress is `secretName: titan-tls` in namespace `apps`.

## Before committing

    git add -A
    make check

`make check` runs `leak-check` first, and `leak-check` reads the **index** — so stage
first. On a tree with nothing staged and nothing modified it falls back to the tracked
tree at HEAD rather than reporting success vacuously. It greps for all three credential
shapes spec §0 names plus the concrete public IPv4 check spec §0 mandates; note the key
*shape*, not the bare word, because this repo's own docs quote the pattern inside their
leak checkers. CI runs GitGuardian on every push and warns, rather than failing, when
`GITGUARDIAN_API_KEY` is absent from the repo.
```

- [ ] **Step 3: Run the full offline gate**

```bash
git add README.md AGENTS.md
make check
```

Expected: `leak-check: clean - scanned staged diff plus untracked non-ignored files`,
every stage directory building OK, `OK: apply/10-secrets/ovh-domain-secrets.yaml`,
`secrets-placement: no Secret outside apply/10-secrets, every secret encrypted`, then
`check: all offline gates passed`. GitGuardian runs in CI, not in `make check`; `make
scan` runs it locally and says `SKIPPED` out loud when ggshield or the API key is
missing.

- [ ] **Step 4: The spec §0 leak checks**

`make check` now runs them (all three credential shapes and the public-IPv4 check, with
the RFC1918 allowlist). Run the raw spec §0 form only if you want to see it independently:

```bash
git diff --cached | grep -nE 'AGE-SECRET-KEY-|BEGIN [A-Z ]*PRIVATE KEY' | grep -v 'grep -nE' && echo "CREDENTIAL LEAK"
git diff --cached | grep -noE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | grep -vE '(^|[^0-9])(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.0\.0\.0|1\.1\.1\.1|8\.8\.[48]\.4|213\.186\.33\.99|224\.)' && echo "PUBLIC IPv4 IN DIFF"
```

Expected: no output from either (the `&&` branches do not fire).

- [ ] **Step 5: Commit and push**

```bash
git commit -m "docs: bootstrap runbook and agent conventions

The runbook names the two failures an operator actually hits on a fresh
cluster — a missing sops-age secret, and dependsOn looking like a fault —
and states plainly that prune:true deletes anything applied by hand."
git push origin main
```

- [ ] **Step 6: Verify CI**

```bash
gh run list --limit 1
```

Expected: `success` on the GitGuardian scan.

---

## Handoff — cluster bootstrap (operator-run, not automatable from here)

The API server is mesh-only, so these steps belong to the operator, from a host on the
WireGuard network or on titan itself:

1. Plant the key: `kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=$HOME/.config/sops/age/titan-k8s-key.txt` (use `$HOME`, not `~` — bash does not expand a tilde after `=` in a non-assignment word, so kubectl receives a literal `~`)
2. Preflight: `flux check --pre` (spec §8 item 4) — it catches a cluster that cannot run
   Flux before anything is applied.
3. Apply `gotk-components.yaml`, then `gotk-sync.yaml` (README, in order).
4. Watch convergence: `kubectl get kustomization -A -w` until all five are `Ready=True`.
5. Confirm the certificate: `kubectl -n apps get certificate titan-wildcard`, and that
   the OVH zone received `_acme-challenge.titan` TXT records during issuance.
6. Run the throwaway-Ingress check from the README, then delete it.
7. Copy the `titan-k8s` private key to the password manager and to each operator
   machine. Until that is done the secrets have a single point of failure.

## Out of scope for this plan

PV backups, monitoring, external-dns, Reflector, bundled-Traefik tuning, apps, and
making the repo private — each with its promotion trigger in spec §9.
