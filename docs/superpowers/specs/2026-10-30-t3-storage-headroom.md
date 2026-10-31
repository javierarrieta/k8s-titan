# T3 — storage preconditions and destination headroom

Measured 2026-10-30 from the read-only identities on both clusters plus casa's Prometheus. **One
number is still missing and it is the one that decides the stateful wave** — see §4.

## 1. Node-level capacity (measured)

Source: casa's Prometheus, `node_filesystem_*_bytes{mountpoint="/"}`, instances `192.168.133.1`
(titan) and `192.168.133.5` (techdelivery). Cross-checked against `kubectl get nodes -o
jsonpath=.status.allocatable`.

| | titan | VPS (techdelivery) |
|---|---|---|
| Root filesystem size | **146.6 GiB** | 95.8 GiB |
| Available now | **50.75 GiB** | 18.55 GiB |
| Used now | 95.8 GiB | 77.3 GiB |
| `allocatable.ephemeral-storage` | 132.0 GiB | 91.0 GiB |
| CPU allocatable | **12 cores** | 6 cores |
| Memory allocatable | **125.7 GiB** | 11.4 GiB |

## 2. Compute and memory are not a constraint — not close

Summed `resources.requests` over running pods:

| | titan used / allocatable | VPS used / allocatable |
|---|---|---|
| CPU | 4.25 / 12 cores | 2.45 / 6 cores |
| Memory | 9.72 / 125.7 GiB | 3.39 / 11.4 GiB |
| Running pods | 43 | 34 |

The whole VPS workloads set requests **2.45 cores and 3.39 GiB**. Excluding mailserver (out of scope),
authentik (retires, D3) and the Postgres that merges into CNPG, the arriving set is roughly **1.5 cores
and ~2 GiB**. Titan has **7.75 free cores and ~116 free GiB**. Titan is 2× the CPU and 11× the memory of
the box it is absorbing.

**Verdict: compute and memory are green with an order of magnitude to spare.** Nothing in the migration
needs a capacity reservation.

**GPU: none required.** `llm.v.arrieta.eu` is a front door to the halogen endpoint on llm01 over the
mesh, which is how titan already runs `apply/50-apps/llm/`. No migrated workload computes locally.

## 3. Disk is the constraint, and there is a 90 GiB reclaim sitting in plain sight

Five `local-path-retain` PersistentVolumes on titan are **`Released`** — unbound, but `retain` means
their directories were not deleted when the claim went away:

| PV | Capacity | Former claim |
|---|---|---|
| `coder-home-recovered` | 40 GiB | `coder-1258c2a6-…-home` |
| `pvc-2a10168c-e7b3-47a2-8268-3b0ca1ffb424` | 40 GiB | `coder-0d0d2457-…-home` |
| `pvc-3694c681-7f3a-457c-bf74-b581f194f53e` | 5 GiB | `opencloud-data` |
| `pvc-80e2343d-b6f2-4637-b832-2a08d49ebba2` | 5 GiB | `opencloud-data` |
| `pvc-86aae016-f34f-48e1-96d5-7ea83abc74b9` | 5 GiB | `ocis-data` |
| **Total** | **90 GiB** | |

This is pre-flight **F-D**, and it is the headroom. Two of them are superseded coder workspace homes,
three are leftovers from the ocis→opencloud rename.

**But `Released` capacity is not the same as bytes on disk.** `local-path` is thin-provisioned — a 40 GiB
PV whose directory holds 200 MiB costs 200 MiB. Titan's filesystem shows 95.8 GiB used while the *bound*
PVCs request 87 GiB between them, so the Released set cannot be occupying all 90 GiB; some of those
directories are already gone or nearly empty. **Which ones, and how much, is unmeasured** — see §4.

Reclamation is destructive, so per the plan's own rule: **list every PV removed in the PR before removing
any**, and note that `coder-home-recovered` has a name suggesting someone recovered data into it on
purpose. Do not delete that one on the assumption it is junk.

## 4. The missing number, and why Prometheus cannot supply it

Per-PVC **actual** usage is not obtainable from casa's Prometheus for either cluster, and the naive query
actively lies:

