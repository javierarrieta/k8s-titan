# coder workspace templates

Source of truth for Coder workspace templates. **Nothing here is applied by Flux.** Coder keeps
its own copy of every template version, and a template is only live once it has been pushed:

    coder templates push dev -d coder/templates/dev

**Accepted gap (spec C7).** Git is the source of truth and nothing enforces it. Editing a template
in Coder's UI drifts it from this directory and no gate notices — `make check` cannot see a
template that only exists inside coder's database. The diagnostic is that Coder reports which
template version a workspace is running, so a failed build points at the discrepancy; that is a
diagnostic, not a prevention. Automatic push is deferred, spec §14.

Two things worth knowing before editing:

- `interval` and `timeout` in a `coder_agent` `metadata` block are **seconds**, not milliseconds.
  The provider schema says so, and a value of 10000 refreshes the panel roughly every three hours
  without ever erroring.
- Cores, memory and home size are `coder_parameter`s (`cpu`, `memory`, `disk`), and their menu stops
  at 4 CPU / 8 Gi / 40 Gi because that is what `apply/50-apps/coder/workspaces.yaml` allows: the
  ResourceQuota is 8 CPU / 16 Gi / 80 Gi for two workspaces and the LimitRange caps a claim at 40 Gi.
  A bigger option would be a selector that produces a Forbidden or a Pending pod.
- **Cores and memory are mutable; disk is not.** Changing cores or memory restarts the workspace: the
  pod is `count = start_count`, so the rebuild creates a fresh pod at the new size instead of patching
  a running one. Kubernetes 1.35 *can* resize a running Guaranteed pod in place, and this template
  deliberately does not rely on it: the pinned kubernetes provider cannot express `resizePolicy`, so a
  live memory shrink would be best-effort and could leave the container capped at the old limit while
  coder displayed the new one. Stopping the workspace by hand first is still the safe instruction.
  Disk is one-way forever — `local-path-retain` has `allowVolumeExpansion: false`, so a home is the
  size it was created at, and growing one is a StorageClass decision (spec §14), not a template edit.
- The template's pod is created by the coder server's own ServiceAccount, in `coder-workspaces`,
  under the Role in `apply/50-apps/coder/workspaces.yaml`. Anything a template tries to create
  beyond pods, `pods/log`, `pods/exec` and PVCs fails with a Forbidden naming the missing verb.
  That is the fence working, and widening it is a review decision, not a workaround.
