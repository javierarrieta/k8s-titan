SHELL := /bin/bash
KUSTOMIZE_DIRS := $(shell find apply -mindepth 1 -maxdepth 2 -name kustomization.yaml 2>/dev/null | sed 's|/kustomization.yaml$$||' | sort)
# Both extensions: .sops.yaml's path_regex matches .yml too, so a .yml secret must
# not be able to slip between the encryption rule and the validation glob.
SECRET_FIND := find apply/10-secrets \( -name '*.yaml' -o -name '*.yml' \) ! -name kustomization.yaml

.PHONY: check check-ci kustomize-check validate update-keys scan leak-check secrets-placement secrets-present secrets-list

# leak-check runs FIRST: make has no -k, so it stops at the first failing prerequisite.
# validate needs the age key, so an operator who forgot SOPS_AGE_KEY_FILE would never
# reach a leak gate placed behind it.
check: leak-check kustomize-check validate secrets-placement
	@echo "check: all offline gates passed"

# The subset provable from the tree alone - no age key, no cluster, no network.
# `validate` is deliberately absent: it needs the sops age private key, and that key must
# never sit in CI for any reason. Leaving it out is the whole point of this target - a
# gate that needs a secret to run is a gate that gets skipped.
#
# Each gate runs even when an earlier one fails, so one red gate cannot hide the others.
# `check` cannot do this (make has no -k), which is exactly how a leak gate ended up
# masked behind a decrypt failure once already.
#
# On a CI checkout nothing is staged and the tree is clean, so leak-check's diff pass
# finds nothing - but its tree pass re-scans the whole tracked tree regardless, which is
# what makes this worth running in CI at all.
check-ci:
	@rc=0; \
	for t in leak-check kustomize-check secrets-placement; do \
	  echo "--- $$t ---"; \
	  $(MAKE) --no-print-directory $$t || rc=1; \
	done; \
	if [ $$rc -eq 0 ]; then echo "check-ci: all keyless gates passed"; \
	else echo "check-ci: one or more keyless gates FAILED"; fi; \
	exit $$rc

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
	grdocs=$$(find apply \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null \
	  | xargs -0 -r awk '/^---[ \t]*$$/{if(isgr)printf "DOC\n%s",buf;isgr=0;buf="";next} /^kind:[ \t]*GitRepository[ \t]*$$/{isgr=1} {buf=buf $$0 "\n"} END{if(isgr)printf "DOC\n%s",buf}'); \
	grcount=$$(printf '%s\n' "$$grdocs" | grep -c '^DOC$$'); \
	if [ "$$grcount" -ne 1 ]; then \
	  echo "FAIL (expected exactly 1 GitRepository document, found $$grcount - the assertion cannot be trusted)"; fail=1; \
	elif printf '%s\n' "$$grdocs" | grep -q 'secretRef'; then \
	  echo "FAIL (secretRef on the GitRepository - the anonymous-clone contract is gone)"; fail=1; \
	else echo "none (anonymous public clone)"; fi; \
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

update-keys: secrets-present
	@$(SECRET_FIND) -print0 | xargs -0 -P 4 -I{} sh -c \
	  'sops updatekeys -y "{}" >/dev/null && echo "Updated: {}" || { echo "FAILED: {}"; exit 1; }'

# AGENTS.md promises that a plaintext Secret outside apply/10-secrets/ is caught.
# Nothing else does: ggshield detects credential *shapes*, not a misplaced `kind: Secret`,
# and CI is skipped whenever the per-repo key is absent. So the promise needs a gate.
# (b) is belt-and-braces - `sops --decrypt` already exits 1 on a plaintext file - but it
# fails with a sentence instead of a sops stack trace.
# AGENTS.md promises "Secrets go in apply/10-secrets/ only". This is that promise, and
# it scans the whole tree rather than just apply/: a plaintext Secret under docs/ or
# .github/ is exactly as public. Depends on secrets-present so it cannot pass vacuously
# when run on its own.
#
# One exemption: a Secret that is a ServiceAccount token REQUEST -- typed
# kubernetes.io/service-account-token and carrying no data/stringData. The
# controller fills those in-cluster, so nothing secret is in git. The exemption is
# narrow on purpose: add a data: or stringData: block to such a file, or use any
# other Secret type outside apply/10-secrets, and the gate fails again.
secrets-placement: secrets-present
	@fail=0; \
	stray=""; \
	for f in $$(grep -rlI --exclude-dir=.git --include='*.yaml' --include='*.yml' -E '^kind: *Secret$$' . 2>/dev/null | grep -v '^\./apply/10-secrets/' || true); do \
	  if grep -q '^type: *kubernetes\.io/service-account-token$$' "$$f" \
	     && ! grep -qE '^(data|stringData):' "$$f"; then continue; fi; \
	  stray="$$stray $$f"; \
	done; \
	if [ -n "$$stray" ]; then echo "FAIL: Secret manifest outside apply/10-secrets:"; for s in $$stray; do echo "  $$s"; done; fail=1; fi; \
	for f in $$($(SECRET_FIND)); do \
	  if ! grep -q 'ENC\[' "$$f"; then echo "FAIL: $$f is not sops-encrypted (no ENC[)"; fail=1; fi; \
	done; \
	if [ "$$fail" -eq 0 ]; then echo "secrets-placement: no Secret outside apply/10-secrets, every secret encrypted"; fi; \
	exit $$fail

