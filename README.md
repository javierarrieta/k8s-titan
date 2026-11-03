# k8s-titan

Flux-managed manifests for `titan`, a single-node k3s cluster on OVH bare metal.

The cluster is public-internet-facing. SSH is on 13491, the API server on 6443 is reachable
only over WireGuard, and ingress is a **Flux-managed Traefik** in namespace `traefik-system`
(`apply/20-infra/traefik/traefik.yaml`) answering on 80/443 via `externalIPs` on the node's
own public address. It was k3s' bundled Traefik plus ServiceLB until 2026-11-02; the handover
is `docs/traefik-cutover-runbook.md` and the ownership decision behind it is
`docs/superpowers/specs/2026-10-31-titan-ingress-ownership-decision.md`.

Design is not one document any more. The bootstrap spec
(`docs/superpowers/specs/2026-10-03-k8s-titan-flux-bootstrap-design.md`) and the
authentik/CloudNativePG spec that amended it still explain the shape, but the structure this
repo actually has was set by later ones: **`2026-10-19-titan-app-scale-out-design.md`** (the
stage split, the namespace admission test), **`2026-10-22-titan-restic-pv-backups-design.md`**
(the PV backup path), **`2026-10-30-vps-to-titan-workload-migration-design.md`** (what is
arriving and why hostnames change), and **`2026-10-31-titan-ingress-ownership-decision.md`**
(who owns Traefik). Per-app specs and runbooks are under `docs/`.

## The stage model — read this before adding anything

**One numbered directory under `apply/` is one Flux `Kustomization` is one atomic apply is
one failure boundary.** Flux applies a `Kustomization` atomically: one object failing
server-side dry-run means nothing in that unit is applied. The directory boundary is
therefore the blast radius, and nesting a stage inside a stage would collapse two failure
domains back into one.

Stage order is `flux-system` → `secrets` → `infra` → `databases` → `certificates` → `apps` →
`tesla` → `backup`, wired by `dependsOn` in `apply/00-bootstrap/stage-*.yaml`. The numbers
are build and reading order; `dependsOn` is what actually orders reconciles.

| stage | holds |
|---|---|
| `00-bootstrap` | the namespaces, the eight stage `Kustomization`s, Flux itself (`gotk-*.yaml`) |
| `10-secrets` | every SOPS-encrypted `Secret`, decrypted by kustomize-controller. Nowhere else |
| `20-infra` | cert-manager + the OVH DNS-01 webhook, Reflector, Reloader, the CloudNativePG operator, the read-only `k8s-reader` identity, **Traefik**, promtail + kube-state-metrics, the `local-path-retain` StorageClass |
| `30-databases` | the shared Postgres `Cluster` and its daily `ScheduledBackup` |
| `40-certificates` | the wildcard `Certificate`, plus two deliberate exceptions (below) |
| `50-apps` | every app that passed the admission test: authentik, coder, open-webui, grafana, gatus, opencloud + collabora, mealie, sure, llm, investing-agent, searxng, and the two Home Assistant passthroughs |
| `60-tesla` | TeslaMate, its Fleet Telemetry intake, its own Grafana, and the streaming bridge |
| `70-backup` | restic PV backups to casa's MinIO: per-namespace discovery, retention, integrity, RBAC |

A new small app is **one subdirectory under `apply/50-apps/` and one line in that stage's
`kustomization.yaml`** — not a new numbered directory. Whether a workload earns its own
namespace is decided by the admission test in the scale-out spec §3.1; whether it earns its
own *stage* is a different question and the test says so explicitly.

Namespaces are declared centrally in `apply/00-bootstrap/namespaces.yaml` — all seventeen of
them: `apps`, `auth`, `cert-manager`, `certificates`, `cnpg-system`, `coder`,
`coder-workspaces`, `databases`, `files`, `gatus`, `llm`, `mealie`, `monitoring`,
`observability`, `open-webui`, `sure`, `traefik-system`. `k8s-reader` is the one exception:
its own manifest under `20-infra` creates it, because the identity and the namespace are one
thing.

## What runs here

Sixteen public hostnames, seventeen `Ingress` objects. "Gated" means a Traefik `forwardAuth`
`Middleware` in the Ingress's own namespace; "open" means deliberately not proxy-gated and
named with a citation in `tools/ingress-auth-check.py`'s `NOT_PROXY_GATED`.

