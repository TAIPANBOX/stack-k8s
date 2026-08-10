# scopyx with a browser, for SCOPYX_BACKEND=chromium.
#
#   docker build -f images/scopyx-browser.Dockerfile \
#     --build-arg SRC=./scopyx -t stack/scopyx-browser:dev .
#
# WHY THIS IS A SEPARATE FILE AND NOT A FLAG ON go-service.Dockerfile
#
# That file builds four planes that are the same shape and produces a
# distroless image of about 15 MB. This one produces about 1 GB, because a
# browser is in it. Folding them together would put a build-arg between an
# operator and a sixty-seven-fold difference in what lands on their disk, and
# the estate's rule is that a decision with a size attached should look like a
# decision.
#
# WHY THE OPERATOR BUILDS IT AT ALL
#
# On a single box, everything else here is built from source too, so this is
# consistent rather than special. In the cluster the published
# `ghcr.io/taipanbox/scopyx:VERSION-chromium` is pulled instead, because a
# cluster pulls and does not build.
#
# THE SANDBOX IS NOT DISABLED HERE
#
# Chromium ships with its renderer sandbox on, and this image leaves it that
# way. Where a container cannot give it the user namespaces it needs, the
# DEPLOYMENT decides between relaxing the container's syscall filter and
# setting SCOPYX_CHROMIUM_NO_SANDBOX=1, and scopyx's own error names both.
ARG GO_VERSION=1.26

FROM golang:${GO_VERSION}-alpine AS build
ENV GOTOOLCHAIN=auto
ARG SRC
WORKDIR /src
COPY ${SRC}/go.mod ${SRC}/go.su[m] ./
RUN go mod download
COPY ${SRC}/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/service ./cmd/scopyx

FROM debian:bookworm-slim
LABEL org.opencontainers.image.title="scopyx (with a browser)"
LABEL org.opencontainers.image.source="https://github.com/TAIPANBOX/scopyx"

# `--no-install-recommends` is load-bearing rather than tidy: the recommends of
# chromium pull a desktop's worth of packages, and every one of them is more
# code on the box that reaches the open web. The removals after it are measured
# rather than folklore, and none of them is drawn by a headless renderer.
RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium ca-certificates fonts-liberation \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /usr/lib/chromium/libVkLayer_khronos_validation.so \
 && rm -rf /usr/share/icons /usr/share/doc /usr/share/man /usr/share/locale \
 && rm -rf /usr/share/X11 /usr/share/mime \
 && groupadd -g 65532 nonroot \
 && useradd -u 65532 -g 65532 -M -s /usr/sbin/nologin nonroot \
 && mkdir -p /var/lib/scopyx \
 && chown 65532:65532 /var/lib/scopyx

VOLUME ["/var/lib/scopyx"]
COPY --from=build /out/service /usr/local/bin/service

# Named rather than searched, so a base image that renames or moves chromium
# fails at startup with a message about the browser instead of at the first
# fetch with a message about the network.
ENV SCOPYX_CHROMIUM=/usr/bin/chromium

# HOME must name a directory that exists and is writable. `useradd -M` creates
# no home directory, and on a k3s pod on EC2 that was fatal: Chromium died with
# `chrome_crashpad_handler: --database is required`, which says nothing about a
# home directory. Measured there 2026-08-10, and NOT reproduced under `docker
# run` locally in any shape tried, so the precise trigger is not isolated. The
# fix stands regardless.
ENV HOME=/tmp

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/service"]
