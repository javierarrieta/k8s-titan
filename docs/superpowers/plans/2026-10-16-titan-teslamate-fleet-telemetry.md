# titan TeslaMate on the official Fleet API — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run TeslaMate and Grafana on titan against the official Tesla Fleet API, with self-hosted Fleet Telemetry streaming replacing the Owner-API websocket that Tesla retired, and the existing trip history migrated off k8s-techdelivery.

**Architecture:** TeslaMate polls the EU Fleet API with deliberately coarse intervals while a self-hosted `fleet-telemetry` server receives realtime signals pushed directly from the car. fleet-telemetry dispatches each record to an in-cluster Redis; a dependency-free Node forwarder subscribes to Redis and re-POSTs each record to the MyTeslaMate websocket bridge, which speaks the old streaming protocol to TeslaMate. Everything lands in the shared CNPG Postgres, which is already backed up to S3.

**Tech Stack:** k3s v1.35.x + Traefik 3.7.8, Flux v2 (Kustomization only — no HelmRelease in this plan), CloudNativePG 1.30.x, `tesla/fleet-telemetry:v0.9.5`, `ghcr.io/myteslamate/websocket:0.1.2`, `teslamate/teslamate:4.3.0`, `teslamate/grafana:4.3.0`, `library/redis:8.8.3-alpine`, `library/node:22-alpine`, sops+age.

## Status after implementation (2026-10-16)

Tasks 1-6 and 8-9 are implemented and committed; the per-task record, including every ruling that
changed this plan while it was being executed, is in
`.superpowers/sdd/2026-10-16-titan-teslamate-fleet-telemetry/progress.md`. Task 11's runbook is
`docs/teslamate-runbook.md`. What is NOT done, and why:

- **Task 7 (migration) and every `make dry-run` in this plan** need an admin kube context. The
  read-only `k8s-reader` identity is Forbidden on `pods/exec` in `databases` and on everything the
  dry-run asks for — verified, not assumed. The scripts are written and their guards are tested;
  they have not been run.
- **Task 10 (pointing the car at it)** is the operator's, from their own machine, and now has a
  script (`scripts/tesla-push-telemetry-config.sh`) instead of the curl one-liner below, so the
  bearer token never appears in argv or shell history.
- **Task 11 Step 4 (settle the budget)** needs a week of driving. The runbook carries the predicted
  numbers with the measured column left empty on purpose.

Deviations from this plan that are already baked into the manifests: `ghcr.io/myteslamate/websocket`
is `0.1.2`, not `0.1.0` (0.1.2 fixes per-VIN frame ordering); `TESLA_AUTH_CLIENT_ID` is a fourth
Secret rather than a ConfigMap; `DATABASE_HOST` is `postgres-rw.databases.svc.cluster.local`, since
CNPG publishes no bare `postgres` service; and `setup-tesla-secrets.sh` is idempotent per file so
that adding the public key days later cannot rotate `ENCRYPTION_KEY`.

**Spec:** `docs/superpowers/specs/2026-10-16-titan-teslamate-fleet-telemetry-design.md` — read it alongside this plan. It carries the pricing arithmetic (§2), the decision table (§3) and the not-proven list (§9); this plan argues from it and does not repeat the reasoning.

## Global Constraints

- Never set a top-level `namespace:` in any `kustomization.yaml`; these trees span namespaces and that field rewrites them all.
- Every file added under `apply/` must be listed in that directory's `kustomization.yaml`. `make kustomize-listing` enforces it, and an unlisted manifest is silently never applied.
- Secrets live only in `apply/10-secrets/`, sops-encrypted, recipients from `.sops.yaml` only. **Never pass `--age`** — it silently drops every other keyholder. Stage plaintext as `apply/10-secrets/.staging.<name>.yaml` (git-ignored, matches `path_regex`) and `sops --encrypt --in-place`.
- This repo is public. No credentials, and no concrete public IPv4 — write `<OVH_PUBLIC_IP>`.
- Ingress class is k3s' bundled `traefik`; TLS is `secretName: titan-tls` referenced from the namespace the Ingress lives in (`apps` — already on the reflector allow-list). Do not copy the Secret.
- Live drift is not corrected here. HelmReleases run `driftDetection: mode: enabled`; anything poked with `kubectl edit` must be removed again and said out loud.
- Offline gate: `git add -A && make check`. `make check-ci` is the keyless subset and is what CI runs. `make dry-run DRYRUN_CONTEXT=<admin context>` is the only check that asks the live API server.
- Flux syncs from `main`. Nothing is live until it merges.
- Every container gets `resources.requests` and `resources.limits`, a `securityContext`, and a pinned image tag.
- Read-only cluster access is the `k8s-reader` ServiceAccount (`--context titan`); it cannot read Secrets and is Forbidden on `pods/exec`. Steps that need more than that say so.

## Measured during planning (2026-10-16)

Probes, not assumptions. Two of them change the manifests below.

| probe | result | consequence |
|---|---|---|
| `kubectl --context titan -n kube-system get svc traefik` | entrypoints `web` :80, `websecure` :443 | the `IngressRouteTCP` uses `entryPoints: [websecure]` |
| `kubectl get crd ingressroutetcps.traefik.io` schema | `passthrough` exists **only** at `spec.tls.passthrough`. A route has `match, middlewares, priority, services, syntax` — **no route-level `tls`** | the passthrough block is `spec.tls`, not `spec.routes[].tls`. The Traefik v2 examples floating around are wrong for 3.7.8 |
| `curl -sI https://tesla.titan.arrieta.eu/` | **404 from Traefik** | wildcard DNS + cert already answer; a new host works the moment an Ingress exists |
| Docker Hub `tesla/fleet-telemetry` | `v0.9.5` newest | pinned |
| `ghcr.io/myteslamate/websocket/manifests/0.1.0` with an anonymous pull token | **200** | pullable without a registry credential |
| Docker Hub `library/node` | `22-alpine` exists; `22.20.1-alpine3.23` **404** | pin `node:22-alpine` **by digest** |
| Docker Hub `library/redis` | `8.8.3-alpine` exists | pinned |
| Docker Hub `nginxinc/nginx-unprivileged` | `1.31.7-alpine` exists | pinned |
| `datastore/redis/redis.go` in fleet-telemetry | `client.Publish(ctx, channel, entry.Payload())`, channel `fmt.Sprintf("%s_{%s}", BuildTopicName(ns, txType), vin)` | one Redis message **per record**, channel `tesla_telemetry_V_{<VIN>}` with literal braces |
| `datastore/mqtt/mqtt_payload.go` | one MQTT message **per field**, payload = bare value | MQTT is unusable here — spec §3 T5 |
| `server/monitoring/status_server.go` | the only status route is `/status` | probes hit `/status`, not `/healthz` |
| `apply/10-secrets/coder-db-credentials.yaml` | `namespace: databases`, `labels: cnpg.io/reload: "true"`, `username: coder` | the teslamate DB Secret copies that shape exactly |
| `kubectl --context k8s-techdelivery -n databases exec … pods/exec` | **Forbidden** for `k8s-reader` | Task 8 needs an admin context on both clusters |

**One deliberate deviation from spec §6.** The spec put the Tesla application EC private key in `apply/10-secrets/tesla-app-keys.yaml`. It does not need to be in the cluster at all: the only thing that uses it is the vehicle-command proxy, which runs on the operator's laptop (Task 10), and `ghcr.io`/Docker Hub ship no vehicle-command image (*verified*: no Docker Hub repo, and release v0.4.1 has no assets). Keeping a signing key out of a public-internet cluster when nothing in it needs the key is the smaller blast radius, so the private half goes to the password manager and **only the public half enters this repo**, as a ConfigMap. Task 1 says this where an implementer will hit it.

## Review Focus

The five things no task's own test catches by construction, most likely to bite first. Each has a pinning step in the named task.

