.PHONY: scan update-keys update-keys-serial validate validate-serial info secrets-list

# Secret scan of the working tree. CI runs the same engine on every push; this is
# the local pre-commit form of it. Needs ggshield authenticated (ggshield auth login).
scan:
	@echo "Scanning working tree for secrets:"
	@ggshield secret scan path -r -y .

# Serial execution (shows errors, safer)
update-keys-serial:
	@echo "Updating keys (serial) - showing errors:"
	@find apply/10-secrets -name "*.yaml" -exec sh -c 'echo "Processing: {}" && sops updatekeys --yes "{}" || echo "FAILED: {}"' \;

# Parallel execution (faster, 4 concurrent processes)
update-keys:
	@echo "Updating keys (parallel) - showing errors:"
	@find apply/10-secrets -name "*.yaml" -print0 | xargs -0 -P 4 sh -c 'for f; do echo "Processing: $$f" && sops updatekeys --yes "$$f" || echo "FAILED: $$f"; done' sh

# Validate all secrets can be decrypted (serial)
validate-serial:
	@echo "Validating all secrets can be decrypted:"
	@find apply/10-secrets -name "*.yaml" -exec sh -c 'sops --decrypt "{}" > /dev/null 2>&1 && echo "OK: {}" || echo "FAILED: {}"' \;

# Validate all secrets can be decrypted (parallel)
validate:
	@echo "Validating all secrets can be decrypted:"
	@find apply/10-secrets -name "*.yaml" -print0 | xargs -0 -P 4 sh -c 'for f; do sops --decrypt "$$f" > /dev/null 2>&1 && echo "OK: $$f" || echo "FAILED: $$f"; done' sh

# Show info for a specific secret
info:
	@echo "Usage: make info SECRET=<path>"
	@sops info $(SECRET)

# List all secrets
secrets-list:
	@find apply/10-secrets -name "*.yaml" | sort
