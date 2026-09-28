SHELL := /bin/bash

DOCKERFILE ?= .docker/Dockerfile
DOCKER_CONTEXT ?= .
IMAGE ?= postgres-augurs-extension:local
TOOLCHAIN_IMAGE ?= postgres-augurs-extension:toolchain
PACKAGE_IMAGE ?= postgres-augurs-extension:package

.DEFAULT_GOAL := all

.PHONY: all
all: test

.PHONY: ci-pre-build
ci-pre-build:
	@test -f "$(DOCKERFILE)"
	@test -f Cargo.toml
	@test -f Cargo.lock

.PHONY: docker-build
docker-build:
	docker build \
		--file "$(DOCKERFILE)" \
		--tag "$(IMAGE)" \
		"$(DOCKER_CONTEXT)"

.PHONY: docker-build-toolchain
docker-build-toolchain:
	docker build \
		--file "$(DOCKERFILE)" \
		--target toolchain \
		--tag "$(TOOLCHAIN_IMAGE)" \
		"$(DOCKER_CONTEXT)"

.PHONY: docker-build-package
docker-build-package:
	docker build \
		--file "$(DOCKERFILE)" \
		--target package \
		--tag "$(PACKAGE_IMAGE)" \
		"$(DOCKER_CONTEXT)"

.PHONY: docker-run
docker-run: docker-build
	docker run --rm \
		--env POSTGRES_HOST_AUTH_METHOD=trust \
		"$(IMAGE)"

.PHONY: test
test: docker-build-toolchain
	docker run --rm "$(TOOLCHAIN_IMAGE)" sh -euc \
		'cargo fmt --check && cargo test --locked && cargo clippy --locked --all-targets --all-features -- -D warnings'

.PHONY: lint
lint: docker-build-toolchain
	docker run --rm "$(TOOLCHAIN_IMAGE)" \
		cargo clippy --locked --all-targets --all-features -- -D warnings

.PHONY: format-check
format-check: docker-build-toolchain
	docker run --rm "$(TOOLCHAIN_IMAGE)" cargo fmt --check

.PHONY: smoke
smoke:
	bash scripts/poc.sh

.PHONY: package
package:
	bash scripts/package.sh

.PHONY: package-smoke
package-smoke:
	archive="$$(find dist -maxdepth 1 -type f -name '*.tar.gz' -print -quit)"; \
	test -n "$$archive"; \
	bash scripts/package-smoke.sh "$$archive"

.PHONY: benchmark
benchmark:
	bash scripts/benchmark.sh

.PHONY: benchmark-changepoint
benchmark-changepoint:
	bash scripts/benchmark-changepoint.sh

.PHONY: benchmark-decomposition
benchmark-decomposition:
	bash scripts/benchmark-decomposition.sh

.PHONY: benchmark-keyed
benchmark-keyed:
	bash scripts/benchmark-keyed.sh

.PHONY: benchmark-rolling-mad
benchmark-rolling-mad:
	bash scripts/benchmark-rolling-mad.sh

.PHONY: benchmark-seasonality
benchmark-seasonality:
	bash scripts/benchmark-seasonality.sh
