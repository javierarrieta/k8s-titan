# #209 — how titan's ingress gets its public address

Decision doc for [#209](https://github.com/javierarrieta/k8s-titan/issues/209). The migration depends on
titan replacing k3s's embedded Traefik with a Flux-managed chart (spec D5), and the one genuinely open
design question was **what binds the public IPv4 once k3s's ServiceLB is gone**.

It turns out that question has a bad framing, and the fleet already contains the answer.

**Measured 2026-10-31** against both live clusters and `nixos-configurations`. Everything below is
observed, not assumed.

## 1. What titan does today

```
svc  kube-system/traefik        type=LoadBalancer  externalIPs=None  loadBalancerIP=None
                                  externalTrafficPolicy=Cluster
                                  web:80->NodePort 31109   websecure:443->NodePort 30431
ds   kube-system/svclb-traefik-da79b8e7   rancher/klipper-lb:v0.4.17
                                  hostNetwork=false, hostPort 80 and 443 declared
node InternalIP = <TITAN_PUBLIC_IP>   ← the public address is the node's own primary address
```

`nixos-configurations/hosts/titan/configuration.nix:80` explains why that works:

> *OVH's primary IP is a /24 with on-link gateway, so this is empty.*

So the public IP is **statically configured on the host interface**. Nothing needs to claim it, announce
it, or route it — it is simply the node's address. klipper-lb's job is only to get packets from
`node:80`/`node:443` into the pod network, and it does that by declaring `hostPort` 80/443.

**`traefik` is the only `LoadBalancer` Service in the cluster.** ServiceLB exists on titan solely to serve
this one object.

## 2. MetalLB is not a candidate, and it can be eliminated on evidence

The first draft of #209 listed MetalLB in L2 mode as an option. It is not one:

- L2 mode works by answering ARP for an address the node does not own. Titan's public IP **is** configured
  on `eno1` with a /24 and an on-link gateway. There is nothing to ARP for.
- MetalLB would be a new component, with a new CRD surface and a new speaker DaemonSet, to solve a problem
  the host configuration already solved.
- It earns its place with floating IPs or multi-node failover. Titan is one node with one primary address.

Cross-node BGP mode is likewise irrelevant here. **Drop MetalLB from the options.**

## 3. The VPS already solved this, and its answer is better than either remaining option

The VPS disabled the bundled chart and runs a Flux Traefik. Its service is **not** a `LoadBalancer`:

```
svc  traefik-system/traefik   type=ClusterIP
                               externalIPs=['<VPS_PUBLIC_IP>']
                               externalTrafficPolicy=Cluster
                               annotations: helm.sh/resource-policy=keep
pods                           hostNetwork=false, no hostPort 80/443
ds   (none)                   no svclb-* DaemonSet anywhere in the cluster
```

`externalIPs` is a plain ClusterIP Service with the node's address listed on it. kube-proxy installs the
DNAT rules itself, so traffic arriving at the node on 80/443 goes straight to the Traefik endpoints.

That is **simpler than titan's current setup**, not just different: no klipper-lb image to mirror, no
per-Service DaemonSet, no `hostPort` contention, and **no NodePorts at all** — which retires the
`31109`/`30431` firewall question rather than answering it.

## 4. The options

| | Mechanism | nixos `disable` | Verdict |
|---|---|---|---|
| **A** | Keep ServiceLB; Flux Traefik stays `LoadBalancer` and gets its own `svclb-*` DaemonSet | `["traefik"]` | Works. Preserves today's path exactly, including its NodePorts and its extra DaemonSet. Smallest diff, most machinery kept. |
| **B** | MetalLB L2 | `["traefik","servicelb"]` | **Eliminated** — §2. |
| **C** | `hostNetwork: true` Traefik, no Service abstraction | `["traefik","servicelb"]` | Works, fewest moving parts, but loses the Service object, pins Traefik to node networking, and collides with anything else wanting 80/443. |
| **D** | **ClusterIP + `externalIPs`, the VPS pattern** | `["traefik","servicelb"]` | **Recommended.** Proven on the sibling box, fewest components, no NodePorts, keeps the Service abstraction. |

**Recommend D.** It is the only option with a working precedent on an identical box in this fleet, it
removes a component instead of preserving one, and it makes the firewall story strictly simpler. A is a
legitimate fallback if D hits a surprise — and A is *cheaper to try*, since it is a one-word change to the
`disable` list.

## 5. Three hazards, in the order they will bite

**1. `hostPort` contention during cutover.** Today `svclb-traefik-*` holds `hostPort` 80 and 443. Under D
those ports are taken by kube-proxy DNAT instead, but **the old svclb DaemonSet must be gone before the new
path is trusted**, or both want the same ports on the same node. This is a real, if brief, outage window on
a box serving 14 hostnames. Sequence it: deploy the new Traefik with a different Service name and no
`externalIPs` yet, verify it internally, then move the address and delete the old chart in one change.

**2. The CRD question is still unverified, and it is the one that can take the cluster down.** Titan has
**25** `traefik.io`/`hub.traefik.io` CRDs, all `managed-by: Helm`, from a `traefik-crd` HelmChart that is
separate from the `traefik` HelmChart. Three live `Middleware` objects and the `IngressRouteTCP` objects
under `60-tesla/` depend on those types.

**It is not known whether `--disable=traefik` also removes `traefik-crd`.** If it does, every `Middleware`
is orphaned the moment the flag lands — and `crd-check` and `ingress-auth` both read `vendor/traefik-crds/`
in the repo, so **the gates stay green while the cluster loses the types.** Verify before switching, and
install the CRDs from the new chart first regardless. `k8s-titan` already vendors them under
`vendor/traefik-crds/`.

**3. Client source IP is already being lost, and D does not fix it.** Both titan today and the VPS use
`externalTrafficPolicy: Cluster`, which SNATs — so Traefik sees a masqueraded peer, not the client. That
means real client IP is unavailable to Traefik logs, rate limits, and any authentik IP/geoip policy. This
is **pre-existing, not a regression**, but the cutover is the moment to fix it: on a single node
`externalTrafficPolicy: Local` is safe and restores the real peer address. Decide deliberately rather than
inheriting `Cluster` by copy-paste from the VPS manifest.

## 6. What a replacement must still reproduce

Carried from #209, unchanged by the choice above:

- **A `websecure` entrypoint that terminates TLS.** `investing-agent` and `llm` pin
  `router.entrypoints: websecure`; `investing-agent.yaml:299` calls that pin the most important line in
  the object. Without it Traefik binds both entrypoints and the dashboard answers on cleartext.
- **Dashboard and API off.** The current install has them off; upstream chart defaults do not.
- **`Middleware` CRs in the app's own namespace**, referenced as `<name>@kubernetescrd` — titan's existing
  convention (`apps/teslamate-auth`, `observability/observability-grafana-auth`, `llm/llm-bearer-auth`).
  The VPS annotates `traefik-system-bearer-auth@kubernetescrd`, coupled to a namespace titan does not have,
  so migrated middleware references are **rewritten, not copied**.
- **The firewall allow-list.** 80/443 stay open. Under D the NodePorts disappear, which is an improvement
  worth stating in the PR rather than leaving implicit.

## 7. What this does to the migration

D5 makes the migration land **after** this. That ordering is the argument for doing it now: the cutover
touches **14 live hostnames instead of 27**, and it closes the chart-version gap D5 left unowned — the
bundled chart is 40.1.4, two versions behind the release that fixed F19.

Under D, `nixos-configurations` spec D4 is fully reversed rather than half-preserved:
`disable = [ "traefik", "servicelb" ]`. That should be said plainly in the PR, because D4 was a confirmed
founding decision and reversing it deserves a sentence about why the reason it was made no longer holds —
ServiceLB was kept because there was no LoadBalancer controller, and it turns out one was never needed.

## 8. Before committing to D

1. **Verify the CRD behaviour** of `--disable=traefik` on a scratch cluster or by reading the k3s version in
   use. This is the only item that can take the cluster down.
2. **Confirm kube-proxy mode** on titan (iptables vs nftables vs IPVS) — `externalIPs` works in all three,
   but the rendered rules differ and the firewall module has to agree with them.
3. **Decide `externalTrafficPolicy`** deliberately (§5.3).
4. **Check nothing else wants `hostPort` 80/443** once svclb is gone.
