# One image for every Go plane in the stack: wardryx (policy), idryx
# (identity), qryx (crypto), mockryx (drills). All four are the same shape -
# a module at the repo root with its entrypoint at cmd/<name>/main.go - so
# they take one parameterised build rather than four near-identical files.
#
#   docker build -f images/go-service.Dockerfile \
#     --build-arg SERVICE=wardryx --build-arg SRC=../wardryx \
#     -t stack/wardryx:dev ..
#
# Static binary, distroless runtime, non-root: nothing in the final layer can
# run a shell, which matters more than usual for a policy decision point.
ARG GO_VERSION=1.26

FROM golang:${GO_VERSION}-alpine AS build
ENV GOTOOLCHAIN=auto
ARG SERVICE
ARG SRC
WORKDIR /src
# Dependencies first, so a code-only change does not re-download the module
# graph on every build.
COPY ${SRC}/go.mod ${SRC}/go.su[m] ./
RUN go mod download
COPY ${SRC}/ ./
# CGO off is what makes this runnable on distroless static; trimpath keeps the
# build reproducible and keeps local paths out of the binary.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
      -ldflags="-s -w" \
      -o /out/service ./cmd/${SERVICE}

FROM gcr.io/distroless/static-debian12:nonroot
ARG SERVICE
LABEL org.opencontainers.image.title="${SERVICE}"
LABEL org.opencontainers.image.source="https://github.com/TAIPANBOX/${SERVICE}"
# The event directory and any per-service store are mounted, never baked.
VOLUME ["/var/lib/stack"]
COPY --from=build /out/service /usr/local/bin/service
# 65532 is distroless's `nonroot` uid. Numeric on purpose: a kubelet with
# runAsNonRoot cannot verify a NAME, and refuses the container outright.
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/service"]
