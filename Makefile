# palette-agent-toolkit has no build step; it ships manifests, skills, and
# documentation rather than compiled source.

.PHONY: install
install: ## placeholder for future local git hooks
	@echo "local git hooks are not configured yet; CI runs secret scanning and linting"
	@exit 0

.PHONY: secrets-selftest
secrets-selftest: ## prove the secret-scan hook actually blocks, not just detects
	@echo "TODO: add a self-test once local secret-scanning hooks are introduced."
