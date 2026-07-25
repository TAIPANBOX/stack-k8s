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
# `git` first: `go install` fetches this module over git and fails with a bare
# exit 1 without it.
RUN apk add --no-cache git
# The module's main package is at its ROOT, not under `cmd/`, and its release
# tags (`v0.0.20230223`-style) do not resolve through the Go module proxy at
# all: only the pseudo-version does. Both of those cost a failed build to
# learn, so the working form is written down here rather than rediscovered.
# Pinned rather than @latest, because an installer that silently installs
# something different between two runs of the same script is not reproducible.
RUN go install golang.zx2c4.com/wireguard@v0.0.0-20260522210424-ecfc5a8d5446

FROM alpine:3.20
# `wireguard-tools` for `wg`, which talks the same UAPI this image serves, and
# `iproute2` to give the interface its address.
RUN apk add --no-cache wireguard-tools iproute2

# The binary takes its name from the module, so it installs as `wireguard`.
# Renamed here to the name every piece of WireGuard documentation uses.
COPY --from=build /go/bin/wireguard /usr/local/bin/wireguard-go

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

# `-f`, not the WG_PROCESS_FOREGROUND environment variable. Without it
# wireguard-go DAEMONISES: the process this script starts forks and exits
# immediately, so `$!` names a parent that is already gone, `wait` returns at
# once, this script ends, and the container restarts - taking the tunnel and
# its socket with it. The symptom is a container in a restart loop with exit
# code 0, a UAPI socket that appears and vanishes, and `wg set` failing with
# "Unable to access interface: Protocol error" against a daemon that just
# died. The flag is what makes the container's lifecycle the tunnel's.
#
# The second variable is not optional here either, despite how it is spelled.
# wireguard-go REFUSES to start on a kernel that has WireGuard built in, and
# prints a box telling you to use the kernel module instead. That advice is
# right for a normal tunnel and wrong for this one: a kernel interface is
# driven over netlink inside THIS container's network namespace, and the
# console lives in a different container with no privileges, so it could never
# manage peers on it. The userspace implementation is what exposes the UAPI
# socket, and that socket is the whole privilege split. The performance it
# costs is irrelevant for a console session and would matter only if this
# carried fleet traffic, which it does not.
WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1 wireguard-go -f "$IFACE" &
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

# Assert rather than announce. The previous version printed "up" with an empty
# key while the daemon was already dead, which is the worst possible output: a
# healthy-looking line for a tunnel nobody can reach.
SERVER_PUB="$(wg show "$IFACE" public-key 2>/dev/null || true)"
if [ -z "$SERVER_PUB" ]; then
  echo "!! $IFACE reports no public key: the tunnel is not actually up" >&2
  kill "$WG_PID" 2>/dev/null || true
  exit 1
fi
echo ">> $IFACE up on :$PORT, server public key: $SERVER_PUB"
echo ">> UAPI socket $SOCK is group $SOCK_GID, the console can manage peers"

# Do not exec-replace: the socket permissions above must be in place first,
# and this process is what notices the tunnel dying.
wait "$WG_PID"
ENTRY

ENTRYPOINT ["/usr/local/bin/wg-entrypoint.sh"]
