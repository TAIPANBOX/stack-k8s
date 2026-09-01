# CostCrew, the finops plane, as a cluster image.
#
#   docker build -f images/costcrew.Dockerfile -t stack/costcrew:dev ../costcrew
#
# Why this is not go-service.Dockerfile, which already builds the four plain Go
# planes: that file builds ONE binary, `./cmd/${SERVICE}`, and this repository
# needs two. The console and the thing that spends money are deliberately
# separate programs in CostCrew's own design - the console reads, shows and
# records, and holds no credential and makes no outbound call; `tools/run` is
# what calls a model, and it is the only half that is ever given a key. Baking
# both into one image keeps that separation visible in the manifest (one
# Deployment with no Secret, one suspended CronJob with one) instead of
# dissolving it into a single entrypoint that could do either.
#
# CGO off works here for the same reason the console advertises: the SQLite
# driver is pure Go, so there is no C dependency to carry into a static
# runtime.
ARG GO_VERSION=1.27

FROM golang:${GO_VERSION}-alpine AS build
ENV GOTOOLCHAIN=auto
WORKDIR /src
# Dependencies first, so a code-only change does not re-download the module
# graph on every build.
COPY go.mod go.su[m] ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/costcrew ./cmd/costcrew \
 && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/costcrew-run ./tools/run

FROM gcr.io/distroless/static-debian12:nonroot
LABEL org.opencontainers.image.title="costcrew"
LABEL org.opencontainers.image.source="https://github.com/TAIPANBOX/costcrew"
# The database, the journal and the signing key are mounted, never baked.
VOLUME ["/var/lib/costcrew"]
COPY --from=build /out/costcrew     /usr/local/bin/costcrew
COPY --from=build /out/costcrew-run /usr/local/bin/costcrew-run
# 65532 is distroless's `nonroot` uid. Numeric on purpose: a kubelet with
# runAsNonRoot cannot verify a NAME, and refuses the container outright.
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/costcrew"]
