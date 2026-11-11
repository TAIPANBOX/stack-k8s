# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
# REQUIRES BuildKit. The entrypoint below is written with a heredoc, which only
# the BuildKit frontend understands. The legacy builder accepts the Dockerfile,
# reports success, and produces an EMPTY entrypoint: the container then dies
# with "exec format error" and nothing in the build output hints why
# (GOTCHAS.md item 47). Build with `DOCKER_BUILDKIT=1` and docker-buildx
# installed.
# TLS for the console, inside the operator's own tunnel.
#
# Why this exists at all: WebAuthn - the passkey ceremony every destructive
# action is confirmed with - only runs in a secure context. That means HTTPS or
# `localhost`, and a console reached at `http://10.9.0.1:7420` over WireGuard is
# neither, so the browser refuses to expose the API at all. Worse, WebAuthn
# scopes credentials to a DOMAIN and forbids a bare IP as the relying party, so
# no amount of configuration makes `10.9.0.1` work. Passkeys and the tunnel are
# two features that cannot coexist without a name and a certificate.
#
# Why the certificate cannot be obtained the usual way: the box deliberately
# publishes nothing on 80/443, so the HTTP-01 challenge has nothing to answer.
# DNS-01 proves domain ownership by writing a TXT record instead, which works
# for a machine the internet cannot reach - and that is exactly this machine.
# It needs a DNS provider plugin, and the stock Caddy image ships none, so this
# builds one in.
#
# The whole point is a certificate for a name that resolves to a PRIVATE
# address. That is not a trick: the certificate attests to the name, and where
# the name points is the operator's business. It is how every "reach my private
# thing by hostname" product works.

# Built on the Go every other image here names, not on caddy's own builder image.
# That image carries whichever Go it was cut with, so a Go advisory would wait on
# its release, and `caddy:2-builder-alpine` moved under this file at every rebuild.
# Go, xcaddy, Caddy and the plugin are each named, so a rebuild of one tag compiles
# the same inputs (invariant 80). XCADDY_SETCAP is what the builder image set, and
# the published binary carries it: cap_net_bind_service.
FROM golang:1.27.4-alpine@sha256:0a5f7fe796599ff487605987432e7619ae45beeb2fba4c2ce0b907879932aebf AS build
# A digest outranks the tag beside it, so a bump that moved the tag alone would
# keep the old Go under the new name. This line stops that build (invariant 80).
RUN test "$(go env GOVERSION)" = go1.27.4
RUN apk add --no-cache git libcap
ENV XCADDY_SETCAP=1
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7
# Cloudflare because that is where the zone this ships against is hosted. Any
# other provider is a one-word change here plus the matching credential.
RUN xcaddy build v2.11.8 --with github.com/caddy-dns/cloudflare@v0.2.4 --output /usr/bin/caddy

FROM caddy:2.11.8-alpine@sha256:f6228111e5fafa1a5238258d0858e103f10599b8d1659a146e7726681a002bb9
COPY --from=build /usr/bin/caddy /usr/bin/caddy

RUN cat > /usr/local/bin/caddy-entrypoint.sh <<'ENTRY' && chmod +x /usr/local/bin/caddy-entrypoint.sh
#!/bin/sh
# Write a Caddyfile for whichever certificate this box can actually get, then
# run it. Two modes, chosen by whether a DNS credential is present rather than
# by a separate switch the operator could set inconsistently.
set -eu

DOMAIN="${CONSOLE_DOMAIN:-}"
UPSTREAM="${CONSOLE_UPSTREAM:-console:7420}"
CF_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

if [ -z "$DOMAIN" ]; then
  echo "!! CONSOLE_DOMAIN is not set: there is no name to put on a certificate." >&2
  echo "   WebAuthn scopes credentials to a domain and refuses a bare IP, so the" >&2
  echo "   console needs a name even inside the tunnel. Set it in .env." >&2
  exit 1
fi

if [ -n "$CF_TOKEN" ]; then
  # A real, publicly-trusted certificate. No device has to be told to trust
  # anything, which is what makes a passkey enrolled on a laptop work on a
  # phone as well.
  MODE="letsencrypt via DNS-01"
  cat > /etc/caddy/Caddyfile <<EOF
{
$( [ -n "$ACME_EMAIL" ] && echo "  email $ACME_EMAIL" )
}

$DOMAIN {
  tls {
    dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    # The record points at a private address, so Caddy must not try to reach
    # the name itself to check propagation from in here.
    propagation_delay 30s
    resolvers 1.1.1.1 8.8.8.8
  }
  reverse_proxy $UPSTREAM
}
EOF
else
  # No DNS credential: Caddy issues from its own internal CA. This still gives
  # the browser a secure context, but ONLY on devices that have been told to
  # trust that CA - so it is the honest fallback for one operator testing,
  # never the answer for a fleet of devices.
  MODE="internal CA (self-signed; each device must trust it)"
  cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
  tls internal
  reverse_proxy $UPSTREAM
}
EOF
fi

echo ">> console TLS for $DOMAIN -> $UPSTREAM, $MODE"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ENTRY

# A heredoc that silently produced nothing is the failure this catches: the
# build fails here instead of the container failing at runtime.
RUN test -s /usr/local/bin/caddy-entrypoint.sh || (echo "entrypoint is EMPTY: build with DOCKER_BUILDKIT=1" >&2; exit 1)

ENTRYPOINT ["/usr/local/bin/caddy-entrypoint.sh"]
