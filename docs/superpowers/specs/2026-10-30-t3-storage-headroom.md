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

### What the requests imply, and what was actually measured

Measured 2026-10-31 with an admin context (`kubectl exec deploy/… -- du -sh`). **The requests were a
5× overstatement of the bytes that move.**

| VPS volume | Request | **Actual** | Disposition |
|---|---|---|---|
| `postgres-pv-claim` | 6 GiB | **4.2 GiB** | merges into titan's CNPG (#102) |
| `open-webui-pv-claim` | 5 GiB | 896 MiB | **accepted loss** — not copied (D4) |
| `postgres-backup-pv-claim` | 3 GiB | 499 MiB | not migrated — titan backs up to S3 |
| `databasus-pv-claim` | 10 GiB | **89 MiB** | arrives if #113 keeps it |
| `trading-reports-pv-claim` | 1 GiB | **9.3 MiB** | arrives (#106) |
| `grafana-pv-claim` | 100 MiB | 6.7 MiB | **accepted loss** — not copied (D4) |
| `investing-agent-pv-claim` | 10 GiB | not measured — source scaled to 0; **data already migrated** | #105 → retire only |
| `mailserver-maildata-pvc` | 50 GiB | **25 GiB** | **out of scope** |
| `mailserver-mailstate-pvc` | 2 GiB | 419 MiB | **out of scope** |

**Genuinely arriving: ~4.4 GiB actual** (postgres 4.2 GiB + databasus 89 MiB + trading-reports 9.3 MiB),
against **50.75 GiB free** on titan. Not 17 GiB. The disk verdict flips to green.

**The one number that matters is postgres at 4.2 GiB against a 6 GiB claim — 70 % full.** It is the only
volume anywhere near its request. Two consequences: (a) titan's CNPG `Cluster postgres` (pod `postgres-1`,
10 GiB PVC) has to absorb it, and titan's own current usage is still unmeasured, so the merge needs that
number before it happens rather than after; (b) a 4.2 GiB restore into CNPG is a real window, not a
formality — #102's rollback should budget for it.

**New finding: the VPS `investing-agent` Deployment is scaled to `replicas: 0`.** That is why its `du`
timed out — there is no ready pod to exec into. The Deployment exists, its pod template does mount
`investing-agent-pv-claim`, but nothing is running and nothing is writing. **The operator has since
confirmed the data was already migrated to titan** (2026-10-31), so the dormant PVC is dead weight rather
than an un-migrated dataset, and #105 reduces to retiring the VPS side. Worth recording why this was
misreadable in the first place: neither the scale-down nor the completed copy is visible from git, in
either repo — which is the same class of gap the VPS authentik state has (§3), and the same fix: write it
down somewhere a reader can find it.

The VPS's 77.3 GiB of used disk is only partly PVC data: the measured volumes sum to ~31 GiB, of which
mail alone is 25 GiB. The remaining ~46 GiB is system, container images and logs on a box that is
**18.55 GiB from full** — worth knowing because a migration that fills the VPS with copy staging before
the cutover has nowhere to put it.

## 5. Verdict

| Axis | Verdict | Basis |
|---|---|---|
| **CPU** | **GREEN** | 7.75 free cores vs ~1.5 arriving |
| **Memory** | **GREEN** | ~116 GiB free vs ~2 GiB arriving |
| **GPU** | **GREEN / n/a** | no migrated workload computes locally |
| **Disk** | **GREEN** | **~4.4 GiB arriving actual** into 50.75 GiB free. Requests overstated it 5× |
| **Reclaim available** | **up to 90 GiB claim capacity** | 5 Released PVs; real on-disk size still unmeasured |

**The stateful wave (#106, #113, #102) is unblocked.** 4.4 GiB into 50.75 GiB free is not a constraint,
and there is a 90 GiB reclaim behind it if it ever becomes one. What must not happen is starting it on
the assumption that the Released PVs are already reclaimed, or that `kubelet_volume_stats_used_bytes`
measured anything.

One thing still open, and it is now the only one: **titan's own postgres usage is unmeasured.** The VPS
side is 4.2 GiB; titan's CNPG holds authentik, coder, open-webui, grafana, sure and mealie and its volume
is 10 GiB. The `du` pass on titan's storage root answers it — that is the half of the script that needs
the temporary probe pod.

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

## 7. Postgres: the arriving volume was never 4.2 GiB

Prompted by the postgres number, both clusters were queried per-database (`pg_database_size`, not PVC
bytes). The result re-scoped #102 and is recorded here because it is where it was discovered.

| VPS database | Size | |
|---|---|---|
| `teslamate` | 1319 MB | titan has `teslamate` at 1321 MB — likely already migrated |
| `authentik` | 160 MB | **must not migrate** — D3; titan's secret key derives user IDs |
| `postgres`, `template0`, `template1` | ~22 MB | system |

titan CNPG for comparison: `teslamate` 1321 MB · `authentik` 148 MB · `sure` 109 MB · `coder` 24 MB ·
`mealie` 13 MB · `open_webui` 11 MB · `app` 7.8 MB (unattributed — no obvious owner in `k8s-titan`) ·
system ~23 MB. Datadir 2.2 GiB against a 10 GiB claim.

**Three things follow.**

1. **The VPS Postgres holds no databasus, trading-reports, open-webui or investing-agent database.**
   open-webui runs SQLite inside its own volume (the 896 MiB measured above); trading-reports is static
   files; databasus keeps backups on its own volume. The plan's "VPS Postgres → CNPG" framing assumed a
   payload that does not exist.
2. **A whole-cluster restore would be unrecoverable.** `pg_dumpall` from the VPS restores over titan's
   `authentik`, and titan's `AUTHENTIK_SECRET_KEY` derives user IDs — so it changes the identity of every
   existing user rather than merely overwriting rows. Any Postgres move here is a **named-database
   allowlist**, never a cluster copy. This is the single worst failure mode available in the migration and
   the obvious command walks into it.
3. **The #102 ↔ #113 ordering tension dissolves.** With no merge to sequence, databasus's decision stops
   being coupled to it. The tension was sound reasoning about a payload nobody had counted.

**Unverified:** the teslamate size match is suggestive, not proof. A row-count comparison on both sides is
the check. **Also unmeasured:** roles and grants — if a VPS app still connects with a role defined in that
cluster, retiring it takes those grants with it. And the VPS datadir is 4.2 GiB against ~1.5 GiB of
databases, so ~2.7 GiB is WAL; on a box with 18.55 GiB free, unbounded WAL is its own problem regardless
of the migration.
