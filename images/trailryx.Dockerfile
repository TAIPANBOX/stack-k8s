# The record plane's sealing tools: `trailryx-node`, which reads the shared
# event log and seals what it maps into a tamper-evident store, and
# `trailryx-verify`, which proves a pack of it offline.
#
#   docker build -f images/trailryx.Dockerfile -t stack/trailryx:dev ../trailryx
#
# WHY THIS IS BUILT HERE RATHER THAN PULLED
#
# trailryx publishes a GHCR image and it carries `trailryx-ingest` only. The
# release workflow builds `trailryx-verify` and `trailryx-ingest`, and every
# sealing command lives in `trailryx-node`, which is published nowhere. So a
# deployment that wants a sealed record has no pull-and-run path today.
#
# Building it here is the established answer for exactly this case rather than
# a workaround: `stack/tokenfuse:dev` comes out of an unpublished Rust
# workspace the same way, and `pinned-images.sh` accepts a locally built
# `stack/*:dev` tag on that basis. The day trailryx ships `trailryx-node` in
# its image, this file goes away and the manifest names
# `ghcr.io/taipanbox/trailryx:vX.Y.Z` instead, with nothing else moving.
ARG RUST_VERSION=1.85

FROM rust:${RUST_VERSION}-slim AS build
WORKDIR /src
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY . .
# --locked, because a record plane that built against a different dependency
# set than its own lockfile names is one whose reproducibility claim is a
# guess. trailryx's own `scripts/reproduce.sh` makes the same demand of the
# verifier.
RUN cargo build --release --locked -p trailryx-node -p trailryx-verify

FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /var/lib/stack stack \
 && mkdir -p /var/lib/stack \
 && chown stack:stack /var/lib/stack
LABEL org.opencontainers.image.title="trailryx"
LABEL org.opencontainers.image.source="https://github.com/TAIPANBOX/trailryx"
COPY --from=build /src/target/release/trailryx-node /usr/local/bin/trailryx-node
COPY --from=build /src/target/release/trailryx-verify /usr/local/bin/trailryx-verify
VOLUME ["/var/lib/stack"]
# Numeric, for the same reason the other images are: runAsNonRoot cannot verify
# a user name.
USER 10001:10001
# No default command on purpose: this image carries two tools and a manifest
# must say which one it is running.
