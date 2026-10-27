# The OVH DNS webhook chart

`apply/20-infra/cert-manager/ovh-webhook.yaml` pins `cert-manager-webhook-ovh` from
`https://aureq.github.io/cert-manager-webhook-ovh/`. Its values are validated against a
JSON schema shipped inside the chart, and that schema is strict enough to reject this
file's values outright — which is the whole reason this page exists. The credential
itself — how the Secret gets its three keys and how to rotate them — is
`docs/ovh-dns-credential.md`.

## Why the values look the way they do

Chart 0.7.0 rewrote the values layout and added `values.schema.json`. Two of those
changes are load-bearing for this file and neither is obvious from a diff:

- **`issuers[].ovhAuthenticationMethod` is required.** The schema's issuer branch lists
  it alongside `name`/`create`/`kind`/`acmeServerUrl`/`email`/`ovhEndpointName`. Omit it
  and Helm refuses to render: `at '/issuers/0': missing property
  'ovhAuthenticationMethod'`. Titan uses `application` (key + secret + consumer key), not
  `oauth2`.
- **The consumer key is `applicationConsumerKeyRef`, not `consumerKeyRef`.** The schema
  sets `additionalProperties: false` on `ovhAuthenticationRef`, so the old name is not
  merely ignored, it is rejected. The same rename reaches the rendered `ClusterIssuer`:
  its `spec.acme.solvers[].dns01.webhook.config` carries `applicationConsumerKeyRef` and
  `authenticationMethod`, which is what the 0.9.x webhook binary decodes.

The rest of the 0.7.0 rewrite is silent rather than loud: top-level `securityContext`,
`replicas`, `environment`, `port`, `hostNetwork`, `resources`, `nodeSelector`,
`tolerations`, `affinity`, `annotations` and `podAnnotations` moved under `pod.*`, and
`image.repository` split into `image.registry` plus `image.repository`. **This tree sets
none of them**, so nothing here broke — but a value written against the 0.6.0 layout now
fails schema validation instead of being quietly dropped, which is the better failure.
Do not copy old-layout values out of the upstream 0.6.0 README.

## Proving a bump before merging it

Nothing in `make check` renders `HelmRelease` values, so a chart bump that cannot install
passes every gate in this repo. It did: PR #176 went green on a values set the chart
rejects. Until that gap is closed, check a bump offline. This block is bash, not fish —
run it under `bash`:

```bash
cd "$(mktemp -d)"
for v in <old> <new>; do
  curl -sLO "https://aureq.github.io/cert-manager-webhook-ovh/packages/cert-manager-webhook-ovh-$v.tgz"
  mkdir -p "$v" && tar xzf "cert-manager-webhook-ovh-$v.tgz" -C "$v"
done
# extract spec.values from the HelmRelease, then render both and diff
helm template cert-manager-webhook-ovh ./<new>/cert-manager-webhook-ovh \
  -n cert-manager -f /tmp/values.yaml
```

A clean render is necessary and not sufficient. What the rendered diff is worth reading
for: the `Deployment` `spec.selector` (immutable — a change there fails the upgrade),
the `cert-manager-webhook-ovh-ca` and `-webhook-tls` secret names (a change reissues the
webhook CA), the `APIService` name (`v1alpha1.acme.titan.arrieta.eu`, cluster-scoped and
named from `groupName`), and the `secret-reader` `Role`, which must still name
`ovh-domain-secrets` in `resourceNames` for the webhook's own `ServiceAccount`.
Between 0.6.0 and 0.9.19 all four are unchanged.

## After it lands

The `ClusterIssuer` config and the webhook image change in the same apply, so a challenge
already in flight can be presented by the old pod with a config it cannot read. That
fails one challenge, which cert-manager retries once the new pod is up; it is not an
outage, but expect it and do not read it as a broken credential.

```bash
kubectl -n cert-manager get pods -l app.kubernetes.io/name=cert-manager-webhook-ovh
kubectl -n cert-manager get clusterissuer le-prod-titan le-staging-titan
kubectl -n cert-manager get helmrelease cert-manager-webhook-ovh
```

`Ready=True` on both issuers is the same evidence as in
`docs/ovh-dns-credential.md` §3. A red `HelmRelease` naming `values don't meet the
specifications of the schema` means the values were never fixed — the live 0.6.0 objects
are untouched in that state, because Helm validates before it applies, so renewals keep
working on the old webhook while the release is red.

## Not proven

- **No end-to-end DNS-01 challenge has been observed against 0.9.19 on this cluster.**
  The chart declares no minimum cert-manager version and cert-manager is pinned 1.21.1;
  the render diff and a `Ready` issuer are the evidence available offline, and they are
  weaker than a renewal actually solved by the new pod. Record the first one here.
- **The schema gap is still open.** `make check-ci` does not render charts, so the next
  automated bump can repeat this. This page is a workaround, not a gate.
