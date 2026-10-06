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
- The template's pod is created by the coder server's own ServiceAccount, in `coder-workspaces`,
  under the Role in `apply/50-apps/coder/workspaces.yaml`. Anything a template tries to create
  beyond pods, `pods/log`, `pods/exec` and PVCs fails with a Forbidden naming the missing verb.
  That is the fence working, and widening it is a review decision, not a workaround.
