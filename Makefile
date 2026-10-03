SHELL := /bin/bash
KUSTOMIZE_DIRS := $(shell find apply -mindepth 1 -maxdepth 2 -name kustomization.yaml 2>/dev/null | sed 's|/kustomization.yaml$$||' | sort)
# Both extensions: .sops.yaml's path_regex matches .yml too, so a .yml secret must
# not be able to slip between the encryption rule and the validation glob.
SECRET_FIND := find apply/10-secrets \( -name '*.yaml' -o -name '*.yml' \) ! -name kustomization.yaml

.PHONY: check kustomize-check validate validate-serial update-keys update-keys-serial scan leak-check secrets-placement secrets-list

check: kustomize-check validate secrets-placement leak-check
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
	n=$$(grep -A14 '^kind: GitRepository' apply/00-bootstrap/flux-system/gotk-sync.yaml | grep -c 'secretRef'); \
	if [ "$$n" -eq 0 ]; then echo "none (anonymous public clone)"; else echo "FAIL ($$n secretRef found)"; fail=1; fi; \
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
secrets-placement:
	@fail=0; \
	stray=$$(grep -rl --include='*.yaml' --include='*.yml' -E '^kind: *Secret$$' apply/ 2>/dev/null | grep -v '^apply/10-secrets/' || true); \
	if [ -n "$$stray" ]; then echo "FAIL: Secret manifest outside apply/10-secrets:"; echo "$$stray"; fail=1; fi; \
	for f in $$($(SECRET_FIND)); do \
	  if ! grep -q 'ENC\[' "$$f"; then echo "FAIL: $$f is not sops-encrypted (no ENC[)"; fail=1; fi; \
	done; \
	if [ "$$fail" -eq 0 ]; then echo "secrets-placement: no Secret outside apply/10-secrets, every secret encrypted"; fi; \
	exit $$fail

# Spec §0's three credential shapes AND its concrete-public-IPv4 check, against the
# staged diff. It used to implement two of the three shapes and no IPv4 check, and it
# grepped only the index - which AGENTS.md told you to run before `git add`, so it
# scanned an empty diff and reported success. Now: index if non-empty, else the working
# tree, and if there is genuinely nothing to scan it says so instead of passing.
#
# The patterns are assembled from pieces so this Makefile can never match itself: the
# literal text 'ssh-ed25519 AA''AA' does not contain four consecutive A's, a regex
# written as '[A-Z ]*PRIVATE KEY' does not match its own source, and '{1,3}\.' has no
# digit-followed-by-dot triple in it.
leak-check:
	@age='AGE-SECRET-KEY-1[A-Z2-9]{40,}'; pem='BEGIN [A-Z ]*PRIVATE KEY'; ssh='ssh-ed25519 AA''AA'; \
	ip='\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'; \
	allow='(^|[^0-9])(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.0\.0\.0|1\.1\.1\.1|8\.8\.[48]\.4|213\.186\.33\.99|224\.)'; \
	if git diff --cached --quiet && git diff --quiet; then \
	  echo "leak-check: FAIL - nothing staged and no working-tree changes, so there is nothing to scan"; \
	  echo "          stage the change (git add -A) and run it again"; exit 1; \
	fi; \
	if git diff --cached --quiet; then d=$$(git diff HEAD); else d=$$(git diff --cached); fi; \
	if printf '%s' "$$d" | grep -nE "$$age|$$pem|$$ssh"; then \
	  echo "LEAK: credential shape found in the diff - unstage and re-encrypt"; exit 1; \
	fi; \
	if printf '%s' "$$d" | grep -noE "$$ip" | grep -vE "$$allow"; then \
	  echo "LEAK: concrete public IPv4 in the diff - write <OVH_PUBLIC_IP>"; exit 1; \
	fi; \
	echo "leak-check: diff carries no credential shape and no public IPv4"

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
