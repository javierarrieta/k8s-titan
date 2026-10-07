# titan — rolling workloads when the Secrets they consume change

Status: **implemented** in the same change as this spec — `apply/20-infra/reloader/reloader.yaml` plus
one annotation on coder. Most of what is here is the reasoning the manifests carry in compressed form,
and the part that is not obvious is the interaction in §4.

## 1. The problem, found the hard way

Rotating coder's OIDC client secret (2026-10-07, PR #32) merged, Flux applied both Secrets, every
status condition stayed green — and nothing happened. Coder kept authenticating with the leaked secret
indefinitely, because **a running container's environment is fixed at creation**.

There are two ways a pod consumes a Secret and only one of them updates:

| how it is consumed | when the Secret changes |
|---|---|
| volume mount (a file) | kubelet rewrites the file in place, ~1 min, **no restart** |
| `valueFrom.secretKeyRef` / `envFrom` → env | resolved **once** at container start. The Secret is not part of the pod spec, so there is no diff, no rollout, no update |

The second case is silent. Nothing errors. The pod is `Ready`, the release is `Ready`, and the process
is running a credential that no longer exists.

**This is not a coder-specific curiosity.** Read from the live cluster:

| workload | how it consumes Secrets | affected |
|---|---|---|
| `coder/coder` | `secretKeyRef` → env, three keys from `coder-secrets` | yes |
| `auth/authentik-server` | `envFrom: authentik, authentik-secrets` | yes |
| `auth/authentik-worker` | same | yes |
| `auth/authentik-worker` blueprint | volume mount | no — which is exactly why the blueprint converged and coder did not |

So the same cluster, the same Flux, two opposite behaviours, and the difference is entirely in how each
thing reads a Secret. Authentik's DB password has the same property: rotating it would leave
authentik running the old one until something restarted it.

Nothing in the cluster does that today, verified:

```
kubectl get crd | grep -i reload                 -> nothing
kubectl get deploy,daemonset -A | grep reloader  -> nothing
grep -rniE "checksum|reloader|rollme" coder chart + libcoder -> nothing
```

The coder chart renders the Deployment through its bundled `libcoder` chart
(`charts/libcoder/templates/_coder.yaml`), and neither computes a checksum of anything.

## 2. Why the obvious fix is wrong here

The usual Helm idiom is a checksum annotation on the pod template, computed at build time. **It does not
work with sops.** sops re-encrypts on every run, so the file bytes change even when every value inside
is identical — demonstrated during this very rotation, where three Secret files showed as modified with
byte-identical credentials inside. Hashing the encrypted file would roll coder on unrelated commits;
hashing the decrypted value means the pipeline needs the age key, which is the one thing
`make check-ci` is built to keep out of CI (AGENTS.md: `validate` is excluded for exactly this reason).

So the checksum has to be computed **inside the cluster, from the live Secret object**. That is what
Reloader does.

## 3. Decisions

| # | Decision | Rejected alternative |
|---|---|---|
| R1 | Install **Stakater Reloader**, chart `2.2.18` / app `v1.4.22`, pinned | Do nothing and document "restart it yourself". Already tried: it is what we had, and it silently failed on a real rotation |
| R2 | `reloader.reloadStrategy: annotations` — **load-bearing, not cosmetic** | The default `env-vars`, which injects a `STAKATER_*` env var into the pod template. Flux's `driftDetection: mode: enabled` reverts it, and the restart is cancelled mid-roll |
| R3 | Scoped RBAC: `watchGlobally: false`, `namespaces: [coder]` → namespaced Role, **no ClusterRole** | The chart default, a cluster-wide grant. `apply/20-infra/reflector/reflector.yaml` already documents that Reflector's cluster-wide `secrets: *` is a regret held in check only by review; adding a second one would be worse, because Reloader is *designed* to read every Secret. Scoped to `coder` alone rather than also `auth`: an unannotated namespace would buy a read grant for no behaviour, so `auth` arrives in the same change that annotates authentik |
| R4 | Per-workload **explicit** annotation `secret.reloader.stakater.com/reload: "<name>"` | `reloader.stakater.com/auto: "true"`, which discovers everything referenced and rolls on any of it. Explicit names match how this repo lists everything else, and make "what will restart if I touch this Secret" answerable by reading one file |
| R5 | Annotate **coder only** in the first change; authentik after it is proven | Annotating both at once. An authentik worker restart can interrupt a blueprint apply or a sync task; that deserves its own step after the mechanism is known good |
| R6 | Release lives in `apps`, matching Reflector | A dedicated `reloader` namespace — one component does not earn a namespace here |

