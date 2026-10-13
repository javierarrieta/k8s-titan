# titan Kubernetes metrics into k8s-casa's Prometheus — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make k8s-casa's central Prometheus scrape titan's kube-apiserver, kubelet, cAdvisor, controller-manager, scheduler and kube-state-metrics over the WireGuard mesh, with no change to nixos-configurations.

**Architecture:** casa's Prometheus pulls directly from `192.168.133.1` (titan's mesh address) using a long-lived bearer token minted by a dedicated ServiceAccount in titan. kube-state-metrics is the only new component in titan and leaves the cluster through the API server's service proxy, so no new port is opened and nothing unauthenticated is added. Every titan series carries `cluster: titan`.

**Tech Stack:** k3s v1.35.8+k3s1 (titan), Flux v2 (Kustomization + HelmRelease), prometheus-operator CRDs (`ScrapeConfig` v1alpha1, `PrometheusRule` v1) in k8s-casa, kube-state-metrics chart 8.6.0 / KSM 2.20.0, sops+age.

**Spec:** `docs/superpowers/specs/2026-10-13-titan-metrics-scrape-design.md` — read it alongside this plan; it carries the reasoning for each decision, and this plan argues from it.

## Global Constraints

- Never set a top-level `namespace:` in any `kustomization.yaml`; these trees span namespaces and that field rewrites them all.
- Every file added under `apply/` must be listed in that directory's `kustomization.yaml`. `make kustomize-listing` enforces it.
- Secrets live only in `apply/10-secrets/` (k8s-titan) / `apply/01-secrets/` (k8s-casa), sops-encrypted. The single exemption is a `type: kubernetes.io/service-account-token` Secret that carries **no** `data` and no `stringData`; `make secrets-placement` enforces exactly that, so pasting a real token into a manifest fails the build.
- Both repos are public. No credentials, and **no concrete public IPv4** — write `<OVH_PUBLIC_IP>`. titan's public IP appears in `kubectl get nodes -o wide` output during verification; it must never be copied into either repo. The mesh address `192.168.133.1` is fine and is already used throughout k8s-casa.
- Stage order is `flux-system → secrets → infra → certificates → apps`, wired by `dependsOn`. Nothing in this plan needs a new stage.
- Offline gates in k8s-titan: `git add -A && make check`. `make validate` needs the age private key and fails where it is absent — that is expected, not a regression to fix. `make check-ci` is the subset CI can run.
- k8s-casa gates: `make validate` (sops decrypt) and `make check-alert-rules`.
- Flux syncs both clusters from `main`. A commit is only live once it is on `main`.
- casa's Prometheus has a **3 Gi** memory limit, `retention: 21d` on a 500 Gi PVC, and an OOM history. Any new scrape gets a `sampleLimit`.

## Measured during planning (2026-10-13, from a box with a LAN/mesh path to titan)

These were probes, not assumptions, and two of them refine spec §7:

| probe | result | consequence |
|---|---|---|
| `curl -k https://192.168.133.1:6443/metrics` | **401** | reachable, needs auth — firewall path already good |
| `curl -k https://192.168.133.1:10250/metrics` | **401** | same |
| `curl -k https://192.168.133.1:10257/metrics`, `:10259` | **403** | bound and open (not refused), authorizer rejecting anonymous — confirms `controlPlaneMetricsBindAddress = "0.0.0.0"` |
| `curl -k https://192.168.133.1:2381/metrics` | connection refused | confirms etcd is out of scope, spec §3 |
| `curl http://192.168.133.1:9100/metrics` | **200** | node_exporter already answers, unauthenticated |
| `kubectl --context k8s-titan get --raw '/api/v1/namespaces/kube-system/services/http:kube-dns:53/proxy/'` | `Forbidden: services "http:kube-dns:53" is forbidden … cannot get "services/proxy"` | the proxy route is recognised; **the SubjectAccessReview resource name is the raw path segment**, so `resourceNames:` on the proxy Role would have to match `http:NAME:PORT` verbatim — grant `services/proxy` without `resourceNames` |
| same, `services/kube-dns:53/proxy/` form | also `Forbidden`, same shape | both path forms parse; use the canonical `http:NAME:PORT` one |
| `helm template` of kube-state-metrics 8.6.0 | Service port is named **`http`**, `port: 8080`; `fullnameOverride` yields a deterministic name | the proxy path is pinned exactly (Task 3) |
| `kubectl --context k8s-titan get pods -A` | 23 pods, no `monitoring` namespace | KSM sizing in Task 2 |

**The refinement to spec §7:** do **not** put a `namespace:` label in the `staticConfigs` of the kubelet, cAdvisor or kube-state-metrics scrapes. With the default `honor_labels: false`, a preconfigured target label *wins* over the scraped one and the scraped value is renamed to `exported_namespace` — so every `kube_*` and `kubelet_volume_stats_*` series would report `namespace="titan"` instead of `auth`, `coder`, `databases`. That is the same class of bug casa already documented for the operator-stamped namespace. Only the three namespace-free targets (apiserver, controller-manager, scheduler) get `namespace: titan`, and they get it so their `up` series do not land in the empty-namespace inhibition group casa complained about in `prom-scrapes.yaml`.

## Review Focus

The five things no task's own test will catch by construction, most likely to bite first. Each has a pinning step in the named task.

1. **Namespace label override (above).** A `namespace` target label on the KSM or kubelet scrape silently renames the real one to `exported_namespace`; every pod- and volume-level alert then reports `namespace="titan"` and groups wrong. Expected: `kube_pod_status_ready` carries `namespace="auth"` for authentik. Pinned in Task 4 Step 6.
2. **The empty-matcher guard.** `absent(up{job="kube-state-metrics", cluster=""})` is only correct while casa's own series carry no `cluster` label. If anyone later adds `externalLabels: {cluster: casa}`, that arm stops firing forever and the regression it exists to catch returns. Expected: it fires for a synthetic absent job today. Pinned in Task 5 Step 1.
3. **A rotated token is a 401, not an absence.** The targets still exist, so every `absent()` guard stays silent and only `TargetDown` speaks. Expected: `up{cluster="titan"} == 0`, not missing. Pinned in Task 3 Step 6.
4. **The merged-registry finding may not hold on titan.** Casa measured identical payloads on 6443/10257/10259 on its own cluster at an earlier k3s; titan is v1.35.8+k3s1. If titan's 10257 really does carry `controller_manager_*` families, the keep-list drops real metrics. Expected: measured counts, written down, before the keep-lists ship. Pinned in Task 4 Step 3.
5. **`sampleLimit` that is too low truncates silently-ish.** A truncated scrape still reports `up == 1`. Expected: limits set from measured counts at ~2×, not guessed. Pinned in Task 4 Steps 3 and 7.

## File Structure

**k8s-titan** (this repo)

