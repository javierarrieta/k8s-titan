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

As of 2026-10-23 steps 1-3 are already done on titan and `OC_ADMIN_USER_ID` is populated. Steps 1-3 are
kept as the record of how that value was obtained and as the procedure for a second instance.

1. **Deploy as-is**, with `OC_ADMIN_USER_ID: ""`. Empty is a valid state — settings skips the grant and
   idm skips the password requirement. Everyone who logs in gets the plain `user` role
   (`PROXY_ROLE_ASSIGNMENT_DRIVER=default`, `GRAPH_ASSIGN_DEFAULT_USER_ROLE=true`).

2. **Log in once** through authentik, so your account exists.

3. **Read your own account UUID.** `GET /graph/v1.0/me` returns it and needs no admin rights — but it
   needs a real API credential, **not the web session cookie**. Opening the URL in a logged-in browser
   prompts for Basic auth, and copying a `Bearer` header out of DevTools is a dead end too: the session
   cookie is not an API token. Note the version — the route is `/graph/v1.0/me`; bare `/graph/v1/me` is
   a 404 (`services/graph/pkg/service/v0/service.go:241` mounts `/v1beta1`, the proxy names `/v1.0` at
   `defaultconfig.go:283`; neither is bare `/v1`).

   The credential that works is an **app token**: web UI → avatar → Preferences → **App Tokens** → New,
   then HTTP Basic with your login name and the token as the password.

   ```sh
   set -x OC_USER javier
   set -x OC_TOKEN (read -s)   # fish: keeps the token out of your history
   curl -s -u "$OC_USER:$OC_TOKEN" https://files.titan.arrieta.eu/graph/v1.0/me
   ```

   The proxy forwards basic credentials as an app-token grant — `services/proxy/pkg/middleware/app_auth.go:29`
   sends `Type: "appauth"` — which is why a token works where the account password would not.
   **Revoke the token afterwards**; it was needed to read one field.

   Observed 2026-10-23, HTTP 200, name and address redacted:

   ```json
   {"displayName":"<you>","id":"0240605d-bdae-40ca-bd48-d036daba0bc4",
    "identities":[{"issuer":"https://auth.titan.arrieta.eu/application/o/opencloud/",
                   "issuerAssignedId":"0240605d-bdae-40ca-bd48-d036daba0bc4"}],
    "mail":"<you@example>","onPremisesSamAccountName":"javier","userType":"Member"}
   ```

   `id == identities[].issuerAssignedId`, so **the OpenCloud account UUID is authentik's own user
   UUID**. The shorter route is therefore the authentik admin UI — Users → the user → UUID — which needs
   no OpenCloud credential at all. Use that next time; the app-token path is recorded anyway because it
   also proves basic auth works here, which is what a WebDAV or carddav client would need.

   The fallback, if graph ever stops answering, is to read the account out of idm's LDAP directly.

4. **Set it and apply.** One line in the manifest, commit, let Flux reconcile. Settings restarts,
   asserts the role, done.

5. **Verify**, do not assume. The admin section appears in the web UI. If it does not, the UUID is
   wrong or the account did not exist when settings started — start settings again after the account
   exists.

   **Observed 2026-10-23:** the admin section appeared after this landed, so the whole chain — UUID from
   `/graph/v1.0/me`, `OC_ADMIN_USER_ID`, settings' `DefaultRoleAssignments` — is confirmed by effect and
   not just by reading source. See `docs/opencloud-bringup-2026-10-23.md`.

## What this does not do

- **It grants one user.** The variable holds a single UUID. The general mechanism is role mirroring from
  authentik groups, documented in the next section — it is ready and deliberately not enabled.
- **It is not a credential.** Nothing here rotates. Removing the UUID from git and reconciling revokes
  the grant on the next settings start — though note step 4 re-asserts *while the value is present*,
  so the revocation is the git revert, not the user's logout.
- opencloud-eu/opencloud#2886 ("Admin role not assigned during OIDC autoprovision") is about the
  **claim** path, not this one. It being open is not evidence against the above, and it is not evidence
  for it either.