| host | namespace | own CNPG DB | PVC in backup scope | edge |
|---|---|---|---|---|
| `auth.titan…` authentik | `auth` | yes | — | it *is* the IdP |
| `coder.titan…` coder | `coder` | yes | workspaces excluded by decision | open (OIDC in-app) |
| `open-webui.titan…` | `open-webui` | yes | yes | open (OIDC, login form off) |
| `meals.titan…` mealie | `mealie` | yes | yes | open (OIDC-only) |
| `sure.titan…` | `sure` | yes | yes | chart-rendered Ingress, see the gate note |
| `files.titan…` opencloud | `files` | no | **no — deliberate, see Backups** | open (OIDC proxy) |
| `collabora.titan…` | `files` | no | no | open (no login of its own) |
| `grafana.titan…` | `observability` | no | no (rebuilds from git) | **gated** |
| `tesla.titan…` teslamate | `apps` | yes | — | **gated** |
| `tesla-boards.titan…` | `apps` | no | no | **gated** |
| `authorize.titan…`, `tesla.titan…/.well-known`, `streaming.titan…` | `apps` | no | no | open by protocol necessity |
| `investing-agent.titan…` | `apps` | no | yes | **gated** |
| `llm.titan…` | `llm` | no | — | bearer token (nginx forwardAuth) |
| `hass.titan…`, `chiclana-hass.titan…` | `apps` | no | — | open; HA authenticates natively |

Two of them — authentik's and Sure's — have their `Ingress` rendered by their own Helm chart
out of `HelmRelease.values`, so **no tree-only gate can see them**: `ingress-auth`,
`secret-refs` and `release-secrets` all walk built objects, and a chart's values map is
opaque to kustomize. That is a real hole, not an oversight, and it is why `chart-values-check`
exists.

`make backup-coverage` is the authority on the backup column: it currently reports 4 opted-in
PVCs across 4 namespaces and proves the runner, the Reflector mirror lists and the RBAC agree
with the annotation.

## Certificates and Reflector

`titan-tls` comes from the wildcard `Certificate` in `apply/40-certificates/titan-wildcard.yaml`
(`titan.arrieta.eu` + `*.titan.arrieta.eu`) and is mirrored into consuming namespaces by
Reflector. **The allow-list is the mechanism**: the `secretTemplate` annotations on that file,
currently `apps,auth,open-webui,observability,files,mealie,llm,sure`. A new consuming namespace
means editing that file — never copying the Secret by hand. A `Certificate` can be `Ready`
while a namespace missing from its allow-list silently has no Secret, and the Ingress then
fails on a missing Secret rather than on a broken certificate.

Two deliberate exceptions, each argued in its own header:

- `streaming.titan.arrieta.eu` uses `tesla-streaming-tls`. TeslaMate's Erlang stream client
  rejects wildcard SANs and takes the whole application down every time a car comes online.
  Not duplication to collapse back.
- `coder.titan.arrieta.eu` uses `coder-tls`, a leaf the cluster wildcard already covers. It is
  kept separate for renewal blast radius; issue #218 contests that and carries both sides.

## Backups — two paths, and read the caveats before trusting either

**Postgres**: base backups plus continuous WAL to `s3://k8s-titan-pg-…-eu-west-1-an` (IAM user
`k8s-titan-pg-backups`, credentials in `apply/10-secrets/s3-backup-secrets.yaml`). This path
has been **drilled**, not just written: a scratch-cluster restore returned a value seeded
seconds earlier, and a point-in-time recovery proved `recoveryTarget` is honoured. Recorded
output in [`docs/authentik-runbook.md`](docs/authentik-runbook.md) §2; `scripts/restore-drill.sh`
is re-runnable. `ContinuousArchiving: True` is not proof the first one is working — §1 of that
runbook says why.

**Everything else on a PVC**: restic to `s3:s3.l.arrieta.eu/titan-pv-backups` on casa's MinIO
(`apply/70-backup/`, credentials in `apply/10-secrets/backup-minio-secrets.yaml`). A volume is
in scope **only if its PVC carries `backup.titan.arrieta.eu/class: daily`** — there is no
volume list, and `make backup-coverage` is what proves the annotation, the per-namespace
runner, the Reflector mirrors and the RBAC agree. Ask the cluster, and not with `-L`:

```fish
kubectl get pvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CLASS:.metadata.annotations.backup\.titan\.arrieta\.eu/class'
```

`-L backup.titan.arrieta.eu/class` prints a *label*; this is an *annotation*, so the label
column reads `<unset>` for every volume — which looks exactly like an empty backup set.

Three things to hold onto. **The restic path has never been restored** — the design spec's §10
is that list. **Neither path is monitored**: casa owns the Prometheus that would alert on a
stale snapshot and no such alert exists for titan, so a week of failed backups currently looks
exactly like a week of successful ones. And the exclusions are decisions, not gaps —
`postgres-1` (CNPG owns that path and a file copy of a live datadir can restore corrupt),
`opencloud-data` (metadata without the blob bucket is a restore that looks healthy and is
corrupt, and there is no capacity to mirror the bucket yet), `coder-workspaces` (a workspace
must be reproducible from its image and from git), and both Grafana volumes (every provider
sets `allowUiUpdates: false`, so a wiped PVC rebuilds itself).

