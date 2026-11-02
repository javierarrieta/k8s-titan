# Traefik cutover runbook — k3s-bundled → Flux-managed (#209)

The sequence that moves titan's ingress from k3s' bundled Traefik to the Flux-managed one.
Read this before touching anything, and follow it in order. Every command is `--context titan`
and fish-safe; there are no heredocs and no bashisms.

Design: `docs/superpowers/specs/2026-10-31-titan-ingress-ownership-decision.md`.
Full plan: `docs/superpowers/plans/2026-10-31-traefik-cutover-209.md`.
This file is the short operational version, and it exists because three commands drifted by
being retyped into chat during the phase-A work — including one that dropped `--type=merge`
and failed on a CRD. Commands belong here, not in a scrollback.

**Downtime budget: one hour** (operator decision 2026-10-31). That is permission to verify
slowly, not permission to skip verification.

---

## Phase A — already done, no traffic

A second Traefik runs in `traefik-system` with a ClusterIP and no public address. It receives
nothing. Merged as #211, fixed by #214.

Prove it is inert before going further:

```fish
kubectl --context titan -n traefik-system get svc traefik \
  -o jsonpath='{"type="}{.spec.type}{" externalIPs="}{.spec.externalIPs}{"\n"}'
# expect: type=ClusterIP externalIPs=
```

---

## C1 — stop k3s from being able to uninstall the bundled charts

**Why this is first and non-negotiable.** `nixos-configurations#163` sets
`disable = ["traefik", "servicelb"]`. k3s then deletes
`/var/lib/rancher/k3s/server/manifests/traefik.yaml` — and that one manifest declares **two**
HelmCharts, because `--disable` matches the manifest basename:

| HelmChart | owns |
|---|---|
| `kube-system/traefik` | the Deployment, Service, IngressClass |
| `kube-system/traefik-crd` | **all 25 Traefik CRDs** |

Deleting `traefik-crd` runs a helm uninstall. Every `Middleware` and `IngressRouteTCP` in the
cluster is then cascade-deleted — including the authentik forwardAuth middlewares that gate the
public hosts — and **every k8s-titan gate stays green the whole way down, because they all read
git.**

`helmcharts.helm.cattle.io/unmanaged` gates `shouldManage()`, which gates both the install path
and the scoped `OnRemove` handler (verified against helm-controller v0.17.7, the version
`v1.35.8+k3s1` pins). The scoped handler returns early without invoking wrangler's remove
handler, so the `wrangler.cattle.io/on-helm-chart-remove` finalizer is never released on its own.
Strip it **after** annotating, never before.

```fish
# 1. mark unmanaged FIRST
kubectl --context titan -n kube-system annotate helmcharts.helm.cattle.io traefik traefik-crd \
  helmcharts.helm.cattle.io/unmanaged=true --overwrite

# 2. then release the finalizers. --type=merge is REQUIRED: CRDs reject kubectl's default
#    strategic-merge patch with "application/strategic-merge-patch+json is not supported".
kubectl --context titan -n kube-system patch helmcharts.helm.cattle.io traefik --type=merge \
  -p '{"metadata":{"finalizers":null}}'
kubectl --context titan -n kube-system patch helmcharts.helm.cattle.io traefik-crd --type=merge \
  -p '{"metadata":{"finalizers":null}}'
```

Verify — both must read `true` / `<none>`, and nothing may be `Terminating`:

```fish
kubectl --context titan -n kube-system get helmcharts.helm.cattle.io traefik traefik-crd \
  -o custom-columns='NAME:.metadata.name,UNMANAGED:.metadata.annotations.helmcharts\.helm\.cattle\.io/unmanaged,FINALIZERS:.metadata.finalizers'
kubectl --context titan get crd | grep -c traefik.io                  # must be 25
kubectl --context titan get middleware -A --no-headers | wc -l        # record it
kubectl --context titan get ingress -A --no-headers | wc -l           # record it
```

**Write the Middleware count down.** It is the only cheap proof the cascade never happened.
Measured 2026-11-02: **25 CRDs, 3 Middlewares, 15 Ingresses.** Note the gate reports *5
forwardAuth references* in the tree while the cluster holds *3 Middleware objects* — references
versus objects, both correct, not a missing object.

> **NEVER RUN:** `helm -n kube-system uninstall traefik-crd`. It deletes all 25 CRDs and
> cascades every Middleware and IngressRouteTCP. The release record is kept on purpose; the
> annotation is what makes it inert, not its absence.

---

## C2 — hand the IngressClass over

`IngressClass/traefik` is owned by helm release `traefik` in `kube-system`. If the Flux release
installs while that is true, helm refuses with `IngressClass "traefik" already exists`, the
HelmRelease goes `InstallFailed`, `stage-infra` waits, and `certificates`, `apps`, `tesla`,
`databases` and `backup` all drop to `DependencyNotReady`. #211 caused exactly that with a
smaller mistake.

