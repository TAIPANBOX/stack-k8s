# The operator's road IN: a WireGuard server for the humans who run this box,
# not for the agents it governs.
#
# Why userspace `wireguard-go` rather than the kernel module: the console has
# to MANAGE peers (issue a device, revoke a device) from inside its own
# container, and it holds no capabilities at all. A kernel interface is
# managed over netlink, which needs NET_ADMIN in the caller. `wireguard-go`
# exposes a userspace API socket instead, so the split is clean: this
# container holds the tunnel and every privilege it needs, the console holds
# one unix socket and none. The data path is slower than the kernel's, which
# is irrelevant for a console session and would matter if this carried fleet
# traffic. It does not.
#
# Nothing about the agents' own path goes through here.

FROM golang:1.23-alpine AS build
# Pinned rather than @latest: an installer that silently changes what it
# installs between two runs of the same script is not reproducible.
RUN go install golang.zx2c4.com/wireguard/cmd/wireguard-go@v0.0.20230223

FROM alpine:3.20
# `wireguard-tools` for `wg`, which talks the same UAPI this image serves, and
# `iproute2` to give the interface its address.
RUN apk add --no-cache wireguard-tools iproute2

COPY --from=build /go/bin/wireguard-go /usr/local/bin/wireguard-go

# Written here rather than shipped as a separate file so the image is one
# self-contained artifact, the same way the other images in this directory are.
RUN cat > /usr/local/bin/wg-entrypoint.sh <<'ENTRY' && chmod +x /usr/local/bin/wg-entrypoint.sh
#!/bin/sh
# Bring up ONE WireGuard interface and hand its UAPI socket to the console.
set -eu

IFACE="${WG_IFACE:-wg-op}"
PORT="${WG_LISTEN_PORT:-51820}"
ADDR="${WG_SERVER_ADDR:-10.9.0.1/24}"
KEY_FILE="${WG_KEY_FILE:-/var/lib/wireguard/server.key}"
SOCK_GID="${WG_SOCKET_GID:-10001}"
SOCK="/var/run/wireguard/${IFACE}.sock"

mkdir -p "$(dirname "$KEY_FILE")" /var/run/wireguard

# Generated once and kept on a volume. Regenerating it on every start would
# invalidate every peer config ever issued, silently: the devices would still
# look configured and would simply never complete a handshake again.
if [ ! -s "$KEY_FILE" ]; then
  umask 077
  wg genkey > "$KEY_FILE"
  echo ">> generated a new server key at $KEY_FILE"
fi
chmod 600 "$KEY_FILE"

# Foreground, so this container's lifecycle IS the tunnel's: no daemon that
# outlives a `docker compose down` and no tunnel that survives its own crash.
WG_PROCESS_FOREGROUND=1 wireguard-go "$IFACE" &
WG_PID=$!

# The socket appears asynchronously. Waiting for it is what makes the rest of
# this script deterministic rather than a race that usually wins.
i=0
while [ ! -S "$SOCK" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    echo "!! wireguard-go did not create $SOCK within 10s" >&2
    kill "$WG_PID" 2>/dev/null || true
    exit 1
  fi
  sleep 0.1
done

wg set "$IFACE" private-key "$KEY_FILE" listen-port "$PORT"
# `|| true`: on a restart with a persisted netns the address can already be
# there, which is success, not failure.
ip address add "$ADDR" dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up

# The console runs as a different, non-root uid and must be able to manage
# peers through this socket. Group access rather than world: everything else
# sharing this volume gets nothing.
chgrp "$SOCK_GID" "$SOCK" 2>/dev/null || echo ">> could not chgrp $SOCK to $SOCK_GID"
chmod 660 "$SOCK"

echo ">> $IFACE up on :$PORT, server public key: $(wg show "$IFACE" public-key)"
echo ">> UAPI socket $SOCK is group $SOCK_GID, the console can manage peers"

# Do not exec-replace: the socket permissions above must be in place first,
# and this process is what notices the tunnel dying.
wait "$WG_PID"
ENTRY

ENTRYPOINT ["/usr/local/bin/wg-entrypoint.sh"]
