# NatWest payments demo — short-name aliases over the numbered scripts.
#
# Every target shells out to scripts/* — keep build logic there, not here.
# This Makefile exists so the presenter can type `make demo` instead of
# remembering the eleven-script sequence under stress.

SHELL := /usr/bin/env bash

# Pretty header for `make help`. Looked up by the help target via grep.
.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help (default)
	@printf '\n  NatWest payments demo — make targets\n\n'
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / { printf "    %-22s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\n  See scripts/run-of-show.md for the talk-track itself.\n\n'

.PHONY: preflight
preflight: ## Verify the demo is ready (pods, RUM token, HEC, proxy)
	scripts/00-preflight.sh

.PHONY: preflight-quick
preflight-quick: ## Faster preflight (skips Splunk Observability + synthetic)
	scripts/00-preflight.sh --quick

.PHONY: demo
demo: ## Build the core demo end-to-end (00..05 + 05b + preflight)
	scripts/00-bootstrap.sh

.PHONY: demo-full
demo-full: ## demo + ITSI + ThousandEyes
	scripts/00-bootstrap.sh --with-itsi --with-thousandeyes

.PHONY: demo-itsi
demo-itsi: ## demo + ITSI service tree
	scripts/00-bootstrap.sh --with-itsi

.PHONY: plan
plan: ## Print the bootstrap plan without running anything
	scripts/00-bootstrap.sh --dry-run

.PHONY: recover
recover: ## Reset every chaos toggle to baseline (calls incident.sh recover)
	scripts/incident.sh recover

.PHONY: incident-status
incident-status: ## Show the active incident toggles on each deployment
	scripts/incident.sh status

.PHONY: arm-fraud
arm-fraud: ## Pre-arm the fraud-cpu-regression scenario (~3 min before stage)
	scripts/incident.sh fraud-cpu-regression

.PHONY: chaos-deploy
chaos-deploy: ## Build, push, deploy the chaos-controller (Chaos Dashboard /ops)
	scripts/01-build-push.sh
	scripts/05c-chaos-controller.sh

.PHONY: chaos-recover
chaos-recover: ## POST /chaos/api/recover via the dashboard backend (preferred)
	@SPA_URL="$$(terraform -chdir=terraform output -raw public_spa_url 2>/dev/null || true)"; \
	TOKEN="$$(kubectl -n natwest get secret chaos-controller-token -o jsonpath='{.data.CHAOS_PRESENTER_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"; \
	if [ -z "$$SPA_URL" ] || [ -z "$$TOKEN" ]; then \
	  echo "chaos-controller not deployed (or SPA URL missing). Falling back to scripts/incident.sh recover."; \
	  scripts/incident.sh recover; \
	else \
	  echo "POST $$SPA_URL/chaos/api/recover"; \
	  curl -fsS -X POST -H "X-Chaos-Token: $$TOKEN" -H "Content-Type: application/json" -d '{}' "$$SPA_URL/chaos/api/recover" | head -c 2000; \
	  echo; \
	fi

.PHONY: repair-apm-topology
repair-apm-topology: ## Fix floating APM services (chaos recover + topology repair + verify)
	scripts/08-repair-apm-topology.sh

.PHONY: verify-apm-topology
verify-apm-topology: ## SPL checks that the APM service map wiring is healthy
	python3 scripts/lib/verify_apm_topology.py

.PHONY: configure-loc
configure-loc: ## Wire Splunk Enterprise Log Observer Connect (scripts/05f-configure-loc.sh)
	scripts/05f-configure-loc.sh

.PHONY: destroy
destroy: ## Tear down everything (terraform destroy + cluster cleanup)
	scripts/99-destroy.sh

.PHONY: test
test: ## Run the unit tests on app/audit.py
	python3 -m pytest -q app/test_audit.py
