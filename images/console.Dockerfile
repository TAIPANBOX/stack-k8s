# The Genaryx console, plus the four tools it EXECUTES rather than calls, and the
# two engines its proofs run (wardryx replay, tokenfuse backtest), copied from the
# images the stack runs.
#
# This is a four-language build on purpose, not by accident. The console
# reaches money, policy and identity over HTTP (those are Services), but it
# reaches qryx, mockryx, verdryx and engram by spawning them: `engram-mcp`
# speaks MCP over stdio to a child process, and the other three are shelled
# out to. A sidecar container cannot be another container's stdin, so these
# binaries have to be in this image or the Crypto, Drills, Quality and Memory
# tabs are permanently empty on a cluster. See ../README.md, "Fact 2".
#
#   docker build -f images/console.Dockerfile -t stack/genaryx-console:dev ..
#
# Build context is the PARENT of the repos (~/Development), because this one
# image legitimately spans five of them.
# --- the console's own web assets -------------------------------------------
FROM node:22-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d AS web
WORKDIR /w
COPY genaryx-a360/apps/web/package.json genaryx-a360/apps/web/pnpm-lock.yam[l] ./
RUN corepack enable && (pnpm install --frozen-lockfile || npm install)
COPY genaryx-a360/apps/web/ ./
# `--mode web` is not a preference, it is which PRODUCT this bundle is.
# It loads apps/web/.env.web, whose one line sets `VITE_GENARYX_API=/api`, and
# that variable is what `src/lib/transport.ts` reads to decide whether a
# backend exists at all. Build without it (a bare `vite build`) and the bundle
# is the no-backend preview: it never calls genaryx-web, so the sign-in gate
# never appears and every panel renders its own "no environment found" empty
# state. The console then looks broken in a way that points at the cluster,
# while the cluster is fine and the browser is simply not talking to it.
# See ../GOTCHAS.md, item 15.
RUN npx vite build --mode web

# --- the console binary -----------------------------------------------------
FROM rust:1.85-slim@sha256:9f841bbe9e7d8e37ceb96ed907265a3a0df7f44e3737d0b100e7907a679acb36 AS rust
WORKDIR /src
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY genaryx-a360/ ./
RUN cargo build --release -p genaryx-web

# --- the Go tools the console shells out to ---------------------------------
FROM golang:1.27.3-alpine@sha256:dbaa054703263d06c8b49576667418473b6231f8c0fa69dee103207fdb8e3654 AS gotools
# A digest outranks the tag beside it, so a bump that moved the tag alone would
# keep the old Go under the new name. This line stops that build (invariant 80).
RUN test "$(go env GOVERSION)" = go1.27.3
ENV GOTOOLCHAIN=auto
WORKDIR /src
COPY qryx/ ./qryx/
COPY mockryx/ ./mockryx/
RUN cd qryx    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/qryx    ./cmd/qryx \
 && cd ../mockryx && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/mockryx ./cmd/mockryx

# --- the two engines the console's proofs run -------------------------------
# The console proves a candidate policy by running `wardryx replay` over the
# decisions already recorded, and a candidate budget by running `tokenfuse
# backtest` over the calls already recorded (genaryx invariants 40 and 41). A
# proof is only as good as the engine behind it, so these two binaries are
# copied from the very images the stack runs, by the same digests the manifests
# name: the engine that replays a decision is the engine that took it.
# scripts/console-engines-are-the-stacks.sh holds the two references equal to
# manifests/10-planes.yaml's (CLAUDE.md invariant 79), and moving one without
# the other fails it. Pulled, not built: the node builds nothing it can pull.
FROM ghcr.io/taipanbox/wardryx:v2.5.1@sha256:2d3c0c9c0798156d3f05b82d0e63cf5b38ee4b9875d6bdbac1829f219c26abf7 AS wardryx-engine
FROM ghcr.io/taipanbox/tokenfuse:v1.21.0@sha256:5cc6484d20249df3e57db34d19eea5b75c54c64bd9b9dab968136e988374ab2c AS tokenfuse-engine

# --- runtime ----------------------------------------------------------------
FROM python:3.12-slim@sha256:4840d514c583a4d3d8cad3940e68dee6f0f6f3635c12fcd0a3d74c21a5b93a54
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /var/lib/stack stack \
 && mkdir -p /var/lib/stack /var/lib/stack/events \
 && chown -R stack:stack /var/lib/stack
LABEL org.opencontainers.image.title="genaryx-console"
# Which engines the proofs run, readable from `docker inspect`: the question an
# incident asks of a proof is which wardryx replayed it.
LABEL dev.taipanbox.engine.wardryx="v2.5.1@sha256:2d3c0c9c0798156d3f05b82d0e63cf5b38ee4b9875d6bdbac1829f219c26abf7"
LABEL dev.taipanbox.engine.tokenfuse="v1.21.0@sha256:5cc6484d20249df3e57db34d19eea5b75c54c64bd9b9dab968136e988374ab2c"

# The two Python tools, installed as real console-invokable commands
# (`verdryx`, `engram-mcp` - see their pyproject [project.scripts]).
COPY verdryx/ /opt/verdryx/
COPY engram/  /opt/engram/
RUN pip install --no-cache-dir /opt/verdryx /opt/engram \
 && rm -rf /root/.cache

COPY --from=gotools /out/qryx    /usr/local/bin/qryx
COPY --from=gotools /out/mockryx /usr/local/bin/mockryx
COPY --from=wardryx-engine /usr/local/bin/service /usr/local/bin/wardryx
COPY --from=tokenfuse-engine /usr/local/bin/tokenfuse /usr/local/bin/tokenfuse
COPY --from=rust /src/target/release/genaryx-web /usr/local/bin/genaryx-web
COPY --from=web  /w/dist /srv/ui

# Where the console keeps its own state (operator record, passkeys) and where
# the shared event volume gets mounted. Both are volumes: an image that
# carried either would be an image that carried a credential.
ENV HOME=/var/lib/stack
VOLUME ["/var/lib/stack"]
EXPOSE 7420
# Numeric, for the same reason the Go image is: runAsNonRoot cannot
# verify a user name.
USER 10001:10001
# Binds wide inside the pod on purpose: the Service, the NetworkPolicy and the
# operator's own tunnel are what keep this off the internet, not a loopback
# bind that would also hide it from kubelet's probes.
ENTRYPOINT ["/usr/local/bin/genaryx-web", "serve", "--bind", "0.0.0.0:7420", "--ui", "/srv/ui"]