| file | responsibility |
|---|---|
| `apply/00-bootstrap/namespaces.yaml` | gains the `monitoring` namespace, declared centrally like the other six |
| `apply/20-infra/monitoring/scrape-identity.yaml` | the scrape identity: SA, ClusterRole/Binding for `/metrics` and `nodes/metrics`, namespaced Role/Binding for `services/proxy` |
| `apply/20-infra/monitoring/scrape-token.yaml` | the token *request* — no `data`, controller-filled |
| `apply/20-infra/monitoring/kube-state-metrics.yaml` | HelmRepository + HelmRelease for kube-state-metrics |
| `apply/20-infra/kustomization.yaml` | lists the three new files |
| `docs/titan-metrics-scrape.md` | runbook: what scrapes titan, how to rotate the token, what is deliberately not scraped |

**k8s-casa** (`../k8s-casa`)

| file | responsibility |
|---|---|
| `apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml` | the token, sops-encrypted |
| `apply/50-apps/monitoring/titan-k8s-scrape.yaml` | the six ScrapeConfigs |
| `apply/50-apps/monitoring/titan-k8s-guards.yaml` | `absent()` guards for titan's three load-bearing jobs |
| `apply/50-apps/monitoring/instrumentation-guards.yaml` | one-expression change so the existing guard stays sharp |
| `apply/01-secrets/monitoring/alertmanager-kube-prometheus-stack-alertmanager.yaml` | inhibit rule gains `cluster` — **its own commit, after the scrape is live** |

Order matters: titan first. Applying casa's scrapes before titan has an identity produces six red targets and a `TargetDown` storm for a cluster that has not been told about the scrape yet.

---

### Task 1: titan scrape identity

**Files:**
- Modify: `apply/00-bootstrap/namespaces.yaml`
- Create: `apply/20-infra/monitoring/scrape-identity.yaml`
- Create: `apply/20-infra/monitoring/scrape-token.yaml`
- Modify: `apply/20-infra/kustomization.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: ServiceAccount `prometheus-scrape` in namespace `monitoring`; Secret `monitoring/scrape-token` whose `.data.token` is a non-expiring bearer token; ClusterRole `prometheus-scrape`; Role `prometheus-scrape-proxy` in `monitoring`. Task 3 reads the token; Task 2's proxy RBAC depends on the Role existing.

- [ ] **Step 1: Record the failing baseline**

Run:

```bash
curl -m 6 -sk -o /dev/null -w '%{http_code}\n' https://192.168.133.1:6443/metrics
curl -m 6 -sk -o /dev/null -w '%{http_code}\n' https://192.168.133.1:10250/metrics
```

Expected: `401` for both. This is the state to be able to improve — anonymous is refused, and nothing yet exists that could authenticate.

- [ ] **Step 2: Add the namespace**

Append to `apply/00-bootstrap/namespaces.yaml`, matching the existing entries' style exactly:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    name: monitoring
  annotations:
    kubernetes.io:description: "The identity k8s-casa's Prometheus scrapes with, and kube-state-metrics"
```

- [ ] **Step 3: Write the identity**

Create `apply/20-infra/monitoring/scrape-identity.yaml`:

```yaml
# The identity k8s-casa's Prometheus scrapes titan with.
#
# This is deliberately NOT k8s-reader. That identity is the one agents investigate
# with, is Forbidden on Secrets on purpose, and is already held by things this
# cluster does not control. Widening it for a scrape would couple a monitoring
# credential to every agent that carries it, and the two grants below are not
# read-only-inventory grants -- /metrics on the apiserver and the kubelet is a
# different data surface with a different audience.
#
# Three grants, and the reason for each:
#   nonResourceURLs /metrics   kube-apiserver's /metrics is a non-resource path;
#                              RBAC for it lives nowhere else.
#   nodes/metrics              the kubelet authorizes its bearer token with a
#                              SubjectAccessReview against exactly this subresource.
#   services/proxy (namespaced) how kube-state-metrics leaves the cluster. See the
#                              note on the Role below; it is the only reason this
#                              file touches a namespace-scoped object at all.
#
# What this identity cannot do: read any object, in any namespace, including
# Secrets. It reads metrics and proxies to one Service.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-scrape
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-scrape
rules:
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["nodes/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-scrape
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-scrape
subjects:
  - kind: ServiceAccount
    name: prometheus-scrape
    namespace: monitoring
---
# No resourceNames here, and that is measured rather than lazy. The apiserver's
# proxy authorizer puts the RAW PATH SEGMENT into the SubjectAccessReview, so a
# request to .../services/http:kube-state-metrics:http/proxy/metrics is checked
# against the resource name "http:kube-state-metrics:http". Pinning
# resourceNames to that string would work right up until the chart renames its
# Service port, and then fail as a 403 in a scrape three time zones away. The
# namespace is the boundary: `monitoring` holds kube-state-metrics and nothing
# else, so this grants proxy access to exactly one Service either way.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-scrape-proxy
  namespace: monitoring
rules:
  - apiGroups: [""]
    resources: ["services/proxy"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-scrape-proxy
  namespace: monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: prometheus-scrape-proxy
subjects:
  - kind: ServiceAccount
    name: prometheus-scrape
    namespace: monitoring
```

- [ ] **Step 4: Write the token request**

Create `apply/20-infra/monitoring/scrape-token.yaml`. This file carries **no token** — same shape and same gate exemption as `apply/20-infra/k8s-reader/serviceaccount-token.yaml`:

```yaml
# Long-lived API credential for the prometheus-scrape ServiceAccount.
#
# This Secret carries NO data in git. It is a token *request*: the
# ServiceAccount token controller populates it in-cluster. That is the only
# reason it is allowed to live outside apply/10-secrets, and `make
# secrets-placement` enforces exactly that -- it exempts a Secret only while it
# is typed kubernetes.io/service-account-token AND has no data/stringData, so
# pasting a real token into this file fails the gate.
#
# The real value lives in k8s-casa, sops-encrypted, because ScrapeConfig has no
# credentialsFile: auth there is Secret-only. Read it out with an admin context:
#   kubectl -n monitoring get secret scrape-token -o jsonpath='{.data.token}' | base64 -d
#
# Rotate by deleting it and letting the controller recreate it, then re-copy into
# k8s-casa -- docs/titan-metrics-scrape.md is the runbook. Until the new value
# lands there, titan's six targets return 401 and TargetDown fires.
#
# This token does not expire.
apiVersion: v1
kind: Secret
metadata:
  name: scrape-token
  namespace: monitoring
  annotations:
    kubernetes.io/service-account.name: prometheus-scrape
type: kubernetes.io/service-account-token
```

- [ ] **Step 5: List all three, and run the offline gates**

Add to `apply/20-infra/kustomization.yaml`, after the `k8s-reader` entries (identity before token — the controller needs the SA to exist to fill the Secret):

```yaml
  - monitoring/scrape-identity.yaml
  - monitoring/scrape-token.yaml
  - monitoring/kube-state-metrics.yaml
