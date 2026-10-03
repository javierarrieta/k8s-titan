# Read-only agent access

`k8s-reader` is the identity to hand an investigation agent. It is a plain
ServiceAccount bound to a read-only ClusterRole — no `system:masters` client
certificate, no admin kubeconfig, and **no path to Secret values**.

Manifests: `apply/20-infra/k8s-reader/`, applied by the `infra` stage.

## What it can and cannot see

Read (`get`/`list`/`watch`) across pods and logs, workloads, events, configmaps,
nodes, RBAC, admission and webhook config, storage classes, apiservices, leases,
CRDs, `metrics.k8s.io`, all Flux and cert-manager objects, and k3s's own
`helm.cattle.io` charts.

Deliberately absent:

| not granted | why |
|---|---|
| `secrets` | cluster-wide read on Secrets is write-equivalent — registry creds, the OVH DNS credential, every token |
| `nodes/proxy` | reaches the kubelet API; a real escalation path that "read-only" roles often miss |
| `pods/exec`, `/attach`, `/portforward`, `/proxy` | not read operations |
| `serviceaccounts/token` | mints a credential for another identity |
| any write verb | the role is get/list/watch only |

The resource list is enumerated rather than `*` so that a new API group appearing
in the cluster is invisible until someone adds it on purpose.

## Handing out access

**Preferred — short-lived, for one investigation.** Nothing to rotate:

```bash
kubectl -n k8s-reader create token k8s-reader --duration=8h
```

**For unattended agents — the long-lived token.** It does not expire, so treat it
as a standing credential:

```bash
kubectl -n k8s-reader get secret k8s-reader-kubeconfig-token \
  -o jsonpath='{.data.token}' | base64 -d
```

Either way the agent also needs the CA. It is not secret — it ships inside every
kubeconfig — and Kubernetes mirrors it into a ConfigMap:

```bash
kubectl -n k8s-reader get cm kube-root-ca.crt -o jsonpath='{.data.ca\.crt}'
```

Then:

```bash
SERVER=https://192.168.133.1:6443     # over the WireGuard mesh
kubectl config set-cluster titan --server="$SERVER" --certificate-authority=titan-ca.crt --embed-certs=true
kubectl config set-credentials agent  --token="$TOKEN"
kubectl config set-context titan --cluster=titan --user=agent
kubectl --context titan get nodes      # must succeed with no insecure flag anywhere
```

The mesh address is in the API server's serving-certificate SAN list, so this
verifies properly. Never add `insecure-skip-tls-verify` to an agent kubeconfig —
an agent will not notice it is there, and neither will anyone else.

## Verify after any change to the role

Positive and negative, both required. A role that silently grants Secrets still
looks healthy in `describe`:

```bash
A=system:serviceaccount:k8s-reader:k8s-reader
kubectl auth can-i list pods             --as="$A"   # yes
kubectl auth can-i get secrets           --as="$A"   # NO  -- if this says yes, stop
kubectl auth can-i list secrets          --as="$A"   # NO
kubectl auth can-i get pods/exec         --as="$A"   # NO
kubectl auth can-i create deployments    --as="$A"   # NO
kubectl auth can-i list kustomizations   --as="$A"   # yes
```

## Rotating the long-lived token

```bash
kubectl -n k8s-reader delete secret k8s-reader-kubeconfig-token
```

Flux recreates it on the next sync (or apply `serviceaccount-token.yaml` by hand
to do it now), the controller mints a fresh token, and every kubeconfig carrying
the old one stops working. Re-issue from there.

## Notes

- The token authenticates from anywhere that can reach 6443. Off-mesh hosts need
  WireGuard; there is no IP allowlist behind k3s, so treat a leaked token as
  leaked and rotate it.
- The token Secret is exempt from `make secrets-placement` only while it stays a
  token request with no `data:` block. Paste a real token into that file and the
  gate fails.
- This identity is read-only by construction, not by policy. Nothing here stops a
  determined agent from *reading* a lot of cluster state — configmaps included.
  It stops reading Secrets and from changing anything.