1. **The forwarder must forward bytes, not text.** If the RESP parser returns a decoded string and anything upstream ever sets `transmit_decoded_records: false`, the flatbuffers payload is mangled by UTF-8 round-tripping and every frame fails silently at the bridge, which answers **200** to bad bodies. Expected: the parser hands back a `Buffer` and the base64 is of the raw bytes. Pinned in Task 6 Step 1.
2. **`transmit_decoded_records: true` is load-bearing, not cosmetic.** With it off, the bridge's `JSON.parse` throws, it logs `Bad POST body`, returns 200, and TeslaMate simply never sees a frame. Expected: a synthetic record published to Redis arrives on the websocket. Pinned in Task 6 Step 5.
3. **A reflected `titan-tls` Secret is a copy, not a live reference.** If the wildcard rotates, fleet-telemetry keeps the old bytes until the pod restarts, and the car's TLS handshake starts failing while every Flux condition stays green. Expected: the fleet-telemetry pod's cert generation matches the live `titan-tls` after a rotation. Pinned in Task 4 Step 7.
4. **The bridge is stateful and single-replica.** Its own chart says the telemetry POST and the websocket must land on the same pod; a second replica or a RollingUpdate misroutes frames per VIN. Expected: `replicas: 1` and `strategy: Recreate`, and a rolling-update test that shows the old pod is gone before the new one is Ready. Pinned in Task 5 Step 4.
5. **The polling budget is a claim about the future, not a property of the manifest.** A wrong `POLLING_*` value shows up as a Tesla invoice or a disabled application, not as a failing test. Expected: measured device-data counts from the Tesla dashboard after a week, written into the runbook. Pinned in Task 11 Step 4.

## File Structure

| file | responsibility |
|---|---|
| `scripts/setup-tesla-secrets.sh` | generates and encrypts the three Secrets; prints truncated SHA-256 per value, never a value |
| `apply/10-secrets/teslamate-secrets.yaml` | TeslaMate runtime: `ENCRYPTION_KEY`, `DATABASE_*`, generated at Task 1 |
| `apply/10-secrets/teslamate-db-credentials.yaml` | `kubernetes.io/basic-auth` for the CNPG `DatabaseRole`, `cnpg.io/reload` |
| `apply/10-secrets/tesla-wellknown.yaml` | the application **public** key, as a Secret so the shape matches every other credential-adjacent file — see Task 1 Step 1 for why it is a Secret and not only a ConfigMap |
| `apply/50-apps/tesla/teslamate-db.yaml` | CNPG `Database` + `DatabaseRole`, namespace `databases` |
| `apply/50-apps/tesla/wellknown.yaml` | static server for `/.well-known/appspecific/com.tesla.3p.public-key.pem` |
| `apply/50-apps/tesla/redis.yaml` | ephemeral Redis for the telemetry hop |
| `apply/50-apps/tesla/fleet-telemetry.yaml` | fleet-telemetry Deployment + config + Service + `IngressRouteTCP` passthrough |
| `apply/50-apps/tesla/streaming.yaml` | MyTeslaMate websocket bridge + Ingress |
| `apply/50-apps/tesla/forwarder.yaml` | the Node forwarder + its script ConfigMap |
| `scripts/tesla-forwarder-tests.sh` | runs the shipped forwarder script — parser unit tests plus an end-to-end run against a fake Redis and a fake bridge; added during execution, wired into `check` and `check-ci` |
| `apply/50-apps/tesla/teslamate.yaml` | TeslaMate Deployment + Service + Ingress |
| `apply/50-apps/tesla/grafana.yaml` | Grafana PVC + Deployment + Service + Ingress |
| `apply/50-apps/kustomization.yaml` | lists all eight new files, in apply order |
| `scripts/migrate-teslamate-db.sh` | dump from techdelivery, restore into CNPG |
| `docs/teslamate-runbook.md` | what is running, the polling budget and how it was measured, what is deliberately not wired |
| `AGENTS.md` | gains TeslaMate to the "what is backed up" and "what lives where" paragraphs |

Order matters and is the order Flux applies: `teslamate-db.yaml` before `teslamate.yaml`; `redis.yaml` before `fleet-telemetry.yaml`; `fleet-telemetry.yaml` and `streaming.yaml` before `forwarder.yaml`; `forwarder.yaml` before `teslamate.yaml`.

## Operator handoff points

Spec §7 lists eight things only the operator can do. They are not a task, but three of them gate tasks, and an implementer who does not know that will wait on a cluster that is fine:

| spec §7 step | gated by / gates |
|---|---|
| 1-2. create the app, generate the keypair, serve the public key | **must happen before Task 1**, which takes the public key as an argument, and is only *provable* after Task 3 Step 4 |
| 3. partner token + `register` for EU | after Task 3 is live; pairing fails without it |
| 4. redirect URI | read from TeslaMate's sign-in page in Task 8 Step 4 |
| 5. pair the virtual key at `https://tesla.com/_ak/tesla.titan.arrieta.eu` | after step 3; Task 10 cannot proceed without it |
| 6-7. push `fleet_telemetry_config`, wait for `synced` | Task 10, which needs a signed-in TeslaMate from Task 8 |
| 8. payment method + billing limit | before the first real drive, or the application is disabled when it trips |

---

### Task 1: Secrets and the Tesla application keypair

**Files:**
- Create: `scripts/setup-tesla-secrets.sh`
- Create: `apply/10-secrets/teslamate-secrets.yaml` (encrypted by the script)
- Create: `apply/10-secrets/teslamate-db-credentials.yaml` (encrypted by the script)
- Create: `apply/10-secrets/tesla-wellknown.yaml` (encrypted by the script)
- Modify: `apply/10-secrets/kustomization.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: Secret `databases/teslamate-db-credentials` (`username: teslamate`, `password`), Secret `apps/teslamate-secrets` (`ENCRYPTION_KEY`, `DATABASE_USER`, `DATABASE_PASS`, `DATABASE_NAME`, `DATABASE_HOST`), Secret `apps/tesla-wellknown` (`com.tesla.3p.public-key.pem`). Task 2 consumes the DB Secret by name; Task 3 consumes the public key; Task 8 consumes `teslamate-secrets`.

- [ ] **Step 1: Write the script**

Follow `scripts/setup-coder-secrets.sh` exactly on the parts that are not specific to this secret: `set -euo pipefail`, `trap 'rm -f "$STAGE_…"' EXIT`, the `command -v` preflight, `SOPS_AGE_KEY_FILE` defaulting to `~/.config/sops/age/titan-k8s-key.txt`, python3 for randomness, and **no value ever printed** — only a truncated SHA-256 per generated value so a re-run can be compared.

```bash
#!/usr/bin/env bash
# Generate everything TeslaMate needs that this repo cannot simply commit, encrypt it into
# apply/10-secrets, and print nothing but a truncated SHA-256 per value.
#
# RUN IT, DON'T READ IT INTO A SHELL — the operator's login shell is fish, which has no heredocs.
#
# The Tesla application EC private key is deliberately NOT generated or stored here. Nothing in
# the cluster uses it: it signs fleet_telemetry_config, which the vehicle-command proxy does on
# the operator's laptop (spec §7 step 6), and ghcr/Docker Hub ship no vehicle-command image
# (verified: no Docker Hub repo, release v0.4.1 has no assets). A signing key that no pod needs
# has no business living in a public-internet cluster. Keep the private half in the password
# manager; only the public half is committed, and this script takes it as an argument.
set -euo pipefail
PUBKEY=${1:?usage: setup-tesla-secrets.sh <path to com.tesla.3p.public-key.pem>}
```

Generate `ENCRYPTION_KEY` (32 random bytes, hex) and two DB passwords (24 random bytes, base64url, no padding), then write three staging files and encrypt each in place:

```bash
stage=apply/10-secrets/.staging.teslamate-secrets.yaml
cat > "$stage" <<EOF
apiVersion: v1
kind: Secret
metadata: {name: teslamate-secrets, namespace: apps}
type: Opaque
stringData:
  ENCRYPTION_KEY: "$EK"
  DATABASE_USER: teslamate
  DATABASE_PASS: "$DBPASS"
  DATABASE_NAME: teslamate
  DATABASE_HOST: postgres.databases