```

If you are running Task 2 in the same sitting, add all three lines at once. If Task 1 ships alone, add only the first two — `kustomize-listing` reports a listed-but-missing file as an error, and that is the louder and more confusing of the two failure modes. Either way, an unlisted file is the one that must never happen.

```bash
git add -A && make kustomize-check kustomize-listing secrets-placement leak-check
```

Expected: `build apply/00-bootstrap: OK`, `build apply/20-infra: OK`, `kustomize-listing: … 0 unlisted, 0 listed-but-missing`, `secrets-placement: no Secret outside apply/10-secrets, every secret encrypted and listed`. If `secrets-placement` fails on `scrape-token.yaml`, the file has a `data:` or `stringData:` key in it — remove it.

- [ ] **Step 6: Deploy and verify the identity exists**

Push to `main`, then:

```bash
kubectl --context k8s-titan -n flux-system wait kustomization infra --for=condition=Ready --timeout=5m
kubectl --context k8s-titan get ns monitoring
kubectl --context k8s-titan -n monitoring get sa prometheus-scrape
kubectl --context k8s-titan -n monitoring get secret scrape-token -o jsonpath='{.data.token}' | wc -c
```

Expected: namespace `Active`, the SA present, and a token longer than 700 bytes. If the token is empty, the controller has not filled it yet — wait a few seconds and re-read; if it stays empty, the annotation name is wrong.

- [ ] **Step 7: Verify the grants actually authorize (the improvement over Step 1)**

```bash
TOKEN=$(kubectl --context k8s-titan -n monitoring get secret scrape-token -o jsonpath='{.data.token}')
for p in 6443/metrics 10250/metrics; do
  curl -m 8 -sk -o /dev/null -w "$p -> %{http_code}\n" -H "Authorization: Bearer $TOKEN" "https://192.168.133.1:$p"
done
```

Expected: `6443/metrics -> 200` and `10250/metrics -> 200`. **401 means the ClusterRole is not bound to this ServiceAccount; 403 means it is bound but a grant is missing.** Do not proceed to Task 3 with anything other than 200 — the token is the thing Task 3 transports, and a token that cannot read `/metrics` will look like a broken scrape later.

- [ ] **Step 8: Commit**

```bash
git add apply/00-bootstrap/namespaces.yaml apply/20-infra/monitoring/ apply/20-infra/kustomization.yaml
git commit -m "monitoring: the identity casa scrapes titan with, and why it is not k8s-reader"
```

---

### Task 2: kube-state-metrics in titan

**Files:**
- Create: `apply/20-infra/monitoring/kube-state-metrics.yaml`
- Modify: `apply/20-infra/kustomization.yaml`

**Interfaces:**
- Consumes: namespace `monitoring` from Task 1.
- Produces: Service `monitoring/kube-state-metrics`, port name `http`, port `8080`, ClusterIP only. Task 3 and Task 4 consume the exact proxy path `/api/v1/namespaces/monitoring/services/http:kube-state-metrics:http/proxy/metrics`. **`fullnameOverride` is what makes that name stable — do not remove it.**

- [ ] **Step 1: Confirm the chart version is still what planning measured**

```bash
curl -s https://artifacthub.io/api/v1/packages/helm/prometheus-community/kube-state-metrics \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['version'], d['app_version'])"
```

Expected: `8.6.0 2.20.0`. If the chart version has moved, pin the new one and re-run the `helm template` in Step 2 to confirm the Service port is still named `http` — the proxy path in Task 4 depends on that name.

- [ ] **Step 2: Confirm the rendered Service name and port name before writing the path**

```bash
helm template ksm oci://ghcr.io/prometheus-community/charts/kube-state-metrics --version 8.6.0 \
  -n monitoring --set fullnameOverride=kube-state-metrics --set prometheusScrape=false \
  | grep -A6 "^kind: Service$"
```

Expected: `name: kube-state-metrics`, `type: "ClusterIP"`, a port named `http` on `8080`. If the port name is not `http`, the proxy path in Task 4 must use whatever name is printed.

- [ ] **Step 3: Write the HelmRelease**

Create `apply/20-infra/monitoring/kube-state-metrics.yaml`:

```yaml
# kube-state-metrics on titan, so that casa's shipped kubernetes-apps and
# kubernetes-resources rule groups mean something here instead of matching zero
# series. Without it there is no pod-, deployment- or PVC-level signal at all:
# KubePodCrashLooping, replica shortfalls and KubePersistentVolumeFillingUp all
# read kube_* families that only KSM emits.
#
# It is ClusterIP-only and nothing exposes it. Its metrics leave the cluster
# through the kube-apiserver service proxy on the already-open :6443, which is
# why there is no NodePort and no firewall change here: a NodePort would have put
# an UNAUTHENTICATED full cluster inventory -- pod names, images, env var names,
# secret names, ingress hosts -- on a port that publicHost.meshTCPPortExtraSources
# opens to the whole home LAN. See spec D2.
#
# fullnameOverride is load-bearing, not cosmetic: casa scrapes this Service by
# name through the apiserver proxy
# (/api/v1/namespaces/monitoring/services/http:kube-state-metrics:http/proxy/metrics),
# and the default name is prefixed with the release name. A release rename would
# change the Service name and silently drop the target to a 404.
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: monitoring
spec:
  interval: 1h
  type: oci
  url: oci://ghcr.io/prometheus-community/charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-state-metrics
  namespace: monitoring
spec:
  releaseName: ksm
  chart:
    spec:
      chart: kube-state-metrics
      # 8.6.0 ships kube-state-metrics 2.20.0 via the chart's appVersion; the
      # image tag is deliberately not pinned a second time.
      version: "8.6.0"
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
  interval: 30m
  driftDetection:
    mode: enabled
  install:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  upgrade:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  values:
    fullnameOverride: kube-state-metrics
    # One node. Autosharding on a single-node cluster shards work that does not
    # exist and adds a StatefulSet to reason about.
    replicas: 1
    autosharding:
      enabled: false
    # No prometheus-operator CRDs exist in titan, and casa is the scraper. Leaving
    # this on advertises a scrape that nothing here acts on.
    prometheusScrape: false
    rbac:
      create: true
    # 23 pods on titan as measured 2026-10-13. KSM's baseline RSS for a cluster
    # this size is well under the limit; the limit exists so a leak is contained
    # on a host whose root filesystem is 150 G and whose etcd is on it.
    resources:
      requests:
        memory: 64Mi
        cpu: 20m
      limits:
        memory: 256Mi
