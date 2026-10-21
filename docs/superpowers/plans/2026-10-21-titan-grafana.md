# titan Grafana Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a Grafana in namespace `observability` on titan that reads casa's Prometheus and Loki over the mesh and serves casa's seven dashboards, gated by authentik forward-auth at the edge and authentik OIDC for identity.

**Architecture:** One `Deployment` + `PVC` + `Service` + `Ingress` + Traefik `Middleware` in a new `observability` namespace, inside the existing shared `apps` Flux stage. Dashboards and datasources arrive as provisioned ConfigMaps mounted read-only, so git is the only editor. Identity is two independent layers: a namespaced forward-auth middleware decides reachability, an authentik OIDC client decides who you are and what role you get.

**Tech Stack:** Kubernetes manifests, Kustomize, Flux, cert-manager + Reflector, authentik blueprints, sops/age, Grafana 12 provisioning files, Python 3 gates in `tools/`.

**Spec:** `docs/superpowers/specs/2026-10-21-titan-grafana-design.md` — every decision below is argued there; this plan only executes it.

## Global Constraints

- Namespace is **`observability`**. Stage is **`apply/50-apps/`** — no new numbered stage, and **no `kustomization.yaml` inside `apply/50-apps/grafana/`** (spec §4; a subdirectory of a stage never gets one).
- Never set a top-level `namespace:` in any `kustomization.yaml`. Every object carries its own `metadata.namespace`.
- Image pinned by digest: `grafana/grafana:12.3.1@sha256:2175aaa91c96733d86d31cf270d5310b278654b03f5718c59de12a865380a31f`.
- Host is `grafana.titan.arrieta.eu`. TLS `secretName: titan-tls`. **No `public-dns-tf` change, no new `Certificate`** (spec D2).
- Secrets live only in `apply/10-secrets/`, sops-encrypted, and every one must be listed in `apply/10-secrets/kustomization.yaml`.
- No concrete public IPv4 anywhere in this repo — write `<OVH_PUBLIC_IP>`.
- Dashboards are copied **byte-for-byte from `../k8s-casa` except `metadata.namespace`**. No query edits, no uid pinning inside the JSON (spec §6, D1).
- Every gate in `make check` must pass before each commit: `git add -A && make check`.
- Do not push or merge without explicit operator confirmation.

## Review Focus

The five things no offline gate will catch, most likely to bite first:

- **The forward-auth annotation silently absent.** A `Middleware` that exists but is not referenced by the Ingress leaves the homelab's metrics public with a healthy-looking pod. Expected behaviour: an unauthenticated `curl -sSI https://grafana.titan.arrieta.eu/` returns **302 to `auth.titan.arrieta.eu`**, never 200. Task 2 step 7 pins it.
- **The Reloader namespace list.** `reloader.stakater.com/auto: "true"` is inert outside `values.reloader.namespaces`; the annotation alone looks correct. Expected behaviour: editing a dashboard ConfigMap restarts the pod. Task 2 step 6 pins the list entry; the live half is Task 5 step 8.
- **A blueprint that is mounted in one place but not the other.** `authentik.yaml` needs the Secret in `blueprints.secrets` **and** in the `secret.reloader.stakater.com/reload` annotation; the worker re-discovers blueprints hourly, so a missing second entry means an edit sits unread for an hour. Task 3 step 8 pins both.
- **`profile` missing from either side of the OIDC pair.** Without the scope on the authentik provider or in `GF_AUTH_GENERIC_OAUTH_SCOPES`, there is no `groups` claim and every login silently becomes Viewer — a permissions bug that presents as working. Task 3 steps 1 and 6 pin both sides.
- **A dashboard ConfigMap that is not listed in `apply/50-apps/kustomization.yaml`.** It builds green and is silently never applied — the exact `coder-db.yaml` story. Task 1 step 6 pins it with the gate that exists for it.

---

### Task 1: Dashboards, datasources and provisioning ConfigMaps

**Files:**
- Create: `apply/00-bootstrap/namespaces.yaml` (modify — append the `observability` Namespace)
- Create: `apply/50-apps/grafana/grafana-datasources.yaml`
- Create: `apply/50-apps/grafana/grafana-dashboard-provisioning.yaml`
- Create: `apply/50-apps/grafana/grafana-dashboards/{node-exporter,postgres,comin,disk,alerts,amdgpu,security-scans}-dashboard.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Produces: ConfigMaps `grafana-datasources`, `grafana-dashboard-provisioning`, and `grafana-<topic>-dashboard` ×7, all in namespace `observability`. Task 2 mounts these by exactly these names.

- [ ] **Step 1: Declare the namespace**

Append to `apply/00-bootstrap/namespaces.yaml`:

```yaml
# Grafana, and nothing else. It fails the admission test in
# docs/superpowers/specs/2026-10-19-titan-app-scale-out-design.md §3.1 on own public hostname and
# own Secret set, so it gets a namespace; it stays in the shared `apps` stage, per coder and
# open-webui (see the §3.1/§3.2 amendment of 2026-10-21 — §3.1 buys a namespace, not a stage).
#
# Unlike open-webui, this one CAN carry the restricted warn label: the official grafana image runs
# as uid 472 gid 0 by design, and the Deployment sets runAsNonRoot. A warn label on a workload that
# can never meet it is noise (open-webui's note above); on this one it is a real signal.
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    name: observability
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
  annotations:
    kubernetes.io/metadata.name: observability
    kubernetes.io/description: "Grafana, reading casa's Prometheus and Loki over the mesh"
```

- [ ] **Step 2: Copy the seven dashboards**

```bash
mkdir -p apply/50-apps/grafana/grafana-dashboards
for f in node-exporter postgres comin disk alerts amdgpu security-scans; do
  sed 's/^  namespace: casa$/  namespace: observability/' \
    ../k8s-casa/apply/50-apps/casa/grafana-dashboards/$f-dashboard.yaml \
    > apply/50-apps/grafana/grafana-dashboards/$f-dashboard.yaml
