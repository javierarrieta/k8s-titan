SHELL := /bin/bash
KUSTOMIZE_DIRS := $(shell find apply -mindepth 1 -maxdepth 2 -name kustomization.yaml 2>/dev/null | sed 's|/kustomization.yaml$$||' | sort)
# Both extensions: .sops.yaml's path_regex matches .yml too, so a .yml secret must
# not be able to slip between the encryption rule and the validation glob.
SECRET_FIND := find apply/10-secrets \( -name '*.yaml' -o -name '*.yml' \) ! -name kustomization.yaml

.PHONY: check kustomize-check validate validate-serial update-keys update-keys-serial scan leak-check secrets-placement secrets-present secrets-list

# leak-check runs FIRST: make has no -k, so it stops at the first failing prerequisite.
# validate needs the age key, so an operator who forgot SOPS_AGE_KEY_FILE would never
# reach a leak gate placed behind it.
check: leak-check kustomize-check validate secrets-placement
	@echo "check: all offline gates passed"

# Offline gate: every stage directory must build with kubectl kustomize, every stage
# path declared by the bootstrap must exist, and the two invariants that only show up
# as a live-cluster failure are asserted here instead.
# The build loop enumerates directories that DECLARE a kustomization.yaml, not every
# directory under apply/: plain-directory fallback still works at runtime, but it
# cannot be built offline, and offline validation is the only kind this repo can run.
kustomize-check:
	@fail=0; \
	for d in $(KUSTOMIZE_DIRS); do \
	  printf 'build %s: ' "$$d"; \
	  if kubectl kustomize "$$d" >/dev/null 2>&1; then echo OK; else echo FAIL; fail=1; fi; \
	done; \
	for p in $$(grep -h '^  path:' apply/00-bootstrap/stage-*.yaml apply/00-bootstrap/flux-system/gotk-sync.yaml | awk '{print $$2}'); do \
	  printf 'path %s: ' "$$p"; \
	  if [ ! -d "$${p#./}" ]; then echo "FAIL (declared stage path has no directory)"; fail=1; \
	  elif [ ! -f "$${p#./}/kustomization.yaml" ]; then echo "FAIL (no kustomization.yaml - this stage is never built offline)"; fail=1; \
	  else echo OK; fi; \
	done; \
	printf 'gitrepository auth: '; \
	if [ ! -f apply/00-bootstrap/flux-system/gotk-sync.yaml ]; then \
	  echo "FAIL (gotk-sync.yaml is missing - grep would report zero secretRefs and pass)"; fail=1; \
	else n=$$(grep -A14 '^kind: GitRepository' apply/00-bootstrap/flux-system/gotk-sync.yaml | grep -c 'secretRef'); \
	  if [ "$$n" -eq 0 ]; then echo "none (anonymous public clone)"; else echo "FAIL ($$n secretRef found)"; fail=1; fi; fi; \
	printf 'acme groupName: '; \
	g=$$(grep -rhoE 'groupName:[[:space:]]*[^[:space:]]+' apply/ | sort -u | tr '\n' ' '); \
	if [ "$$g" = "groupName: acme.titan.arrieta.eu " ]; then echo "acme.titan.arrieta.eu"; \
	else echo "FAIL (expected exactly one, acme.titan.arrieta.eu; got: $$g)"; fail=1; fi; \
	exit $$fail

# The gate has to be able to fail. An empty apply/10-secrets is not a pass: the
# sibling Makefiles this was copied from exited 0 while checking zero secrets.
secrets-present:
	@set +e; n=$$($(SECRET_FIND) | wc -l); \
	if [ "$$n" -eq 0 ]; then \
	  echo "FAIL: apply/10-secrets holds no secret manifests - nothing to validate"; \
	  echo "      the secrets stage cannot go Ready without them, and infra, certificates"; \
	  echo "      and apps block behind it. See docs/ovh-dns-credential.md"; \
	  exit 1; \
	fi

