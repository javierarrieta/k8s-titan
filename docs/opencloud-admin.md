# Becoming an administrator in OpenCloud

**Status: the mechanism is read from source and has not been observed working on this cluster.** The
grant path below is traced through `opencloud-eu/opencloud` v8.1.0 to the code that performs it, which
is a stronger claim than the first draft of this page made — see the correction below — but the last
step, watching it actually take, is still to come.

## The grant: `OC_ADMIN_USER_ID`

Set `OC_ADMIN_USER_ID` in `apply/50-apps/opencloud/opencloud.yaml` to your account UUID. That is the
whole change.

The chain, end to end:

1. `OC_ADMIN_USER_ID` is a global that lands in `cfg.Commons.AdminUserID`
   (`pkg/config/parser/parse.go:113`).
2. The settings service reads it as `OC_ADMIN_USER_ID;SETTINGS_ADMIN_USER_ID`
   (`services/settings/pkg/config/config.go:31`).
3. `DefaultRoleAssignments` appends `{AccountUuid: cfg.AdminUserID, RoleId: BundleUUIDRoleAdmin}`
   when it is non-empty (`services/settings/pkg/store/defaults/defaults.go:717`).
4. On startup the store walks those assignments and, for the admin account specifically, calls
   `userMustHaveAdminRole` — whose own comment is *"for the adminUserID we need to check if the user
   has the admin role every time"* (`services/settings/pkg/store/metadata/store.go:144`). If the
   account lacks the admin role it deletes the old assignment and writes the admin one (`:199-215`).

Step 4 is what makes this worth using rather than tolerating: **it re-asserts on every settings
startup.** A role lost to a restore, a bad API call or a metadata-store hiccup comes back on the next
pod start. It is not a one-shot bootstrap that can drift.

There is also a second effect from the same variable — idm creates a local `admin` service user
(`services/idm/pkg/command/server.go:147`). That is incidental here and is why `IDM_ADMIN_PASSWORD`
becomes mandatory: `services/idm/pkg/config/parser/parse.go:45` returns
`MissingServiceUserPassword("idm", "admin")` when `AdminUserID` is set and the password is not. The
Secret already carries `idm-admin-password` for exactly that reason, so filling in the UUID is a
one-line change with no Secret edit.

## Correction: an earlier version of this page was wrong

The first draft said `OC_ADMIN_USER_ID` "makes idm create a local service user and does not promote an
authentik-autoprovisioned user". That was based on reading the idm command and stopping there. The
settings path above is the real grant and it is keyed on the account UUID alone — it does not care how
the account came to exist. The claim that OpenCloud 8.1.0 ships no `user role set` CLI **is** still
correct: `services/users/pkg/command/root.go:12` offers only `server`, `health` and `version`, and
there is no `role` command anywhere in the tree.

## Procedure

1. **Deploy as-is**, with `OC_ADMIN_USER_ID: ""`. Empty is a valid state — settings skips the grant and
   idm skips the password requirement. Everyone who logs in gets the plain `user` role
   (`PROXY_ROLE_ASSIGNMENT_DRIVER=default`, `GRAPH_ASSIGN_DEFAULT_USER_ROLE=true`).

2. **Log in once** through authentik, so your account exists.

3. **Read your own account UUID.** `GET /graph/v1/me` returns it and needs no admin rights — the route
   is registered at `services/graph/pkg/service/v0/service.go:242`. In practice: open the web UI,
   DevTools → Network, copy the `Authorization: Bearer …` header off any XHR, then

   ```sh
   curl -s -H "Authorization: Bearer <token>" https://files.titan.arrieta.eu/graph/v1/me
   ```

   The `id` field is the value. **This step is the unverified part** — the route exists in source, but
   whether it answers on this build, and whether `id` is the same UUID the settings store keys on, has
   not been observed. If it returns 401 or the id does not work, the fallback is to read the account
   out of idm's LDAP directly.

4. **Set it and apply.** One line in the manifest, commit, let Flux reconcile. Settings restarts,
   asserts the role, done.

5. **Verify**, do not assume. The admin section appears in the web UI. If it does not, the UUID is
   wrong or the account did not exist when settings started — start settings again after the account
   exists.

## What this does not do

- **It grants one user.** The variable holds a single UUID. A second administrator needs a different
  mechanism, and the candidate is the `roles` claim: `PROXY_ROLE_ASSIGNMENT_DRIVER=oidc` with the
  default mapping (claim `roles`, value `opencloudAdmin` → admin), fed by an authentik property
  mapping. Not wired, because with the `oidc` driver a user whose claim matches no mapping "will not
  be able to login" and `role_mapping` is config-file-only so it cannot be widened by env
  (`services/proxy/pkg/config/config.go:160`). That is the open-webui lockout shape. If a second admin
  is ever needed, prove it on scratch first.
- **It is not a credential.** Nothing here rotates. Removing the UUID from git and reconciling revokes
  the grant on the next settings start — though note step 4 re-asserts *while the value is present*,
  so the revocation is the git revert, not the user's logout.
- opencloud-eu/opencloud#2886 ("Admin role not assigned during OIDC autoprovision") is about the
  **claim** path, not this one. It being open is not evidence against the above, and it is not evidence
  for it either.
