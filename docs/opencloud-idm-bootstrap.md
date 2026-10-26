# OpenCloud IDM — the bootstrap guard is one `os.Stat`, and it can wedge permanently

Written 2026-10-23 against OpenCloud 8.1.0. This is a code-level finding about the embedded identity
store, recorded because the failure it allows is silent, durable, and looks like something else.

## What IDM is here

OpenCloud ships its own LDAP, backed by a single BoltDB file, in the same container as everything else:

| | |
|---|---|
| file | `/var/lib/opencloud/idm/idm.boltdb` — `IDM_DATABASE_PATH`, default `$OC_BASE_DATA_PATH/idm/idm.boltdb` (`services/idm/pkg/config/defaults/defaultconfig.go:34`) |
| storage | `OC_BASE_DATA_PATH=/var/lib/opencloud` is the `opencloud-data` **PVC** (`apply/50-apps/opencloud/opencloud.yaml`) |
| LDAP | localhost only, inside the pod |

The PVC matters. This is not an `emptyDir` that gets wiped and re-seeded on the next start — whatever
ends up in that file is the identity store until someone deletes it.

## The guard

```go
// services/idm/pkg/command/server.go:70
if _, err := os.Stat(servercfg.BoltDBFile); errors.Is(err, os.ErrNotExist) {
    logger.Debug().Msg("Bootstrapping IDM database")
    if err = bootstrap(logger, cfg, servercfg); err != nil {
        logger.Error().Err(err).Msg("failed to bootstrap idm database")
```

**Existence of the file is the only condition.** `bootstrap()` parses `idm.BaseLDIF` through a template,
optionally appends demo users, and feeds the LDIF to the go-ldap loader (`server.go:169-207`). The file
is created before that import completes.

So if the process dies between "file created" and "LDIF imported" — OOM, eviction, a sibling service in
the same pod crashing on a bad secret, a node going away during the very first start — the file exists
with partial contents, and **every subsequent start sees it and skips bootstrap**. Not at `Warn`. At
`Debug`.

Restarting the pod does not fix it. There is no repair path, no version check, no completeness check.
The only guard is a stat.

## What it looks like from outside

Nothing looks unhealthy. The pod becomes Ready. The web UI renders the login page. What fails is
*after* authentication, when a service tries to read an identity that was never written:

- login fails with `LDAP Result Code 49` — a bind against a user or service account that is absent
- `graph` logs `could not get group: backend error`
- autoprovisioning fails for a user who is *already* supposed to exist

The shape to remember: **an identity store that is half-populated answers correctly for whatever got
written and returns nothing for the rest**, so a partial bootstrap can serve some users normally
indefinitely.

## Checking it

The boltdb exists but the identities are missing is the whole diagnosis:

```sh
kubectl --context titan -n files exec deploy/opencloud -- ls -l /var/lib/opencloud/idm/
```

A bootstrapped file is not empty and not tiny; a file that was created and never imported is small.
Compare against a known-good instance rather than guessing at a size. The behavioural check is better:
can a known account be read? If login gives LDAP 49 for an account that has logged in before, suspect
the bootstrap rather than the credential.

## Recovery, and what each costs

OpenCloud's `idm` command has exactly one subcommand that touches this file outside the server —
`resetpw.go` — and it also refuses to run unless the file already exists (`resetpw.go:62`). There is no
`ldapsync` or re-import verb. So:

1. **Delete the boltdb and restart.** IDM re-bootstraps from scratch. Cost: every account and group in
   IDM is gone.
2. **Hand-import LDIF over LDAP** with `ldapadd` against the in-pod LDAP and a manager DN. Surgical, but
   it means knowing exactly what is missing, and there is no tool in the tree that tells you.

### Why option 1 may be cheaper than it sounds — *reasoned, not observed*

The account UUID OpenCloud uses is **authentik's own user UUID** — observed 2026-10-23 via
`/graph/v1.0/me`, where `id` and `identities[].issuerAssignedId` are the identical value
(`docs/opencloud-admin.md` step 3). Autoprovisioning recreates the account on the next OIDC login, and
if the recreated account keeps the same UUID, then storage keyed on that UUID and any role assignment
keyed on it should survive.

**This has not been tested and the downside of being wrong is the user's file tree.** Do not reach for
option 1 on that reasoning alone. Prove it on a scratch instance first, or take a PVC snapshot, or both.

## Prevention

The cheap one: **watch the first start.** `kubectl -n files logs -f deploy/opencloud` through the first
boot, and confirm a known account can log in before walking away. The window in which this can happen is
the first few seconds of the first start, and after that it is permanent.

If the first start crashes for any reason — and during a port it usually crashes on something, a missing
Secret, an LDAP bind, a bad mount path — **treat the identity store as suspect until proven otherwise**,
rather than fixing the crash and assuming the restart cleaned up after it. It does not.
