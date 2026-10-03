SHELL := /bin/bash
KUSTOMIZE_DIRS := $(shell find apply -mindepth 1 -maxdepth 2 -name kustomization.yaml 2>/dev/null | sed 's|/kustomization.yaml$$||' | sort)
# Both extensions: .sops.yaml's path_regex matches .yml too, so a .yml secret must
# not be able to slip between the encryption rule and the validation glob.
SECRET_FIND := find apply/10-secrets \( -name '*.yaml' -o -name '*.yml' \) ! -name kustomization.yaml

.PHONY: check kustomize-check validate validate-serial update-keys update-keys-serial scan leak-check secrets-list

check: kustomize-check validate leak-check
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
	  if [ -d "$${p#./}" ]; then echo OK; else echo "FAIL (declared stage path has no directory)"; fail=1; fi; \
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

# Credential shapes in the staged diff. The patterns are assembled from pieces so this
# Makefile can never match itself: the literal text 'ssh-ed25519 AA''AA' does not
# contain four consecutive A's, and a regex written as '[A-Z ]*PRIVATE KEY' does not
# match its own source. Spec §0's three shapes, all three, always on - ggshield needs
# a configured endpoint and GitGuardian CI is skipped until the org enables secret
# detection, so this grep is the only control that is always running.
leak-check:
	@age='AGE-SECRET-KEY-1[A-Z2-9]{40,}'; pem='BEGIN [A-Z ]*PRIVATE KEY'; ssh='ssh-ed25519 AA''AA'; \
	if git diff --cached | grep -nE "$$age|$$pem|$$ssh"; then \
	  echo "LEAK: credential shape found in staged diff - unstage and re-encrypt"; exit 1; \
	fi; \
	echo "leak-check: no credential shapes in staged diff"

scan:
	@command -v ggshield >/dev/null 2>&1 && ggshield secrets scan --text . || echo "ggshield not installed, skipping"

secrets-list:
	@find apply/10-secrets -name '*.yaml' ! -name kustomization.yaml | sort