# xargs exits 123 if ANY invocation failed, so a single undecryptable secret turns
# this red. `&& echo OK || echo FAILED` would swallow it and exit 0 - the gate would
# print FAILED and still pass, which is worse than having no gate.
validate: secrets-present
	@echo "Validating all secrets can be decrypted:"
	@$(SECRET_FIND) -print0 | xargs -0 -P 4 -I{} sh -c \
	  'if sops --decrypt "{}" >/dev/null 2>&1; then echo "OK: {}"; else echo "FAILED: {}"; exit 1; fi'

validate-serial: secrets-present
	@echo "Validating all secrets can be decrypted (serial):"
	@fail=0; for f in $$($(SECRET_FIND)); do \
	  if sops --decrypt "$$f" >/dev/null 2>&1; then echo "OK: $$f"; else echo "FAILED: $$f"; fail=1; fi; \
	done; exit $$fail

update-keys: secrets-present
	@$(SECRET_FIND) -print0 | xargs -0 -P 4 -I{} sh -c \
	  'sops updatekeys -y "{}" >/dev/null && echo "Updated: {}" || { echo "FAILED: {}"; exit 1; }'

update-keys-serial: secrets-present
	@fail=0; for f in $$($(SECRET_FIND)); do \
	  if sops updatekeys -y "$$f" >/dev/null; then echo "Updated: $$f"; else echo "FAILED: $$f"; fail=1; fi; \
	done; exit $$fail

# AGENTS.md promises that a plaintext Secret outside apply/10-secrets/ is caught.
# Nothing else does: ggshield detects credential *shapes*, not a misplaced `kind: Secret`,
# and CI is skipped whenever the per-repo key is absent. So the promise needs a gate.
# (b) is belt-and-braces - `sops --decrypt` already exits 1 on a plaintext file - but it
# fails with a sentence instead of a sops stack trace.
# AGENTS.md promises "Secrets go in apply/10-secrets/ only". This is that promise, and
# it scans the whole tree rather than just apply/: a plaintext Secret under docs/ or
# .github/ is exactly as public. Depends on secrets-present so it cannot pass vacuously
# when run on its own.
secrets-placement: secrets-present
	@fail=0; \
	stray=$$(grep -rlI --exclude-dir=.git --include='*.yaml' --include='*.yml' -E '^kind: *Secret$$' . 2>/dev/null | grep -v '^\./apply/10-secrets/' || true); \
	if [ -n "$$stray" ]; then echo "FAIL: Secret manifest outside apply/10-secrets:"; echo "$$stray"; fail=1; fi; \
	for f in $$($(SECRET_FIND)); do \
	  if ! grep -q 'ENC\[' "$$f"; then echo "FAIL: $$f is not sops-encrypted (no ENC[)"; fail=1; fi; \
	done; \
	if [ "$$fail" -eq 0 ]; then echo "secrets-placement: no Secret outside apply/10-secrets, every secret encrypted"; fi; \
	exit $$fail