EOF
sops --encrypt --in-place "$stage" && mv "$stage" apply/10-secrets/teslamate-secrets.yaml
```

`teslamate-db-credentials.yaml` is `type: kubernetes.io/basic-auth` in namespace `databases` with `labels: {cnpg.io/reload: "true"}` and `username: teslamate` — the same shape as `coder-db-credentials`, which is the file that proves the label belongs on the Secret and not the `DatabaseRole`.

`tesla-wellknown.yaml` carries `com.tesla.3p.public-key.pem` read from `$PUBKEY` under `stringData`. It is a Secret rather than a bare ConfigMap for one reason: `make secrets-placement` and `make leak-check` only inspect `apply/10-secrets/` thoroughly, and a public key is exactly the kind of file a later reader might otherwise drop next to the Deployment where nothing watches it. It is not secret, and the file says so in a comment.

- [ ] **Step 2: Run it and prove the recipients**

```bash
umask 077 && ./scripts/setup-tesla-secrets.sh ~/tesla/com.tesla.3p.public-key.pem
grep -oE 'age1[a-z0-9]{12}' apply/10-secrets/teslamate-secrets.yaml | sort -u | wc -l   # must be 5
grep -oE 'age1[a-z0-9]{12}' .sops.yaml | sort -u | wc -l                                  # must be 5
```

Expected: `5` and `5`. A count of 1 means `--age` was passed somewhere.

- [ ] **Step 3: Prove no plaintext survived**

```bash
ls apply/10-secrets/.staging.*.yaml 2>/dev/null && echo "FAIL: staging file left behind"
grep -c 'ENC\[' apply/10-secrets/teslamate-secrets.yaml   # > 0
```

- [ ] **Step 4: List them and run the gates**

Add the three filenames to `apply/10-secrets/kustomization.yaml`, then:

```bash
git add -A && make secrets-placement && make leak-check && make validate
```

Expected: `secrets-placement` reports all three encrypted and listed; `validate` decrypts each.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "secrets: teslamate runtime, CNPG role, and the Tesla application public key"
```

---

### Task 2: The CNPG database and role

**Files:**
- Create: `apply/50-apps/tesla/teslamate-db.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: Secret `databases/teslamate-db-credentials` from Task 1.
- Produces: Postgres role `teslamate` (LOGIN) and database `teslamate` on cluster `postgres`, reachable at `postgres.databases:5432`. Task 7 restores into it; Task 8 connects as it.

- [ ] **Step 1: Write the manifest**

```yaml
# TeslaMate's database and role, authored next to the app that owns them. Both live in
# `databases`: a CNPG Database must share a namespace with its Cluster.
#
# The password is not here — it is in apply/10-secrets/teslamate-db-credentials.yaml, encrypted,
# and referenced by name. Read auth/authentik-db.yaml first; everything it records about
# DatabaseRole applies verbatim, including that `login: true` is required and silent when missing.
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: teslamate
  namespace: databases
spec:
  name: teslamate
  owner: teslamate
  cluster:
    name: postgres
---
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: teslamate
  namespace: databases
spec:
  name: teslamate
  cluster:
    name: postgres
  # Required, and nothing complains when it is absent. CNPG creates the role NOLOGIN by default.
  login: true
  passwordSecret:
    name: teslamate-db-credentials
```

- [ ] **Step 2: List it and run the offline gates**

Add `tesla/teslamate-db.yaml` to `apply/50-apps/kustomization.yaml` (first of the tesla files — the Database must exist before anything connects to it).

```bash
git add -A && make kustomize-check && make kustomize-listing && make crd-check
```

Expected: `crd-check` reports the two new objects checked and every field declared. This is the gate that catches a mis-nested `passwordSecret`.

- [ ] **Step 3: Server-side dry-run**

```bash
make dry-run DRYRUN_CONTEXT=<admin context>
```

Expected: `apply/50-apps` OK. Skip out loud if no admin context is configured — a skipped check is honest, a vacuous one is not.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "apps: CNPG database and role for teslamate"
```

---

### Task 3: The `/.well-known` public key — the thing that unblocks registration

**Files:**
- Create: `apply/50-apps/tesla/wellknown.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: Secret `apps/tesla-wellknown` from Task 1.
- Produces: `https://tesla.titan.arrieta.eu/.well-known/appspecific/com.tesla.3p.public-key.pem` serving the PEM. Tesla re-checks this path forever; pairing fails with a misleading "application has not registered" when it 404s.

- [ ] **Step 1: Write the manifest**

A static nginx whose only route is that path, plus an Ingress path rule that wins over TeslaMate's catch-all on the same host. `pathType: Prefix` on `/.well-known` is more specific than `/`, so Traefik routes it here and everything else to TeslaMate in Task 9.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tesla-wellknown
  namespace: apps
  labels: {app: tesla-wellknown}
spec:
  replicas: 1
  selector:
    matchLabels: {app: tesla-wellknown}
  template:
    metadata:
      labels: {app: tesla-wellknown}
    spec:
      securityContext:
        runAsNonRoot: true
        # nginx-unprivileged runs as UID 101, not 1000. Verified the same way as every other
        # image in this plan — Step 2, not memory.
        runAsUser: 101
        fsGroup: 101
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:1.31.7-alpine
        ports: [{containerPort: 8080, name: http}]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: {drop: ["ALL"]}
        volumeMounts:
        - name: pubkey
          mountPath: /usr/share/nginx/html/.well-known/appspecific
          readOnly: true
        resources:
          requests: {cpu: 10m, memory: 16Mi}
          limits: {cpu: 100m, memory: 64Mi}
      volumes:
      - name: pubkey
        secret:
          secretName: tesla-wellknown
---
apiVersion: v1
kind: Service
metadata: {name: tesla-wellknown, namespace: apps}
spec:
  selector: {app: tesla-wellknown}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tesla-wellknown
  namespace: apps
spec:
  ingressClassName: traefik
  rules:
  - host: tesla.titan.arrieta.eu
    http:
      paths:
      - path: /.well-known
        pathType: Prefix
        backend: {service: {name: tesla-wellknown, port: {number: 80}}}
  tls:
  - hosts: [tesla.titan.arrieta.eu]
    secretName: titan-tls
```

- [ ] **Step 2: Verify the image's real UID before trusting 101**

```bash
kubectl --context titan -n default run uidprobe --rm -i --restart=Never \
  --image=nginxinc/nginx-unprivileged:1.31.7-alpine -- id
```

Expected: `uid=101(...) gid=101(...)`. If it differs, fix `runAsUser`/`fsGroup` here rather than letting the pod CrashLoop.

- [ ] **Step 3: Gates, then commit**

```bash
git add -A && make check-ci && git commit -m "apps: serve the Tesla application public key at /.well-known"
```

- [ ] **Step 4: After merge, prove it is public**

```bash
curl -s https://tesla.titan.arrieta.eu/.well-known/appspecific/com.tesla.3p.public-key.pem | head -1
```

Expected: `-----BEGIN PUBLIC KEY-----`. **Stop here and hand off:** the operator cannot finish app registration (spec §7 steps 1-3) until this returns a key.

---

### Task 4: Redis and fleet-telemetry behind TLS passthrough

**Files:**
- Create: `apply/50-apps/tesla/redis.yaml`
- Create: `apply/50-apps/tesla/fleet-telemetry.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: reflected Secret `apps/titan-tls` (already present).
- Produces: `tesla-redis.apps.svc:6379`; `tesla-fleet-telemetry.apps.svc:8443` terminating TLS itself; `telemetry.titan.arrieta.eu:443` passing TLS through to it. Task 6 subscribes to the Redis channels it publishes: `tesla_telemetry_V_{<VIN>}`.