Annotation placement was checked rather than assumed: `ShouldReload` in `pkg/common/common.go:203-256`
reads the workload's own annotations first and **falls back to pod-template annotations** when nothing
matches, so `coder.podAnnotations` is a valid hook. Confirmed present in
`charts/libcoder/templates/_coder.yaml:25-29`.

## 4. The Flux interaction, which is the whole risk

Reloader triggers a restart by patching the workload, and **any patch is drift** to a HelmRelease with
`driftDetection: mode: enabled`. Left at its default, Reloader injects an env var into the pod template;
Flux reconciles, sees a field it owns disagreeing with Git, reverts it, and the rollout is cancelled
before the new pod ever reads the new Secret. The failure looks like nothing happened — which is precisely
the failure this spec exists to fix, so getting this wrong would replace one silent failure with another.

The fix is R2, and it works for a reason this repo already established: **`reloader.reloadStrategy:
annotations`** makes Reloader write
`reloader.stakater.com/last-reloaded-from` to the pod template using its own server-side-apply field
manager. SSA tracks field ownership per manager; Flux never declared that field, so Flux does not own it
and does not remove it. This depends on kustomize-controller applying with SSA — which is already a
proven fact about this cluster, established when `make dry-run` had to be switched to
`--server-side` because client-side apply was producing false positives.

No `driftDetection.suppress`, no `mode: warn`, no weakening of drift detection anywhere. If verification
shows Flux fighting the annotation anyway, the fallback is to drop the component, not to turn off drift
detection — drift detection is the more valuable of the two.

## 5. Sketch

`apply/20-infra/reloader/reloader.yaml`, added to that directory's `kustomization.yaml`:

```yaml
# HelmRepository stakater (https://stakater.github.io/stakater-charts) + HelmRelease, pinned 2.2.18,
# same install/upgrade retry strategy and driftDetection as the Reflector release beside it.
values:
  reloader:
    reloadStrategy: annotations   # R2 - see §4, do not change this casually
    watchGlobally: false          # R3
    namespaces: [coder]           # release namespace (apps) is added by the chart itself
```

The chart enforces R3 rather than merely preferring it: `templates/role.yaml:1-2` fails the render if
`namespaces` is set while `watchGlobally` is true, so the two settings cannot drift apart.

and one line in `apply/50-apps/coder/coder.yaml`, under `coder.podAnnotations`:

```yaml
podAnnotations:
  secret.reloader.stakater.com/reload: coder-secrets
```

## 6. Verification

**One thing to be clear-eyed about first.** Adding `podAnnotations` changes the pod template, so the
Helm upgrade that installs the annotation rolls coder by itself. The pending OIDC rotation therefore
completes whether or not Reloader works — which means it proves the annotation is wired but proves
nothing about Reloader. The Reloader-specific evidence is steps 3 and 4, and any later rotation.

1. **The pending rotation closes.** Coder's live pod still holds the pre-rotation client secret while the
   cluster Secret already holds the new one; the rollout above is what finally swaps them. Verify by a
   real login, which is the only check that shows both ends agree.
2. **Flux does not revert the annotation.** After any Reloader-triggered roll, the next HelmRelease
   reconcile must leave the release `Ready` with no further action, and
   `reloader.stakater.com/last-reloaded-from` must survive. This is the R2 claim being tested, not
   assumed.
3. **No spurious rolls.** Re-run `scripts/setup-coder-secrets.sh` with every value pinned so sops
   re-encrypts identical plaintext, merge, and confirm coder does **not** restart. This is the property
   the CI-checksum alternative could not provide, so it is the one worth proving — and note it can only
   be tested with a change that does not itself touch the pod template.
4. **Then, and only then,** add `auth` to `reloader.namespaces` and annotate authentik, repeating with a
   value that matters. An authentik worker restart can interrupt a blueprint apply, which is why it is a
   separate step.

## 7. Not proven / accepted

- Reloader's behaviour on **first** annotation — whether it rolls immediately to record a baseline, or
  waits for the next change — is expected to roll immediately, and step 6.1 is what settles it rather
  than this document.
- A Reloader restart is invisible to Helm. The HelmRelease stays `Ready` throughout; the evidence of a
  restart is pod age, not a release condition.
- Reloader can restart a workload at any moment a watched Secret changes. Both watched workloads are
  stateless and DB-backed, so that is acceptable here; it would not be acceptable for a workload holding
  local state, and coder's own workspace pods are deliberately **not** annotated.
- Chart `3.0.0-beta.2` exists and was not used. Betas are not what this cluster pins.