## Role mirroring from authentik — ready, deliberately not enabled

This is the mechanism for defining administrators in authentik instead of in OpenCloud. It works, every
link is checked, and it is not switched on because of an ordering hazard and one real limitation.

### The chain, link by link

| link | evidence |
|---|---|
| authentik `profile` scope emits `groups` | built-in mapping, `request.user.ak_groups.all()` |
| the OpenCloud provider releases `profile` | `apply/50-apps/auth/opencloud-blueprint.yaml`, `property_mappings` |
| web requests `profile` | `WEB_OIDC_SCOPE` default `openid profile email`, `services/web/pkg/config/config.go:87` |
| **Android, desktop and iOS request `profile`** | `nativeAppScopes`, `services/webfinger/pkg/config/defaults/defaultconfig.go:11` and `:60-66`, handed to clients as the `http://opencloud.eu/ns/oidc/scopes` webfinger property that the desktop reads at `oauth.cpp:608` |
| claim value → OpenCloud role | shipped default `RolesMap`, `services/proxy/pkg/config/defaults/defaultconfig.go:76-81`: `opencloudAdmin`→admin, `opencloudSpaceAdmin`→spaceadmin, `opencloudUser`→user, `opencloudGuest`→user-light |

So the switch is two env vars — `PROXY_ROLE_ASSIGNMENT_DRIVER=oidc` and
`PROXY_ROLE_ASSIGNMENT_OIDC_CLAIM=groups` — plus authentik groups **named exactly as those claim
values**. No scope change, and no config file: `role_mapping` is config-file-only
(`services/proxy/pkg/config/config.go:160`) but its shipped default already covers the four standard
roles, so it never needs writing. Naming the groups anything else is what would force a config file.

An earlier draft of this doc, and of the blueprint header, claimed a new scope was needed and that
clients would not request it. Both were wrong; `groups` rides a scope every client already asks for.

### Procedure — the order is load-bearing

1. **Apply the groups** (`opencloudUser`, `opencloudAdmin`, declared in the OpenCloud authentik
   blueprint). They arrive empty.
2. **Join `opencloudAdmin`** in the authentik UI. Do this before step 3, never after.
3. **Only then flip the driver**, and in the same change set `OC_ADMIN_USER_ID` back to `""`. Leaving
   both means settings re-asserts admin at every startup while the proxy asserts the claim role at
   every login, so the effective role depends on which ran last.
4. **Delete the stale assignment.** The grant from the procedure above is *data in the settings store*,
   not config; clearing the env var does not remove the row.

Never do steps 1 and 3 in one apply. With the `oidc` driver an absent or unmatched claim means the
proxy refuses the login outright (`services/proxy/pkg/userroles/oidcroles.go:86` and `:106`) — there is
no fallback role — so flipping the driver before anyone is in a group locks every account out.

### The limitation that defines what this is good for

```go
// services/settings/pkg/store/metadata/assignments.go:118
// WriteRoleAssignment appends the given role assignment to the existing assignments of the respective account.
```

Assignments **append**, and the proxy only ever calls `AssignRoleToUser` (`oidcroles.go:127`) — never
`RemoveRoleFromUser`. So taking someone out of `opencloudAdmin` does not demote them; it leaves them
holding two roles, and holding two roles is a logged warning rather than a handled case:

```go
if len(assignedRoles) > 1 {
    logger.Error()...Msg("The user has too many roles assigned")   // oidcroles.go:116
```

Which of the two wins is not decided by anything in the code read here.

**Granting from authentik works. Revoking from authentik does not.** Demotion stays a manual
`RemoveRoleFromUser` call — the service method exists
(`services/settings/pkg/service/v0/service.go:428`) and requires role-management permission; the exact
HTTP route has not been verified here.

That asymmetry is why this is parked. "Admin can be granted from the IdP but only revoked from
OpenCloud" may or may not be the control plane you want, and it is a worse surprise than the one-line
`OC_ADMIN_USER_ID` above.
