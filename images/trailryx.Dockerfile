# The record plane's sealing tools: `trailryx-node`, which reads the shared
# event log and seals what it maps into a tamper-evident store, and
# `trailryx-verify`, which proves a pack of it offline.
#
#   docker build -f images/trailryx.Dockerfile -t stack/trailryx:dev ../trailryx
#
# WHAT THIS BUILDS, AND WHO READS IT
#
# The two sealing binaries, `trailryx-node` and `trailryx-verify`, built from a
# trailryx checkout. The same binaries are published: ghcr.io/taipanbox/trailryx-node
# carries both, and the manifests pull that image by tag (v1.2.0 today). So no
# manifest names `stack/trailryx:dev`, and nothing that runs reads this build.
#
# It is here for a source build: a trailryx checkout that is not released yet,
# or a cluster that cannot reach ghcr.io. Using it means editing the image line
# in the manifest, the same as any other `stack/*:dev` tag (pinned-images.sh).
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
