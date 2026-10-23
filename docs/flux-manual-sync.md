# Flux manual sync — the annotation value must change, or it does nothing

Written 2026-10-23. Short, because the whole rule is one line, and the failure mode is a command that
exits 0 and lies.

## The rule

```sh
kubectl -n <ns> annotate --overwrite <kind> <name> \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

**The value must be different from the last one the controller handled.** It is not a flag and it is not
a trigger word — it is an opaque token the controller compares against what it already processed.

Re-using a value is a **silent no-op**: kubectl prints `annotated`, the command exits 0, and nothing
reconciles. There is no error, no warning, and no dashboard that goes red. During an incident this reads
as "I forced a sync and it changed nothing, so the problem must be elsewhere."

`$(date +%s)` is the idiom precisely because it cannot repeat. A literal — `now`, `retry`, the same
timestamp pasted from history — can.

## Why it works that way

The controller records the last value it handled in `status.lastHandledReconcileAt` and strips the
annotation once processed. Observed on titan without any annotation present:

```
$ kubectl -n coder get helmrelease coder -o jsonpath='{.status.lastHandledReconcileAt}'
1791385872
```

That number is a `$(date +%s)` value from a manual sync (the pattern is already used at
`docs/authentik-runbook.md:969`). The annotation is gone; the record of having handled it is not. A new
annotation equal to that stored value is the no-op above.

## Proving it actually synced

Do not infer it from the annotate command's exit code. Check the result:

```sh
kubectl -n flux-system get kustomization apps -o jsonpath='{.status.lastHandledReconcileAt}{"\n"}'
kubectl -n flux-system get kustomization apps -o jsonpath='{.status.conditions[0].message}{"\n"}'
# Applied revision: main@sha1:05e28bddfbce2bf8f16cca12b2584494633809bc
```

The `Applied revision:` line is the proof — it names the commit that was applied, so it also tells you
whether the sync picked up *your* commit. `status.lastHandledReconcileAt` moving to the value you just
set is the other half.

## What to annotate here

| what | where |
|---|---|
| the stage `Kustomization`s — `flux-system`, `secrets`, `infra`, `databases`, `certificates`, `apps`, `tesla` | namespace `flux-system`; declared in `apply/00-bootstrap/stage-*.yaml` |
| any `HelmRelease` | the namespace of its release, e.g. `coder`, `auth`, `files` |

The `flux` CLI is **not installed** on these workspaces, so `flux reconcile kustomization X --with-source`
is not available as a shortcut; the annotation is the path. If the CLI is ever wanted, it is a
`nix-shell -p flux2 --run '...'` away and needs the operator's approval first.

## What a manual sync will not fix

`HelmRelease`s in this repo run `driftDetection.mode: enabled`, which per `AGENTS.md` is **notify-only**,
and Helm's new-vs-old patching lets an out-of-band edit survive every later upgrade. So if the live
object was changed with `kubectl edit` or `kubectl set env`, forcing a sync is not guaranteed to put it
back — the sync may well re-apply the chart template and leave the drifted field alone.

The rule from `AGENTS.md` stands: prefer a commit. If a live poke was unavoidable, remove it explicitly
(`kubectl -n <ns> set env deploy/<name> FOO-`) and say so.
