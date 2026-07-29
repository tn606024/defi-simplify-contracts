SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.NOTPARALLEL:

FOUNDRY_PROFILE ?= ci
export FOUNDRY_PROFILE

.PHONY: \
	help \
	check \
	check-toolchain \
	check-foundry \
	check-dependencies \
	check-build-lock-regression \
	format \
	build \
	check-artifacts \
	check-base-verification-inputs \
	generate-base-v1.1-payloads \
	test \
	snapshot \
	coverage \
	reproducible \
	slither \
	slither-review \
	slither-gate \
	require-base-rpc \
	check-base \
	check-base-candidate \
	preflight-base-v1.1 \
	check-base-deployment \
	test-base \
	snapshot-base

help:
	@printf '%s\n' \
		'make check                 Run the complete non-RPC validation suite' \
		'make check-base            Run active Base fork and gas checks (requires BASE_RPC_URL)' \
		'make check-base-candidate  Check candidate vacancy and dry-run deployment on Base' \
		'make preflight-base-v1.1   Run no-broadcast deployment preflight (requires RPC and deployer address)' \
		'make generate-base-v1.1-payloads  Generate exact ignored factory calldata review file' \
		'make check-toolchain       Verify Foundry and pinned dependency revisions' \
		'make format                Check Solidity formatting' \
		'make build                 Build contracts and report sizes' \
		'make check-artifacts       Check current contract surfaces, ABIs, and direct artifacts' \
		'make test                  Run the non-fork test suite' \
		'make snapshot              Check deterministic non-fuzz gas snapshots' \
		'make coverage              Enforce production-only coverage thresholds' \
		'make reproducible          Compare two clean artifact builds' \
		'make slither               Run dependency-inclusive review and the project-owned high gate'

check: check-toolchain format check-artifacts test snapshot coverage reproducible slither

check-toolchain: check-foundry check-dependencies

check-foundry:
	./script/check-foundry-version.sh

check-dependencies:
	./script/check-account-abstraction-revision.sh
	$(MAKE) check-build-lock-regression
	./script/check-forge-std-revision.sh

check-build-lock-regression:
	./test/scripts/check-foundry-build-settings.sh

format:
	forge fmt --check

build:
	forge build --sizes

check-artifacts: build check-base-verification-inputs
	./script/check-minimal-account-surface.sh
	./script/check-flow-assertions-surface.sh
	./script/check-static-call-uint256-assertions-surface.sh
	./script/check-direct-immutable-artifacts.sh
	./script/check-abi-fixtures.sh
	./script/check-base-v1.1-candidate-manifest.sh

check-base-verification-inputs:
	./script/check-base-v1.1-verification-inputs.sh

generate-base-v1.1-payloads:
	./script/generate-base-v1.1-factory-payloads.sh

test:
	forge test \
		--no-match-path 'test/fork/**' \
		--no-match-contract 'BaseDeploymentManifestTest' \
		-vvv

snapshot:
	forge snapshot --check \
		--no-match-test 'testFuzz|invariant_' \
		--no-match-contract 'BaseDeployment.*ManifestTest|BaseV1_1DeploymentAuthorizationTest|DeterministicDeploymentTest' \
		--no-match-path 'test/fork/**'

coverage:
	./script/check-production-coverage.sh

reproducible:
	./script/check-reproducible-build.sh

slither: slither-review slither-gate

slither-review:
	slither . --fail-none

slither-gate:
	slither . --filter-paths 'lib/' --fail-high

require-base-rpc:
	@test -n "$${BASE_RPC_URL:-}" || { \
		echo "BASE_RPC_URL is required for Base checks" >&2; \
		exit 1; \
	}

check-base: check-toolchain check-base-candidate test-base snapshot-base

check-base-candidate: require-base-rpc
	./script/check-base-v1.1-candidate-onchain.sh
	temporary_run_directory="$$(mktemp -d "$${TMPDIR:-/tmp}/base-v1.1-candidate.XXXXXX")"; \
	trap 'rm -rf -- "$$temporary_run_directory"' EXIT; \
	FOUNDRY_BROADCAST="$$temporary_run_directory/broadcast" \
	FOUNDRY_CACHE_PATH="$$temporary_run_directory/cache" \
		forge script script/DeployBaseV1_1Candidate.s.sol:DeployBaseV1_1Candidate \
			--rpc-url "$${BASE_RPC_URL}"

preflight-base-v1.1: require-base-rpc
	./script/preflight-base-v1.1-deployment.sh

check-base-deployment: require-base-rpc
	./script/check-base-v1-onchain-deployment.sh

test-base: require-base-rpc
	forge test \
		--match-path 'test/fork/**/*.t.sol' \
		--no-match-path 'test/fork/BaseAaveV3*Gas.t.sol' \
		--no-match-contract 'BaseDeploymentFactoryTest' \
		--fork-url "$${BASE_RPC_URL}" \
		--fork-retries 5 \
		--fork-retry-backoff 1000 \
		-vvv

snapshot-base: require-base-rpc
	forge snapshot --check \
		--match-path 'test/fork/BaseAaveV3*Gas.t.sol' \
		--match-test 'test_Gas_' \
		--fork-url "$${BASE_RPC_URL}" \
		--fork-retries 5 \
		--fork-retry-backoff 1000