- [ ] **Step 1: Write `redis.yaml`**

Ephemeral on purpose — pub/sub only, nothing to survive a restart, and a lost frame is one frame rather than a lost trip.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: tesla-redis, namespace: apps, labels: {app: tesla-redis}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: tesla-redis}}
  template:
    metadata: {labels: {app: tesla-redis}}
    spec:
      containers:
      - name: redis
        image: library/redis:8.8.3-alpine
        # No persistence: this is a hop, not a store.
        args: ["redis-server", "--save", "", "--appendonly", "no"]
        ports: [{containerPort: 6379, name: redis}]
        resources:
          requests: {cpu: 25m, memory: 64Mi}
          limits: {cpu: 250m, memory: 256Mi}
---
apiVersion: v1
kind: Service
metadata: {name: tesla-redis, namespace: apps}
spec:
  selector: {app: tesla-redis}
  ports: [{name: redis, port: 6379, targetPort: redis}]
```

- [ ] **Step 2: Find redis's real UID and set the securityContext from it**

```bash
kubectl --context titan -n default run uidprobe --rm -i --restart=Never \
  --image=library/redis:8.8.3-alpine -- id redis
```

Add `runAsNonRoot`/`runAsUser`/`fsGroup` using the UID it prints, plus `allowPrivilegeEscalation: false` and `capabilities.drop: ["ALL"]`. Do not guess: the redis image's user differs between the Debian and alpine variants.

- [ ] **Step 3: Write `fleet-telemetry.yaml`**

The config is the load-bearing part. `transmit_decoded_records: true` is what makes the Redis payload the JSON the bridge parses, and `publish_vin_topics: true` is required — the producer refuses to start with neither it nor `subscriber_set_prefix`, because nothing would be published at all.

```yaml
apiVersion: v1
kind: ConfigMap
metadata: {name: tesla-fleet-telemetry-config, namespace: apps}
data:
  config.json: |
    {
      "host": "0.0.0.0",
      "port": 8443,
      "status_port": 8080,
      "log_level": "info",
      "json_log_enable": true,
      "namespace": "tesla_telemetry",
      "transmit_decoded_records": true,
      "rate_limit": { "enabled": true, "message_interval_time": 30, "message_limit": 1000 },
      "records": { "alerts": ["logger"], "errors": ["logger"], "V": ["redis"] },
      "redis": { "addrs": ["tesla-redis:6379"], "publish_vin_topics": true },
      "tls": { "server_cert": "/etc/certs/tls.crt", "server_key": "/etc/certs/tls.key" }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: tesla-fleet-telemetry, namespace: apps, labels: {app: tesla-fleet-telemetry}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: tesla-fleet-telemetry}}
  template:
    metadata: {labels: {app: tesla-fleet-telemetry}}
    spec:
      containers:
      - name: fleet-telemetry
        image: tesla/fleet-telemetry:v0.9.5
        command: ["/fleet-telemetry", "-config=/etc/fleet-telemetry/config.json"]
        ports:
        - {containerPort: 8443, name: telemetry}
        - {containerPort: 8080, name: status}
        # /status is the only route the status server registers — verified against
        # server/monitoring/status_server.go, not guessed.
        livenessProbe:
          httpGet: {path: /status, port: status}
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet: {path: /status, port: status}
        volumeMounts:
        - {name: config, mountPath: /etc/fleet-telemetry, readOnly: true}
        - {name: certs, mountPath: /etc/certs, readOnly: true}
        resources:
          requests: {cpu: 50m, memory: 128Mi}
          limits: {cpu: 500m, memory: 512Mi}
      volumes:
      - name: config
        configMap: {name: tesla-fleet-telemetry-config}
      - name: certs
        secret: {secretName: titan-tls}
---
apiVersion: v1
kind: Service
metadata: {name: tesla-fleet-telemetry, namespace: apps}
spec:
  selector: {app: tesla-fleet-telemetry}
  ports:
  - {name: telemetry, port: 8443, targetPort: telemetry}
  - {name: status, port: 8080, targetPort: status}
---
# Passthrough, not termination: Tesla requires mTLS terminated on the telemetry service, and
# the car must see the wildcard cert directly.
#
# `passthrough` lives at spec.tls on this CRD, NOT at spec.routes[].tls — verified against the
# live ingressroutetcps.traefik.io schema on Traefik 3.7.8, where a route has only
# match/middlewares/priority/services/syntax. The v2 examples are wrong here.
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata: {name: tesla-telemetry, namespace: apps}
spec:
  entryPoints: [websecure]
  routes:
  - match: HostSNI(`telemetry.titan.arrieta.eu`)
    services:
    - name: tesla-fleet-telemetry
      port: 8443
  tls:
    passthrough: true
```

- [ ] **Step 4: Gates and commit**

```bash
git add -A && make check-ci && make dry-run DRYRUN_CONTEXT=<admin context>
git commit -m "apps: fleet-telemetry behind Traefik TLS passthrough, with the redis hop"
```

The `IngressRouteTCP` is exactly the object only the API server can reject, so the dry-run is not optional here.

- [ ] **Step 5: After merge — prove the handshake and the route**

```bash
echo | openssl s_client -connect telemetry.titan.arrieta.eu:443 -servername telemetry.titan.arrieta.eu 2>/dev/null | openssl x509 -noout -subject
kubectl --context titan -n apps logs deploy/tesla-fleet-telemetry --tail=20
```

Expected: the subject is the `*.titan.arrieta.eu` wildcard (proof Traefik passed it through rather than answering with its own default cert), and the fleet-telemetry log shows it registered the redis dispatcher.

- [ ] **Step 6: Run upstream's own server check**

From a machine with the repo cloned:

```bash
cat > /tmp/validate_server.json <<'EOF'
{"hostname":"telemetry.titan.arrieta.eu","port":443,"ca":"<the full chain that issued titan-tls>"}
EOF
./tools/check_server_cert.sh /tmp/validate_server.json
```

This is the check Tesla's own setup list names. Record the output in the runbook (Task 11).

- [ ] **Step 7: Pin the rotation hazard (Review Focus 3)**

`titan-tls` is a Reflector *copy*. When the wildcard renews, the mounted file in a running pod does not change. Prove the failure mode is understood rather than discovered:

```bash
kubectl --context titan -n apps exec deploy/tesla-fleet-telemetry -- \
  openssl x509 -in /etc/certs/tls.crt -noout -enddate
kubectl --context titan -n apps get secret titan-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate
```

Expected: the two dates match. If they ever differ, the pod needs a restart — write that into the runbook next to the renewal schedule.

---

### Task 5: The streaming bridge

**Files:**
- Create: `apply/50-apps/tesla/streaming.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: `http://tesla-streaming.apps.svc.cluster.local/` accepting PubSub-shaped POSTs, and `wss://streaming.titan.arrieta.eu/streaming/` for TeslaMate. Task 6 POSTs to it; Task 8 points `TESLA_WSS_HOST` at it.

- [ ] **Step 1: Decide `ENFORCE_TOKEN` from the source, not from a guess**

Read the subscribe handler in `index.js` upstream (`app.ws("/streaming/", …)`, the `reject` closure and the async validation block that runs on every `data:subscribe_oauth`). It decides whether the bridge validates the subscriber against Tesla's API before accepting a VIN. Record the decision and the line range in the manifest comment. Default for v1: `ENFORCE_TOKEN: "false"`, because the only client is TeslaMate inside the cluster and the hostname is public — which is precisely the argument for reading the code rather than assuming the flag is decorative.

