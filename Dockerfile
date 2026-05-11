# syntax=docker/dockerfile:1.7

FROM node:25-alpine AS node_builder

WORKDIR /usr/src/app

RUN npm i -g pnpm@10.33.0

COPY package.json ./
COPY pnpm-lock.yaml ./

RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --store-dir /pnpm/store

COPY rsbuild.config.ts ./
COPY tsconfig.json ./
COPY postcss.config.mjs ./
COPY openapi-ts.config.ts ./
COPY openapi.yaml ./
COPY public ./public
COPY web-src ./web-src

RUN pnpm openapi-ts
RUN pnpm type-check
RUN pnpm build

FROM rust:alpine AS cargo_chef

RUN apk update
RUN apk add --no-cache pkgconfig libressl-dev musl-dev

ENV RUSTFLAGS='-C target-feature=-crt-static'

RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git \
    cargo install cargo-chef --locked

FROM cargo_chef AS rust_planner

WORKDIR /usr/src/app

COPY Cargo.toml ./
COPY Cargo.lock ./
COPY src ./src
COPY openapi.yaml ./

RUN cargo chef prepare --recipe-path recipe.json

FROM cargo_chef AS rust_builder

WORKDIR /usr/src/app

COPY --from=rust_planner /usr/src/app/recipe.json recipe.json

RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=geoip-cargo-target,target=/usr/src/app/target \
    cargo chef cook --release --recipe-path recipe.json

COPY Cargo.toml ./
COPY Cargo.lock ./
COPY src ./src
COPY openapi.yaml ./

RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=geoip-cargo-target,target=/usr/src/app/target \
    cargo build --release --bin geoip && \
    cp /usr/src/app/target/release/geoip /usr/local/bin/geoip

FROM alpine AS runtime

WORKDIR /opt/app

RUN apk update
RUN apk add --no-cache libgcc libressl tzdata tzdata-utils

ENV USER=appuser
ENV UID=10001
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

COPY --from=rust_builder /usr/local/bin/geoip ./
COPY --from=node_builder /usr/src/app/dist ./dist

RUN mkdir -p /data && chown -R ${UID}:${UID} /data
VOLUME ["/data"]

USER appuser:appuser

ENV DATA_DIR=/data
ENV LISTEN_ADDR=0.0.0.0:8080

EXPOSE 8080

CMD ["/opt/app/geoip"]
