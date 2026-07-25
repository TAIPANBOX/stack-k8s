# The money plane: tokenfuse-gateway (the budget-enforcing proxy in front of
# the Anthropic Messages API) and tokenfuse-cloud (the control API behind it).
# Both come out of one Rust workspace, so they share one build and the caller
# picks which binary the image runs:
#
#   docker build -f images/tokenfuse.Dockerfile -t stack/tokenfuse:dev ../tokenfuse
#   # then in the manifest: command: ["/usr/local/bin/tokenfuse-cloud"]
#
# Note the gateway's binary is `tokenfuse` in the workspace and is installed as
# `tokenfuse-gateway` by stack-up; both names are present here so a manifest can
# use either without a surprise.
ARG RUST_VERSION=1.85

FROM rust:${RUST_VERSION}-slim AS build
WORKDIR /src
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY . .
RUN cargo build --release -p tokenfuse-gateway -p tokenfuse-cloud

# Debian slim rather than distroless: these link against system OpenSSL, and
# swapping that for rustls is a change to the stack, not to its packaging.
FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /var/lib/stack stack \
 && mkdir -p /var/lib/stack \
 && chown stack:stack /var/lib/stack
LABEL org.opencontainers.image.title="tokenfuse"
LABEL org.opencontainers.image.source="https://github.com/TAIPANBOX/tokenfuse"
COPY --from=build /src/target/release/tokenfuse /usr/local/bin/tokenfuse-gateway
COPY --from=build /src/target/release/tokenfuse /usr/local/bin/tokenfuse
COPY --from=build /src/target/release/tokenfuse-cloud /usr/local/bin/tokenfuse-cloud
VOLUME ["/var/lib/stack"]
# Numeric, for the same reason the Go image is: runAsNonRoot cannot
# verify a user name.
USER 10001:10001
# No default command on purpose: the two binaries are different services and a
# manifest must say which one it is running.