- [ ] **Step 2: Write the manifest**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: tesla-streaming, namespace: apps, labels: {app: tesla-streaming}}
spec:
  # Stateful by design: for a given VIN the telemetry POST and the websocket must land on the
  # same pod, because the tag/lastValue state is in-memory. One replica, and Recreate so old and
  # new never overlap and misroute a VIN.
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: tesla-streaming}}
  template:
    metadata: {labels: {app: tesla-streaming}}
    spec:
      containers:
      - name: websocket
        image: ghcr.io/myteslamate/websocket:0.1.2@sha256:3d8b98e1df946d656814d428b5f0d9e2f246b55228ea0253f7884323f22f673f
        ports: [{containerPort: 8081, name: http}]
        env:
        - name: ENFORCE_TOKEN
          value: "false"
        - name: OPENTOPODATA_URL
          value: ""          # elevation enrichment off for v1 — spec §9
        livenessProbe:
          httpGet: {path: /, port: http}
          initialDelaySeconds: 5
          periodSeconds: 15
        readinessProbe:
          httpGet: {path: /, port: http}
        resources:
          requests: {cpu: 50m, memory: 128Mi}
          limits: {cpu: 500m, memory: 512Mi}
---
apiVersion: v1
kind: Service
metadata: {name: tesla-streaming, namespace: apps}
spec:
  selector: {app: tesla-streaming}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: tesla-streaming, namespace: apps}
spec:
  ingressClassName: traefik
  rules:
  - host: streaming.titan.arrieta.eu
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: {service: {name: tesla-streaming, port: {number: 80}}}
  tls: [{hosts: [streaming.titan.arrieta.eu], secretName: titan-tls}]
```

- [ ] **Step 3: Gates and commit**

```bash
git add -A && make check-ci && make dry-run DRYRUN_CONTEXT=<admin context>
git commit -m "apps: MyTeslaMate websocket bridge for fleet telemetry"
```

- [ ] **Step 4: Prove the single-replica claim (Review Focus 4)**

After merge, confirm the deployment cannot be scaled by accident and that a rollout is a clean replace:

```bash
kubectl --context titan -n apps get deploy tesla-streaming -o jsonpath='{.spec.replicas} {.spec.strategy.type}{"\n"}'
kubectl --context titan -n apps rollout restart deploy/tesla-streaming && \
  kubectl --context titan -n apps get pods -l app=tesla-streaming -w
```

Expected: `1 Recreate`, and at no point two Ready pods.

---

### Task 6: The forwarder — Redis pub/sub to the bridge

**Files:**
- Create: `apply/50-apps/tesla/forwarder.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: Redis channels `tesla_telemetry_V_{<VIN>}` from Task 4; `POST http://tesla-streaming.apps.svc.cluster.local/` from Task 5.
- Produces: for every Redis message, one `POST` whose body is `{"message":{"data":"<base64 of the raw payload bytes>"}}`. Task 9's TeslaMate receives the resulting frames over `wss://streaming.titan.arrieta.eu/streaming/`.

- [ ] **Step 1: Write the script — bytes, not text (Review Focus 1)**

The RESP parser returns **`Buffer`** for bulk strings. That is not a style choice: if `transmit_decoded_records` is ever turned off the payload is flatbuffers, and a string round-trip would corrupt it while every layer reported success.

```js
// tesla-forwarder.js — Redis pub/sub -> MyTeslaMate websocket bridge. No dependencies: raw
// RESP over net.Socket, built-in fetch, base64 by hand. That is deliberate — no image-build
// pipeline exists in this organisation, so the alternative is a registry artifact nobody owns.
'use strict';
const net = require('node:net');
const http = require('node:http');

const REDIS_HOST = process.env.REDIS_HOST || 'tesla-redis';
const REDIS_PORT = Number(process.env.REDIS_PORT || 6379);
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || '';
const PATTERN = process.env.PATTERN || 'tesla_telemetry_V_*';
const BRIDGE_URL = process.env.BRIDGE_URL || 'http://tesla-streaming.apps.svc.cluster.local/';
const HEALTH_PORT = Number(process.env.HEALTH_PORT || 8080);

let connected = false, attempts = 0, forwarded = 0, rejected = 0, lastPost = 'never';

function encode(...args) {
  let out = `*${args.length}\r\n`;
  for (const a of args) out += `$${Buffer.byteLength(a)}\r\n${a}\r\n`;
  return out;
}

// Returns [value, bytesConsumed] or null when the buffer holds an incomplete reply.
// Bulk strings come back as Buffer on purpose — see the header comment.
function read(buf, i) {
  if (i >= buf.length) return null;
  const type = String.fromCharCode(buf[i]);
  const eol = buf.indexOf('\r\n', i + 1);
  if (eol === -1) return null;
  const head = buf.toString('utf8', i + 1, eol);
  if (type === '+' || type === ':' || type === '-') return [head, eol + 2];
  if (type === '$') {
    const n = Number(head);
    if (n === -1) return [null, eol + 2];
    if (buf.length < eol + 2 + n + 2) return null;
    return [buf.subarray(eol + 2, eol + 2 + n), eol + 2 + n + 2];
  }
  if (type === '*') {
    const n = Number(head);
    const out = [];
    let p = eol + 2;
    for (let k = 0; k < n; k++) {
      const r = read(buf, p);
      if (r === null) return null;
      out.push(r[0]); p = r[1];
    }
    return [out, p];
  }
  throw new Error(`unexpected RESP type ${JSON.stringify(type)}`);
}

// Serialised: the bridge orders per VIN itself, but two in-flight POSTs can still land out of
// order, and its monotonic guard drops the older frame rather than reordering it.
let queue = Promise.resolve();
function post(payload) {
  queue = queue.then(async () => {
    try {
      const res = await fetch(BRIDGE_URL, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ message: { data: payload.toString('base64') } }),
      });
      // The bridge answers 200 even when it could not parse the body, so a non-2xx here is
      // transport, and a 2xx is NOT proof the frame was understood.
      if (!res.ok) { rejected++; lastPost = `HTTP ${res.status}`; console.error(`bridge ${res.status}`); }
      else { forwarded++; lastPost = 'ok'; }
    } catch (e) { rejected++; lastPost = e.message; console.error(`bridge unreachable: ${e.message}`); }
  });
}

function handle(v) {
  if (!Array.isArray(v)) return;
  const kind = Buffer.isBuffer(v[0]) ? v[0].toString() : v[0];
  if (kind === 'pmessage' && v.length === 4) post(v[3]);
  else if (kind === 'message' && v.length === 3) post(v[2]);
}

function connect() {
  const sock = net.connect(REDIS_PORT, REDIS_HOST);
  let buf = Buffer.alloc(0);
  sock.on('connect', () => {
    connected = true; attempts = 0;
    if (REDIS_PASSWORD) sock.write(encode('AUTH', REDIS_PASSWORD));
    sock.write(encode('PSUBSCRIBE', PATTERN));
    console.log(`subscribed redis://${REDIS_HOST}:${REDIS_PORT} ${PATTERN}`);
  });
  sock.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const r = read(buf, 0);
      if (r === null) break;
      buf = buf.subarray(r[1]);
      try { handle(r[0]); } catch (e) { console.error(`parse: ${e.message}`); buf = Buffer.alloc(0); break; }
    }
  });
  const down = (why) => {
    if (!connected) return;
    connected = false; sock.destroy();
    const wait = Math.min(30000, 1000 * 2 ** attempts++);
    console.error(`redis down (${why}); retrying in ${wait}ms`);
    setTimeout(connect, wait);
  };
  sock.on('error', (e) => down(e.message));
  sock.on('close', () => down('close'));
}