done
```

Anchored `^  namespace: casa$` on purpose: the dashboard JSON contains the word `casa` in panel
descriptions (the postgres board's header describes "the casa cluster"), and an unanchored `sed`
would rewrite prose inside the dashboards, which is a content edit D1 forbids.

- [ ] **Step 3: Verify the copy is a copy**

```bash
for f in apply/50-apps/grafana/grafana-dashboards/*.yaml; do
  b=$(basename "$f"); s=../k8s-casa/apply/50-apps/casa/grafana-dashboards/$b
  printf "%-34s lines %s/%s ns=%s casa-left=%s\n" "$b" \
    "$(wc -l < "$f")" "$(wc -l < "$s")" \
    "$(grep -c '^  namespace: observability$' "$f")" "$(grep -c 'namespace: casa' "$f")"
done
```

Expected: seven rows, source and destination line counts equal, `ns=1`, `casa-left=0`.

- [ ] **Step 4: Write `grafana-datasources.yaml`**

```yaml
# Datasource provisioning. Both are casa's, reached over the OPNsense WireGuard mesh — titan runs no
# Prometheus and no Loki of its own (docs/titan-metrics-scrape.md, docs/titan-logs-loki.md).
#
# WHY THESE ARE HTTPS HOSTNAMES AND NOT IN-CLUSTER SERVICES
# `prometheus.local.arrieta.eu` and `loki.local.arrieta.eu` are published in public DNSSEC-valid OVH
# DNS and return RFC1918 addresses, so they are unreachable from the internet by construction and
# reachable from titan only because the mesh advertises 192.168.0.0/24. Measured from this repo's
# workspace, not assumed: `/-/ready` answers 200 and `count(up)` returns 106 with NO AUTHENTICATION.
# That is load-bearing: Grafana proxies server-side and has no browser session to present, so if
# casa ever puts prometheus.local behind authentik, every panel goes empty at once and the datasource
# test is the first place it shows.
#
# WHAT THIS DATASOURCE SEES
# It is a SHARED Prometheus: `count by (cluster) (up)` returns 94 targets with no cluster label
# (casa's own), 7 with cluster=titan, 5 with cluster=techdelivery. That is the whole-homelab view
# the design chose deliberately (spec D1), not an oversight. Note `cluster` is absent on titan's own
# node_exporter and comin scrapes, so it is not a usable filter even for titan.
#
# The uid on each is pinned so a hand-made datasource in the UI cannot quietly become the one the
# dashboards resolve to. The dashboards themselves bind through template variables ($datasource,
# $loki), not uids — which is what lets them be copied verbatim from casa.
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: observability
  labels:
    app: grafana
data:
  prometheus.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        uid: prometheus
        url: https://prometheus.local.arrieta.eu
        access: proxy
        isDefault: true
        jsonData:
          timeInterval: "30s"
  loki.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        uid: loki
        url: https://loki.local.arrieta.eu
        access: proxy
        isDefault: false
        jsonData:
          maxLines: 2000
```

Two deliberate departures from casa's file: casa's Prometheus datasource carries an
`exemplarTraceIdDestinations` block naming a `tempo` datasource that does not exist here, so it is
dropped rather than copied; and both uids are pinned.

- [ ] **Step 5: Write `grafana-dashboard-provisioning.yaml`**

```yaml
# Dashboard providers: one per dashboard ConfigMap, each pointed at the directory that ConfigMap is
# mounted into (see the volumeMounts on the Deployment in grafana.yaml).
#
# allowUiUpdates is FALSE on every provider, which is the one place this file differs from casa's
# (casa uses `editable: true`). A UI edit there survives every later apply — Helm/Grafana never
# reverts it, and `make dry-run` cannot see it — which is the same class of invisible live drift
# AGENTS.md already warns about for `kubectl edit`. Here the dashboards are in git, so git is the
# only editor and a browser edit is an anomaly rather than a state to tolerate.
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-provisioning
  namespace: observability
  labels:
    app: grafana
data:
  node-exporter-dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'node-exporter'
        orgId: 1
        folder: 'Servers'
        type: file
        disableDeletion: false
        allowUiUpdates: false
        options:
          path: /var/lib/grafana/dashboards/node-exporter
  disk-dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'disk'
        orgId: 1
        folder: 'Servers'
        type: file
        disableDeletion: false
        allowUiUpdates: false
        options:
          path: /var/lib/grafana/dashboards/disk
  comin-dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'comin'
        orgId: 1
        folder: 'Servers'
        type: file
        disableDeletion: false
        allowUiUpdates: false
        options:
          path: /var/lib/grafana/dashboards/comin
  amdgpu-dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'amdgpu'
        orgId: 1
        folder: 'Servers'
        type: file
        disableDeletion: false
        allowUiUpdates: false
        options:
          path: /var/lib/grafana/dashboards/amdgpu
  postgres-dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'postgres'
        orgId: 1
        folder: 'Databases'
        type: file
        disableDeletion: false
        allowUiUpdates: false
        options:
          path: /var/lib/grafana/dashboards/postgres
  alerts-dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'alerts'
        orgId: 1
        folder: 'Monitoring'
        type: file
        disableDeletion: false
        allowUiUpdates: false
        options:
          path: /var/lib/grafana/dashboards/alerts
  security-scans-dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'security-scans'
        orgId: 1
        folder: 'Security'
        type: file
        disableDeletion: false
        allowUiUpdates: false
        options:
          path: /var/lib/grafana/dashboards/security-scans
```

- [ ] **Step 6: List all ten files in the stage**

Add to `apply/50-apps/kustomization.yaml` `resources:` (after the open-webui entries):

```yaml
  # Grafana. Ten files, and the listing is not ceremony: an unlisted manifest builds green and is
  # silently never applied, which is the coder-db.yaml story. The dashboards are ConfigMaps, so a
  # mis-nested field in one of them fails THIS unit atomically and freezes coder's and authentik's
  # updates until the next commit — the accepted cost recorded in the header above and in
  # docs/superpowers/specs/2026-10-21-titan-grafana-design.md §10.
  - grafana/grafana-datasources.yaml
  - grafana/grafana-dashboard-provisioning.yaml
  - grafana/grafana-dashboards/node-exporter-dashboard.yaml
  - grafana/grafana-dashboards/postgres-dashboard.yaml
  - grafana/grafana-dashboards/comin-dashboard.yaml
  - grafana/grafana-dashboards/disk-dashboard.yaml
  - grafana/grafana-dashboards/alerts-dashboard.yaml
  - grafana/grafana-dashboards/amdgpu-dashboard.yaml
  - grafana/grafana-dashboards/security-scans-dashboard.yaml
```

- [ ] **Step 7: Run the gates**

Run: `make kustomize-check make kustomize-listing && make leak-check`
Expected: `kustomize-check` builds every stage including `apply/50-apps`; `kustomize-listing` reports nothing unlisted; `leak-check` clean.

Run: `kubectl kustomize apply/50-apps | grep -c 'kind: ConfigMap'`
Expected: the previous count plus 9 (7 dashboards + datasources + provisioning).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(observability): provision grafana with casa's seven dashboards

Byte-for-byte copies except metadata.namespace, anchored so the sed cannot rewrite the
word casa inside panel prose. Datasources point at casa's Prometheus and Loki over the
mesh; both uids pinned. allowUiUpdates false on every provider so git is the only
editor of a dashboard."
```

---

### Task 2: The workload — Deployment, Service, Ingress, edge gate

**Files:**
- Create: `apply/50-apps/grafana/grafana.yaml`
- Modify: `apply/40-certificates/titan-wildcard.yaml` (Reflector allow-list)
- Modify: `apply/20-infra/reloader/reloader.yaml` (`values.reloader.namespaces`)
- Modify: `apply/50-apps/kustomization.yaml` (list `grafana/grafana.yaml`)

**Interfaces:**
- Consumes: ConfigMaps from Task 1 by name (`grafana-datasources`, `grafana-dashboard-provisioning`, `grafana-<topic>-dashboard`), and the Secrets `observability-grafana-admin` / `observability-grafana-oidc` created in Task 3.
- Produces: `Deployment/observability/grafana` with container name `grafana`, `Service/observability/grafana` port 80, `Middleware/observability/grafana-auth`, Ingress host `grafana.titan.arrieta.eu`. Task 3's gate reads this Deployment's `env` and `envFrom`.

- [ ] **Step 1: Write `apply/50-apps/grafana/grafana.yaml`**

The full file. Note the OIDC env values reference the `observability` slug and host; the Secrets it
`envFrom`s do not exist until Task 3, so the pod stays `Pending` between the two tasks — acceptable
inside one PR, and said so in the file.

```yaml
# Grafana — the homelab's pane of glass.
#
# Design and every declined alternative: docs/superpowers/specs/2026-10-21-titan-grafana-design.md.
# The three things below are the ones that fail silently, so they are stated where the manifests are.
#
#   1. THE IMAGE IS grafana/grafana, NOT teslamate/grafana. The Tesla image (what casa and
#      tesla-boards both use) ships Tesla's dashboards and provisions a Postgres datasource from
#      DATABASE_*; neither is wanted here, and inheriting the image would inherit both.
#
#   2. THE EDGE GATE AND OIDC ANSWER DIFFERENT QUESTIONS. The Middleware below decides whether the
#      host may be reached at all and never tells Grafana who you are; GF_AUTH_GENERIC_OAUTH_*
#      supplies identity and role. Both are on purpose — the same split tesla-boards records, and
#      the reason is there: without OIDC the only thing inside a public host is a shared admin
#      password, and without the edge gate Grafana's own config is the only barrier between the
#      internet and every cluster this Prometheus holds.
#
#   3. THE SECRETS THIS envFrom'S ARRIVE IN TASK 3. Between the two commits the pod is Pending on a
#      missing Secret. That is a half-finished tree, not a broken one, and it resolves within the
#      same PR.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-data
  namespace: observability
spec:
  accessModes:
  - ReadWriteOnce
  # local-path-retain, the same class open-webui uses: it survives `kubectl delete pvc`, which
  # local-path does not. Note this volume is NOT backed up — this cluster backs up the Postgres
  # cluster and nothing else. With allowUiUpdates false on every provider the volume holds only
  # Grafana's sqlite (users, preferences, API keys), so losing it means re-login, not lost
  # dashboards. That is an argument, not a drilled restore.
  storageClassName: local-path-retain
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: observability
  annotations:
    # Does nothing until `observability` is in reloader's values.reloader.namespaces — Reloader does
    # not look at a namespace outside that list, and the annotation sitting inert is the recorded
    # promtail/open-webui defect. Both halves are in this PR; the comment is so the next person does
    # not delete the "useless" one.
    reloader.stakater.com/auto: "true"
spec:
  replicas: 1
  # RWO PVC: a RollingUpdate schedules pod 2 while pod 1 still holds the volume and the new pod sits
  # Pending on a volume conflict forever. Recreate costs a few seconds of dashboards.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      securityContext:
        runAsNonRoot: true
        # The official image's own USER is grafana at uid 472, gid 0, and Grafana's images keep gid 0
        # deliberately so a mounted PVC can be group-writable. Same reasoning tesla-boards records.
        runAsUser: 472
        runAsGroup: 0
        fsGroup: 0
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: grafana
        image: grafana/grafana:12.3.1@sha256:2175aaa91c96733d86d31cf270d5310b278654b03f5718c59de12a865380a31f
        ports:
        - containerPort: 3000
          name: http
        envFrom:
        - secretRef:
            name: observability-grafana-admin
        - secretRef:
            name: observability-grafana-oidc
        env:
        # What Grafana puts in the links it generates itself, so it must be the hostname users
        # actually reach. The OIDC redirect below has to name this same host; make
        # observability-oidc-check fails if the two ever move apart.
        - name: GF_SERVER_ROOT_URL
          value: https://grafana.titan.arrieta.eu/
        - name: GF_SERVER_SERVE_FROM_SUB_PATH
          value: "false"
        - name: TZ
          value: UTC
        - name: GF_AUTH_ANONYMOUS_ENABLED
          value: "false"
        # Grafana's own signup form, separate from OIDC's allow_sign_up below. Off: accounts come
        # from authentik, not from whoever finds the form.
        - name: GF_USERS_ALLOW_SIGN_UP
          value: "false"
        - name: GF_ANALYTICS_REPORTING_ENABLED
          value: "false"
        - name: GF_ANALYTICS_CHECK_FOR_UPDATES
          value: "false"
        # --- single sign-on: Grafana delegates identity to authentik over OIDC ------------------
        # Endpoints from this instance's live discovery document, not from documentation: authorize,
        # token and userinfo are GLOBAL paths with no slug in them; only issuer and jwks carry the
        # slug. Composing `.../o/observability/authorize/` looks obvious and 404s.
        - name: GF_AUTH_GENERIC_OAUTH_ENABLED
          value: "true"
        - name: GF_AUTH_GENERIC_OAUTH_NAME
          value: authentik
        - name: GF_AUTH_GENERIC_OAUTH_AUTH_URL
          value: https://auth.titan.arrieta.eu/application/o/authorize/
        - name: GF_AUTH_GENERIC_OAUTH_TOKEN_URL
          value: https://auth.titan.arrieta.eu/application/o/token/
        - name: GF_AUTH_GENERIC_OAUTH_API_URL
          value: https://auth.titan.arrieta.eu/application/o/userinfo/
        # Without validate_id_token Grafana trusts an unverified id_token, which is a real weakening
        # even behind the edge gate. It is not free: with it true and a wrong jwk_set_url,
        # authentication fails outright.
        - name: GF_AUTH_GENERIC_OAUTH_VALIDATE_ID_TOKEN
          value: "true"
        - name: GF_AUTH_GENERIC_OAUTH_JWK_SET_URL
          value: https://auth.titan.arrieta.eu/application/o/observability/jwks/
        # profile is load-bearing, not decoration: the `groups` claim exists only because authentik's
        # default profile scope mapping emits it. Drop it and the role expression below evaluates
        # against a missing claim and everyone silently lands as Viewer.
        - name: GF_AUTH_GENERIC_OAUTH_SCOPES
          value: openid email profile offline_access
        - name: GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH
          value: email
        - name: GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH
          value: preferred_username
        - name: GF_AUTH_GENERIC_OAUTH_NAME_ATTRIBUTE_PATH
          value: name
        # authentik Admins -> Grafana Org Admin, everyone else Viewer. GrafanaAdmin (server admin) is
        # deliberately not granted.
        - name: GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH
          value: contains(groups[*], 'authentik Admins') && 'Admin' || 'Viewer'
        - name: GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP
          value: "true"
        # Safe specifically because the edge gate means authentik already holds a session by the time
        # Grafana is reached, so this is a silent redirect, not a second prompt. If the forward-auth
        # annotation is ever removed, revisit this — it is then the thing deciding who gets in.
        - name: GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN
          value: "true"
        - name: GF_AUTH_GENERIC_OAUTH_USE_REFRESH_TOKEN
          value: "true"
        # THE ESCAPE HATCH — keep this true. If the OIDC config is ever wrong and basic auth is off,
        # the only way back in is editing the admin Secret and restarting the pod.
        - name: GF_AUTH_BASIC_ENABLED
          value: "true"
        volumeMounts:
        - name: data
          mountPath: /var/lib/grafana
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources
          readOnly: true
        - name: dashboard-provisioning
          mountPath: /etc/grafana/provisioning/dashboards
          readOnly: true
        - name: dashboards-node-exporter
          mountPath: /var/lib/grafana/dashboards/node-exporter
          readOnly: true
        - name: dashboards-postgres
          mountPath: /var/lib/grafana/dashboards/postgres
          readOnly: true
        - name: dashboards-comin
          mountPath: /var/lib/grafana/dashboards/comin
          readOnly: true
        - name: dashboards-disk
          mountPath: /var/lib/grafana/dashboards/disk
          readOnly: true
        - name: dashboards-alerts
          mountPath: /var/lib/grafana/dashboards/alerts
          readOnly: true
        - name: dashboards-amdgpu
          mountPath: /var/lib/grafana/dashboards/amdgpu
          readOnly: true
        - name: dashboards-security-scans
          mountPath: /var/lib/grafana/dashboards/security-scans
          readOnly: true
        livenessProbe:
          httpGet:
            path: /api/health
            port: http
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /api/health
            port: http
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: grafana-data
      - name: datasources
        configMap:
          name: grafana-datasources
      - name: dashboard-provisioning
        configMap:
          name: grafana-dashboard-provisioning
      - name: dashboards-node-exporter
        configMap:
          name: grafana-node-exporter-dashboard
      - name: dashboards-postgres
        configMap:
          name: grafana-postgres-dashboard
      - name: dashboards-comin
        configMap:
          name: grafana-comin-dashboard
      - name: dashboards-disk
        configMap:
          name: grafana-disk-dashboard
      - name: dashboards-alerts
        configMap:
          name: grafana-alerts-dashboard
      - name: dashboards-amdgpu
        configMap:
          name: grafana-amdgpu-dashboard
      - name: dashboards-security-scans
        configMap:
          name: grafana-security-scans-dashboard
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: observability
spec:
  selector:
    app: grafana
  ports:
  - name: http
    port: 80
    targetPort: http
---
# Forward-auth to authentik's embedded outpost. Its own Middleware because Traefik CRD middlewares
# are namespaced — apps-teslamate-auth cannot be referenced from observability, and a second
# namespace needs its own object.
#
# The three values are tesla-boards' and for its documented reasons: the outpost selects its provider
# from X-Forwarded-Host (so trustForwardHeader is what makes resolution work at all), and
# maxResponseBodySize is what authentik's own Traefik-3 generator sets — unset, Traefik logs a DoS
# warning and buffers an unbounded auth response.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: grafana-auth
  namespace: observability
spec:
  forwardAuth:
    address: http://authentik-server.auth.svc.cluster.local/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    maxResponseBodySize: 4194304
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: observability
  # THE LINE THAT MATTERS MOST IN THIS FILE. Without it the homelab's metrics are public to anyone who
  # learns the hostname, with only Grafana's own login in front — which is the state tesla-boards was
  # in by accident and documents. The `@kubernetescrd` suffix is the CRD provider's own name;
  # `@kubernetes` is the Ingress provider and does not resolve a CRD middleware.
  #
  # No authentik proxy-provider change is needed for this host: the provider is forward_domain over
  # titan.arrieta.eu with cookie_domain at that apex, so any host under the domain is served and the
  # existing session cookie already covers it. That is also a coupling worth knowing — the provider
  # lives in apply/50-apps/auth/tesla-outpost-blueprint.yaml, a Tesla file, and narrowing it later
  # reaches this host. Spec §10.
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: observability-grafana-auth@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
  - host: grafana.titan.arrieta.eu
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 80
  tls:
  - hosts:
    - grafana.titan.arrieta.eu
    # Reflected from namespace `certificates` by Reflector. `observability` must be in the allow-list
    # on apply/40-certificates/titan-wildcard.yaml — step 4. Hand-copying this Secret is forbidden by
    # AGENTS.md.
    secretName: titan-tls
```

- [ ] **Step 2: Add it to the stage listing**

Append to `apply/50-apps/kustomization.yaml` after the dashboard entries:

```yaml
  # The workload itself: PVC + Deployment + Service + Middleware + Ingress in namespace
  # `observability`. It reads observability-grafana-admin and observability-grafana-oidc (Task 3) and
  # titan-tls, reflected in.
  - grafana/grafana.yaml
```

- [ ] **Step 3: Verify it builds and the middleware is referenced**

```bash
kubectl kustomize apply/50-apps > /tmp/g.yaml
grep -c 'kind: Middleware' /tmp/g.yaml
grep -n 'router.middlewares' /tmp/g.yaml
grep -n 'secretName: titan-tls' /tmp/g.yaml
```

Expected: `1`; the middleware line reads `observability-grafana-auth@kubernetescrd`; one `titan-tls`.

- [ ] **Step 4: Let Reflector deliver `titan-tls`**

In `apply/40-certificates/titan-wildcard.yaml`, add `observability` to **both** annotation lists:

```yaml
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps,auth,open-webui,observability"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "apps,auth,open-webui,observability"
```

Skip it and the Ingress references a Secret that never arrives; Traefik serves its default cert and
the host resolves with a name mismatch, which reads as a broken certificate rather than a missing
reflection.

- [ ] **Step 5: Verify the allow-list took**

Run: `kubectl kustomize apply/40-certificates | grep -A1 reflection-allowed-namespaces`
Expected: the line now ends `...,observability"`.

- [ ] **Step 6: Put `observability` in Reloader's scope**

In `apply/20-infra/reloader/reloader.yaml`, append to `values.reloader.namespaces`:

```yaml
        # Grafana. Without this line `reloader.stakater.com/auto: "true"` on the Deployment is inert
        # and a dashboard or OIDC Secret edit never restarts the pod — Grafana keeps serving whatever
        # it read at start and reports healthy the whole time. This is the third time this list has
        # bitten (promtail, then open-webui, both recorded above), which is why the comment is here
        # rather than in a commit message nobody will read.
        - observability
```

- [ ] **Step 7: Verify, and prove the annotation is not alone**

```bash
kubectl kustomize apply/20-infra | grep -n "observability"
grep -n 'reloader.stakater.com/auto' apply/50-apps/grafana/grafana.yaml
```

Expected: `observability` appears in the Reloader HelmRelease values, and the annotation exists on
the Deployment. Both, or neither works.

- [ ] **Step 8: Run the gates**

Run: `git add -A && make check`
Expected: all offline gates pass, including `crd-check` validating the `Middleware` against
`vendor/traefik-crds` and `release-secrets` (which does **not** scan this Deployment — a typo'd
`secretRef` here is caught by live apply, not by a gate).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(observability): grafana workload, gated by authentik forward-auth

PVC + Deployment + Service + Middleware + Ingress in namespace observability, official
grafana image pinned by digest. titan-tls reflected in and observability added to
Reloader's namespace list — the annotation is inert without it, which is now the third
time that list has been the reason a config looked healthy and did nothing."
```

---

### Task 3: OIDC client, admin Secret, and the gate that proves they agree

**Files:**
- Create: `authentik/blueprints-observability.yaml`
- Create: `scripts/setup-observability-grafana.sh`
- Create (generated by running it): `apply/10-secrets/authentik-observability-blueprint.yaml`, `apply/10-secrets/observability-grafana-oidc.yaml`, `apply/10-secrets/observability-grafana-admin.yaml`
- Modify: `apply/10-secrets/kustomization.yaml`
- Modify: `apply/50-apps/auth/authentik.yaml` (mount list + reloader annotation)
- Modify: `tools/grafana-oidc-check.py` (variant selector)
- Modify: `Makefile` (`observability-oidc-check` target, added to `check` and `.PHONY`)

**Interfaces:**
- Consumes: `Deployment/observability/grafana` from Task 2 — the gate reads its `env` and `envFrom`.
- Produces: three Secrets named exactly as Task 2's `envFrom` expects; `make observability-oidc-check`.

- [ ] **Step 1: Write the reviewed template `authentik/blueprints-observability.yaml`**

```yaml
# authentik blueprint: the OIDC application and provider Grafana on titan uses, for
# grafana.titan.arrieta.eu.
#
# WHY A SECOND GRAFANA OIDC CLIENT, WHEN ONE ALREADY EXISTS
# `authentik-grafana-blueprint` and its application slug `tesla-boards` belong to the Tesla Grafana
# at tesla-boards.titan.arrieta.eu. Two Grafanas, two clients, two redirect URIs. Sharing one client
# would mean one client_secret held by two deployments and a redirect list that grows a second entry
# every time either moves. The word "grafana" in the existing chain is Tesla's; this file is named
# after the namespace instead, and renaming Tesla's chain is a separate change with a working login
# on the line.
#
# WHY OIDC AT ALL, WHEN THE PROXY PROVIDER ALREADY GATES THIS HOST
# Two different questions. The proxy provider answers "may this host be reached at all" and never
# tells Grafana who you are, so Grafana would still demand its own password — two logins, the second
# one a shared admin account in a Secret. OIDC answers "who is this and what may they see inside
# Grafana". Both stay in place on purpose: the edge gate survives Grafana config drift.
#
# HOW THIS FILE BECOMES A SECRET
# Nothing here is applied directly. scripts/setup-observability-grafana.sh substitutes the two
# `${...}` placeholders and writes the result, sops-encrypted, to
# apply/10-secrets/authentik-observability-blueprint.yaml. `make observability-oidc-check` proves the
# rendered Secret still agrees with this file, with Grafana's own copy of the client, and with the
# host Grafana is configured to serve.
#
# WHAT THIS MUST NOT DO
# The OIDC provider is deliberately NOT added to the embedded outpost's `providers` list. That list
# belongs to a proxy outpost and validate_providers dispatches on provider type
# (outposts/api/outposts.py:69-88); a proxy outpost given an OAuth2 provider is a type error.
#
# The endpoints are read from the live discovery document, not from documentation: authorize, token
# and userinfo are GLOBAL paths with no slug in them, while issuer and jwks are per-provider.
# Composing `.../o/observability/authorize/` looks obvious and returns 404 — measured, not assumed.
version: 1
metadata:
  name: titan-observability
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: observability-provider
    identifiers:
      name: observability
    state: present
    attrs:
      name: observability
      client_type: confidential
      client_id: "${GRAFANA_OIDC_CLIENT_ID}"
      client_secret: "${GRAFANA_OIDC_CLIENT_SECRET}"
      # Grafana's documented callback path for generic_oauth, on the host Grafana is served from.
      # strict, not a prefix: a prefix match on a redirect URI is a redirect bypass.
      redirect_uris:
        - url: https://grafana.titan.arrieta.eu/login/generic_oauth
          matching_mode: strict
      grant_types:
        - authorization_code
        - refresh_token
      # 'profile' is not decoration. Grafana's role mapping reads a `groups` claim, and that claim
      # only exists because the default profile scope mapping emits it
      # (blueprints/system/providers-oauth2.yaml:45). Drop this scope and every OIDC login silently
      # becomes Viewer, because contains(groups[*], ...) evaluates against nothing.
      property_mappings:
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-offline_access]]
      # implicit-consent: a consent screen for an app this cluster owns and configures adds a click
      # and no security. Same reasoning as coder's and tesla-boards'.
      authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      invalidation_flow: !Find [authentik_flows.flow, [slug, default-invalidation-flow]]
      signing_key: !Find [authentik_crypto.certificatekeypair, [managed, goauthentik.io/crypto/jwt-managed]]
      # per_provider makes the issuer .../application/o/observability/, which pins the token to this
      # client. Grafana verifies the audience against it when validate_id_token is on.
      issuer_mode: per_provider
      sub_mode: hashed_user_id

  - model: authentik_core.application
    identifiers:
      slug: observability
    state: present
    attrs:
      name: Grafana
      slug: observability
      provider: !KeyOf observability-provider
      meta_launch_url: https://grafana.titan.arrieta.eu/
      # The proxy provider's application (`tesla`) stays as it is: it is what makes forward-auth
      # work. Two applications, two providers, two jobs — collapsing them breaks one of the two.
```

- [ ] **Step 2: Prove the gate fails before the credentials exist**

Run: `python3 tools/grafana-oidc-check.py apply --variant=observability`
Expected: FAIL — the `--variant` flag does not exist yet, so argparse-style it errors or (if implemented first) it reports the template's checks and then `observability-grafana-oidc not present`. Either way it must not report clean.

- [ ] **Step 3: Write `scripts/setup-observability-grafana.sh`**

Modelled on `scripts/setup-grafana-oidc.sh`, same guarantees: nothing prints a value, plaintext is
trapped away on any failure, staging files sit under `apply/10-secrets/` because sops picks
recipients from the file's own path. It mints **three** files because the admin password is a second
credential with the same drift problem.

```bash
#!/usr/bin/env bash
# Mint Grafana's OIDC client and its local admin password, and write each to every place it has to
# appear. RUN IT, DON'T READ IT INTO A SHELL — the operator's login shell is fish, which has no
# heredocs and no `read -rs -p`; the bash-isms here are deliberate and the shebang is the interpreter.
#
# WHY A SCRIPT AND NOT A UI CLICK
# authentik takes this configuration as a blueprint, so generating the client here and handing it to
# both sides means a rebuilt authentik gets Grafana's client back from git rather than from someone's
# memory, and nothing is ever pasted into a chat transcript. Same reasoning as
# scripts/setup-grafana-oidc.sh, which this file is modelled on.
#
# THREE FILES, TWO CREDENTIALS
#   - the OIDC pair: authentik's blueprint AND Grafana's env. If they disagree, every login fails
#     with an OIDC error that reads like a Grafana bug. `make observability-oidc-check` proves it.
#   - the admin password: Grafana's escape hatch, held once, in one Secret the Deployment envFroms.
#
# Nothing prints a value. What you see is a truncated SHA-256 per file, so a re-run can be compared
# against the last one without a secret being on screen.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

TEMPLATE=authentik/blueprints-observability.yaml
BP_SECRET=apply/10-secrets/authentik-observability-blueprint.yaml
APP_SECRET=apply/10-secrets/observability-grafana-oidc.yaml
ADMIN_SECRET=apply/10-secrets/observability-grafana-admin.yaml
STAGE_BP=apply/10-secrets/.staging.authentik-observability-blueprint.yaml
STAGE_APP=apply/10-secrets/.staging.observability-grafana-oidc.yaml
STAGE_ADMIN=apply/10-secrets/.staging.observability-grafana-admin.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}

trap 'rm -f "$STAGE_BP" "$STAGE_APP" "$STAGE_ADMIN"' EXIT

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"
[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE missing - nothing to render"; exit 1; }

existing=()
for f in "$BP_SECRET" "$APP_SECRET" "$ADMIN_SECRET"; do
  [ -f "$f" ] && existing+=("$f")
done
if [ ${#existing[@]} -gt 0 ]; then
  echo "FAIL: these already exist and would be replaced with NEW credentials:"
  printf '  %s\n' "${existing[@]}"
  echo "Grafana would then present a client authentik no longer recognises, and every OIDC login"
  echo "fails until both sides are re-rendered together. If that is what you want, re-run with FORCE=1."
  [ "${FORCE:-0}" = "1" ] || exit 1
fi

CID=$(python3 -c 'import uuid; print(uuid.uuid4())')
CSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
APASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')

TEMPLATE="$TEMPLATE" STAGE_BP="$STAGE_BP" STAGE_APP="$STAGE_APP" STAGE_ADMIN="$STAGE_ADMIN" \
CID="$CID" CSEC="$CSEC" APASS="$APASS" python3 - <<'PY'
import os, re, sys, yaml

env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${GRAFANA_OIDC_CLIENT_ID}", "${GRAFANA_OIDC_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - template and script disagree")

# Exact string substitution and nothing else: what a reviewer reads in the template is byte-for-byte
# what authentik applies, apart from these two values.
rendered = (tpl.replace("${GRAFANA_OIDC_CLIENT_ID}", env["CID"])
              .replace("${GRAFANA_OIDC_CLIENT_SECRET}", env["CSEC"]))
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s) remain: {leftover}")

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=100)

dump(env["STAGE_BP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "authentik-observability-blueprint", "namespace": "auth"},
    "type": "Opaque",
    # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
    "stringData": {"observability.yaml": rendered},
})

# Grafana's copy. The names are the config keys Grafana reads, so envFrom injects them with no
# mapping and no chance of a typo'd alias between the Secret and the Deployment.
dump(env["STAGE_APP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "observability-grafana-oidc", "namespace": "observability"},
    "type": "Opaque",
    "stringData": {
        "GF_AUTH_GENERIC_OAUTH_CLIENT_ID": env["CID"],
        "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET": env["CSEC"],
    },
})

# The escape hatch. GF_AUTH_BASIC_ENABLED stays true in the Deployment precisely so this account is
# usable when the OIDC config is the thing that is broken.
dump(env["STAGE_ADMIN"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "observability-grafana-admin", "namespace": "observability"},
    "type": "Opaque",
    "stringData": {
        "GF_SECURITY_ADMIN_USER": "admin",
        "GF_SECURITY_ADMIN_PASSWORD": env["APASS"],
    },
})
PY

for f in "$STAGE_BP" "$STAGE_APP" "$STAGE_ADMIN"; do
  sops --encrypt --in-place "$f"
  dest=$([ "$f" = "$STAGE_BP" ] && echo "$BP_SECRET" || { [ "$f" = "$STAGE_APP" ] && echo "$APP_SECRET" || echo "$ADMIN_SECRET"; })
  mv "$f" "$dest"
  echo "wrote $dest  (fingerprint $(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$dest"))"
done

cat <<'DONE'

Done. Three files, two credentials, all encrypted.

Still to do, in order:
  1. List all three in apply/10-secrets/kustomization.yaml, and mount the blueprint in
     apply/50-apps/auth/authentik.yaml (blueprints.secrets AND the reloader annotation).
  2. make observability-oidc-check  proves the two copies, the mount and the host agree.
  3. Merge, and let the authentik worker apply the blueprint (hourly, or force it from the UI).
  4. Sign in with authentik once and confirm the role you expected. GF_AUTH_BASIC_ENABLED stays
     true on purpose: it is the way back in if the OIDC config is ever wrong.
DONE
```

- [ ] **Step 4: Run it**

```bash
chmod +x scripts/setup-observability-grafana.sh
./scripts/setup-observability-grafana.sh
```

Expected: three `wrote …` lines with fingerprints, no secret on screen, and no
`.staging.*` files left (`ls apply/10-secrets/.staging.* 2>/dev/null` prints nothing).

- [ ] **Step 5: Verify the Secrets decrypt and carry the right keys**

```bash
for f in authentik-observability-blueprint observability-grafana-oidc observability-grafana-admin; do
  printf "%-38s " "$f"
  sops -d "apply/10-secrets/$f.yaml" | python3 -c 'import sys,yaml;d=yaml.safe_load(sys.stdin);print(list((d.get("stringData") or {}).keys()))'
done
```

Expected: `['observability.yaml']`, `['GF_AUTH_GENERIC_OAUTH_CLIENT_ID', 'GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET']`, `['GF_SECURITY_ADMIN_USER', 'GF_SECURITY_ADMIN_PASSWORD']`. Key names only — never print the values.

- [ ] **Step 6: List the three Secrets**

Append to `apply/10-secrets/kustomization.yaml`:

```yaml
  # Grafana on titan. Minted together by scripts/setup-observability-grafana.sh so the duplicated
  # half cannot be authored apart: the OIDC client exists in authentik's blueprint (namespace auth)
  # and in Grafana's own env (namespace observability), and `make observability-oidc-check` is what
  # proves they agree. The admin Secret is the escape hatch that keeps GF_AUTH_BASIC_ENABLED=true
  # meaningful. An unlisted file here builds green and is silently never applied.
  - authentik-observability-blueprint.yaml
  - observability-grafana-oidc.yaml
  - observability-grafana-admin.yaml
```

- [ ] **Step 7: Mount the blueprint — in both places**

In `apply/50-apps/auth/authentik.yaml`, add to `spec.values.blueprints.secrets`:

```yaml
        # Grafana's OIDC client for grafana.titan.arrieta.eu. A valid blueprint that is never mounted
        # is indistinguishable from one that was never written — the worker only reads what is listed
        # here. Same trap the tesla and open-webui entries above record.
        - authentik-observability-blueprint
```

And add the Secret to the reloader annotation on the same file, appending to the existing comma list:

```yaml
        secret.reloader.stakater.com/reload: "authentik-secrets,authentik-coder-blueprint,authentik-google-blueprint,authentik-grafana-blueprint,authentik-open-webui-blueprint,authentik-observability-blueprint"
```

Both, or the blueprint sits unread for up to an hour after every edit: kubelet rewrites the mounted
file in place and the worker re-discovers blueprints hourly.

- [ ] **Step 8: Verify both mount points**

```bash
kubectl kustomize apply/50-apps | grep -c authentik-observability-blueprint
```

Expected: **2** (the HelmRelease `blueprints.secrets` entry and the reloader annotation). One means
half the wiring is missing.

- [ ] **Step 9: Add the variant to the gate**

In `tools/grafana-oidc-check.py`, replace the module-level constants with a variant table and keep
`tesla` as the default so `make grafana-oidc-check` is unchanged:

```python
VARIANTS = {
    "tesla": {
        "TEMPLATE": "authentik/blueprints-grafana.yaml",
        "PLACEHOLDERS": ("GRAFANA_OIDC_CLIENT_ID", "GRAFANA_OIDC_CLIENT_SECRET"),
        "REDIRECT": "https://tesla-boards.titan.arrieta.eu/login/generic_oauth",
        "HOST": "tesla-boards.titan.arrieta.eu",
        "BLUEPRINT_SECRET": "authentik-grafana-blueprint",
        "BLUEPRINT_KEY": "grafana.yaml",
        "APP_SECRET": "tesla-grafana-oidc",
        "APP_NS": "apps",
        "DEPLOY": "tesla-grafana",
        "SLUG": "tesla-boards",
        "SCRIPT": "scripts/setup-grafana-oidc.sh",
    },
    "observability": {
        "TEMPLATE": "authentik/blueprints-observability.yaml",
        "PLACEHOLDERS": ("GRAFANA_OIDC_CLIENT_ID", "GRAFANA_OIDC_CLIENT_SECRET"),
        "REDIRECT": "https://grafana.titan.arrieta.eu/login/generic_oauth",
        "HOST": "grafana.titan.arrieta.eu",
        "BLUEPRINT_SECRET": "authentik-observability-blueprint",
        "BLUEPRINT_KEY": "observability.yaml",
        "APP_SECRET": "observability-grafana-oidc",
        "APP_NS": "observability",
        "DEPLOY": "grafana",
        "SLUG": "observability",
        "SCRIPT": "scripts/setup-observability-grafana.sh",
    },
}
```

Parse it from argv without disturbing the existing `argv[1] = root` contract:

```python
def variant_from(argv):
    for a in argv[2:]:
        if a.startswith("--variant="):
            name = a.split("=", 1)[1]
            if name not in VARIANTS:
                sys.exit(f"grafana-oidc-check: unknown variant {name!r}; known: {', '.join(VARIANTS)}")
            return VARIANTS[name]
    return VARIANTS["tesla"]
```

Then inside `main()`, bind the chosen dict to the existing names so no other line changes:

```python
    v = variant_from(sys.argv)
    TEMPLATE, PLACEHOLDERS = v["TEMPLATE"], v["PLACEHOLDERS"]
    REDIRECT, HOST = v["REDIRECT"], v["HOST"]
    BLUEPRINT_SECRET, BLUEPRINT_KEY = v["BLUEPRINT_SECRET"], v["BLUEPRINT_KEY"]
    APP_SECRET, APP_NS = v["APP_SECRET"], v["APP_NS"]
```

and replace the remaining hardcoded strings: the slug assertion `!= "tesla-boards"` becomes
`!= v["SLUG"]`, `find(docs, "Deployment", "tesla-grafana", APP_NS)` becomes
`find(docs, "Deployment", v["DEPLOY"], APP_NS)`, and the three messages that name
`scripts/setup-grafana-oidc.sh` use `v["SCRIPT"]`.

A fork into a second script was declined (spec §9): the failure modes are identical and two scripts
drift, which is the thing these gates exist to prevent.

- [ ] **Step 10: Wire the Makefile target**

Add `observability-oidc-check` to the `.PHONY` line and to `check`, and the target itself beside
`grafana-oidc-check`:

```make
# observability-oidc-check: the same four-way agreement, one Grafana further along. Same script,
# different variant — see spec §9 of the 2026-10-21 Grafana design for why a fork was declined.
observability-oidc-check:
	@python3 tools/grafana-oidc-check.py apply --variant=observability
```

- [ ] **Step 11: Run both variants**

```bash
make grafana-oidc-check && make observability-oidc-check
```

Expected: `grafana-oidc-check: 13 check(s) run, 0 mismatch(es)` (unchanged from before this task) and
`grafana-oidc-check: 13 check(s) run, 0 mismatch(es)` for the new variant. If the new one reports
fewer checks, something is not being found — a zero-count pass is not a pass.

- [ ] **Step 12: Prove the gate actually bites**

Temporarily break one half and confirm a FAIL, then restore:

```bash
python3 - <<'PY'
import re
p = "apply/50-apps/grafana/grafana.yaml"
s = open(p).read()
open(p, "w").write(s.replace("https://grafana.titan.arrieta.eu/", "https://wrong.example/", 1))
PY
make observability-oidc-check; echo "exit=$?"
git checkout apply/50-apps/grafana/grafana.yaml
```

Expected: a FAIL naming `GF_SERVER_ROOT_URL` versus the redirect host, non-zero exit. Then restore
and re-run to green. (If `git checkout` also reverts other work, use a targeted edit-back instead.)

- [ ] **Step 13: Run the full gate set and commit**

```bash
git add -A
make check
git commit -m "feat(observability): grafana OIDC client, admin secret, and the gate that binds them

authentik blueprint template + setup script minting three encrypted files from one
credential, mounted in both places authentik needs (blueprints.secrets and the reloader
annotation). grafana-oidc-check gains a variant selector rather than a forked script, so
both Grafanas are held to the same four-way agreement."
```

---

### Task 4: Documentation

**Files:**
- Create: `docs/grafana-runbook.md`
- Modify: `AGENTS.md` (layout paragraph + the load-bearing facts)

**Interfaces:**
- Consumes: everything above.
- Produces: the operational half of the record, in the shape `docs/titan-metrics-scrape.md` and `docs/teslamate-runbook.md` use — what is measured, what is assumed, and how to tell "not deployed" from "deployed and wrong".

- [ ] **Step 1: Write `docs/grafana-runbook.md`**

Sections, in this order, each written from the spec rather than invented:

1. **What this is** — the homelab's Grafana, reading casa's Prometheus and Loki over the mesh; titan runs neither. Point at the spec for decisions.
2. **The two datasources and the one dependency that breaks both** — `prometheus.local.arrieta.eu` and `loki.local.arrieta.eu` are unauthenticated today and Grafana proxies server-side; if casa ever puts them behind authentik, every panel empties at once. Include the measured `count(up)` = 106 and `count by (cluster) (up)` = 94 / 7 titan / 5 techdelivery.
3. **What each dashboard actually shows** — copy the §6 table from the spec verbatim, including that the postgres board is **casa's** database and not titan's CNPG, and that `alerts` reads casa's Alertmanager.
4. **Login** — edge gate then OIDC; role from `authentik Admins`; the local admin escape hatch and why `GF_AUTH_BASIC_ENABLED` stays true.
5. **Dashboards are edited in git, not the browser** — `allowUiUpdates: false`, and how to add a dashboard (new ConfigMap, new provider entry, list it in `apply/50-apps/kustomization.yaml`).
6. **When a dashboard edit does not appear** — check Reloader first (`values.reloader.namespaces` must contain `observability`), then the pod's start time vs the ConfigMap's. This is the recorded failure mode, so give it its own section.
7. **Verification** — the seven live steps from spec §11, with the fish-safe forms.
8. **Not proven** — the PVC has no backup and no drilled restore; the gating coupling to `tesla-outpost-blueprint.yaml`; `release-secrets` does not scan this Deployment.

- [ ] **Step 2: Update `AGENTS.md`**

In the `## Layout` block, add `grafana/` to the `50-apps` description and one sentence to the
Metrics paragraph:

```markdown
Metrics: … `docs/titan-metrics-scrape.md` is the runbook. **The consumer of all of it is now on
titan**: `apply/50-apps/grafana/` runs a Grafana in namespace `observability` whose Prometheus
datasource is casa's, reached over the mesh at `https://prometheus.local.arrieta.eu`. It is a
whole-homelab view by decision, not misconfiguration — that Prometheus holds casa, titan and
techdelivery, and `cluster` is absent on titan's own node_exporter and comin scrapes, so it is not a
usable filter. `docs/grafana-runbook.md` is the runbook.
```

- [ ] **Step 3: Verify and commit**

```bash
grep -n "observability" AGENTS.md docs/grafana-runbook.md | head
git add -A && make check
git commit -m "docs: grafana runbook, and the metrics paragraph now has a consumer

Records the one dependency no manifest shows: both datasources are unauthenticated today
and Grafana proxies server-side, so casa putting prometheus.local behind authentik empties
every panel at once. Also records that the postgres board is casa's database, not titan's."
```

---

### Task 5: Post-merge live verification

Requires the operator's go-ahead to merge, and an admin kubeconfig context for steps 2 and 4b (both
use `pods/exec`, which `k8s-reader` cannot). Run in order — each step distinguishes "not deployed yet"
from "deployed and wrong".

- [ ] **Step 1: Merge, then watch the two stages converge**

```bash
timeout 60 gh pr merge <n> --squash --delete-branch
timeout 60 flux -n flux-system get kustomizations
```

Expected: `apps` and `infra` both `Ready=True`. If `apps` is red, read the failure before retrying —
a malformed ConfigMap in this stage freezes coder's updates, which is the accepted cost.

- [ ] **Step 2: The workload is up and the volume bound**

```bash
kubectl -n observability get pvc,deploy,pods -l app=grafana
kubectl -n observability exec deploy/grafana -- wget -qO- localhost:3000/api/health
```

Expected: PVC `Bound`, pod `Running` 1/1, health JSON with `"database":"ok"`. This check stays inside
the cluster, so it proves Grafana is up without crossing the edge gate.

- [ ] **Step 3: The edge gate holds — the check that matters most**

```bash
curl -sSI https://grafana.titan.arrieta.eu/ | head -5
```

Expected: **302** with a `location:` pointing at `auth.titan.arrieta.eu`. A **200** here means the
middleware annotation did not land and the homelab's metrics are public — fix before anything else.

- [ ] **Step 4: TLS is the wildcard, not Traefik's default**

```bash
echo | openssl s_client -connect grafana.titan.arrieta.eu:443 -servername grafana.titan.arrieta.eu 2>/dev/null | openssl x509 -noout -subject -dates
```

Expected: a `*.titan.arrieta.eu` cert. A `TRAEFIK DEFAULT CERT` means Reflector has not delivered
`titan-tls` into `observability` — re-check the allow-list edit.

- [ ] **Step 4b: authentik actually ingested the blueprint — before debugging any login**

Needs the admin context; `k8s-reader` is `Forbidden` on `pods/exec` in `auth`.

```bash
kubectl -n auth exec deploy/authentik-worker -- ak shell -c 'from authentik.blueprints.models import BlueprintInstance; [print(b.name, "|", b.path, "|", b.status, "|", b.last_applied) for b in BlueprintInstance.objects.all()]'
```

Expected: a `titan-observability` row with `status: successful` and a `path` of
`mounted/secret-authentik-observability-blueprint/observability.yaml`. **Run this before step 5, not
after it fails**, because the failure mode is invisible from Grafana: `docs/authentik-runbook.md` §5
records 2026-10-20, when a blueprint was applied by Flux, the worker restarted for it, the file was
demonstrably on disk, `apply_blueprint` finished with `exc: null` — and no `BlueprintInstance` was
created. Mounting in both places (Task 3 step 7) is necessary and was demonstrably not sufficient.
No row is not a lag and not a Grafana bug; the login in step 5 would simply fail in a way that reads
like one. The `path` column is what distinguishes a wrong mount from a wrong blueprint. To apply now
rather than wait for the hourly discovery, use the command in `docs/grafana-runbook.md` "Forcing the
blueprint" — pipe it through the `sed -E 's/[a-f0-9]{64}/REDACTED/g'` filter there, because a
validation failure prints the client secret to stdout.

- [ ] **Step 5: Sign in, and check the role rather than the login**

Only after step 4b shows a successful row.
Sign in through authentik. Confirm an authentik Admin lands as Grafana Admin-adjacent `Admin` and a
non-member as `Viewer`. A login that works with everyone as Viewer means the `profile` scope went
missing on one side of the pair.

- [ ] **Step 6: Both datasources answer**

Connections → data sources → Prometheus → **Save & test** → success. Same for Loki. A Prometheus
failure here, with the pod healthy, means the mesh path or casa's exposure changed.

- [ ] **Step 7: One panel per dashboard returns data, not "No data"**

node-exporter, disk, comin, postgres, amdgpu, alerts, security-scans. An empty panel is expected for
some boards and the reason is in the runbook's table; the point of this step is knowing which empties
are on purpose.

- [ ] **Step 8: Prove the drift controls work**

Try to save a dashboard edit in the UI — it should not offer to. Then change one byte of a dashboard
in git, push, and confirm the pod restarts. A restart proves the Reloader namespace entry landed;
no restart means the annotation is sitting inert and step 6 of Task 2 needs re-checking.

- [ ] **Step 9: Record what was observed**

Append the measured results to `docs/grafana-runbook.md` — which panels returned what, the health
output, the 302, and the `BlueprintInstance` row from step 4b — in a dated "first deploy" section, the
way `docs/open-webui-runbook.md` records its own first deploy. Evidence, not a claim.