```

- [ ] **Step 4: List it and run the gates**

Add `- monitoring/kube-state-metrics.yaml` to `apply/20-infra/kustomization.yaml` if not already there.

```bash
git add -A && make kustomize-check kustomize-listing release-secrets
```

Then the only check that asks the live API server — the new namespace and HelmRelease are exactly the objects it catches, and offline gates cannot see core-type validation rules:

```bash
make dry-run DRYRUN_CONTEXT=k8s-titan
```

Expected: it applies the built objects against the live server in dry-run mode and reports OK. If it refuses the context, that is the read-only identity being correctly Forbidden — `dry-run` needs an admin context, per AGENTS.md.

Expected: `0 unlisted`, and `release-secrets` reporting the new HelmRelease with no Secret references to resolve.

- [ ] **Step 5: Deploy and verify KSM is running**

```bash
kubectl --context k8s-titan -n flux-system wait kustomization infra --for=condition=Ready --timeout=10m
kubectl --context k8s-titan -n monitoring get deploy,svc,pods -l app.kubernetes.io/name=kube-state-metrics
```

Expected: Deployment `1/1`, Pod `Running`, Service `kube-state-metrics` ClusterIP with port `8080`. A `ImagePullBackOff` means the registry is unreachable from titan — check the mesh path to the internet, not the manifest.

- [ ] **Step 6: Commit**

```bash
git add apply/20-infra/monitoring/kube-state-metrics.yaml apply/20-infra/kustomization.yaml
git commit -m "monitoring: kube-state-metrics on titan, and the proxy path that keeps it unexposed"
```

---

### Task 3: transport the token to k8s-casa

**Files:**
- Create (in `../k8s-casa`): `apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml`

**Interfaces:**
- Consumes: `monitoring/scrape-token` from Task 1; the proxy path from Task 2.
- Produces: Secret `monitoring/titan-scrape-token` in casa with key `token`, base64-decoding to the bearer token. Task 4's six ScrapeConfigs all reference `bearerTokenSecret: {name: titan-scrape-token, key: token}`.

- [ ] **Step 1: Read the token out of titan**

```bash
cd /home/coder/k8s-titan
TOKEN=$(kubectl --context k8s-titan -n monitoring get secret scrape-token -o jsonpath='{.data.token}')
test -n "$TOKEN" && echo "token length ${#TOKEN}"
```

Expected: a length above 700. This value is a credential: it goes straight into a sops file and nowhere else. Do not echo it, do not put it in a shell history file you will keep, and never write it into k8s-titan.

- [ ] **Step 2: Write the plaintext staging file in casa**

```bash
cd /home/coder/k8s-casa
B64=$(printf '%s' "$TOKEN" | base64 -w0)
cat > apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: titan-scrape-token
  namespace: monitoring
type: Opaque
data:
  token: ${B64}
