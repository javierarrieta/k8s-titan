# Issuing titan's OVH DNS credential

`apply/20-infra/cert-manager/ovh-webhook.yaml` reads `Secret ovh-domain-secrets`
(namespace `cert-manager`) with three keys — `OVH_APPLICATION_KEY`,
`OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`. This page is how that Secret gets its
content, and it is also the rotation procedure.

The credential is **titan's own**, not the one `k8s-techdelivery` uses. That was a
deliberate choice: a public-internet cluster sharing a DNS-write credential with the
home cluster means either one's compromise edits both zones.

## 1. Create the API application

In the [OVHcloud API console](https://api.ovh.com/console/), log in with the account
that hosts the `arrieta.eu` zone, then open the
[application creation page](https://api.ovh.com/createToken/index.cgi?GET=/domain/zone/arrieta.eu/*&PUT=/domain/zone/arrieta.eu/*&POST=/domain/zone/arrieta.eu/*&DELETE=/domain/zone/arrieta.eu/*)
pre-filled for this zone.

| field | value |
|---|---|
| Application name | `k8s-titan-cert-manager` |
| Description | DNS-01 challenge records for titan.arrieta.eu |
| Validity | as short as your patience for rotating allows — see the note on the issued credential below |
| Rights | `GET`, `PUT`, `POST`, `DELETE` on `/domain/zone/arrieta.eu/*` — this zone only |
| Restrict IPs | titan's public egress IPv4 |

Those four verbs are what the webhook needs and nothing more — it only ever creates and
deletes `_acme-challenge` TXT records and refreshes the zone. Scope them to
`arrieta.eu` rather than `/domain/zone/*`: an account-wide DNS-write credential sitting
in a public-internet cluster can rewrite **every** zone you own, so a leaked key secret
stops being a titan incident and becomes a domain-loss incident.

Two honest caveats on the narrow scope:

- The webhook probes zone-status endpoints as well as `/record`, so test a narrowed
  credential against **`le-staging-titan`** before trusting production. A credential
  that passes staging is proven; one that fails only at production is a rate-limit
  problem you created for yourself.
- IP-pinning to titan's egress assumes that address is stable. If titan's egress moves,
  certificate renewal fails silently until the 10-minute reconcile starts erroring —
  which is a louder failure than an unpinned key, but still a outage for renewals.

**The credential currently in `apply/10-secrets` predates this page.** It was issued
with account-wide `/domain/zone/*` rights, unlimited validity, and no IP restriction,
because that is what the first version of this document asked for. It works. It is also
the widest-blast-radius shape available, so treat it as a rotation candidate: issue a
zone-scoped, IP-pinned application per the table, prove it on `le-staging-titan`, cut
over, then delete the old one.

You get `ApplicationKey` and `ApplicationSecret` immediately and a `ConsumerKey`; if the
page hands you a validation URL, open it and accept, or the consumer key will not
authenticate.

## 2. Encrypt it into the repo

Run this yourself. The values should not pass through a chat, a shell history entry, or a
commit message.

sops reads age identities from `~/.config/sops/age/keys.txt` and does not scan the
directory, so if your `titan-k8s` key is at `~/.config/sops/age/titan-k8s-key.txt`,
export `SOPS_AGE_KEY_FILE` to point at it before encrypting or validating — otherwise
`make validate` reports a bare `FAILED:` on a secret that is fine.

### The way that works

sops picks its recipients by matching the **file's own path** against `path_regex` in
`.sops.yaml`. That has a consequence worth knowing before you try to be clever: you
cannot write the plaintext somewhere else and encrypt it into place.

```bash
$ sops --encrypt /tmp/ovh-plain.XXXXXX > apply/10-secrets/ovh-domain-secrets.yaml
error loading config: no matching creation rules found
```

`/tmp/...` matches no creation rule, so sops refuses — which is the good outcome. The
bad outcome would be a rule that matched and named the wrong key group.

So the plaintext has to live at a path under `apply/10-secrets/`. Give it a name git
ignores, encrypt it there, and move it:

```bash
cd ~/k8s-titan
umask 077
mkdir -p apply/10-secrets
stage=apply/10-secrets/.staging.ovh.yaml     # git-ignored, matches path_regex
cat > "$stage" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: ovh-domain-secrets
  namespace: cert-manager
type: Opaque
stringData:
  OVH_APPLICATION_KEY: <paste>
  OVH_APPLICATION_SECRET: <paste>
  OVH_CONSUMER_KEY: <paste>
EOF
sops --encrypt --in-place "$stage" && mv "$stage" apply/10-secrets/ovh-domain-secrets.yaml
```

One `&&` chain, so the plaintext sits in the tree for milliseconds and under a name
`git add -A` cannot stage. Encrypting in place at the final path also works — it is
what was done for the first issuance — it just leaves a wider window in which a
well-timed `git add -A` publishes the triple to a public repo.

`stringData` rather than base64 `data` because `encrypted_regex` in `.sops.yaml` only
encrypts `data`/`stringData` — the plaintext never leaves the file, and the encrypted
result keeps `metadata` readable for review.

Then prove it:

```bash
make validate      # OK: apply/10-secrets/ovh-domain-secrets.yaml
make leak-check    # staged diff must carry no credential shape
```

And check the recipients, because a secret encrypted to the wrong key group decrypts
fine on your laptop and fails in the cluster:

```bash
grep -oE 'age1[a-z0-9]{12}' apply/10-secrets/ovh-domain-secrets.yaml | sort -u
grep -oE 'age1[a-z0-9]{12}' .sops.yaml | sort -u    # must print the same four
```

## 3. Confirm it works in the cluster

```bash
kubectl -n cert-manager get clusterissuer le-prod-titan -o jsonpath='{.status.conditions[*]}'
```

A `Ready=True` condition on both `le-prod-titan` and `le-staging-titan` means the
credential was accepted and the webhook answered the ACME server's probe. A `False`
carrying a 403 means the consumer key was never validated or the rights are missing;
`Unhealthy` naming the webhook means the API service is not reachable yet, which is an
install-order problem rather than a credential one.

## Rotating

Re-issue (step 1), re-encrypt (step 2), then `git push` — Flux reconciles `secrets` every
10 minutes and cert-manager picks the new value up on its next challenge. Delete the old
application in the OVH console once the new one has issued a certificate successfully.
