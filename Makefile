.PHONY: scan update-keys update-keys-serial validate validate-serial info secrets-list kustomize-check check

# Secret scan of the working tree. CI runs the same engine on every push; this is
# the local pre-commit form of it. Needs ggshield authenticated (ggshield auth login).
scan:
	@echo "Scanning working tree for secrets:"
	@ggshield secret scan path -r -y .

# Serial execution (shows errors, safer)
update-keys-serial:
	@echo "Updating keys (serial) - showing errors:"
	@find apply/10-secrets -name "*.yaml" ! -name kustomization.yaml -exec sh -c 'echo "Processing: {}" && sops updatekeys --yes "{}" || echo "FAILED: {}"' \;

# Parallel execution (faster, 4 concurrent processes)
update-keys:
	@echo "Updating keys (parallel) - showing errors:"
	@find apply/10-secrets -name "*.yaml" ! -name kustomization.yaml -print0 | xargs -0 -P 4 sh -c 'for f; do echo "Processing: $$f" && sops updatekeys --yes "$$f" || echo "FAILED: $$f"; done' sh

# Validate all secrets can be decrypted (serial)
validate-serial:
	@echo "Validating all secrets can be decrypted:"
	@find apply/10-secrets -name "*.yaml" ! -name kustomization.yaml -exec sh -c 'sops --decrypt "{}" > /dev/null 2>&1 && echo "OK: {}" || echo "FAILED: {}"' \;

# Validate all secrets can be decrypted (parallel)
validate:
	@echo "Validating all secrets can be decrypted:"
	@find apply/10-secrets -name "*.yaml" ! -name kustomization.yaml -print0 | xargs -0 -P 4 sh -c 'for f; do sops --decrypt "$$f" > /dev/null 2>&1 && echo "OK: $$f" || echo "FAILED: $$f"; done' sh

# Show info for a specific secret
info:
	@echo "Usage: make info SECRET=<path>"
	@sops info $(SECRET)

# List all secrets
secrets-list:
	@find apply/10-secrets -name "*.yaml" ! -name kustomization.yaml | sort

# Build every stage directory that declares a kustomization.yaml. This is the
# offline gate: kustomize-controller will happily attempt a malformed tree and
# fail three time zones away, which is a worse place to learn it. The empty-tree
# case is a failure on purpose — a stage directory that forgets its
# kustomization.yaml would otherwise pass by being invisible.
kustomize-check:
	@dirs=$$(find apply -name kustomization.yaml -printf '%h\n' | sort); \
	if [ -z "$$dirs" ]; then \
	  echo "FAIL: no directory under apply/ declares a kustomization.yaml"; exit 1; \
	fi; \
	for d in $$dirs; do \
	  printf 'kustomize %s: ' "$$d"; \
	  if kubectl kustomize "$$d" > /dev/null; then echo OK; else echo " FAIL"; exit 1; \
	  fi; \
	done
	@echo "kustomize-check: all stage directories build"

# Everything that can be proven without a cluster.
check: kustomize-check validate scan
	@echo "check: all offline gates passed"