# Spec §0's three credential shapes AND its concrete-public-IPv4 check.
#
# Three-tier source, never vacuous and never red on a legitimate state:
#   1. the index, when something is staged - what is about to be committed
#   2. the working tree, when it differs from HEAD
#   3. the tracked tree at HEAD - strictly stronger than a diff, it re-proves the
#      published state on every run
# Untracked non-ignored files are scanned ON TOP of whichever tier is selected: a key
# dropped next to a manifest is exactly what this gate exists to catch, and a
# diff-only gate walked straight past one - an untracked AGE-SECRET-KEY file plus any
# unrelated edit used to exit 0. --exclude-standard keeps the documented
# apply/10-secrets/.staging.*.yaml flow from tripping it.
#
# Tier 3 excludes docs/superpowers/ and nothing else: the spec and plan quote the
# checker's own patterns in prose (the OpenSSH key prefix among them), so scanning them
# fails forever.
# The cost is real - a credential pasted into a spec or plan survives tier 3 - and is
# accepted because tiers 1 and 2 exclude nothing, so the commit that introduces it is
# still caught. The tier scanned is printed so the result is never ambiguous.
#
# Patterns are assembled from pieces so this Makefile cannot match itself: the literal
# text 'ssh-ed25519 AA''AA' holds no four consecutive A's, a regex written as
# '[A-Z ]*PRIVATE KEY' does not match its own source, and '{1,3}\.' contains no
# digit-followed-by-dot triple.
#
# Diff tiers scan ADDED lines only. A credential being deleted is the fix, not the leak
# - and this repo's own plan history had to delete a line quoting the checker's pattern,
# which a whole-diff grep flagged as a leak.
leak-check:
	@age='AGE-SECRET-KEY-1[A-Z2-9]{40,}'; pem='BEGIN [A-Z ]*PRIVATE KEY'; ssh='ssh-ed25519 AA''AA'; \
	ip='\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'; \
	allow='(^|[^0-9])(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.0\.0\.0|1\.1\.1\.1|8\.8\.[48]\.4|213\.186\.33\.99|224\.)'; \
	shapes="$$age|$$pem|$$ssh"; rc=0; \
	if ! git diff --cached --quiet; then tier='staged diff'; body=$$(git diff --cached); files=''; \
	elif ! git diff --quiet; then tier='working tree vs HEAD'; body=$$(git diff HEAD); files=''; \
	else tier='tracked tree at HEAD'; body=''; \
	  files=$$(git grep -lI -E "$$shapes|$$ip" -- . ':(exclude)docs/superpowers' || true); fi; \
	if [ -n "$$body" ]; then \
	  added=$$(printf '%s\n' "$$body" | grep '^+' || true); \
	  if printf '%s\n' "$$added" | grep -nE "$$shapes"; then echo "LEAK: credential shape in $$tier"; rc=1; fi; \
	  if printf '%s\n' "$$added" | grep -noE "$$ip" | grep -vE "$$allow"; then \
	    echo "LEAK: concrete public IPv4 in $$tier - write <OVH_PUBLIC_IP>"; rc=1; fi; \
	fi; \
	scanlist=$$(printf '%s\n' $$files $$(git ls-files --others --exclude-standard) | grep -v '^$$' | sort -u); \
	if [ -n "$$scanlist" ]; then \
	  if printf '%s\n' "$$scanlist" | xargs grep -nHE "$$shapes" 2>/dev/null | grep -v '^$$'; then \
	    echo "LEAK: credential shape in $$tier (tracked/untracked files)"; rc=1; fi; \
	  if printf '%s\n' "$$scanlist" | xargs grep -noHE "$$ip" 2>/dev/null | grep -vE "$$allow" | grep -v '^$$'; then \
	    echo "LEAK: concrete public IPv4 in $$tier (tracked/untracked files)"; rc=1; fi; \
	fi; \
	if [ "$$rc" -eq 0 ]; then \
	  echo "leak-check: clean - scanned $$tier plus untracked non-ignored files"; fi; \
	exit $$rc

# ggshield exits 1 when it FINDS a secret, so the previous `command -v ... && ggshield ...
# || echo skipping` swallowed the finding: a leak printed "ggshield not installed"
# and exited 0. Worse, the command it called was `secrets scan` (plural), which ggshield
# 1.54.0 does not have - so with the real binary installed the gate was lying even with
# no leak. Spec §8 documents `secret scan path -r -y .`; that is the accepted form, and
# this target now fails when the scan fails.
scan:
	@if ! command -v ggshield >/dev/null 2>&1; then \
	   echo "scan: SKIPPED - ggshield not installed"; exit 0; \
	 fi; \
	 if [ -z "$$GITGUARDIAN_API_KEY" ]; then \
	   echo "scan: SKIPPED - GITGUARDIAN_API_KEY unset, ggshield cannot reach the API"; exit 0; \
	 fi; \
	 ggshield secret scan path -r -y .

secrets-list:
	@$(SECRET_FIND) | sort