```fish
kubectl --context titan patch ingressclass traefik --type=merge \
  -p '{"metadata":{"annotations":{"meta.helm.sh/release-name":"traefik","meta.helm.sh/release-namespace":"traefik-system"}}}'

kubectl --context titan get ingressclass traefik \
  -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}{" / "}{.metadata.annotations.meta\.helm\.sh/release-namespace}{"\n"}'
# expect: traefik / traefik-system
```

---

## C3 — merge phase B and watch it

**Merging #215 is the cutover.** There is no staged rollout: when Flux syncs, the public address
DNATs to the new Traefik and it claims the routes. Four things move together because any subset
is an outage — `externalIPs`, `externalTrafficPolicy: Local`, the IngressClass claim, and
`publishedService`.

```fish
kubectl --context titan -n traefik-system get helmrelease traefik -w
```

Then from outside, and re-check the cascade numbers:

```fish
for h in coder grafana auth llm files; printf "%-10s %s\n" $h (curl -s -o /dev/null -w '%{http_code}' https://$h.titan.arrieta.eu); end
kubectl --context titan get middleware -A --no-headers | wc -l    # must still be 3
kubectl --context titan get crd | grep -c traefik.io              # must still be 25
```

The old Traefik keeps running with its `hostPort` bind, so it stays reachable on the node's other
addresses. That is the safety net for this window.

`make dry-run` cannot validate any of this: it applies the `HelmRelease` object, and
`spec.values` is `x-kubernetes-preserve-unknown-fields` in the Flux CRD, so the API server never
sees the Service the chart renders. `make traefik-exposure-check` is what asserts the shape
offline.

---

## Rollback — and why `git revert` alone is a trap

Reverting #215 makes helm **delete the IngressClass it adopted**. The bundled release is now
`unmanaged`, so it will **not** re-create it. Result: no `IngressClass/traefik`, every Ingress
unserved, total outage — with git looking clean.

**Prepare this file before merging**, not during the incident:

```yaml
# /tmp/ingressclass-traefik.yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: traefik
  annotations:
    meta.helm.sh/release-name: traefik
    meta.helm.sh/release-namespace: kube-system
spec:
  controller: traefik.io/ingress-controller
```

Then, in this order:

```fish
# 1. revert #215 and let Flux sync. The revert makes helm delete the IngressClass it adopted.
git revert <sha-of-215-merge> && git push
flux --context titan reconcile kustomization infra --with-source

# 2. put the IngressClass back immediately. Applying it BEFORE the revert is pointless — the
#    revert deletes it again.
kubectl --context titan apply -f /tmp/ingressclass-traefik.yaml

# 3. prove the old path is serving again
kubectl --context titan get ingressclass traefik
for h in coder grafana auth llm files; printf "%-10s %s\n" $h (curl -s -o /dev/null -w '%{http_code}' https://$h.titan.arrieta.eu); end
```

The old Traefik watches IngressClass objects by `spec.controller`, so it picks the routes back up
without a restart. The hand-made class above has no helm ownership annotations at all, which is
fine — nothing needs helm to own it for routing to work. If you want the bundled release to own it
again, re-point the annotations as in C2 **and** remove the `unmanaged` annotation from
`kube-system/traefik`, or it will never reconcile the object.

Expect a short window between steps 1 and 2 with no IngressClass. That is why the file is prepared
in advance.

---

## C4 — only after traffic is proven on the new path

Apply `nixos-configurations#163` (`nixos-rebuild switch` on titan). This is what makes the change
survive a k3s restart. Afterwards:

```fish
kubectl --context titan -n kube-system get helmcharts.helm.cattle.io traefik traefik-crd   # gone, NOT Terminating
kubectl --context titan get crd | grep -c traefik.io      # still 25 — this is the proof C1 worked
kubectl --context titan get middleware -A --no-headers | wc -l    # still 3
kubectl --context titan get ingress -A --no-headers | wc -l       # still 15
```

If the HelmCharts are stuck `Terminating`, C1's finalizer strip did not take. Do not force it;
re-run the two `--type=merge` patches and read the result.

---

## What this runbook does not cover

* The `37.187.159.156` address is allow-listed in `leak-check`; see the citation in the Makefile.
* `externalTrafficPolicy: Local` is a single-node assumption. The day a second node appears or
  this pod is unschedulable, `Local` drops all traffic instead of load-balancing.
* kube-proxy mode matters. The externalIPs analysis is iptables-specific; if titan ever moves to
  `--proxy-mode=nftables` or `ipvs`, re-derive it before trusting this file.
* Nothing here is monitored. A Traefik that stops answering is detected by someone noticing.
