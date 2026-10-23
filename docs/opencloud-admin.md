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
