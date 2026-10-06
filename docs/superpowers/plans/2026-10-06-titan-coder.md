# Coder on titan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Coder on titan with in-cluster workspaces that have persistent home directories, authenticated by authentik, with workspace templates held in this repo.

**Architecture:** Coder's Helm chart runs in a new `coder` namespace against a declarative per-app database on the existing CloudNativePG cluster. Workspaces are Terraform-provisioned pods in a separate `coder-workspaces` namespace, fenced by a `ResourceQuota` and a `LimitRange`, with homes on a `Retain` StorageClass. A second cert-manager `Certificate` supplies `*.coder.titan.arrieta.eu` for workspace app hostnames.

**Tech Stack:** Flux CD (HelmRelease/Kustomization), Helm, CloudNativePG 1.30.1, cert-manager + OVH DNS-01, Reflector, Traefik, sops/age, Python 3 + PyYAML for the one new gate, Terraform (coder/kubernetes providers) for the workspace template.

**Spec:** `docs/superpowers/specs/2026-10-06-titan-coder-design.md` — read it alongside every task; the manifests here argue from it.

## Global Constraints

- This repo is **public**. No credentials in any committed file, and no concrete public IPv4 — write `<OVH_PUBLIC_IP>`.
- Secrets live **only** in `apply/10-secrets/`, sops-encrypted, and every file there is listed in `apply/10-secrets/kustomization.yaml`. An unlisted Secret builds fine and is silently never applied.
- **Never** set a top-level `namespace:` in a `kustomization.yaml`. These trees span namespaces and that field rewrites them all.
- Every stage directory's `kustomization.yaml` lists its resources explicitly. Plain-directory fallback works at runtime but cannot be built offline, and offline is the only validation this repo can run.
- Namespaces are declared **only** in `apply/00-bootstrap/namespaces.yaml`.
- Coder Helm chart pinned **`2.37.4`**. No floating versions.
- Workspace sizing: **4 CPU / 8 Gi / 40 Gi** per workspace. Namespace quota: **8 CPU / 16 Gi / 80 Gi / 2 PVCs**.
- Ingress class is k3s' bundled `traefik`; its configuration is not managed here.
- Reference `titan-tls` / `coder-tls` by name from the namespace that needs it. Never copy a reflected Secret by hand.
- Run `make check` before every commit. `make validate` and the new `db-url-check` need `SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/titan-k8s-key.txt`.
- **Branch from `origin/main` explicitly**, every time: `git checkout -b <name> origin/main`. Two PRs in the previous plan were wrong because branches were cut from wherever HEAD happened to be, and squash-merges make git unable to prove content is already merged.
- The operator's shell is **fish**. `VAR=value cmd` is bash; write `env VAR=value cmd`.
- The `titan` kubectl context is the read-only `k8s-reader` ServiceAccount. It is **Forbidden** on `postgresql.cnpg.io` resources, on Secrets, and on pod `exec`. Anything touching those needs an admin context and is marked **[admin]** below.

## Review Focus

Failure modes the spec implies that no single task's happy-path test will exercise. Each line has a test in the task that owns the code.

- **A DNS record this repo does not own disappears.** `*.titan.arrieta.eu` is declared in `../public-dns-tf/titan.arrieta.eu.tf`. If it is narrowed or removed, `coder.titan.arrieta.eu` and every workspace host stop resolving at once, and no amount of Flux reconciliation will show why. Pinned by Task 5 Step 5 (resolve a workspace host as a verification step, not an assumption).
- **`Retain` is not actually honoured by local-path.** The entire no-backup decision rests on a released PV keeping its bytes. A StorageClass field that the provisioner ignores looks identical to one that works. Pinned by Task 9, which deletes a PVC and proves the bytes survive on disk.
- **The quota is absent, mis-scoped, or bypassed by unset requests.** A workspace with no `requests` is charged against the quota at the `LimitRange` default; without the `LimitRange` it is charged almost nothing and can starve the Postgres that both it and authentik depend on. Pinned by Task 4 Step 4 and Task 10.
- **OIDC-only login locks every human out.** There is no local admin by decision C6. Pinned by Task 1, which gates cutover on a documented recovery path existing at all.
- **The two copies of the database password drift apart.** Coder takes a URL, CNPG takes a basic-auth Secret, so one password is stored twice. Rotating one and not the other reads like a database outage. Pinned by Task 2, which is the gate that catches it.

---

## Task 1: Settle the OIDC lockout question before anything else

**Files:**
- Modify: `docs/superpowers/specs/2026-10-06-titan-coder-design.md` (§8.4, and §4 C6 if the answer forces it)

**Interfaces:**
- Consumes: nothing.
- Produces: a recorded recovery procedure, or a decision to add a break-glass local admin — which changes Task 7's values. **Task 7 must not start until this task is resolved.**

This is first because it can change the design, and because it is the one item the spec explicitly refused to assert. The environment this spec was written in had no web search, so the claim "coder has a documented recovery path" was never checked. Do not skip it because it looks like paperwork.

- [ ] **Step 1: Find the actual recovery procedure**

Read Coder's current documentation on OIDC/single-auth lockout. Start from `https://coder.com/docs/` and look for admin-password recovery and the `coder` CLI's user management commands. Record the exact command and the docs URL.

- [ ] **Step 2: Prove it, or record that it does not exist**

On a throwaway Coder (the cheapest is `docker run -it --rm coder/coder:latest`, which starts an embedded Postgres and no OIDC), confirm the recorded command exists and does what the docs say. If Docker is unavailable, say so in the spec rather than implying the proof happened.

- [ ] **Step 3: Write the finding into the spec**

