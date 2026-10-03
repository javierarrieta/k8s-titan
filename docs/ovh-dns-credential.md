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
[application creation page](https://api.ovh.com/createToken/index.cgi?GET=/domain/zone/*&PUT=/domain/zone/*&POST=/domain/zone/*&DELETE=/domain/zone/*).

| field | value |
|---|---|
| Application name | `k8s-titan-cert-manager` |
| Description | DNS-01 challenge records for titan.arrieta.eu |
| Validity | Unlimited |
| Rights | `GET /domain/zone/*`, `PUT /domain/zone/*`, `POST /domain/zone/*`, `DELETE /domain/zone/*` |
| Restrict IPs | blank (titan's egress is its public IP; pinning it is a hardening step, not a requirement) |

Those four rights are what the webhook documents and nothing more — it only ever
creates and deletes `_acme-challenge` TXT records and refreshes the zone.

If you want to narrow it, `/domain/zone/arrieta.eu/*` instead of `/domain/zone/*` is the
obvious cut. Test the narrower credential against **`le-staging-titan`** before trusting
production: the webhook probes zone-status endpoints as well, and a credential that
passes staging is proven, while one that fails only at production is a rate-limit
problem you created for yourself.

You get `ApplicationKey` and `ApplicationSecret` immediately and a `ConsumerKey`; if the
page hands you a validation URL, open it and accept, or the consumer key will not
authenticate.

## 2. Encrypt it into the repo

Run this yourself. The values should not pass through a chat, a shell history entry, or a
commit message.

```bash
cd ~/k8s-titan
mkdir -p apply/10-secrets
cat > apply/10-secrets/ovh-domain-secrets.yaml <<'EOF'
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
sops --encrypt --in-place apply/10-secrets/ovh-domain-secrets.yaml
```

`stringData` rather than base64 `data` because `encrypted_regex` in `.sops.yaml` only
encrypts `data`/`stringData` — the plaintext never leaves the file, and the encrypted
result keeps `metadata` readable for review.

Then prove it:

```bash
make validate      # OK: apply/10-secrets/ovh-domain-secrets.yaml
git add apply/10-secrets
git diff --cached | grep -nE 'OVH_[A-Z_]+: [A-Za-z0-9]{8,}' && echo "PLAINTEXT STAGED" || echo clean
```

## 3. Confirm it works in the cluster

```bash
kubectl -n cert-manager get clusterissuer le-prod-titan -o jsonpath='{.status.conditions[*].message}'
```

`We could connect to ACME server and the webhook` means the credential is accepted. A
403 from OVH means the consumer key was never validated or the rights are missing.

## Rotating

Re-issue (step 1), re-encrypt (step 2), then `git push` — Flux reconciles `secrets` every
10 minutes and cert-manager picks the new value up on its next challenge. Delete the old
application in the OVH console once the new one has issued a certificate successfully.