```
kubelet_volume_stats_used_bytes{node="vps-f10b475a"}
  apps        databasus-pv-claim      77.29 GiB
  apps        grafana-pv-claim        77.29 GiB
  ... 10 series, all 77.29 GiB, total 772.87 GiB
```

Every VPS volume reports the same 77.29 GiB — which is the **node's** filesystem usage, not the
volume's. The node has 95.8 GiB total, so the 772 GiB "total" is arithmetically impossible. For
`local-path`/hostPath volumes kubelet reports the backing filesystem, not the subdirectory. The same
defect is visible on casa's own series (`nfs-media` at 9443 GiB).

Separately, **titan's kubelet volume stats are not scraped at all** — the only nodes reporting that metric
are casa's and `vps-f10b475a`.

So the honest statement is: **the arriving byte volume is unknown, and the metric that looks like it
answers is wrong.** It needs `du` on the backing directories. Neither `k8s-reader` identity can do it —
`auth can-i create pods/exec` is `no` on both clusters.

### What the requests imply, as the interim answer

| VPS PVC | Request | Disposition |
|---|---|---|
| `databasus-pv-claim` | 10 GiB | arrives if #113 keeps it |
| `trading-reports-pv-claim` | 1 GiB | arrives (#106) |
| `postgres-pv-claim` | 6 GiB | merges into titan's CNPG (#102) |
| `postgres-backup-pv-claim` | 3 GiB | not migrated — titan has its own S3 backup path |
| `investing-agent-pv-claim` | 10 GiB | titan already has a 10 GiB claim; confirm which is authoritative (#105) |
| `open-webui-pv-claim` | 5 GiB | **accepted loss** — history disposable (D4); titan has 10 GiB |
| `grafana-pv-claim` | 100 MiB | **accepted loss** — hand-built dashboards (D4) |
| `postgresus-pv-claim` | 1 GiB | retires (R1 / #114) |
| mailserver ×4 | 54.2 GiB | **out of scope** |

**Genuinely arriving: ~17 GiB of requests** (databasus + trading-reports + postgres), against **50.75 GiB
free** — fits with ~34 GiB margin *before* any reclaim.

## 5. Verdict

| Axis | Verdict | Basis |
|---|---|---|
| **CPU** | **GREEN** | 7.75 free cores vs ~1.5 arriving |
| **Memory** | **GREEN** | ~116 GiB free vs ~2 GiB arriving |
| **GPU** | **GREEN / n/a** | no migrated workload computes locally |
| **Disk** | **CONDITIONAL** | requests fit (17 GiB into 50.75 GiB free), but actual bytes are unmeasured and the obvious metric is wrong |
| **Reclaim available** | **up to 90 GiB** | 5 Released PVs; real size unmeasured |

**The stateful wave (#106, #113, #102) can start on the request-based numbers** — 17 GiB into 50.75 GiB
free is not close to a wall, and there is a 90 GiB reclaim behind it. What must not happen is starting it
on the assumption that the Released PVs are already reclaimed, or that `kubelet_volume_stats_used_bytes`
measured anything.

Two things to close before the wave, both cheap:

1. `du` the five Released directories and the arriving VPS volumes (commands handed over — needs admin).
2. Decide, per PV, whether it is junk. `coder-home-recovered` and the two `opencloud-data`/`ocis-data`
   leftovers each have a plausible reason to exist.

## 6. Policy to record (the ticket's actual file deliverable)

Two `local-path` behaviours bit this plan and should be written down rather than rediscovered:

- **`local-path` is thin.** A PVC's `status.capacity` equals its *request*, not its usage, and
  `kubelet_volume_stats_used_bytes` reports the backing filesystem for hostPath volumes. Neither number
  tells you how much data a volume holds. Size migrations from requests, verify with `du`.
- **titan has two StorageClasses: `local-path` and `local-path-retain`.** Every migrated workload that
  must survive a PVC deletion needs `local-path-retain` explicitly named in its `storageClassName`;
  inheriting the default silently gets `local-path`, which deletes the directory on claim deletion.
  Existing titan apps that matter all name `local-path-retain`; the VPS manifests all say plain
  `local-path`, so **every migrated stateful manifest must be edited, not copied.**