Replace the §8.4 paragraph's "has not verified" wording with the command, the citation, and either "verified on a throwaway install" or "not verified because <reason>". If no recovery path exists, change decision C6 to include a break-glass local admin and note the change in the §15 decision record.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-10-06-titan-coder-design.md
git commit -m "docs: coder OIDC lockout recovery, verified rather than assumed"
```

---

## Task 2: `make db-url-check` — the gate for the duplicated password

**Files:**
- Create: `tools/db-url-check.py`
- Modify: `Makefile` (add the target, add it to `check`, add to `.PHONY`)

**Interfaces:**
- Consumes: `apply/10-secrets/*.yaml` (sops-encrypted or plaintext), `DatabaseRole` CRs, `HelmRelease` env lists.
- Produces: `make db-url-check`, exit 0 with `db-url-check: N PG URL reference(s) checked, 0 mismatch(es)`, or exit 1 naming each mismatch. Accepts `--root <dir>` so it can be run against a fixture tree.

Why a Python tool rather than awk in the Makefile: it has to decrypt, parse a URL, and cross-reference two CR kinds. `tools/crd-field-check.py` already established that a checker too involved for shell lives in `tools/`.

Why it is driven by references rather than by a file list: a gate that iterates "files matching `coder-*`" passes vacuously the day the app is renamed. Same reasoning as `release-secrets`.

- [ ] **Step 1: Write the failing test fixture and watch the tool not exist**

```bash
fix=$(mktemp -d)/root
mkdir -p $fix/apply/10-secrets $fix/apply/50-apps/coder
cat > $fix/apply/10-secrets/coder-secrets.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata: {name: coder-secrets, namespace: coder}
type: Opaque
stringData:
  db-url: "postgres://coder:CORRECT@postgres-rw.databases.svc.cluster.local:5432/coder?sslmode=require"
EOF
cat > $fix/apply/10-secrets/coder-db-credentials.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: coder-db-credentials
  namespace: databases
  labels: {cnpg.io/reload: "true"}
type: kubernetes.io/basic-auth
stringData:
  username: coder
  password: CORRECT
EOF
cat > $fix/apply/50-apps/coder/coder.yaml <<'EOF'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: {name: coder, namespace: coder}
spec:
  values:
    coder:
      env:
        - name: CODER_PG_CONNECTION_URL
          valueFrom:
            secretKeyRef: {name: coder-secrets, key: db-url}
EOF
cat > $fix/apply/50-apps/coder/coder-db.yaml <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata: {name: coder, namespace: databases}
spec:
  name: coder
  login: true
  passwordSecret: {name: coder-db-credentials}
EOF
echo "fixture: $fix"
python3 tools/db-url-check.py --root $fix; echo "exit=$?"
```

Expected: `python3: can't open file 'tools/db-url-check.py'` — the tool does not exist yet.

- [ ] **Step 2: Write the tool**

```python
#!/usr/bin/env python3
"""db-url-check: assert the two copies of an app's DB password agree.

Coder takes one knob, CODER_PG_CONNECTION_URL, with the password inline. CloudNativePG's
declarative role takes a kubernetes.io/basic-auth Secret. Neither can be derived from the
other at apply time, so the same password is committed twice - and rotating one and forgetting
the other produces an authentication failure that reads like a database problem.

Driven by references found in the tree, not by a filename pattern, so it cannot pass vacuously
because something was renamed. For every HelmRelease env var named *PG_CONNECTION_URL it
resolves the referenced Secret and key, parses the URL, and compares against the DatabaseRole
whose role name equals the URL's user.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that fails to decrypt is
reported, never silently skipped.
"""
import argparse, os, re, subprocess, sys, urllib.parse

try:
    import yaml
except ImportError:
    sys.exit("db-url-check: PyYAML is missing (pip install pyyaml) - refusing to report clean")


def load_docs(root):
    """Every YAML document under root, with its path. Secrets and CRs alike."""
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for fn in sorted(files):
            if not fn.endswith((".yaml", ".yml")) or fn == "kustomization.yaml":
                continue
            path = os.path.join(dirpath, fn)
            try:
                text = subprocess.run(["sops", "--decrypt", path], capture_output=True,
                                      text=True, check=True).stdout
            except subprocess.CalledProcessError:
                try:
                    text = open(path).read()
                except OSError as e:
                    sys.exit(f"db-url-check: cannot read {path}: {e}")
            if "ENC[" in text and "sops:" in text:
                sys.exit(f"db-url-check: {path} looks sops-encrypted but did not decrypt "
                         f"(is SOPS_AGE_KEY_FILE set?) - refusing to report clean")
            try:
                docs = [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
            except yaml.YAMLError as e:
                sys.exit(f"db-url-check: {path} is not valid YAML: {e}")
            for d in docs:
                d["__path__"] = path
                out.append(d)
    return docs


def secret_key(docs, name, namespace, key):
    for d in docs:
        if d.get("kind") != "Secret":
            continue
        md = d.get("metadata") or {}
        if md.get("name") != name or md.get("namespace") != namespace:
            continue
        data = (d.get("stringData") or {}) if d.get("stringData") else {}
        if not data:
            import base64
            data = {k: base64.b64decode(v).decode() for k, v in (d.get("data") or {}).items()}
        return data.get(key), data
    return None, None


def pg_url_refs(docs):
    """(helmrelease-name, namespace, secret-name, key) for every *PG_CONNECTION_URL env ref."""
    refs = []
    for d in docs:
        if d.get("kind") != "HelmRelease":
            continue
        md = d.get("metadata") or {}
        for env in (((d.get("spec") or {}).get("values") or {}).get("coder") or {}).get("env") or []:
            if not re.search(r"PG_CONNECTION_URL$", env.get("name", "")):
                continue
            ref = (env.get("valueFrom") or {}).get("secretKeyRef")
            if ref:
                refs.append((md.get("name"), md.get("namespace"), ref.get("name"), ref.get("key")))
    return refs


def roles(docs):
    out = {}
    for d in docs:
        if d.get("kind") == "DatabaseRole":
            spec = d.get("spec") or {}
            out[spec.get("name")] = (d, (spec.get("passwordSecret") or {}).get("name"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="apply")
    args = ap.parse_args()

    docs = load_docs(args.root)
    refs, roles_map, checked, bad = pg_url_refs(docs), roles(docs), 0, 0

    for hr_name, hr_ns, sec_name, key in refs:
        url, _ = secret_key(docs, sec_name, hr_ns if hr_ns else "coder", key)
        if url is None:
            print(f"FAIL: HelmRelease {hr_ns}/{hr_name} reads {sec_name}/{key}, "
                  f"which is not present under {args.root}")
            bad += 1
            continue
        u = urllib.parse.urlparse(url)
        if u.scheme not in ("postgres", "postgresql"):
            print(f"FAIL: {sec_name}/{key} is not a postgres URL (scheme {u.scheme!r})")
            bad += 1
            continue
        checked += 1
        user, password = urllib.parse.unquote(u.username or ""), urllib.parse.unquote(u.password or "")
        entry = roles_map.get(user)
        if entry is None:
            print(f"FAIL: {sec_name}/{key} connects as {user!r}, but no DatabaseRole declares "
                  f"spec.name {user!r} - the URL points at a role nothing manages")
            bad += 1
            continue
        role_doc, cred_name = entry
        role_ns = (role_doc.get("metadata") or {}).get("namespace")
        uname, cdata = secret_key(docs, cred_name, role_ns, "password")
        if cdata is None:
            print(f"FAIL: DatabaseRole {user!r} references Secret {cred_name!r} in namespace "
                  f"{role_ns!r}, which is not under {args.root}")
            bad += 1
            continue
        if cdata.get("username") != user:
            print(f"FAIL: {cred_name} username is {cdata.get('username')!r}, not {user!r} - "
                  f"CNPG sets the password for a role nobody connects as")
            bad += 1
        if password != uname:
            print(f"FAIL: password in {sec_name}/{key} does not match {cred_name} - "
                  f"rotate both or neither")
            bad += 1

    print(f"db-url-check: {checked} PG URL reference(s) checked, {bad} mismatch(es)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run it against the fixture and verify it passes**

Run: `python3 tools/db-url-check.py --root $fix; echo "exit=$?"`
Expected: `db-url-check: 1 PG URL reference(s) checked, 0 mismatch(es)` and `exit=0`.

- [ ] **Step 4: Verify it fails on each drift it claims to catch**

Three mutations, each must exit 1 with the named reason. Restore the fixture between them.

```bash
# a) the two copies disagree
sed -i 's/password: CORRECT/password: ROTATED-BUT-ONLY-HERE/' $fix/apply/10-secrets/coder-db-credentials.yaml
python3 tools/db-url-check.py --root $fix; echo "exit=$? (want 1)"
sed -i 's/password: ROTATED-BUT-ONLY-HERE/password: CORRECT/' $fix/apply/10-secrets/coder-db-credentials.yaml

# b) the URL names a role nothing manages
sed -i 's#postgres://coder:#postgres://stray:#' $fix/apply/10-secrets/coder-secrets.yaml
python3 tools/db-url-check.py --root $fix; echo "exit=$? (want 1)"
sed -i 's#postgres://stray:#postgres://coder:#' $fix/apply/10-secrets/coder-secrets.yaml

# c) the basic-auth username does not match the role
sed -i 's/username: coder/username: coder_typo/' $fix/apply/10-secrets/coder-db-credentials.yaml
python3 tools/db-url-check.py --root $fix; echo "exit=$? (want 1)"
sed -i 's/username: coder_typo/username: coder/' $fix/apply/10-secrets/coder-db-credentials.yaml
python3 tools/db-url-check.py --root $fix; echo "exit=$? (want 0 again)"
```

- [ ] **Step 5: Wire it into the Makefile**

Add to the `.PHONY` list on line 5: `db-url-check`. Add the target after `crd-check`:

```make
# Offline gate, needs the age key, so it joins `check` and never `check-ci`.
# Coder takes a single CODER_PG_CONNECTION_URL with the password inline and CloudNativePG
# takes a kubernetes.io/basic-auth Secret; neither can be derived from the other, so the same
# password is committed twice. Rotating one and forgetting the other reads as a database
# outage. Driven by references found in the tree, so renaming the app cannot make this pass
# vacuously - it prints how many references it checked, and 0 is visible rather than silent.
db-url-check:
	@command -v python3 >/dev/null 2>&1 \
	  || { echo "db-url-check: python3 is missing - refusing to report clean"; exit 1; }; \
	python3 -c 'import yaml' >/dev/null 2>&1 \
	  || { echo "db-url-check: PyYAML is missing (pip install pyyaml) - refusing to report clean"; exit 1; }; \
	python3 tools/db-url-check.py --root apply
```

Add it to the `check` prerequisite list (after `crd-check`). Do **not** add it to `check-ci` — it needs the age key, and a gate that needs a secret is a gate that gets skipped.

- [ ] **Step 6: Verify the gate runs on the real tree and reports zero honestly**

Run: `make db-url-check`
Expected before coder lands: `db-url-check: 0 PG URL reference(s) checked, 0 mismatch(es)`. Zero is legitimate here and the count makes it visible rather than silent.

- [ ] **Step 7: Commit**

```bash
git add tools/db-url-check.py Makefile
git commit -m "make: db-url-check, so the coder DB password cannot drift between its two copies"
```

---

## Task 3: Namespaces and the `Retain` StorageClass

**Files:**
- Modify: `apply/00-bootstrap/namespaces.yaml`
- Create: `apply/20-infra/storage-retain.yaml`
- Modify: `apply/20-infra/kustomization.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: namespaces `coder` and `coder-workspaces`; StorageClass `local-path-retain`. Task 4 and Task 7 reference both by name.

- [ ] **Step 1: Read the existing StorageClass instead of guessing at its parameters**

```bash
kubectl --context titan get sc local-path -o yaml | grep -vE '^\s+(resourceVersion|uid|creationTimestamp):'
kubectl --context titan -n kube-system get cm local-path-config -o yaml | sed -n '/data:/,$p'
```

Record what you see. k3s' local-path reads the `local-path-config` ConfigMap in `kube-system` rather than StorageClass parameters, so a second StorageClass using the same provisioner writes to the same `nodePath` — which is exactly what we want, and exactly the kind of thing not to assert from memory.

- [ ] **Step 2: Add the two namespaces**

Append to `apply/00-bootstrap/namespaces.yaml`, matching the file's existing style:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: coder
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
---
# Workspaces only. Coder's provisioner RBAC is scoped to this namespace and to nothing
# else, which is what makes it safe to hand a workload pod-creation rights at all.
apiVersion: v1
kind: Namespace
metadata:
  name: coder-workspaces
```

Do not put `pod-security: restricted` on `coder-workspaces` in this task — coder injects pods itself and may need capabilities the restricted profile denies. Verify the enforced profile in Task 8 before adding it, or leave it off and say so.

- [ ] **Step 3: Write the StorageClass**

`apply/20-infra/storage-retain.yaml`:

```yaml
# Same provisioner and same node path as k3s' default `local-path`, with one field changed:
# reclaimPolicy Retain. Workspace homes are NOT backed up (spec C2), so the realistic data-loss
# accident is not disk failure, it is `kubectl delete pvc` - which against `Delete` runs a
# helper pod that rm -rf's the directory. Retain turns that into "recreate the PV object and
# the bytes are still there".
#
# This is a deletion mitigation, not a backup, and spec §13 says so. Task 9 proves the provisioner
# actually honours it rather than assuming a field is obeyed because it was written.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path-retain
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: false
```

If Step 1 showed the default SC carries `parameters:`, copy them verbatim into a `parameters:` block here and note why in the comment.

- [ ] **Step 4: List it and build**

Add `- storage-retain.yaml` to `apply/20-infra/kustomization.yaml`'s `resources:`.

Run: `make kustomize-check && kubectl kustomize apply/20-infra | grep -c 'name: local-path-retain'`
Expected: all builds OK, then `1`.

- [ ] **Step 5: Commit**

```bash
git add apply/00-bootstrap/namespaces.yaml apply/20-infra/storage-retain.yaml apply/20-infra/kustomization.yaml
git commit -m "infra: coder namespaces and a Retain StorageClass for unbacked workspace homes"
```

---

## Task 4: Quota, limit range, and coder's scoped RBAC

**Files:**
- Create: `apply/50-apps/coder/workspaces.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: namespaces from Task 3.
- Produces: `ResourceQuota coder-workspaces`, `LimitRange coder-workspaces`, `Role coder-workspace-provisioner` in `coder-workspaces` bound to ServiceAccount `coder` in namespace `coder`. Task 7's HelmRelease must use serviceAccount name `coder`.

- [ ] **Step 1: Write the quota and the default that makes the quota real**

`apply/50-apps/coder/workspaces.yaml`:

```yaml
# Two workspaces at 4 CPU / 8 Gi / 40 Gi, and nothing more. The quota is not tidiness: a
# coder workspace is the first thing on this cluster that can request arbitrary CPU from a
# node that also runs the Postgres that both coder and authentik depend on. A third workspace
# must sit Pending - a legible failure - rather than squeeze the database into a slow
# degradation nobody can attribute.
#
# requests.storage sums PVC requests in the namespace; persistentvolumeclaims caps the count
# so two half-built workspaces cannot quietly become five.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: coder-workspaces
  namespace: coder-workspaces
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    persistentvolumeclaims: "2"
    requests.storage: 80Gi
---
# The quota is charged against *requests*, and an unset request is a small one. Without this
# LimitRange a workspace that declares nothing is charged almost nothing and the quota above
# stops meaning anything. Defaults are half the per-workspace budget so a template that
# declares nothing still fits two at a time.
apiVersion: v1
kind: LimitRange
metadata:
  name: coder-workspaces
  namespace: coder-workspaces
spec:
  limits:
    - type: Container
      default:
        cpu: 2000m
        memory: 4Gi
      defaultRequest:
        cpu: 500m
        memory: 1Gi
    - type: PersistentVolumeClaim
      default:
        storage: 40Gi
```

- [ ] **Step 2: Write the scoped RBAC**

Append to the same file:

```yaml
# Coder's Kubernetes provider needs to create pods, PVCs and services. That capability is
# fenced to coder-workspaces and bound to the coder server's own ServiceAccount - it cannot
# reach databases or auth, which is the property that makes granting it acceptable at all.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: coder-workspace-provisioner
  namespace: coder-workspaces
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "persistentvolumeclaims", "services", "secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: coder-workspace-provisioner
  namespace: coder-workspaces
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: coder-workspace-provisioner
subjects:
  - kind: ServiceAccount
    name: coder
    namespace: coder
```

- [ ] **Step 3: Check what the chart does to RBAC on its own before assuming**

```bash
helm repo add coder https://helm.coder.com/v2 && helm repo update
helm show values coder --version 2.37.4 > /tmp/coder-values.yaml
grep -nE 'rbacCreate|serviceAccount|persistence|^  env:|securityContext' /tmp/coder-values.yaml
```

Record whether the chart creates its own RBAC in the release namespace (`rbacCreate`) and what the default ServiceAccount is called. If the default SA is not named `coder`, either set the chart's service-account name to `coder` in Task 7 or change the RoleBinding subject here — and say which in the commit message.

- [ ] **Step 4: Verify the quota would actually reject a third workspace, offline**

There is no cluster-side test available to `k8s-reader`, so assert the arithmetic instead:

```bash
kubectl kustomize apply/50-apps | python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
q = next(d for d in docs if d["kind"] == "ResourceQuota")
hard = q["spec"]["hard"]
assert int(hard["requests.cpu"]) == 4 * 2, hard
assert hard["requests.memory"] == "16Gi" and hard["requests.storage"] == "80Gi"
lr = next(d for d in docs if d["kind"] == "LimitRange")
assert lr["spec"]["limits"][0]["defaultRequest"]["cpu"], "LimitRange must set defaultRequest"
print("quota: 2 x (4 CPU / 8Gi / 40Gi) and a LimitRange default that makes the quota real")
'
```

Expected: the printed line, exit 0. Task 10 proves the same thing against the live API server.

- [ ] **Step 5: Build, then commit**

Add `- coder/workspaces.yaml` to `apply/50-apps/kustomization.yaml` (before the HelmRelease entry).

```bash
make kustomize-check
git add apply/50-apps/coder/workspaces.yaml apply/50-apps/kustomization.yaml
git commit -m "apps: coder-workspaces quota, limit range, and provisioner RBAC fenced to one namespace"
```

---

## Task 5: The `coder-wildcard` certificate

**Files:**
- Create: `apply/40-certificates/coder-wildcard.yaml`
- Modify: `apply/40-certificates/kustomization.yaml`

**Interfaces:**
- Consumes: `ClusterIssuer le-prod-titan` (already live), Reflector (already live).
- Produces: Secret `coder-tls` in namespace `coder`, kept current by Reflector. Task 7's Ingress references it by name.

- [ ] **Step 1: Confirm the DNS dependency is still what the spec says**

```bash
curl -s "https://dns.google/resolve?name=x.coder.titan.arrieta.eu&type=A" | python3 -m json.tool | head
```

Expected: `"Status": 0` with an `Answer`. If it is NXDOMAIN, stop: `../public-dns-tf` changed, and spec §7's dependency has broken. Do not add a record in the OVH console.

- [ ] **Step 2: Write the Certificate**

`apply/40-certificates/coder-wildcard.yaml`:

```yaml
# A second wildcard, deliberately not a third dnsName on titan-wildcard (spec C4). Adding it
# there would mean editing the reflector allow-list that AGENTS.md treats as the controlled
# mechanism, and every coder renewal would reissue the whole cluster wildcard.
#
# DNS needs nothing: ../public-dns-tf declares `*.titan` as an A record, and OVH's wildcard
# answers at any depth, so `x.coder.titan.arrieta.eu` already resolves. What DNS gives us and
# X.509 does not is label depth - a certificate wildcard matches exactly one label, which is
# why the existing `*.titan.arrieta.eu` cannot serve workspace hosts.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: coder-wildcard
  namespace: certificates
spec:
  secretName: coder-tls
  issuerRef:
    kind: ClusterIssuer
    name: le-prod-titan
  commonName: coder.titan.arrieta.eu
  dnsNames:
    - coder.titan.arrieta.eu
    - "*.coder.titan.arrieta.eu"
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "coder"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "coder"
```

- [ ] **Step 3: Build and assert the allow-list is the narrow one**

```bash
kubectl kustomize apply/40-certificates | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d["kind"] == "Certificate" and d["metadata"]["name"] == "coder-wildcard":
        a = d["spec"]["secretTemplate"]["annotations"]
        assert a["reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces"] == "coder"
        assert d["spec"]["dnsNames"] == ["coder.titan.arrieta.eu", "*.coder.titan.arrieta.eu"]
        print("coder-wildcard: SANs and a coder-only reflector allow-list")
'
```

Expected: the printed line. Also confirm `titan-wildcard.yaml` is untouched: `git diff --name-only` must not list it.

- [ ] **Step 4: Commit**

```bash
git add apply/40-certificates/coder-wildcard.yaml apply/40-certificates/kustomization.yaml
git commit -m "certificates: coder-wildcard, so workspace hosts get a matching SAN"
```

- [ ] **Step 5: After merge, prove it issued**

```bash
kubectl --context titan -n certificates get certificate coder-wildcard
kubectl --context titan -n coder get secret coder-tls   # [admin] - k8s-reader is Forbidden on Secrets
openssl s_client -connect coder.titan.arrieta.eu:443 -servername coder.titan.arrieta.eu </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
```

Expected: `Ready True`, the Secret present in `coder` only, and a SAN list containing `*.coder.titan.arrieta.eu`.

---

## Task 6: Coder's database, and the two Secrets

**Files:**
- Create: `apply/50-apps/coder/coder-db.yaml`
- Create: `apply/10-secrets/coder-secrets.yaml`, `apply/10-secrets/coder-db-credentials.yaml` (via git-ignored staging + sops)
- Modify: `apply/50-apps/kustomization.yaml`, `apply/10-secrets/kustomization.yaml`

**Interfaces:**
- Consumes: `Cluster postgres` in `databases`; the age key for sops.
- Produces: role `coder` + database `coder`; Secrets `coder-db-credentials` (ns `databases`) and `coder-secrets` (ns `coder`). Task 7 consumes `coder-secrets/db-url`, `oidc-client-id`, `oidc-client-secret`. Task 2's gate consumes the pair.

- [ ] **Step 1: Operator creates the authentik application and the DB password**

Two manual prerequisites, both outside git, both recorded here rather than implied:

1. In authentik, create an Application `coder` and an OAuth2/OIDC Provider for it. Note the client ID and secret. Issuer path is `https://auth.titan.arrieta.eu/application/o/coder/`.
2. Generate the coder DB password once, and use the **same value** in both files in Step 3. Task 2's gate is what enforces that afterwards.

Never paste either value into a chat or an agent transcript — `docs/authentik-runbook.md` §1 records why that sentence is in this repo.

- [ ] **Step 2: Write the CRs**

`apply/50-apps/coder/coder-db.yaml`, mirroring `auth/authentik-db.yaml` including its reasoning:

```yaml
# Coder's database and role, authored next to the app that owns them. Both live in `databases`:
# a CNPG Database must share a namespace with its Cluster, so "where the app lives" loses to
# "where the cluster lives".
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: coder
  namespace: databases
spec:
  name: coder
  owner: coder
  cluster:
    name: postgres
---
# Exactly one DatabaseRole for this role, and `login: true` is not optional - CNPG has no
# default for `login`, so without it the role is created NOLOGIN and every connection fails
# with a message pointing somewhere else. See auth/authentik-db.yaml for the live trace.
#
# The cnpg.io/reload label belongs on the referenced Secret, not here. It is on
# coder-db-credentials in apply/10-secrets/, where it actually works.
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: coder
  namespace: databases
spec:
  name: coder
  cluster:
    name: postgres
  login: true
  passwordSecret:
    name: coder-db-credentials
```

- [ ] **Step 3: Create the two Secrets with the staging-and-sops pattern**

Use the same shape `scripts/rotate-s3-backup-key.sh` uses: write to a git-ignored `.staging.*.yaml` under `apply/10-secrets/` so `.sops.yaml`'s `path_regex` picks the right recipients, encrypt in place, then move.

```fish
set stage apply/10-secrets/.staging.coder.yaml
cat > $stage <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: coder-secrets
  namespace: coder
type: Opaque
stringData:
  db-url: "postgres://coder:PASSWORD@postgres-rw.databases.svc.cluster.local:5432/coder?sslmode=require"
  oidc-client-id: "PASTE"
  oidc-client-secret: "PASTE"
EOF
sops --encrypt --in-place $stage
mv $stage apply/10-secrets/coder-secrets.yaml
```

Repeat for `coder-db-credentials.yaml`, which must be `kubernetes.io/basic-auth` and carry the reload label:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: coder-db-credentials
  namespace: databases
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: coder
  password: PASSWORD
```

- [ ] **Step 4: List both, and let the placement gate do its job**

Add both files to `apply/10-secrets/kustomization.yaml`, and `coder/coder-db.yaml` to `apply/50-apps/kustomization.yaml` **before** the HelmRelease entry.

Run: `make secrets-placement && make db-url-check`
Expected: placement OK; `db-url-check: 0 PG URL reference(s) checked, 0 mismatch(es)` — the HelmRelease does not exist yet, so zero is correct and is printed as zero.

- [ ] **Step 5: Verify the pair actually agrees, with the gate pointed at the real tree**

Run: `make db-url-check` after Task 7 Step 3 lands the reference. If you are doing Task 6 alone, prove the pair now with the fixture from Task 2 pointed at `apply`:

```bash
python3 tools/db-url-check.py --root apply; echo "exit=$? (want 0, 0 references until Task 7)"
```

- [ ] **Step 6: Commit**

```bash
git add apply/50-apps/coder/coder-db.yaml apply/50-apps/kustomization.yaml \
        apply/10-secrets/coder-secrets.yaml apply/10-secrets/coder-db-credentials.yaml \
        apply/10-secrets/kustomization.yaml
git commit -m "apps: coder's database, role, and the two Secrets that must agree"
```

---

## Task 7: The HelmRelease and Ingress

**Files:**
- Create: `apply/50-apps/coder/coder.yaml`
- Modify: `apply/50-apps/kustomization.yaml`

**Interfaces:**
- Consumes: `coder-tls` (Task 5), `coder-secrets` (Task 6), ServiceAccount name `coder` (Task 4's RoleBinding), StorageClass `local-path-retain` (Task 3).
- Produces: a running Coder at `https://coder.titan.arrieta.eu/`. Task 8 consumes it.

- [ ] **Step 1: Confirm the chart's value names before writing them**

```bash
sed -n '1,80p' /tmp/coder-values.yaml
grep -n 'coder:\|env:\|service:\|resources:\|rbacCreate\|serviceAccount' /tmp/coder-values.yaml
```

Do not write values from memory. If `serviceAccount` differs from `coder`, reconcile it against Task 4's RoleBinding subject and say which way you resolved it.

- [ ] **Step 2: Write the HelmRelease and both Ingress rules**

`apply/50-apps/coder/coder.yaml` — follow `auth/authentik.yaml` for the HelmRelease skeleton (HelmRepository, `install`/`upgrade` remediation retries, `interval`):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: coder-repo
  namespace: coder
spec:
  interval: 12h
  url: https://helm.coder.com/v2
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: coder
  namespace: coder
spec:
  interval: 30m
  chart:
    spec:
      chart: coder
      version: 2.37.4        # pinned; casa runs 2.35.1 and the index says 2.37.4 is current
      sourceRef:
        kind: HelmRepository
        name: coder-repo
        namespace: coder
  install:
    remediation: {retries: 3}
  upgrade:
    remediation: {retries: 3}
  values:
    coder:
      env:
        - name: CODER_ACCESS_URL
          value: "https://coder.titan.arrieta.eu"
        - name: CODER_WILDCARD_ACCESS_URL
          value: "https://*.coder.titan.arrieta.eu"
        - name: CODER_PG_CONNECTION_URL
          valueFrom:
            secretKeyRef: {name: coder-secrets, key: db-url}
        - name: CODER_OIDC_ISSUER_URL
          value: "https://auth.titan.arrieta.eu/application/o/coder/"
        - name: CODER_OIDC_CLIENT_ID
          valueFrom:
            secretKeyRef: {name: coder-secrets, key: oidc-client-id}
        - name: CODER_OIDC_CLIENT_SECRET
          valueFrom:
            secretKeyRef: {name: coder-secrets, key: oidc-client-secret}
        - name: CODER_OIDC_EMAIL_FIELD
          value: email
        - name: CODER_OIDC_USERNAME_FIELD
          value: preferred_username
        - name: CODER_OIDC_SCOPES
          value: openid,profile,email,offline_access
        - name: CODER_OIDC_IGNORE_EMAIL_VERIFIED
          value: "true"
      resources:
        requests: {cpu: 100m, memory: 512Mi}
        limits: {cpu: 2000m, memory: 1024Mi}
      service:
        enabled: true
        type: ClusterIP
---
# Two rules, one host each. The wildcard rule is what makes C5's payoff real: workspace apps
# get a hostname each instead of a path, which is the difference between a preview port that
# works and one that emits an absolute redirect and lands on the wrong origin.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: coder
  namespace: coder
spec:
  ingressClassName: traefik
  rules:
    - host: coder.titan.arrieta.eu
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: coder, port: {number: 80}}
    - host: "*.coder.titan.arrieta.eu"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: coder, port: {number: 80}}
  tls:
    - hosts: [coder.titan.arrieta.eu, "*.coder.titan.arrieta.eu"]
      secretName: coder-tls
```

If Step 1 shows the chart can manage its own Ingress, prefer the plain Ingress object above anyway, and note why: the chart's Ingress would not carry the wildcard rule and the `coder-tls` reference in the shape this repo controls.

- [ ] **Step 3: Verify the gate now sees the reference, and everything still builds**

```bash
make check
kubectl kustomize apply/50-apps | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d["kind"] == "HelmRelease" and d["metadata"]["name"] == "coder":
        env = {e["name"]: e for e in d["spec"]["values"]["coder"]["env"]}
        assert "CODER_WILDCARD_ACCESS_URL" in env
        assert env["CODER_PG_CONNECTION_URL"]["valueFrom"]["secretKeyRef"]["key"] == "db-url"
        print("coder HelmRelease: wildcard URL set, DB URL from coder-secrets/db-url")
'
```

Expected: `make check` green **including** `db-url-check: 1 PG URL reference(s) checked, 0 mismatch(es)` — this is the task where the gate stops being theoretical. Then the printed line.

- [ ] **Step 4: Commit, merge, and verify against the cluster**

```bash
git add apply/50-apps/coder/coder.yaml apply/50-apps/kustomization.yaml
git commit -m "apps: coder server, OIDC through authentik, wildcard workspace hosts"
```

After merge:

```bash
kubectl --context titan -n coder get helmrelease coder
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://coder.titan.arrieta.eu/
```

Expected: HelmRelease `Ready True`; a 200 or a redirect to a login path. Then log in as `akadmin` through authentik — that is spec §12.2 step 5, and it is a human action, not a curl.

---

## Task 8: The workspace template, in git

**Files:**
- Create: `coder/templates/dev/main.tf`
- Create: `coder/templates/README.md`

**Interfaces:**
- Consumes: `coder-workspaces` namespace, `local-path-retain`, coder's scoped RBAC.
- Produces: template `dev` pushed to coder, creating one pod with a 40 Gi home.

- [ ] **Step 1: Write the template**

`coder/templates/dev/main.tf`:

```hcl
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 1.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23.0"
    }
  }
}

provider "coder" {}
provider "kubernetes" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# 40 Gi on the Retain class. This is the resource the spec's whole accepted-risk argument is
# about: it is not backed up, and Retain is what stands between a wrong `kubectl delete pvc`
# and a lost home directory.
resource "kubernetes_persistent_volume_claim_v1" "home" {
  wait_for_bound = true
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = "coder-workspaces"
    labels = {
      creator = data.coder_workspace_owner.me.name
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path-retain"
    resources {
      requests = { storage = "40Gi" }
    }
  }
}

resource "coder_agent" "dev" {
  os             = "linux"
  startup_script = <<-EOT
    set -eu
    mkdir -p /home/coder/.coder
    echo "workspace up"
  EOT
  metadata {
    display_name = "resource"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10000
    timeout      = 10000
  }
}

resource "kubernetes_pod_v1" "dev" {
  wait_for_rollout = false
  wait_for_delete  = false
  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = "coder-workspaces"
    labels = {
      app     = "coder-workspace"
      coder   = "true"
      creator = data.coder_workspace_owner.me.name
    }
  }
  spec {
    # The quota is charged against requests. These are the per-workspace budget from spec §9.1
    # (4 CPU / 8 Gi); two of these plus the quota of 8 CPU / 16 Gi is the whole point.
    container {
      name  = "dev"
      image = "alpine:3.20"
      command = ["sh", "-c", "while true; do sleep 3600; done"]
      working_dir = "/home/coder"
      resources {
        requests = { cpu = "4000m", memory = "8Gi" }
        limits   = { cpu = "4000m", memory = "8Gi" }
      }
      volume_mount {
        name      = "home"
        mount_path = "/home/coder"
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.dev.token
      }
    }
    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      }
    }
  }
}

resource "coder_metadata" "home" {
  resource_id = kubernetes_persistent_volume_claim_v1.home.id
  item {
    key   = "storage class"
    value = "local-path-retain (Retain: a deleted PVC keeps its bytes)"
  }
}
```

- [ ] **Step 2: Record the push command and the drift it implies**

`coder/templates/README.md`:

```markdown
# coder workspace templates

Source of truth for Coder workspace templates. Nothing here is applied by Flux: Coder holds
its own copy of a template version, and a template is only live once it is pushed.

    coder templates push dev -d coder/templates/dev

**Accepted gap (spec C7).** Git is the source of truth and nothing enforces it. Editing a
template in Coder's UI drifts it from this directory and no gate notices. The diagnostic is
that Coder reports which template version a workspace is running, so a failed build points at
the discrepancy - that is a diagnostic, not a prevention. Automatic push is deferred, spec §14.
```

- [ ] **Step 3: Push, and let coder validate what terraform would have**

```bash
coder templates push dev -d coder/templates/dev --yes
```

Expected: the push succeeds. Coder provisions the template server-side; a provider-schema error surfaces here rather than at workspace start, which is the cheapest place this repo can catch it.

- [ ] **Step 4: Create one workspace and verify the PVC**

```bash
coder create dev --template dev
kubectl --context titan -n coder-workspaces get pvc,pod -o wide
kubectl --context titan -n coder-workspaces get pvc -o jsonpath='{range .items[*]}{.metadata.name}{" sc="}{.spec.storageClassName}{" phase="}{.status.phase}{"\n"}{end}'
```

Expected: PVC `Bound`, `storageClassName=local-path-retain`, pod `Running`.

- [ ] **Step 5: Verify a workspace app gets a wildcard hostname with a valid chain**

Start something on a port inside the workspace (`python3 -m http.server 8080`), expose it as a coder app on port 8080, then **read the URL coder actually assigned** from `coder show <workspace>` or the UI rather than guessing the hostname format — coder's wildcard hostname layout is the chart's business, not this plan's. Then verify the chain for that host:

```fish
set host (coder show dev -o json | python3 -c 'import sys,json; print(json.load(sys.stdin)["apps"][0]["url"])')
echo | openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
```

Expected: a certificate whose SAN contains `*.coder.titan.arrieta.eu`, and the page served over HTTPS. This is decision C5's payoff and it is observed here, not inferred from config.

- [ ] **Step 6: Commit**

```bash
git add coder/templates
git commit -m "coder: dev workspace template in git, 40Gi home on the Retain class"
```

---

## Task 9: Prove `Retain` actually preserves bytes

**Files:**
- Modify: `docs/superpowers/specs/2026-10-06-titan-coder-design.md` (§9.2 — record the observed result)

**Interfaces:**
- Consumes: Task 3's StorageClass, Task 8's workspace.
- Produces: a verified claim, or a design correction. **Nothing downstream may cite `Retain` as a mitigation until this task passes.**

- [ ] **Step 1: Write a marker into a workspace home**

```fish
set pod (kubectl --context titan -n coder-workspaces get pod -l app=coder-workspace -o jsonpath='{.items[0].metadata.name}')
kubectl --context titan -n coder-workspaces exec $pod -- sh -c 'echo marker-proves-retain > /home/coder/RETAIN-PROOF; cat /home/coder/RETAIN-PROOF'
```

Pod `exec` needs the admin context — `k8s-reader` cannot do it. Note which context you used.

- [ ] **Step 2: Find the backing directory on the node**

```bash
kubectl --context titan -n coder-workspaces get pvc -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.volumeName}{"\n"}{end}'
```

The local-path directory is `<nodePath>/<volumeName>`, where `<nodePath>` is what Task 3 Step 1 read out of `kube-system/local-path-config`. List it on titan and confirm the marker file is there.

- [ ] **Step 3: Delete the PVC and the released PV, then look again**

```bash
kubectl --context titan -n coder-workspaces delete pvc <the-home-pvc>
kubectl --context titan get pv <volumeName>    # [admin] expect Released, not gone
# then list the node directory again
```

Expected: the directory and `RETAIN-PROOF` still exist on disk. **If they are gone, local-path ignored `Retain`, decision C3 is wrong, and the spec's accepted-risk section gets worse — stop and rewrite §9.2 and §13 rather than continuing.**

- [ ] **Step 4: Record the result in the spec**

Add to §9.2 the observed volume name, the directory, and the outcome, dated. A mitigation believed but unproven is the failure mode this project has now caught repeatedly; this step is why it exists.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-10-06-titan-coder-design.md
git commit -m "docs: the Retain proof - a deleted PVC keeps its bytes, observed not assumed"
```

---

## Task 10: Prove the quota bites

**Files:**
- Modify: `docs/superpowers/specs/2026-10-06-titan-coder-design.md` (§12.2 — record the observed `Pending` reason)

- [ ] **Step 1: Create a third workspace**

```bash
coder create dev3 --template dev
kubectl --context titan -n coder-workspaces get pod -w
```

- [ ] **Step 2: Verify it is Pending for the quota reason, not something else**

```bash
kubectl --context titan -n coder-workspaces describe pod coder-dev3 | grep -A5 "Events\|FailedScheduling"
```

Expected: a message naming `exceeded quota` with the resource that ran out. If it schedules anyway, the quota is not being charged — check whether the template declares `requests` at all, and whether the `LimitRange` default is being applied.

- [ ] **Step 3: Clean up and record**

```bash
coder delete dev3
```

Record the observed event text in spec §12.2, then commit:

```bash
git add docs/superpowers/specs/2026-10-06-titan-coder-design.md
git commit -m "docs: the workspace quota bites - third workspace Pending, with the event text"
```

---

## Task 11: Prove coder's database restores

**Files:**
- Modify: `docs/authentik-runbook.md` (§2 — add coder to the list of things the drill has proven)

- [ ] **Step 1: Run the drill against a row coder wrote, in the mandated form**

The runbook forbids `count(*)` assertions because they return one row on an empty database. Use a named row:

```fish
env SEED=0 CHECK_DB=coder \
  CHECK_SQL="select email from users where email='akadmin@arrieta.eu'" \
  EXPECT=akadmin@arrieta.eu ./scripts/restore-drill.sh
```

Adjust the table and column to what coder 2.37 actually uses — verify with `\dt` and `\d users` against the restored scratch database rather than trusting this line. A wrong table name is exactly the bug that made the authentik drill fail silently once.

- [ ] **Step 2: Confirm the drill's own PASS wording is honest**

Expected output ends with `PASS: restored value matches the expected value ...`. If it reports a mismatch, the restore did not carry coder's data and the drill needs the same scrutiny Task 9 of the previous plan applied.

- [ ] **Step 3: Record and commit**

Paste the green output verbatim into the runbook's drill section, note that coder's *configuration* is covered while workspace homes are not, and commit:

```bash
git add docs/authentik-runbook.md
git commit -m "docs: the restore drill covers coder's database"
```

---

## Task 12: Record the second uncompensated override

**Files:**
- Modify: `docs/superpowers/specs/2026-10-03-titan-authentik-cnpg-design.md` (§12 row for general PV backups)
- Modify: `docs/superpowers/specs/2026-10-03-k8s-titan-flux-bootstrap-design.md` (§13b row)
- Modify: `AGENTS.md` (backups paragraph)
- Modify: `docs/superpowers/specs/2026-10-06-titan-coder-design.md` (§13 — mark done)

- [ ] **Step 1: Amend both spec tables**

In each, the general-PV-backup row must now say: the trigger has fired a **second** time (coder workspace homes), and unlike the first override this one is **uncompensated** — the Postgres override was compensated when the S3 path landed; this one has no compensation, and `local-path-retain` is a deletion mitigation, not a backup.

- [ ] **Step 2: Amend AGENTS.md**

The backups paragraph currently says the Postgres cluster ships backups "and nothing else does". Still true. Add the named accepted risk so a future reader does not mistake an accepted override for an oversight, and note coder's homes explicitly.

- [ ] **Step 3: Verify the claim is consistent everywhere it appears**

```bash
grep -rn "uncompensated\|nothing else does" AGENTS.md docs/superpowers/specs/ | sed 's/:.*uncompensated/: UNCOMP/'
```

Read every hit. Three documents making the same claim must make the same claim.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md docs/superpowers/specs/
git commit -m "docs: coder's workspace homes are the second PV-backup override, uncompensated"
```

---

## Task 13: Final verification sweep

- [ ] **Step 1: Offline, full gate**

```bash
env SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/titan-k8s-key.txt make check
```

Expected: every gate green, including `db-url-check: 1 PG URL reference(s) checked, 0 mismatch(es)`.

- [ ] **Step 2: Cluster, read-only**

```bash
kubectl --context titan -n flux-system get kustomization
kubectl --context titan -n coder get helmrelease,ingress
kubectl --context titan -n certificates get certificate
kubectl --context titan -n coder-workspaces get resourcequota
```

Expected: all stages Ready (note that a docs-only merge briefly shows downstream stages as `dependency ... is not ready` while the chain re-runs; that settles in about a minute and is not a fault).

- [ ] **Step 3: End to end, by hand**

Log out, log in to `https://coder.titan.arrieta.eu/` through authentik, start a stopped workspace, confirm the marker file from Task 9 is still in the home directory. That last check is the whole design in one command: the workspace was rebuilt and the home survived.
