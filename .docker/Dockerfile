FROM --platform=$BUILDPLATFORM postgres:17-bookworm AS toolchain

ARG RUST_VERSION=1.88.0
ARG PGRX_VERSION=0.16.1
ARG TARGETARCH

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        build-essential \
        ca-certificates \
        clang \
        curl \
        gcc-aarch64-linux-gnu \
        gcc-x86-64-linux-gnu \
        libc6-dev-amd64-cross \
        libc6-dev-arm64-cross \
        postgresql-server-dev-17 \
        pkg-config \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION}

ENV PATH="/root/.cargo/bin:${PATH}"

RUN rustup component add clippy rustfmt

RUN rustup target add \
        aarch64-unknown-linux-gnu \
        x86_64-unknown-linux-gnu

RUN mkdir -p /root/.cargo \
    && printf '%s\n' \
        '[target.aarch64-unknown-linux-gnu]' \
        'linker = "aarch64-linux-gnu-gcc"' \
        '' \
        '[target.x86_64-unknown-linux-gnu]' \
        'linker = "x86_64-linux-gnu-gcc"' \
        > /root/.cargo/config.toml

ENV CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
    AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc \
    AR_x86_64_unknown_linux_gnu=x86_64-linux-gnu-ar \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc

RUN cargo install cargo-pgrx --version ${PGRX_VERSION} --locked

WORKDIR /workspace
COPY Cargo.toml Cargo.lock postgres_augurs_extension.control ./
COPY src ./src

RUN case "${TARGETARCH}" in \
        amd64) rust_target=x86_64-unknown-linux-gnu ;; \
        arm64) rust_target=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && echo "Preparing pgrx for target ${rust_target}" \
    && cargo pgrx init \
        --no-run \
        --pg17 /usr/lib/postgresql/17/bin/pg_config

FROM toolchain AS package

ARG TARGETARCH

RUN case "${TARGETARCH}" in \
        amd64) rust_target=x86_64-unknown-linux-gnu ;; \
        arm64) rust_target=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && rm -rf /workspace/package \
    && cargo pgrx package \
        --target "${rust_target}" \
        --pg-config /usr/lib/postgresql/17/bin/pg_config \
        --out-dir /workspace/package

FROM timescale/timescaledb-ha:pg17.11-ts2.30.0 AS runtime

COPY --from=package /workspace/package/ /
