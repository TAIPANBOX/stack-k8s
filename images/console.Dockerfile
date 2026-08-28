# The Genaryx console, plus the four tools it EXECUTES rather than calls.
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
ARG RUST_VERSION=1.85
ARG GO_VERSION=1.27
ARG PYTHON_VERSION=3.12
ARG NODE_VERSION=22

# --- the console's own web assets -------------------------------------------
FROM node:${NODE_VERSION}-slim AS web
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
FROM rust:${RUST_VERSION}-slim AS rust
WORKDIR /src
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY genaryx-a360/ ./
RUN cargo build --release -p genaryx-web

# --- the Go tools the console shells out to ---------------------------------
FROM golang:${GO_VERSION}-alpine AS gotools
ENV GOTOOLCHAIN=auto
WORKDIR /src
COPY qryx/ ./qryx/
COPY mockryx/ ./mockryx/
RUN cd qryx    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/qryx    ./cmd/qryx \
 && cd ../mockryx && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/mockryx ./cmd/mockryx

# --- runtime ----------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /var/lib/stack stack \
 && mkdir -p /var/lib/stack /var/lib/stack/events \
 && chown -R stack:stack /var/lib/stack
LABEL org.opencontainers.image.title="genaryx-console"

# The two Python tools, installed as real console-invokable commands
# (`verdryx`, `engram-mcp` - see their pyproject [project.scripts]).
COPY verdryx/ /opt/verdryx/
COPY engram/  /opt/engram/
RUN pip install --no-cache-dir /opt/verdryx /opt/engram \
 && rm -rf /root/.cache

COPY --from=gotools /out/qryx    /usr/local/bin/qryx
COPY --from=gotools /out/mockryx /usr/local/bin/mockryx
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
