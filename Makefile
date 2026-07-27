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
	format \
	build \
	check-artifacts \
	test \
	snapshot \
	coverage \
	reproducible \
	slither \
	slither-review \
	slither-gate \
	require-base-rpc \
	check-base \
	check-base-deployment \
	test-base \
	snapshot-base

help:
	@printf '%s\n' \
		'make check                 Run the complete non-RPC validation suite' \
		'make check-base            Run Base on-chain, fork, and gas checks (requires BASE_RPC_URL)' \
		'make check-toolchain       Verify Foundry and pinned dependency revisions' \
		'make format                Check Solidity formatting' \
		'make build                 Build contracts and report sizes' \
		'make check-artifacts       Check surfaces, ABIs, deployment identity, and verification inputs' \
		'make test                  Run the non-fork test suite' \
		'make snapshot              Check deterministic non-fuzz gas snapshots' \
		'make coverage              Generate the coverage summary' \
		'make reproducible          Compare two clean artifact builds' \
		'make slither               Run dependency-inclusive review and the project-owned high gate'

check: check-toolchain format check-artifacts test snapshot coverage reproducible slither

check-toolchain: check-foundry check-dependencies

check-foundry:
	./script/check-foundry-version.sh

check-dependencies:
	./script/check-account-abstraction-revision.sh
	./script/check-forge-std-revision.sh

format:
	forge fmt --check

build:
	forge build --sizes

check-artifacts: build
	./script/check-minimal-account-surface.sh
	./script/check-flow-assertions-surface.sh
	./script/check-static-call-uint256-assertions-surface.sh
	./script/check-direct-immutable-artifacts.sh
	./script/check-abi-fixtures.sh
	./script/generate-base-v1-verification-inputs.sh
	./script/check-base-v1-manifest.sh

test:
	forge test --no-match-path 'test/fork/**' -vvv

snapshot:
	forge snapshot --check \
		--no-match-test 'testFuzz|invariant_' \
		--no-match-contract 'BaseDeploymentManifestTest' \
		--no-match-path 'test/fork/**'

coverage:
	forge coverage \
		--no-match-path 'test/fork/**' \
		--no-match-contract 'BaseDeploymentManifestTest' \
		--no-match-coverage 'script/' \
		--report summary

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

check-base: check-toolchain check-base-deployment test-base snapshot-base

check-base-deployment: require-base-rpc
	./script/check-base-v1-onchain-deployment.sh

test-base: require-base-rpc
	forge test \
		--match-path 'test/fork/**/*.t.sol' \
		--no-match-path 'test/fork/BaseAaveV3*Gas.t.sol' \
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