// Liveness only. Freshness of frames is NOT a liveness signal: a car asleep for six hours is
// healthy, and a probe that killed the pod overnight would be worse than no probe.
http.createServer((_req, res) => {
  const body = JSON.stringify({ connected, forwarded, rejected, lastPost });
  res.writeHead(connected ? 200 : 503, { 'content-type': 'application/json' });
  res.end(body);
}).listen(HEALTH_PORT);

connect();
```

- [ ] **Step 2: Write the Deployment**

`runAsNonRoot: true, runAsUser: 1000` **after** verifying with the same `uidprobe` pod used in Tasks 2-3:

```bash
kubectl --context titan -n default run uidprobe --rm -i --restart=Never --image=library/node:22-alpine -- id node
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata: {name: tesla-forwarder-script, namespace: apps}
data:
  tesla-forwarder.js: |
    <paste the complete script from Step 1 of this task here — the whole file, not a reference>
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: tesla-forwarder, namespace: apps, labels: {app: tesla-forwarder}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: tesla-forwarder}}
  template:
    metadata: {labels: {app: tesla-forwarder}}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: forwarder
        image: library/node:22-alpine@sha256:<digest pinned in Step 4>
        command: ["node", "/app/tesla-forwarder.js"]
        env:
        - {name: REDIS_HOST, value: tesla-redis}
        - {name: PATTERN, value: "tesla_telemetry_V_*"}
        - {name: BRIDGE_URL, value: "http://tesla-streaming.apps.svc.cluster.local/"}
        ports: [{containerPort: 8080, name: health}]
        livenessProbe:
          httpGet: {path: /, port: health}
          initialDelaySeconds: 10
          periodSeconds: 30
        volumeMounts:
        - {name: script, mountPath: /app, readOnly: true}
        resources:
          requests: {cpu: 25m, memory: 64Mi}
          limits: {cpu: 250m, memory: 192Mi}
      volumes:
      - name: script
        configMap:
          name: tesla-forwarder-script
          defaultMode: 0444
```

`node:22-alpine` is the only floating tag in this plan's inventory — no `node:22.20.x-alpine3.23` exists on Docker Hub (*verified*: the exact-patch tag 404s) — so Step 4 pins it by digest, which is the only way to make a moving alpine tag reproducible.

- [ ] **Step 3: Test the parser and the whole process before it touches a cluster**

This became `scripts/tesla-forwarder-tests.sh`, wired into `make check` and `make check-ci`, rather
than a step you run once by hand — a parser that mangles bulk strings fails silently in production,
so it needs a gate and not a checklist item. It reads the script **out of
`apply/50-apps/tesla/forwarder.yaml`**, so it tests the bytes that ship and cannot drift from them.

Two layers:

1. the RESP parser, required directly (everything above the `// Serialised:` marker is pure): full
   pmessage consumed exactly, incomplete reply returns `null`, two replies coalesced into one read
   both parsed, `+`/`:`/`-` replies, and a bulk string of `0xC3 0x28 0xA0 0x00 0xFF` surviving
   byte-for-byte. That last one is Review Focus 1 made executable.
2. the whole process, spawned for real against a fake Redis and a fake bridge on localhost, asserting
   that it PSUBSCRIBEs first, that one published record becomes exactly one `POST`, that the body is
   `{message:{data}}`, and that base64-decoding `data` reproduces the payload byte-for-byte with a
   readable `vin` — which is precisely what the bridge's `app.post("/")` needs in order to route the
   frame at all.

```bash
make tesla-forwarder-test
```

Expected: five parser assertions and one end-to-end assertion, all `ok`. Two traps this caught while
being written, both worth knowing before "simplifying" anything: array elements come back as
**`Buffer`**, so `v[0] === 'pmessage'` is false and only `v[0].toString()` works (the script's
`handle()` does this deliberately); and the fake server must build its replies with a real encoder,
because a hand-counted `$9` for `psubscribe` (ten characters) desyncs the parser — and the forwarder
correctly throws the garbage buffer away, which is the forwarder working and the test being wrong.

- [ ] **Step 4: Pin the digest, then gates and commit**

Docker is not installed on this workspace (*verified*), so resolve the digest from the registry API:
request a scoped pull token from `auth.docker.io`, `HEAD`/`GET` the manifest with the index
`Accept` types, and read `Docker-Content-Digest`. The value to pin is the **top-level** digest (the
index), not the amd64 child — the child is what you read the image `User` from, which is a different
question. Then:

```bash
git add -A && make check-ci && make dry-run DRYRUN_CONTEXT=<admin context>
git commit -m "apps: redis-to-bridge telemetry forwarder, dependency-free Node from a ConfigMap"
```

- [ ] **Step 5: After merge — prove the whole hop with a synthetic record (Review Focus 2)**

No car needed. Start a websocket subscriber, publish a record shaped like fleet-telemetry's decoded JSON, and watch it come back out:

```bash
node -e '
const WebSocket = require("ws");
const ws = new WebSocket("wss://streaming.titan.arrieta.eu/streaming/");
// data:subscribe_oauth, not data:subscribe_all. index.js rejects subscribe_all whenever the token
// fails validation *regardless* of ENFORCE_TOKEN ("Raw passthrough mode: a valid token is
// mandatory"), so the raw mode cannot be exercised without a live Tesla token. subscribe_oauth is
// what TeslaMate actually sends and what the ENFORCE_TOKEN=false grace path accepts.
ws.on("open", () => ws.send(JSON.stringify({msg_type:"data:subscribe_oauth", tag:"TESTVIN", token:"x", values:["VehicleSpeed"]})));
ws.on("message", (m) => console.log("FRAME", String(m)));
' &
kubectl --context titan -n apps exec deploy/tesla-redis -- redis-cli PUBLISH 'tesla_telemetry_V_{TESTVIN}' \
  '{"vin":"TESTVIN","createdAt":"2026-10-16T12:00:00Z","data":[{"key":"VehicleSpeed","value":{"doubleValue":42.5}}]}'
```

Expected: the subscriber prints a `FRAME` naming `TESTVIN` (preceded by a `control:hello`). If it prints nothing, read the forwarder's `/` endpoint (`kubectl exec … -- wget -qO- localhost:8080/`) — `rejected` climbing while the bridge returns 200 is the signature of a payload-shape mismatch, which is spec §9's open item and the reason this step exists.

---

### Task 7: Migrate the database

**Files:**
- Create: `scripts/migrate-teslamate-db.sh`
- Modify: `apply/50-apps/kustomization.yaml` — no change; the script is not a manifest

**Interfaces:**
- Consumes: the live `teslamate` database on techdelivery's `postgres.databases`, and the empty `teslamate` role/database from Task 2 on titan.
- Produces: a populated `teslamate` schema on titan's CNPG cluster, owned by role `teslamate`. Task 8 starts TeslaMate against it.

**Needs an admin context on both clusters.** `k8s-reader` is Forbidden on `pods/exec` in techdelivery's `databases` namespace — verified, not assumed. The source pod is labelled `app=postgres` and its container is named `postgres`; both verified against the live pod, as is titan's `postgres-1`.

**Needs an admin context on both clusters.** `k8s-reader` is Forbidden on `pods/exec` in techdelivery's `databases` namespace — verified, not assumed.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Dump teslamate from k8s-techdelivery's bare Postgres and restore it into titan's CNPG cluster.
# RUN IT, DON'T READ IT INTO A SHELL (fish has no heredocs).
#
# --no-owner --no-privileges on the restore is not cosmetic: the dump names techdelivery's roles,
# which do not exist here, and CNPG owns role creation through the DatabaseRole in git. Restoring
# with ownership intact would fail on the first ALTER OWNER.
#
# Idempotent by refusal: it aborts if the target schema already has tables, because a second run
# against a live TeslaMate would double-insert history.
set -euo pipefail
SRC=${SRC_CONTEXT:?admin context for k8s-techdelivery}
DST=${DST_CONTEXT:?admin context for k8s-titan}
DUMP=$(mktemp -d)/teslamate.dump; trap 'rm -rf "$(dirname "$DUMP")"' EXIT