# Spec §0's credential shapes AND its concrete-public-IPv4 check, plus the shape of the
# credential this repo actually holds (an OVH application triple, which is opaque and
# matches none of the age/PEM/OpenSSH patterns).
#
# Two independent passes, so neither can mask the other:
#   A. a DIFF pass - the index if something is staged, else the working tree vs HEAD.
#      Added lines only: deleting a credential is the fix, not the leak, and this repo's
#      own plan history had to delete a line quoting the checker's pattern.
#   B. a TREE pass - the tracked tree at HEAD plus every untracked non-ignored file,
#      ALWAYS, regardless of pass A.
# Pass B is what makes the gate re-prove the published state on every run. Making it
# conditional on a clean tree was a defect: the documented flow is `git add -A` then
# `make check`, so a tree-only pass would never have run, and a credential already in
# HEAD stayed invisible while any edit was pending.
#
# Untracked files are scanned because a key dropped next to a manifest is exactly what
# this gate exists to catch, and a diff-only gate walked straight past one.
# --exclude-standard keeps the documented apply/10-secrets/.staging.*.yaml flow from
# tripping it.
#
# The tree pass excludes docs/superpowers/ and nothing else: the spec and plan quote the
# checker's own patterns in prose (the OpenSSH prefix among them), so scanning them is
# red forever. The cost is real - a credential pasted into a spec survives pass B - and
# is accepted because pass A excludes nothing, so the commit that introduces it is caught.
#
# File lists are NUL-delimited end to end (git grep -z, git ls-files -z, sort -z, xargs
# -0). A newline-delimited list word-split on filenames with spaces and silently dropped
# the file from the scan - a key at 'my age key.txt' passed the gate.
#
# It refuses to report clean when HEAD cannot be resolved. Inferring the tier from git's
# exit status meant running outside a repo, or with a locked index, printed "clean".
#
# No `\b` in the IPv4 pattern: it is a GNU-regex convention, and two of the four sops
# recipients are MacBooks where BSD grep may treat it as a literal, which would make the
# mandated IPv4 check silently dead. The allow-list absorbs the extra matches instead.
#
# Matched content is NOT echoed - only file names - so a leak cannot be copied into a CI
# log by the gate that found it.
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
	ovh='OVH_(APPLICATION_KEY|APPLICATION_SECRET|CONSUMER_KEY): *[A-Za-z0-9]{16,}$$'; \
	ip='([0-9]{1,3}\.){3}[0-9]{1,3}'; \
	allow='(^|[^0-9.])(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.64\.|169\.254\.|0\.0\.0\.0|1\.1\.1\.1|8\.8\.[48]\.4|213\.186\.33\.99|224\.|255\.255\.255\.255)'; \
	shapes="$$age|$$pem|$$ssh|$$ovh"; rc=0; \
	if ! git rev-parse --verify HEAD >/dev/null 2>&1; then \
	  echo "leak-check: cannot resolve HEAD - refusing to report clean"; exit 1; fi; \
	if ! git diff --cached --quiet 2>/dev/null; then tier='staged diff'; body=$$(git diff --cached); \
	elif ! git diff --quiet 2>/dev/null; then tier='working tree vs HEAD'; body=$$(git diff HEAD); \
	else tier='clean tree'; body=''; fi; \
	if [ -n "$$body" ]; then \
	  added=$$(printf '%s\n' "$$body" | grep '^+' || true); \
	  if printf '%s\n' "$$added" | grep -qE "$$shapes"; then \
	    echo "LEAK: credential shape in $$tier (content not echoed; find it with: git diff --cached | grep -nE ...)"; rc=1; fi; \
	  if printf '%s\n' "$$added" | grep -oE "$$ip" | grep -vE "$$allow" | grep -q .; then \
	    echo "LEAK: concrete public IPv4 in $$tier - write <OVH_PUBLIC_IP>"; rc=1; fi; \
	fi; \
	shithits=$$( { git grep -lI -z -E "$$shapes" -- . ':(exclude)docs/superpowers' 2>/dev/null; \
	               git ls-files -z --others --exclude-standard 2>/dev/null; } | sort -z -u \
	             | xargs -0 -r grep -lE "$$shapes" 2>/dev/null || true); \
	if [ -n "$$shithits" ]; then echo "LEAK: credential shape in tracked tree or untracked files (names only):"; \
	  printf '%s\n' "$$shithits"; rc=1; fi; \
	iphits=$$( { git grep -lI -z -E "$$ip" -- . ':(exclude)docs/superpowers' 2>/dev/null; \
	             git ls-files -z --others --exclude-standard 2>/dev/null; } | sort -z -u \
	           | xargs -0 -r grep -oHE "$$ip" 2>/dev/null | grep -vE "$$allow" || true); \
	if [ -n "$$iphits" ]; then echo "LEAK: concrete public IPv4 in tracked tree or untracked files:"; \
	  printf '%s\n' "$$iphits" | cut -d: -f1 | sort -u; rc=1; fi; \
	if [ "$$rc" -eq 0 ]; then \
	  echo "leak-check: clean - scanned $$tier, the tracked tree at HEAD, and untracked non-ignored files"; fi; \
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
