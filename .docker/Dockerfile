FROM postgres:17-bookworm AS toolchain

ARG RUST_VERSION=1.88.0
ARG PGRX_VERSION=0.16.1

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        build-essential \
        ca-certificates \
        clang \
        curl \
        postgresql-server-dev-17 \
        pkg-config \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION}

ENV PATH="/root/.cargo/bin:${PATH}"

RUN rustup component add clippy rustfmt

RUN cargo install cargo-pgrx --version ${PGRX_VERSION} --locked

WORKDIR /workspace
COPY Cargo.toml Cargo.lock postgres_augurs_extension.control ./
COPY src ./src

RUN cargo pgrx init --pg17 /usr/lib/postgresql/17/bin/pg_config

FROM toolchain AS package

RUN rm -rf /workspace/package \
    && cargo pgrx package \
        --pg-config /usr/lib/postgresql/17/bin/pg_config \
        --out-dir /workspace/package

FROM timescale/timescaledb-ha:pg17.11-ts2.30.0 AS runtime

COPY --from=package /workspace/package/ /