## Day-to-day

Everything is a `git push`. **`prune: true` is on for every stage**, and it does the opposite
of what the name suggests: kustomize-controller garbage-collects only the objects in a stage's
own inventory. Something you `kubectl apply` by hand was never in that inventory, so it
**survives** — indefinitely, invisible to Git, quietly diverging from what the repo says. What
prune does guarantee is that anything Git owns gets put back: edit a live object and the next
reconcile reverts it. So fix things in git, and if you hand-apply something to debug, delete it
yourself — Flux will not do it for you.

    make check            # every gate, including the ones that need the age key
    make check-ci         # the keyless subset — what CI runs, and what you run before a commit
    make dry-run DRYRUN_CONTEXT=<admin context>   # the only check that asks the live API server

`make check` fails until the OVH credential exists. That is deliberate — a gate that passes on
zero secrets is not a gate. CI runs `make check-ci` on every push and PR: the gates provable
from the tree alone. It deliberately excludes `validate`, because that needs the age private
key and that key must never be placed in CI. This is the one control here that `--no-verify`
cannot skip.

### The gates, by what they catch

Every one of these exists because something passed a green build and then broke the cluster.
`AGENTS.md` records the origin story of each; this is the index.

| gate | catches |
|---|---|
| `leak-check` | credential shapes and the concrete public IPv4, in the staged diff **and** the whole tracked tree plus untracked files, so it is never vacuous |
| `kustomize-check` | every stage builds offline; also asserts the `GitRepository` still clones anonymously |
| `kustomize-listing` | a manifest no `kustomization.yaml` names — which is a manifest Flux never applies |
| `secrets-placement` | plaintext Secrets outside `10-secrets`, unencrypted files inside it, unlisted files, and `data:` instead of `stringData` |
| `release-secrets` / `secret-refs` | a `HelmRelease` or a hand-written workload reaching for a Secret that does not exist in its namespace |
| `ingress-auth` | a public `*.titan.arrieta.eu` Ingress with no `forwardAuth` gate, a middleware reference that resolves to nothing or to another namespace, or an allow-list entry with no citation |
| `blueprint-mount-check` | an authentik blueprint that is committed, built green, applied by Flux and never mounted on the worker |
| `backup-coverage` | a PVC annotated for backup with no runner, no mirror or no RBAC behind it |
| `crd-check` | a field the vendored CRD schema does not declare at that position — the class a normal validator waves through |
| `namespace-check` | an object naming a namespace this tree never declares, or one that would land in `default` |
| `chart-values-check` | values a pinned chart cannot render — needs the network, so it is in `check`, not `check-ci` |
| `db-url-check`, `oidc-check`, `*-oidc-check`, `mealie-check`, `sure-check` | one credential stored in two files that nothing else ties together; each needs the age key |
| `traefik-exposure-check` | the Traefik Service losing the `externalIPs`/`externalTrafficPolicy` pairing that makes it reachable at all |
| `dry-run` | core-type validation rules that live in the API server and in no vendored schema |

## Re-bootstrapping a cluster from zero

The cluster is live; this section is a recovery runbook, not a setup guide. You need the
`flux` and `kubectl` binaries and a checkout — `flux check --pre` is not something a bare
shell has.

Two things git cannot deliver, because git is encrypted with one of them:

1. **`sops-age`** — the `titan-k8s` age private key, minted with `age-keygen` on the
   operator's machine and never committed.
2. **`ovh-domain-secrets`** — OVH API credentials that can write `arrieta.eu` DNS. Issue and
   encrypt them per [`docs/ovh-dns-credential.md`](docs/ovh-dns-credential.md).

**Where sops looks for that key.** sops reads age identities from
`~/.config/sops/age/keys.txt`; it does not scan the directory. If your key lives elsewhere,
export `SOPS_AGE_KEY_FILE=...` before running any target that decrypts, or `make validate`
prints a bare `FAILED:` that reads exactly like a broken secret when the real problem is that
sops never had the key.

Merge to `main` first — the `GitRepository` syncs `main`, and until the tree exists there a
bootstrapped Flux has nothing to reconcile. Then, from a machine with titan's kubeconfig (over
the mesh, or on the host with `sudo k3s kubectl`):

    flux check --pre
    kubectl apply -f apply/00-bootstrap/flux-system/gotk-components.yaml
    kubectl -n flux-system create secret generic sops-age \
      --from-file=age.agekey=$HOME/.config/sops/age/titan-k8s-key.txt
    kubectl apply -f apply/00-bootstrap/flux-system/gotk-sync.yaml