EOF
```

Casa's convention is `data:` with base64 values and a `-secrets.yaml` suffix. Confirm the round-trip before encrypting:

```bash
python3 -c "
import yaml,base64
d=yaml.safe_load(open('apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml'))
print('round-trip ok' if base64.b64decode(d['data']['token']).decode()=='''$TOKEN''' else 'MISMATCH')"
```

Expected: `round-trip ok`.

- [ ] **Step 3: Encrypt with sops, in place**

```bash
cd /home/coder/k8s-casa
sops --encrypt --in-place apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml
head -c 60 apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml; echo
```

Expected: the file starts with `sops` / contains `ENC[` and no plaintext token remains. Then:

```bash
grep -c "ENC\[" apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml
git status --short
```

Expected: at least one `ENC[` match, and only that one file modified/untracked. `.sops.yaml` in casa routes `apply/01-secrets/*.yaml` to the right age recipients — if sops complains about recipients, stop and fix recipients rather than encrypting to the wrong key.

- [ ] **Step 4: Prove casa can decrypt it**

```bash
cd /home/coder/k8s-casa && make validate 2>&1 | tail -5
```

Expected: every secret validates, including the new one. A file that encrypts but does not decrypt is the failure mode casa's AGENTS.md warns about explicitly.

- [ ] **Step 5: Prove the proxy path works end to end, authenticated**

Deploy the secret (push to casa `main`), then from a throwaway pod in casa's `monitoring` namespace — a pod is the correct vantage point because it presents the same source address the Prometheus pod will:

```bash
```bash
T=$(kubectl --context casa -n monitoring get secret titan-scrape-token -o jsonpath='{.data.token}' | base64 -d)
kubectl --context casa -n monitoring run scrape-probe --rm -i --restart=Never \
  --image=curlimages/curl -e "T=$T" --command -- sh -c \
  'curl -sk -H "Authorization: Bearer $T" \
   "https://192.168.133.1:6443/api/v1/namespaces/monitoring/services/http:kube-state-metrics:http/proxy/metrics" | head -5'
```

Expected: `# HELP kube_...` lines. A **403** means the `services/proxy` Role from Task 1 is missing or mis-bound; a **404** means the Service name or port name in the path is wrong — re-run Task 2 Step 2 rather than guessing variants.

- [ ] **Step 6: Prove the failure mode is a 401 and not an absence (Review Focus 3)**

```bash
kubectl --context casa -n monitoring run scrape-probe --rm -i --restart=Never \
  --image=curlimages/curl --command -- \
  curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.133.1:6443/metrics
```

Expected: `401`. This is what a rotated-but-not-recopied token looks like from casa: the target still answers, so `up` exists and every `absent()` guard stays silent. Only `TargetDown` (`up == 0`) reports it — which is why Task 5 does not try to guard this case with `absent()`.

- [ ] **Step 7: Commit**

```bash
cd /home/coder/k8s-casa
git add apply/01-secrets/monitoring/titan-scrape-token-secrets.yaml
git commit -m "monitoring: the titan scrape token, and the proxy path it authenticates"
```

---

### Task 4: the six ScrapeConfigs

**Files:**
- Create (in `../k8s-casa`): `apply/50-apps/monitoring/titan-k8s-scrape.yaml`

**Interfaces:**
- Consumes: `monitoring/titan-scrape-token` from Task 3; the proxy path from Task 2; the token's `/metrics` grants from Task 1.
- Produces: six jobs — `apiserver`, `kubelet` (two paths), `kube-controller-manager`, `kube-scheduler`, `kube-state-metrics` — every series labelled `cluster: titan`. Task 5's guards select on exactly these `job`/`cluster` pairs.

- [ ] **Step 1: Record the ingest baseline**

Against casa's Prometheus (`https://prometheus.home.arrieta.eu/` or a port-forward):

```
sum(rate(prometheus_tsdb_head_samples_appended_total[15m]))
count(up)
```

Write both numbers down; Step 7 records the delta in the spec.

- [ ] **Step 2: Confirm the guard baseline**

```
count(up{cluster="titan"})
```

Expected: no data. If series already exist, something else is scraping titan and this plan is duplicating it — stop and find it.

- [ ] **Step 3: Measure titan's merged registry before trusting the keep-lists (Review Focus 4)**

With a valid token from any box that can reach the mesh:

```bash
for p in 6443 10257 10259; do
  printf '%s ' "$p"
  curl -m 20 -sk -H "Authorization: Bearer $TOKEN" "https://192.168.133.1:$p/metrics" \
    | grep -c '^[^#]'
done
curl -m 20 -sk -H "Authorization: Bearer $TOKEN" https://192.168.133.1:10257/metrics | grep -c '^controller_manager_'
curl -m 20 -sk -H "Authorization: Bearer $TOKEN" https://192.168.133.1:10259/metrics | grep -c '^scheduler_'
```

Expected on the three ports: near-identical counts (casa measured one merged registry served on all three). Expected for `controller_manager_`: `0`. **If `controller_manager_` is not 0 on titan, the keep-list below is wrong for this cluster** — add `controller_manager_.*` to the controller-manager keep regex and say so in the commit message. Record all five numbers; Step 7 puts them in the spec.

- [ ] **Step 4: Write the file**

Create `../k8s-casa/apply/50-apps/monitoring/titan-k8s-scrape.yaml`:

```yaml
---
# titan's own single-node k3s cluster, scraped over the WireGuard mesh.
#
# titan is not a node in this cluster, so nothing here discovers it. Every target
# is 192.168.133.1 -- titan's wg0 address -- on a port that
# nixos-configurations/modules/nixos/public-host.nix already accepts from
# wireguard.staticSubnet and from publicHost.meshTCPPortExtraSources
# (192.168.0.0/24). A Prometheus pod here is SNAT'd to the LAN address of the
# node it runs on, which is inside that /24; see node-exporter-titan.yaml for the
# same reasoning and for why the source is NOT pinned to one node.
#
# Node metrics are NOT here. titan's node_exporter is a NixOS service already
# scraped by casa-titan in this directory's sibling file, and it carries
# k3s_etcd_snapshot_* gauges a pod could not produce. See spec section 2.
#
# EVERY series here carries cluster=titan, and casa's own series carry no cluster
# label at all. That asymmetry is deliberate (spec D6) and two things depend on
# it: instrumentation-guards scopes casa's own kube-state-metrics guard with
# cluster="", and the Alertmanager inhibit rule groups on [namespace, cluster] so
# titan's `auth` namespace and casa's `auth` namespace stop sharing an inhibition
# group. Do not "tidy" this by adding externalLabels: that stamps titan's series
# with cluster=casa too, in the wrong direction and silently.
#
# The token is monitoring/titan-scrape-token: a non-expiring bearer token minted by
# the prometheus-scrape ServiceAccount in titan. It grants /metrics on the
# apiserver, nodes/metrics on the kubelet, and services/proxy in titan's
# monitoring namespace -- and nothing else. ScrapeConfig has no credentialsFile,
# which is why this is a Secret and not a mounted file.
#
# DO NOT add a `namespace` label to the kubelet, cAdvisor or kube-state-metrics
# static configs. With honor_labels=false (the default) a preconfigured target
# label WINS over the scraped one and the scraped value is renamed to
# exported_namespace -- so every kube_* and kubelet_volume_stats_* series would
# report namespace="titan" instead of auth, coder, databases, and every pod and
# volume alert would group wrong. The three namespace-free control-plane targets
# do carry one, so their `up` series do not land in the empty-namespace group
# described at length in prom-scrapes.yaml.
---
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: titan-apiserver
  namespace: monitoring
  labels:
    prometheus: prometheus-k8s
spec:
  staticConfigs:
    - targets: ["192.168.133.1:6443"]
      labels:
        cluster: titan
        namespace: titan
  metricsPath: /metrics
  scheme: https
  interval: 30s
  scrapeTimeout: 15s
  bearerTokenSecret:
    name: titan-scrape-token
    key: token
  tlsConfig:
    # k3s' serving cert carries --tls-san=192.168.133.1 but is signed by the
    # cluster's own CA, which this Prometheus does not trust. Same trade as the
    # in-cluster control-plane scrapes in k3s-control-plane-scrape.yaml.
    insecureSkipVerify: true
  # Set generously now, tightened to ~2x measured in step 7. casa's Prometheus has
  # a 3 Gi limit and an OOM history; a runaway target should truncate itself, not
  # restart the evaluator that every alert in this stack depends on.
  sampleLimit: 250000
  relabelings:
    # The shipped rules key off this name: KubeAPIDown is absent(up{job="apiserver"}).
    - targetLabel: job
      replacement: apiserver
---
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: titan-kubelet
  namespace: monitoring
  labels:
    prometheus: prometheus-k8s
spec:
  staticConfigs:
    - targets: ["192.168.133.1:10250"]
      labels:
        cluster: titan
  metricsPath: /metrics
  scheme: https
  interval: 30s
  scrapeTimeout: 15s
  honorLabels: true
  bearerTokenSecret:
    name: titan-scrape-token
    key: token
  tlsConfig:
    insecureSkipVerify: true
  sampleLimit: 150000
  relabelings:
    - targetLabel: job
      replacement: kubelet
    # The endpoint's path does NOT become this label, and 18 shipped rules select
    # on it. Recorded the hard way in k3s-control-plane-scrape.yaml.
    - targetLabel: metrics_path
      replacement: /metrics
---
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: titan-kubelet-cadvisor
  namespace: monitoring
  labels:
    prometheus: prometheus-k8s
spec:
  staticConfigs:
    - targets: ["192.168.133.1:10250"]
      labels:
        cluster: titan
  metricsPath: /metrics/cadvisor
  scheme: https
  interval: 30s
  scrapeTimeout: 15s
  honorLabels: true
  bearerTokenSecret:
    name: titan-scrape-token
    key: token
  tlsConfig:
    insecureSkipVerify: true
  sampleLimit: 250000
  relabelings:
    - targetLabel: job
      replacement: kubelet
    - targetLabel: metrics_path
      replacement: /metrics/cadvisor
---
# k3s runs controller-manager and scheduler embedded in one process with a SINGLE
# merged metrics registry, served identically on 6443, 10257 and 10259. Casa
# measured that on its own cluster (54,241 samples on all three ports, zero
# controller_manager_* families on 10257) and titan was re-measured before this
# shipped -- see the spec's verification log. Without these keep-lists these two
# jobs store a second full copy of the apiserver payload under different job
# names, which is pure ingest cost for no signal.
#
# titan does not need the Nix-side rebinding casa needed: hosts/titan/vars.nix
# already sets k3s.controlPlaneMetricsBindAddress = "0.0.0.0", so 10257 and 10259
# answer from off-host (measured 403 to anonymous, not connection refused).
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: titan-controller-manager
  namespace: monitoring
  labels:
    prometheus: prometheus-k8s
spec:
  staticConfigs:
    - targets: ["192.168.133.1:10257"]
      labels:
        cluster: titan
        namespace: titan
  metricsPath: /metrics
  scheme: https
  interval: 30s
  scrapeTimeout: 15s
  bearerTokenSecret:
    name: titan-scrape-token
    key: token
  tlsConfig:
    insecureSkipVerify: true
  # up is synthesised by Prometheus, so KubeControllerManagerDown --
  # absent(up{job="kube-controller-manager"}) -- is satisfiable from this target
  # alone even with everything else dropped.
  metricRelabelings:
    - sourceLabels: [__name__]
      action: keep
      regex: "up|scrape_.*"
---
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: titan-scheduler
  namespace: monitoring
  labels:
    prometheus: prometheus-k8s
spec:
  staticConfigs:
    - targets: ["192.168.133.1:10259"]
      labels:
        cluster: titan
        namespace: titan
  metricsPath: /metrics
  scheme: https
  interval: 30s
  scrapeTimeout: 15s
  bearerTokenSecret:
    name: titan-scrape-token
    key: token
  tlsConfig:
    insecureSkipVerify: true
  # Unlike controller-manager, this port does carry genuinely unique scheduler_*
  # families, so keep those and drop only the duplicated apiserver payload.
  metricRelabelings:
    - sourceLabels: [__name__]
      action: keep
      regex: "up|scrape_.*|scheduler_.*"
---
# kube-state-metrics leaves titan through the kube-apiserver service proxy, on the
# port that is already open and already authenticated, instead of a NodePort that
# would have to be opened to the whole home LAN and would be UNAUTHENTICATED. The
# apiserver's proxy authorizer checks services/proxy in titan's monitoring
# namespace, which is what prometheus-scrape-proxy grants.
#
# The path names the Service exactly: fullnameOverride in
# k8s-titan/apply/20-infra/monitoring/kube-state-metrics.yaml is what makes
# `kube-state-metrics` and the port name `http` stable. A 404 here means that name
# drifted, not that the network is broken.
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: titan-kube-state-metrics
  namespace: monitoring
  labels:
    prometheus: prometheus-k8s
spec:
  staticConfigs:
    - targets: ["192.168.133.1:6443"]
      labels:
        cluster: titan
  metricsPath: /api/v1/namespaces/monitoring/services/http:kube-state-metrics:http/proxy/metrics
  scheme: https
  interval: 30s
  scrapeTimeout: 20s
  bearerTokenSecret:
    name: titan-scrape-token
    key: token
  tlsConfig:
    insecureSkipVerify: true
  sampleLimit: 150000
  relabelings:
    # The name every kube_* rule and the instrumentation guards expect.
    - targetLabel: job
      replacement: kube-state-metrics
```

- [ ] **Step 5: Validate and deploy**

```bash
cd /home/coder/k8s-casa && make check-alert-rules 2>&1 | tail -3
git add apply/50-apps/monitoring/titan-k8s-scrape.yaml && git commit -m "monitoring: scrape titan's control plane, kubelet and kube-state-metrics over the mesh"
```

Push to casa `main`, then confirm the operator accepted all six:

```bash
kubectl --context casa -n monitoring get scrapeconfig | grep titan
kubectl --context casa -n monitoring get prometheus prometheus-k8s -o jsonpath='{.status.conditions}' | python3 -m json.tool | tail -12
```

Expected: six `titan-*` ScrapeConfigs, and the Prometheus `Available`/`Reconciled` conditions True.

- [ ] **Step 6: Verify targets, labels and the namespace trap (Review Focus 1)**

```
count by (job) (up{cluster="titan"})
```
Expected: six jobs — `apiserver`, `kubelet`, `kube-controller-manager`, `kube-scheduler`, `kube-state-metrics` — all with value `1`. (`kubelet` appears once even though it has two paths; check `count by (job, metrics_path) (up{cluster="titan", job="kubelet"})` shows both.)

Then the trap that a green `up` would hide:

```
count by (namespace) (kube_pod_status_ready{cluster="titan", condition="true"})
count(kubelet_volume_stats_available_bytes{cluster="titan"})
count by (__name__) ({cluster="titan", exported_namespace!=""})
```
Expected: the first returns titan's real namespaces (`auth`, `coder`, `databases`, `kube-system`, …) and **not** a single bucket named `titan`. The third returns **no data** — if it returns series, a `namespace` target label is overriding the scraped one and must be removed from that ScrapeConfig.

- [ ] **Step 7: Set sampleLimit from measurement, not from a guess (Review Focus 5)**

```
topk(10, count by (job) ({cluster="titan"}))
count by (job) (scrape_samples_scraped{cluster="titan"})
```

Set each `sampleLimit` to roughly 2× the measured `scrape_samples_scraped` for that job, edit the file, and record both the before/after ingest rate from Step 1 and the merged-registry counts from Step 3 in the spec's verification log. Then:

```
sum(rate(prometheus_tsdb_head_samples_appended_total[15m]))
```

Expected: a step up, and it should be a fraction of the existing rate, not a doubling — titan is one node against casa's eleven. If it is large, raise the numbers in the spec rather than quietly trimming metrics.

- [ ] **Step 8: Commit the tuned limits**

```bash
cd /home/coder/k8s-casa
git add apply/50-apps/monitoring/titan-k8s-scrape.yaml
git commit -m "monitoring: sample limits set from measured titan scrape sizes"
```

---

### Task 5: guards, and the existing guard that goes blind

**Files:**
- Create (in `../k8s-casa`): `apply/50-apps/monitoring/titan-k8s-guards.yaml`
- Modify (in `../k8s-casa`): `apply/50-apps/monitoring/instrumentation-guards.yaml`

**Interfaces:**
- Consumes: the `job`/`cluster` label pairs produced by Task 4.
- Produces: alerts `TitanKubeStateMetricsScrapeMissing`, `TitanApiserverScrapeMissing`, `TitanKubeletScrapeMissing`; and a re-scoped `KubeStateMetricsScrapeMissing`.

- [ ] **Step 1: Prove the existing guard is now blind**

Against casa's Prometheus:

```
absent(up{job="kube-state-metrics"})
absent(up{job="kube-state-metrics", cluster=""})
absent(up{job="kube-state-metrics", cluster="titan"})
```

Expected: all three return **no data** (nothing is missing today) — but the first is now satisfied by titan's series as well as casa's, which is the regression. Confirm the empty matcher behaves as claimed with a synthetic absent job:

```
absent(up{job="definitely-not-a-real-job", cluster=""})
```

Expected: `1`. This is the assumption the re-scoped guard rests on; if it returns no data, stop and re-read Review Focus 2 before continuing.

- [ ] **Step 2: Re-scope the existing guard**

In `../k8s-casa/apply/50-apps/monitoring/instrumentation-guards.yaml`, change the `KubeStateMetricsScrapeMissing` expression only:

```yaml
        - alert: KubeStateMetricsScrapeMissing
          # Fires when the job has no `up` series at all -- see the header for
          # why this is not redundant with TargetDown.
          #
          # Scoped to cluster="" because titan's kube-state-metrics is now
          # scraped under the SAME job name (titan-k8s-scrape.yaml). Unscoped,
          # this guard would stay silent when casa's own KSM scrape disappeared,
          # because titan's `up` still exists -- which is precisely the 37-dead-
          # rules-and-no-signal failure this file was written to catch. The empty
          # matcher works because casa's series carry no cluster label at all;
          # if externalLabels are ever added, this arm becomes wrong and must be
          # revisited the same day.
          expr: absent(up{job="kube-state-metrics", cluster=""})
```

Keep the existing `for:` and annotations. Do not reformat the rest of the file.

- [ ] **Step 3: Write the titan guards**

Create `../k8s-casa/apply/50-apps/monitoring/titan-k8s-guards.yaml`:

```yaml
---
# absent() guards for the three titan jobs whose absence silently deactivates
# rules elsewhere. Same reasoning as instrumentation-guards.yaml, which exists
# because TargetDown cannot see a target that is gone rather than down: with no
# `up` series the denominator is empty and the rule cannot fire.
#
# Only three of the six jobs get a guard. controller-manager and scheduler exist
# to satisfy their own absent() rules in the shipped groups, so their absence is
# already the signal. cAdvisor shares a job with the kubelet. A token that has
# been rotated but not recopied is a 401, not an absence -- the target still
# answers, `up` still exists, and TargetDown is what reports it. Do not write an
# absent() guard for that case; it cannot fire.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: titan-k8s-guards
  namespace: monitoring
  labels:
    prometheus: prometheus-k8s
spec:
  groups:
    - name: titan-k8s-guards
      rules:
        - alert: TitanKubeStateMetricsScrapeMissing
          expr: absent(up{job="kube-state-metrics", cluster="titan"})
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "titan's kube-state-metrics is not being scraped at all"
            description: >-
              No up{job="kube-state-metrics", cluster="titan"}. titan's kube_*
              families are gone, so every kubernetes-apps and kubernetes-resources
              rule covering titan is inactive. The scrape goes through the
              kube-apiserver service proxy, so the three candidates are: the token
              in monitoring/titan-scrape-token no longer matches, the
              kube-state-metrics pod in titan's monitoring namespace is down, or
              fullnameOverride drifted and the proxy path 404s. Check with
              `kubectl --context k8s-titan -n monitoring get pods`. Note a rotated
              token is a 401, which leaves `up` present and is TargetDown's case,
              not this one.
        - alert: TitanApiserverScrapeMissing
          expr: absent(up{job="apiserver", cluster="titan"})
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "titan's kube-apiserver has no metrics target"
            description: >-
              No up{job="apiserver", cluster="titan"}. KubeAPIDown selects
              absent(up{job="apiserver"}) and cannot tell a dead apiserver from a
              scrape that disappeared; this alert is what separates them. Suspect
              the mesh first: `curl -m 6 -sk -o /dev/null -w '%{http_code}\n'
              https://192.168.133.1:6443/metrics` should answer 401, not time out.
        - alert: TitanKubeletScrapeMissing
          expr: absent(up{job="kubelet", cluster="titan"})
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "titan's kubelet and cAdvisor have no metrics target"
            description: >-
              No up{job="kubelet", cluster="titan"} at all, so both the kubelet and
              the cAdvisor path are gone: no container CPU, memory or disk for
              titan. KubeletDown and every container_* rule for titan is inactive
              while this holds.
```

- [ ] **Step 4: Validate and deploy**

```bash
cd /home/coder/k8s-casa
make check-alert-rules 2>&1 | tail -5
git add apply/50-apps/monitoring/instrumentation-guards.yaml apply/50-apps/monitoring/titan-k8s-guards.yaml
git commit -m "monitoring: keep the KSM guard sharp now that titan shares the job name"
```

Expected: `check-alert-rules` passes (it parses every rule file; a template syntax error in an annotation surfaces here). Push, then:

```bash
kubectl --context casa -n monitoring get prometheusrule titan-k8s-guards
kubectl --context casa -n monitoring get configmap | grep prometheus-prometheus-k8s-rulefiles
```

Expected: the rule exists and the rulefiles ConfigMap was updated.

- [ ] **Step 5: Test the guard by breaking it (Review Focus: an unobserved guard is a guess)**

Point one ScrapeConfig at a dead port for a few minutes. Edit `titan-kube-state-metrics` target to `192.168.133.1:6444`, apply, wait past `for: 10m`, and confirm in the Prometheus UI / Alertmanager that `TitanKubeStateMetricsScrapeMissing` fires.

Expected: it fires. Then **revert immediately** and confirm it resolves. If it does not fire, the guard is wrong — most likely the `cluster` label is not landing on `up`, which means the static-config labels block is misplaced.

- [ ] **Step 6: Commit the verification log**

Append the measured numbers (Step 1 baseline, merged-registry counts, ingest before/after, guard-fire confirmation) to the spec's verification section in k8s-titan and commit:

```bash
cd /home/coder/k8s-titan
git add docs/superpowers/specs/2026-10-13-titan-metrics-scrape-design.md
git commit -m "docs: what the titan metrics scrape actually measured once it was live"
```

---

### Task 6: split inhibition groups by cluster

**Files:**
- Modify (in `../k8s-casa`): `apply/01-secrets/monitoring/alertmanager-kube-prometheus-stack-alertmanager.yaml`

**Interfaces:**
- Consumes: `cluster: titan` on every titan series (Task 4).
- Produces: Alertmanager inhibit rules grouping on `[namespace, cluster]`.

**This task is its own commit, and it goes only after Task 4 is live and its labels are confirmed.** It changes alert grouping fleet-wide, not just for titan.

- [ ] **Step 1: Confirm the collision is real before changing anything**

```
count by (namespace) (up{cluster="titan"})
```

Expected: `titan` plus the real namespaces KSM and kubelet emit — and at least one of `auth`, `certificates`, `cert-manager`, `default`, `flux-system`, `monitoring`, `kube-system`, all of which casa also uses. That overlap is the problem: the PR #169 inhibit rule is `equal: [namespace]`, so a titan `KubePodCrashLooping{namespace="auth"}` and a casa info alert in `auth` share one inhibition group and can mute each other.

- [ ] **Step 2: Edit the encrypted Alertmanager config**

```bash
cd /home/coder/k8s-casa
sops apply/01-secrets/monitoring/alertmanager-kube-prometheus-stack-alertmanager.yaml
```

Find the `inhibit_rules:` entry whose `equal:` list is `[namespace]` and change it to:

```yaml
  equal: ['namespace', 'cluster']
```

Save and close; sops re-encrypts on write. Then:

```bash
make validate 2>&1 | tail -3
grep -c 'ENC\[' apply/01-secrets/monitoring/alertmanager-kube-prometheus-stack-alertmanager.yaml
```

Expected: validation passes and the file is still encrypted. If there is more than one inhibit rule with `equal: [namespace]`, change every one and say so in the commit message.

- [ ] **Step 3: Verify the split**

After Alertmanager reloads, confirm with two queries that a titan alert and a casa alert in the same namespace no longer share a group — check the Alertmanager UI, or:

```
count by (namespace, cluster) (InfoInhibitor)
```

Expected: `cluster` now appears in the grouping, with casa's rows at `cluster=""` and titan's at `cluster="titan"`.

- [ ] **Step 4: Commit**

```bash
git add apply/01-secrets/monitoring/alertmanager-kube-prometheus-stack-alertmanager.yaml
git commit -m "monitoring: inhibit rules group by cluster, so titan's auth and casa's auth stop sharing a group"
```

---

### Task 7: the runbook

**Files:**
- Create: `docs/titan-metrics-scrape.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the document someone reads at 23:00 when titan's targets are red, and the one that tells a future maintainer why `validate` cannot be the only gate here.

- [ ] **Step 1: Write it**

Create `docs/titan-metrics-scrape.md` covering, in this order and with the real commands:

1. **What scrapes titan and from where.** casa's `ScrapeConfig` objects (`casa-titan` for node_exporter, `comin-devices` for comin, the six `titan-*` for k8s), all reaching `192.168.133.1`. State that node metrics come from the NixOS `node_exporter` and never from a DaemonSet, and why (spec §2).
2. **First triage.** The one command that separates "mesh is down" from "titan is broken": `curl -m 6 -sk -o /dev/null -w '%{http_code}\n' https://192.168.133.1:6443/metrics` — `401` means the path is fine and the problem is credentials or a component; a timeout means the mesh; `000` from a container is a false negative if tested through a podman bridge (see `hosts/titan/README.md`).
3. **Token rotation.** Delete `monitoring/scrape-token` on titan, read the new one, re-stage and re-sops in casa, commit. State the consequence window explicitly: between the delete and casa's apply, the six targets return 401 and `TargetDown` fires — that is expected, not a second incident.
4. **What is deliberately not scraped**, with the reason: etcd (`:2381` refused, measured 2026-10-13, needs a k3s flag change and a restart of the only server), CoreDNS, Traefik, CNPG's Postgres exporter, authentik, coder, and Grafana dashboards for titan.
5. **The two label traps**, so the next person does not rediscover them: no `namespace` target label on the kubelet/cadvisor/KSM scrapes, and `KubeStateMetricsScrapeMissing`'s `cluster=""` arm being wrong the day someone adds `externalLabels`.

- [ ] **Step 2: Cross-link it**

Add a one-line pointer from `AGENTS.md`'s relevant paragraph and from the spec's status line (`proposed` → `implemented in <commit>`), then:

```bash
cd /home/coder/k8s-titan && git add -A && make check
```

Expected: everything passes except `validate` if the age key is absent here — say so in the commit message rather than dropping the gate.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs: the titan metrics runbook, including what is deliberately not scraped"
```

---

### Task 8: read what actually fires, then suppress only what is demonstrably wrong

**Files:**
- Possibly modify (in `../k8s-casa`): `apply/10-infra/monitoring/prometheus.yaml` (a `postRenderers` entry on the `kube-prometheus-stack` HelmRelease), **or** `apply/01-secrets/monitoring/alertmanager-kube-prometheus-stack-alertmanager.yaml` (a route or inhibit change). Which one depends on what Step 1 finds.

**Interfaces:**
- Consumes: a week of live alert history for `cluster="titan"`.
- Produces: an evidenced suppression, or a recorded finding that none was needed.

**Do not run this task immediately.** It needs several days of live alerts, and spec §7.3's policy is deliberate: a rule muted on a guess is a rule nobody will ever re-enable.

There is no such thing as a "mute file" in this stack — a `PrometheusRule` can only *add* rules, never remove them. Suppression has exactly two homes, named in Step 2.

- [ ] **Step 1: Enumerate what actually fired for titan, against the measured baseline**

```
ALERTS{cluster="titan", alertstate="firing"}
```

and, for what is *inactive* rather than firing, `count by (name) (group_last_evaluation_samples)`.

Two things were already measured on 2026-10-13 and are the baseline, not a finding:

- **There is no `KubeProxyDown` rule to fire.** Chart 82.18.x ships no kube-proxy group — measured across all 45 `PrometheusRule` objects and 326 rules in casa's `monitoring` namespace, zero rules whose name mentions proxy. The note at the foot of `k3s-control-plane-scrape.yaml` calling it a standing false positive is stale against this chart pin.
- **The etcd group is inert, not wrong.** `kube-prometheus-stack-etcd` holds 15 rules, all keyed on `etcd_*` series or `up{job=~".*etcd.*"}` sums; with no etcd target they yield nothing and never fire. So nobody will ever alert on titan's embedded etcd being unhealthy. That is a visibility hole, **not** a suppression candidate — you cannot fix silence by muting.

Anything on the Step 1 list beyond those two is a real finding. Write it down with the evidence for each line. Anything not on the list is expected to work, and if it is firing wrongly the fix is the scrape, not a mute.

- [ ] **Step 2: For each real finding, choose the home — and prefer not to choose one**

**Wrong for k3s everywhere** → remove it at the chart with a `postRenderer` on the `kube-prometheus-stack` HelmRelease in `apply/10-infra/monitoring/prometheus.yaml`. That file already carries exactly this pattern: a Kustomize postRenderer stripping `apiserver_request:burnrate1d` and `burnrate3d` from the apiserver burnrate group, with the measured 405.6s/cycle cost that justified it. Copy that structure, name the group from the *rendered* chart (`helm template` plus `kubectl --context casa -n monitoring get prometheusrule <name> -o yaml`), and verify by diffing the resulting rulefiles ConfigMap. Never write a group name from memory.

**Right for casa, wrong only for titan** → suppress in Alertmanager, in the encrypted config, with a route matcher on `cluster=titan`. A chart-level removal would take the rule away from casa's eleven nodes to fix one node, which is the wrong trade.

**Nothing found** → say so. Committing no suppression file, and recording in the spec that the shipped rule set needed no changes for titan, is the outcome the whole design was aiming at.

- [ ] **Step 3: Validate and commit**

```bash
cd /home/coder/k8s-casa
make check-alert-rules 2>&1 | tail -3
make validate 2>&1 | tail -3
git add -A
git commit -m "monitoring: what titan's shipped rules actually got wrong, with the evidence"
```

If Step 1 found nothing to suppress, commit nothing here and instead record in the spec that the shipped rule set needed no changes for titan — which is the outcome the whole design was aiming at.
