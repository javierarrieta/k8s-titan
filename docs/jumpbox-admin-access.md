# The jumpbox holds cluster-admin here, on purpose

This is a record of an accepted decision, not a finding. If an audit or an agent
surfaces "the ssh jumpbox has a `system:masters` credential for titan", that is
the intended state. Read `docs/agent-read-access.md` first — it describes the
identity agents are supposed to get. This file describes the one place that
deliberately does not use it.

## What the credential is

```
subject    O=system:masters, CN=system:admin
notAfter   2027-10-02
server     https://192.168.133.1:6443   (wg-mesh)
context    titan
```

`system:masters` is k3s's built-in cluster-admin group. This is not a reader
token and it is not scoped.

## Where it lives

Not in this repo. It is one entry in a SOPS-encrypted Secret owned by
**k8s-casa**:

```
apply/01-secrets/casa/ssh-kube-config.yaml   ->  Secret/casa/kube-config
                                                 key: config (base64 kubeconfig)
```

That Secret is mounted at `/root/.kube/config` in `Deployment/casa/ssh` — the
jumpbox. The same file also carries admin credentials for casa and for the VPS,
so titan is not the only cluster exposed by this one Secret.

Five age recipients can decrypt it (`.sops.yaml` in k8s-casa): the cluster, two
Coder workspaces, and two laptops. Rotating any of those keys requires
`sops updatekeys` on the file, then `make validate` in k8s-casa — `updatekeys`
does not verify that anything still decrypts.

## Why it is admin rather than `k8s-reader`

The jumpbox is the break-glass path, and the things break-glass needs are exactly
what `k8s-reader` is denied:

| needed from the jumpbox | `k8s-reader` can do it |
| --- | --- |
| read a Secret (rotated token, registry creds) | no — `secrets` is deliberately absent |
| `kubectl exec` into a pod that will not start | no — `pods/exec` absent |
| `kubectl port-forward` to reach a service | no — `pods/portforward` absent |
| mint a token for another ServiceAccount | no — `serviceaccounts/token` absent |
| anything that writes | no — get/list/watch only |

An investigation agent should still use `k8s-reader`. The jumpbox is a human
recovery path, and a recovery path that cannot read Secrets or exec is not a
recovery path.

## What limits the blast radius

The credential is only reachable by logging in as root over ssh to
`192.168.0.41:22`, which is port-forwarded from the WAN. Since image `0.1.4`
(k8s-casa#348) that sshd runs with:

- key-only auth — `PasswordAuthentication no`, `PermitRootLogin prohibit-password`,
  `KbdInteractiveAuthentication no`
- `GatewayPorts no` — was `yes`. That was the real exposure: with `yes`, any
  session could bind an `ssh -R` forward to a routable address on a flat L2.
- `MaxAuthTries 3`, `LoginGraceTime 30`, `ClientAliveInterval 300`

The deprecated KEX and host-key algorithms the previous image re-enabled
(`diffie-hellman-group1-sha1`, `+ssh-rsa`, and a DSA host key that failed to load
on every start) are gone.

So the honest statement of the risk is: **one root ssh key, held on a laptop and
two Coder workspaces, guards a cluster-admin credential for three clusters.**
That is the accepted trade. Tightening it means either moving the jumpbox off the
WAN, or splitting per-purpose credentials out of the single `kube-config` Secret.

## Rotation

The client certificate is issued by k3s on titan. To rotate:

1. Issue a new client cert on titan (the `system:admin` group is what carries the
   privilege; the CA is unchanged).
2. Rebuild the kubeconfig with server `https://192.168.133.1:6443` and context
   `titan`.
3. Re-encrypt the Secret in k8s-casa and run `make validate` there.
4. Confirm from the jumpbox: `kubectl --context titan auth can-i get pods -A`.

**Rotation does not revoke the old certificate.** Nothing in this repo
configures a CRL or `--client-ca-file` revocation for the API server, and I have
not verified the k3s server arguments on titan to confirm one is absent — so
assume the previous cert keeps working until it expires. If a key is suspected
compromised, that is a CA-level decision, not a Secret edit, and it needs
verifying against the live k3s config before anyone relies on this section.

## Verify it is still admin

```bash
kubectl --context titan auth whoami
# expect: Username system:admin, Groups [system:masters ...]
```

If that ever reports `k8s-reader` instead, someone tightened this and this file
is now stale — update it rather than reverting the change.