`$HOME`, not `~`. Bash expands a tilde only at the start of a word or after `=` in something
that looks like a variable assignment, and `--from-file=age.agekey=~/...` is neither — kubectl
is handed a literal `~` and reports the key file is missing. The same `~/` is fine in
`export SOPS_AGE_KEY_FILE=~/...`, which *is* an assignment, so this is not a style preference.

Order matters: `sops-age` before the sync object means the `secrets` stage finds its key on the
first attempt; on a bootstrap a red object is indistinguishable from a broken one.

No `flux bootstrap`, and no git credentials in the cluster: the repo is public, so the
source-controller clones anonymously. If this repo ever goes private, that anonymous clone is
the first thing to break — add a deploy key as a `secretRef` on the `GitRepository` in
`apply/00-bootstrap/flux-system/gotk-sync.yaml` at the same moment you flip visibility, or
every stage stops reconciling in silence. Update the `gitrepository auth` assertion in
`make kustomize-check` in the same change; it asserts no `secretRef` exists and would otherwise
fail permanently.

### Verifying

    kubectl get kustomization -A        # all eight Ready=True
    kubectl get helmrelease -A          # ten: cert-manager + its OVH webhook, reflector,
                                        # reloader, cloudnative-pg, authentik, coder,
                                        # kube-state-metrics, sure, traefik
    kubectl -n cert-manager get clusterissuer          # both Ready=True
    kubectl -n certificates get certificate           # three, all Ready
    for ns in certificates apps auth observability llm; do kubectl -n $ns get secret titan-tls; done
    kubectl -n databases get cluster,database,databaserole,backup,scheduledbackup
    kubectl -n flux-system get pods

**What the read-only identity can prove.** `k8s-reader` (`docs/agent-read-access.md`) can read
the CNPG resources — `get cluster`, `get database`, `get backup` all work — but it is Forbidden
on Secrets and on `dry-run`, and it says so rather than returning an empty list. So the
`get secret` lines above need an admin context; the proof available to a read-only agent is a
TLS handshake against any `*.titan.arrieta.eu` host, since a valid wildcard leaf means the
reflected Secret is present.

Then prove the whole path with a throwaway Ingress on `whoami.titan.arrieta.eu` and
`openssl s_client -connect <OVH_PUBLIC_IP>:443 -servername whoami.titan.arrieta.eu`. Delete it
afterwards, and keep it out of git: `make ingress-auth` fails any *committed* apex Ingress with
no `router.middlewares`, and a throwaway has none.

Reading a failure:

- `secrets` red with a decryption error → the `sops-age` secret is missing or holds a different
  key. Delete and recreate it, then
  `kubectl -n flux-system annotate kustomization secrets -s reconcile.fluxcd.io/requestedAt=`.
- `certificates` red with `dependency 'flux-system/infra' is not Ready` → `infra` has not gone
  Ready yet. That is `dependsOn` plus `wait: true` working, not a fault. It is also transient in
  the other direction: a stage can read `Ready=False / DependencyNotReady` for one interval
  after its dependency recovers.
- `Certificate` stuck `NotReady` with an ACME challenge error → the OVH credentials lack write
  access to `arrieta.eu`, or DNS has not propagated. Check the challenge Order's events before
  assuming DNS: a challenge that was presented but never seen is DNS or credentials, while an
  issuer that is not Ready is a dependency that has not landed.

## Not here (yet)

**external-dns**, deliberately. Public DNS is Terraform in `../public-dns-tf`, and the
`*.titan.arrieta.eu` wildcard A means a new hostname is a new Ingress rule and nothing else.
The one thing that claim hides is documented in that repo: a per-host `Certificate` writes a
`_acme-challenge` node that shadows the wildcard for that exact name, so a per-host
certificate and an explicit A record are one change, not two.

**Alerting.** Grafana, promtail→Loki, kube-state-metrics and Gatus all landed, so the data is
there; what is not there is a rule that fires when a backup goes stale, when WAL archiving
stops, or when free space on `/var/lib/rancher/k3s/storage` runs out — the real ceiling for
every PVC, because `local-path` ignores the size a PVC asks for. Dashboards are not alerting,
and this is the deferred item most likely to bite.

**Traefik tuning is no longer deferred** — it moved here with #209 and lives in
`apply/20-infra/traefik/`. Anything still saying the bundled chart's values are set from
`nixos-configurations` is describing the world before 2026-11-02.