src_pod=$(kubectl --context "$SRC" -n databases get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl --context "$SRC" -n databases exec "$src_pod" -- \
  pg_dump -Fc -d teslamate -U postgres > "$DUMP"

existing=$(kubectl --context "$DST" -n databases exec postgres-1 -c postgres -- \
  psql -U postgres -d teslamate -tAc "select count(*) from pg_tables where schemaname='public'")
[ "$existing" -eq 0 ] || { echo "FAIL: target already has $existing tables; refusing to double-insert"; exit 1; }

kubectl --context "$DST" -n databases exec -i postgres-1 -c postgres -- \
  pg_restore -U teslamate -d teslamate --no-owner --no-privileges < "$DUMP"
```

- [ ] **Step 2: Record the source baseline before touching anything**

```bash
kubectl --context <admin techdelivery> -n databases exec "$src_pod" -- \
  psql -U postgres -d teslamate -c "\dt+" -c \
  "select (select count(*) from drives) drives, (select count(*) from trips) trips, (select count(*) from charges) charges, (select count(*) from addresses) addresses"
```

Write the numbers down; Task 8 Step 5 asserts against them.

- [ ] **Step 3: Run it**

```bash
SRC_CONTEXT=<admin techdelivery> DST_CONTEXT=<admin titan> ./scripts/migrate-teslamate-db.sh
```

Expected: no output, exit 0. A `role teslamate is not permitted to connect` here means Task 2's `login: true` or the Secret password is wrong.

- [ ] **Step 4: Verify the copy matches**

```bash
kubectl --context <admin titan> -n databases exec postgres-1 -c postgres -- \
  psql -U teslamate -d teslamate -c \
  "select (select count(*) from drives) drives, (select count(*) from trips) trips, (select count(*) from charges) charges, (select count(*) from addresses) addresses"
```

Expected: identical to Step 2. If they differ, stop — do not proceed to Task 8 with a partial history.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "scripts: migrate the teslamate database from techdelivery into CNPG"
```

---

### Task 8: TeslaMate

**Files:**
- Create: `apply/50-apps/tesla/teslamate.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: `apps/teslamate-secrets` (Task 1), the `teslamate` database (Tasks 2, 7), `wss://streaming.titan.arrieta.eu` (Task 5).
- Produces: TeslaMate at `https://tesla.titan.arrieta.eu`, signed in against the EU Fleet API. Task 10 needs a signed-in TeslaMate, because pushing `fleet_telemetry_config` requires the owner's third-party token.

- [ ] **Step 1: Write the manifest**

```yaml
# Not a credential: the public client id of the Tesla developer application. It is a ConfigMap
# rather than a key in teslamate-secrets so `make secrets-placement` does not police a non-secret.
apiVersion: v1
kind: ConfigMap
metadata: {name: tesla-config, namespace: apps}
data:
  TESLA_AUTH_CLIENT_ID: <client id from the developer dashboard>
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: teslamate, namespace: apps, labels: {app: teslamate}}
spec:
  replicas: 1
  selector: {matchLabels: {app: teslamate}}
  template:
    metadata: {labels: {app: teslamate}}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: teslamate
        image: teslamate/teslamate:4.3.0
        ports: [{containerPort: 4000, name: http}]
        envFrom:
        - secretRef: {name: teslamate-secrets}
        env:
        - name: VIRTUAL_HOST
          value: tesla.titan.arrieta.eu
        - name: CHECK_ORIGIN
          value: "true"
        - name: TZ
          value: UTC
        - name: DISABLE_MQTT
          value: "true"          # no Home Assistant integration in v1 — spec §3 T12
        # Official Fleet API, EU region (spec §3 T3). TESLA_AUTH_CLIENT_ID is not a secret:
        # it is the public client id of the developer application.
        - name: TESLA_API_HOST
          value: https://fleet-api.prd.eu.vn.cloud.tesla.com
        - name: TESLA_AUTH_HOST
          value: auth.tesla.com
        - name: TESLA_AUTH_PATH
          value: /oauth2/v3
        - name: TESLA_AUTH_CLIENT_ID
          valueFrom: {configMapKeyRef: {name: tesla-config, key: TESLA_AUTH_CLIENT_ID}}
        - name: TESLA_WSS_HOST
          value: wss://streaming.titan.arrieta.eu
        - name: TESLA_WSS_USE_VIN
          value: "true"
        # TESLA_WSS_TLS_ACCEPT_INVALID_CERTS is deliberately absent. The bridge serves the
        # wildcard, which is publicly trusted. techdelivery's security report removed this
        # variable once; if streaming fails to connect, the cert is the bug, not this.
        #
        # Spec §3.1. Tesla's default polling (driving 2.5 s) costs about $65/month and blows the
        # free 200 device-data calls/vehicle/day cap inside one trip. These values put a typical
        # day near $8.60, inside the $10 discount. Streaming carries the realtime path; polling
        # only has to detect state transitions.
        - name: POLLING_DRIVING_INTERVAL
          value: "30"
        - name: POLLING_CHARGING_INTERVAL
          value: "60"
        - name: POLLING_ONLINE_INTERVAL
          value: "300"
        - name: POLLING_ASLEEP_INTERVAL
          value: "1800"
        - name: POLLING_DEFAULT_INTERVAL
          value: "120"
        livenessProbe:
          httpGet: {path: /, port: http}
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet: {path: /, port: http}
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits: {cpu: 600m, memory: 512Mi}
---
apiVersion: v1
kind: Service
metadata: {name: teslamate, namespace: apps}
spec:
  selector: {app: teslamate}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: teslamate, namespace: apps}
spec:
  ingressClassName: traefik
  rules:
  - host: tesla.titan.arrieta.eu
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: {service: {name: teslamate, port: {number: 80}}}
  tls: [{hosts: [tesla.titan.arrieta.eu], secretName: titan-tls}]
```

`tesla-config` is created in this task, in the same file, above the Deployment that reads it.

- [ ] **Step 2: Confirm the image's user before trusting UID 1000**

```bash
kubectl --context titan -n default run uidprobe --rm -i --restart=Never --image=teslamate/teslamate:4.3.0 -- id
```

Expected: `uid=1000`. If it differs, fix the pod `securityContext` here.

- [ ] **Step 3: Gates and commit**

```bash
git add -A && make check-ci && make dry-run DRYRUN_CONTEXT=<admin context>
git commit -m "apps: teslamate against the EU Fleet API with budgeted polling"
```

- [ ] **Step 4: After merge — sign in**

Open `https://tesla.titan.arrieta.eu`, sign in with the Tesla account. The redirect URI registered in Task 1's prerequisite step must match what the page uses — **read it from the page**, do not trust any document. Then Settings → remove the streaming toggle's default assumption: confirm streaming is enabled and pointing at the bridge.

- [ ] **Step 5: Prove the migrated history is visible, by count**

```bash
kubectl --context <admin titan> -n databases exec postgres-1 -c postgres -- \
  psql -U teslamate -d teslamate -c \
  "select (select count(*) from drives) drives, (select count(*) from trips) trips, (select count(*) from charges) charges, (select count(*) from addresses) addresses"
```

Expected: the same four numbers Task 7 Step 2 recorded. Then confirm the UI agrees — previous drives and charges render. If TeslaMate instead shows an empty onboarding, the restore did not land in the database it connected to; check `DATABASE_NAME`/`DATABASE_HOST` before believing anything else.

---

### Task 9: Grafana

**Files:**
- Create: `apply/50-apps/tesla/grafana.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: `apps/teslamate-secrets` (the dashboards read the same DB credentials), `apps/titan-tls`.
- Produces: `https://grafana.titan.arrieta.eu` with the TeslaMate dashboards.

- [ ] **Step 1: Write the manifest**

`runAsNonRoot: true, runAsUser: 1000, fsGroup: 1000` **after** the same `uidprobe` check used in Tasks 2-3, 6 and 8:

```bash
kubectl --context titan -n default run uidprobe --rm -i --restart=Never --image=teslamate/grafana:4.3.0 -- id
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: tesla-grafana-pv-claim, namespace: apps}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: tesla-grafana, namespace: apps, labels: {app: tesla-grafana}}
spec:
  # RWO PVC: a rolling update would have two pods wanting the same volume.
  strategy: {type: Recreate}
  replicas: 1
  selector: {matchLabels: {app: tesla-grafana}}
  template:
    metadata: {labels: {app: tesla-grafana}}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: grafana
        image: teslamate/grafana:4.3.0
        ports: [{containerPort: 3000, name: http}]
        env:
        - name: GF_SERVER_ROOT_URL
          value: https://grafana.titan.arrieta.eu/
        - name: GF_AUTH_ANONYMOUS_ENABLED
          value: "false"
        envFrom:
        - secretRef: {name: teslamate-secrets}
        volumeMounts:
        - {name: data, mountPath: /var/lib/grafana}
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits: {cpu: 500m, memory: 512Mi}
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: tesla-grafana-pv-claim}
---
apiVersion: v1
kind: Service
metadata: {name: tesla-grafana, namespace: apps}
spec:
  selector: {app: tesla-grafana}
  ports: [{name: http, port: 3000, targetPort: http}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: tesla-grafana, namespace: apps}
spec:
  ingressClassName: traefik
  rules:
  - host: grafana.titan.arrieta.eu
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: {service: {name: tesla-grafana, port: {number: 3000}}}
  tls: [{hosts: [grafana.titan.arrieta.eu], secretName: titan-tls}]
```

- [ ] **Step 2: Gates and commit**

```bash
git add -A && make check-ci && make dry-run DRYRUN_CONTEXT=<admin context>
git commit -m "apps: grafana for teslamate dashboards"
```

- [ ] **Step 3: After merge — prove the dashboards have data**

Open a drive dashboard. Empty panels mean the datasource could not reach `postgres.databases`, not that the drive is missing.

---

### Task 10: Point the car at the pipeline

This task is the operator's, with the exact commands. It cannot happen before Task 8, because pushing the configuration needs the owner's third-party token, which is what TeslaMate's sign-in produced.

**Files:** none in this repo.

**Interfaces:**
- Consumes: the app private key (password manager, Task 1), a signed-in TeslaMate, `telemetry.titan.arrieta.eu` answering (Task 4).
- Produces: the vehicle streaming to the self-hosted endpoint. Task 11's budget measurement depends on it.

- [ ] **Step 1: Build the vehicle-command proxy on the operator's machine**

No container image exists (*verified*: no Docker Hub repo for `teslamotors/vehicle-command`, and release v0.4.1 ships no assets), so build from source:

```bash
go install github.com/teslamotors/vehicle-command/cmd/tesla-http-proxy@v0.4.1
```

- [ ] **Step 2: Run it with the application private key**

```bash
TESLA_HTTP_PROXY_TLS_CERT=~/tesla/titan.arrieta.eu.pem \
TESLA_HTTP_PROXY_TLS_KEY=~/tesla/private-key.pem \
TESLA_HTTP_PROXY_HOST=127.0.0.1 TESLA_HTTP_PROXY_PORT=4443 \
tesla-http-proxy --insecure --server-address 127.0.0.1:4443
```

- [ ] **Step 3: Push the telemetry configuration**

`ca` is omitted, which is what tells the vehicle to trust a publicly trusted CA — the assumption spec §9 flags, and the one Task 4 Step 6's `check_server_cert.sh` output supports.

```bash
curl -sk --request POST \
  --header "Authorization: Bearer <third-party access token from TeslaMate>" \
  --header "Content-Type: application/json" \
  --data '{
    "hostname": "telemetry.titan.arrieta.eu",
    "port": 443,
    "fields": {
      "VehicleSpeed": {"interval_seconds": 10},
      "Location": {"interval_seconds": 10},
      "Soc": {"interval_seconds": 60},
      "Odometer": {"interval_seconds": 60},
      "EstBatteryRange": {"interval_seconds": 60},
      "DetailedChargeState": {"interval_seconds": 10},
      "Locked": {"interval_seconds": 10},
      "Gear": {"interval_seconds": 1},
      "CarType": {"interval_seconds": 3600},
      "Version": {"interval_seconds": 3600}
    }
  }' \
  "https://127.0.0.1:4443/api/1/vehicles/fleet_telemetry_config"
```

- [ ] **Step 4: Wait for `synced`**

```bash
curl -sk --header "Authorization: Bearer <token>" \
  "https://127.0.0.1:4443/api/1/vehicles/fleet_telemetry_config" | jq
```

Expected: `"synced": true`. Until it is, nothing downstream is evidence of anything.

- [ ] **Step 5: Watch a real frame arrive**

```bash
kubectl --context titan -n apps logs deploy/tesla-fleet-telemetry --tail=5
kubectl --context titan -n apps logs deploy/tesla-forwarder --tail=5
```

Expected: fleet-telemetry logs a connection from the VIN; the forwarder's `/` endpoint shows `forwarded` climbing.

---

### Task 11: Runbook, and the two claims that need a week

**Files:**
- Create: `docs/teslamate-runbook.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: everything above, plus a week of real driving.
- Produces: the document the next person reads instead of re-deriving this.

- [ ] **Step 1: Write the runbook**

It must contain, at minimum: the component table from spec §4; the polling values **and the arithmetic that produced them**; the `check_server_cert.sh` output from Task 4 Step 6; the `titan-tls` rotation hazard from Task 4 Step 7 with the exact two commands; the `fleet_telemetry_config` body from Task 10 Step 3 verbatim; the synthetic-record test from Task 6 Step 5; and the honest limitations — live power reads 0, no elevation, no remote commands, settings live in the database and not in git.

Also record the one thing spec §3 T14 decided *not* to fix: TeslaMate reads `teslamate-secrets` through `envFrom`, and Reloader is scoped to the `coder` namespace, so **rotating `teslamate-secrets` does not restart TeslaMate**. The rollout is manual, and saying so in the runbook is what keeps the next person from assuming the repo does it for them.

- [ ] **Step 2: Update AGENTS.md**

Two edits, no more: the backups paragraph gains "and TeslaMate's history, which lives in the same cluster", and the layout line for `apply/50-apps/` gains TeslaMate. Nothing else about TeslaMate belongs in AGENTS.md — it is one app, and the runbook is where its detail lives.

- [ ] **Step 3: Gates and commit**

```bash
git add -A && make check-ci && git commit -m "docs: teslamate runbook"
```

- [ ] **Step 4: After a week of driving — settle the budget (Review Focus 5)**

Open the Tesla developer dashboard's usage page and record, in the runbook, the actual device-data, command and wake counts and the streaming signal count. Then:

- device-data near or above 200/day → raise `POLLING_*` intervals, do not add a payment method to cover a mistake
- a bill above $0 → the discount is gone; re-derive the intervals from the measured numbers
- streaming signals large → expected and irrelevant at $1 per 150,000

Write the measured numbers into the runbook next to the predicted ones. The gap between the two is the actual content of this step.

---

## Out of scope, restated so it does not get lost

Remote commands (no standing vehicle-command proxy — Task 10 runs it once, on a laptop), Home Assistant MQTT (`DISABLE_MQTT=true`), elevation enrichment (`OPENTOPODATA_URL` empty), and live instantaneous power, which the bridge reports as 0. Each is a separate change with its own spec if it is ever wanted.
