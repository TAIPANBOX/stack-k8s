# syntax=docker/dockerfile:1.7
# REQUIRES BuildKit. The entrypoint below is written with a heredoc, which only
# the BuildKit frontend understands. The legacy builder accepts the Dockerfile,
# reports success, and produces an EMPTY entrypoint: the container then dies
# with "exec format error" and nothing in the build output hints why
# (GOTCHAS.md item 47). Build with `DOCKER_BUILDKIT=1` and docker-buildx
# installed.
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

# The authenticated, filtering door for a console in ANOTHER pod. Built from
# this repository rather than fetched: standard library only, so there is
# nothing to resolve and the dependency list stays a security property.
# CGO off so it runs on the distroless-ish alpine below without a libc match.
COPY images/uapi-proxy /src/uapi-proxy
RUN cd /src/uapi-proxy && CGO_ENABLED=0 go build -ldflags='-s -w' -o /go/bin/uapi-proxy ./...

FROM alpine:3.20
# `wireguard-tools` for `wg`, which talks the same UAPI this image serves,
# `iproute2` to give the interface its address, and `socat` for the console
# relay (see the entrypoint: the real UAPI socket must stay 0700).
RUN apk add --no-cache wireguard-tools iproute2 socat

# The binary takes its name from the module, so it installs as `wireguard`.
# Renamed here to the name every piece of WireGuard documentation uses.
COPY --from=build /go/bin/wireguard /usr/local/bin/wireguard-go
COPY --from=build /go/bin/uapi-proxy /usr/local/bin/uapi-proxy

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
# What the console connects to. A separate path so the real socket keeps the
# 0700 wireguard-go requires; see the relay below.
RELAY="${WG_CONSOLE_SOCKET:-/var/run/wireguard/console.sock}"
# Where the tunnel leads. The address is this interface's own, and the target
# is the console service by compose name, so the forward below follows the
# same DNS the rest of the stack uses.
TUNNEL_IP="${WG_TUNNEL_IP:-10.9.0.1}"
CONSOLE_HOST="${WG_CONSOLE_HOST:-console}"
CONSOLE_PORT="${WG_CONSOLE_PORT:-7420}"
# Issued peers, kept beside the server key. Without this every restart of this
# container silently revokes every device ever issued: the configs on those
# phones stay valid-looking and simply never complete a handshake again.
PEERS_FILE="${WG_PEERS_FILE:-/var/lib/wireguard/peers.conf}"
PEERS_SAVE_SECONDS="${WG_PEERS_SAVE_SECONDS:-10}"
# The network door, for a console that is NOT in this pod. Empty means off,
# which is every single-box install: compose shares a volume, so the unix relay
# below is the whole story there and this must not change it. Set it and the
# certificate, key and bearer become required rather than defaulted, because a
# missing one would mean "trust nothing" or "accept an empty bearer".
PROXY_LISTEN="${WG_PROXY_LISTEN:-}"
PROXY_CERT="${WG_PROXY_CERT:-/etc/wg-proxy/tls.crt}"
PROXY_KEY="${WG_PROXY_KEY:-/etc/wg-proxy/tls.key}"
PROXY_TOKEN_FILE="${WG_PROXY_TOKEN_FILE:-/etc/wg-proxy/token}"

mkdir -p "$(dirname "$KEY_FILE")" /var/run/wireguard

# The socket directory is a VOLUME, so it survives this container. A socket
# file left by a killed predecessor makes the next wireguard-go exit with
# "UAPI listen error: unix socket in use", which turns any ungraceful stop
# into a permanent restart loop that the logs blame on the kernel module.
# This container is the only thing that ever owns this interface, so a
# leftover file is by definition stale. Removed only when nothing is
# listening on it, so a second copy started by mistake fails loudly instead
# of silently stealing a live tunnel's socket.
if [ -S "$SOCK" ]; then
  if wg show "$IFACE" >/dev/null 2>&1; then
    echo "!! $SOCK is live: another wireguard-go already owns $IFACE" >&2
    exit 1
  fi
  echo ">> removing a stale $SOCK left by a previous container"
  rm -f "$SOCK"
fi

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
# The directory, not the socket. It is setgid and owned by the console's
# group so the relay created inside it below inherits that group without a
# fix-up afterwards. The real UAPI socket is deliberately left exactly as
# wireguard-go makes it (0700, root): loosening THAT is what breaks the
# daemon, which is why the relay exists at all.
chgrp "$SOCK_GID" /var/run/wireguard 2>/dev/null \
  || echo ">> could not chgrp the socket directory to $SOCK_GID"
chmod 2770 /var/run/wireguard
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

# Wait for the daemon to ANSWER, not for its socket file to exist. The file
# appears first and the daemon is not ready behind it yet, so a wait on `-S`
# returns after ~100ms and everything after it lands in that gap: `wg set`
# reports success, the configuration is dropped, and the interface then has no
# public key. That failure reads as a bad key or a broken image, and it is
# neither. `wg show` is the readiness probe because it is the same round trip
# the configuration below performs.
i=0
while ! wg show "$IFACE" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    echo "!! wireguard-go did not answer on $SOCK within 10s" >&2
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
#
# State is printed before touching it because everything above can succeed
# while the socket is gone: that combination is what a dead daemon looks like
# from here, and without this line it surfaces only as a bare `chmod: No such
# file or directory` with nothing to attribute it to.
if ! kill -0 "$WG_PID" 2>/dev/null; then
  echo "!! wireguard-go (pid $WG_PID) died during bring-up" >&2
  exit 1
fi
if [ ! -S "$SOCK" ]; then
  echo "!! $SOCK vanished after bring-up while the daemon is still alive" >&2
  echo "   directory now holds: $(ls -a /var/run/wireguard 2>&1 | tr '\n' ' ')" >&2
  exit 1
fi

# The console reaches the UAPI through a RELAY, not through the real socket.
#
# The real socket cannot be shared by loosening it: wireguard-go requires its
# own socket to stay 0700 and starts answering "Unable to access interface:
# Protocol error" the moment the mode changes, so `chmod 0770` on it does not
# grant access, it breaks the tunnel. Verified directly: the interface reports
# its public key before the chmod and errors immediately after.
#
# So the permission lives on a second socket that forwards to the first. The
# console gets exactly the access it needs, the daemon keeps the posture it
# insists on, and the forwarder is a place a future version can log or
# restrict what crosses it.
socat "UNIX-LISTEN:$RELAY,fork,unlink-early,mode=0660,group=$SOCK_GID" \
      "UNIX-CONNECT:$SOCK" &
RELAY_PID=$!

k=0
while [ ! -S "$RELAY" ]; do
  k=$((k + 1))
  if [ "$k" -gt 50 ]; then
    echo "!! the console relay socket never appeared at $RELAY" >&2
    kill "$WG_PID" "$RELAY_PID" 2>/dev/null || true
    exit 1
  fi
  sleep 0.1
done

# Assert rather than announce. The previous version printed "up" with an empty
# key while the daemon was already dead, which is the worst possible output: a
# healthy-looking line for a tunnel nobody can reach.
SERVER_PUB="$(wg show "$IFACE" public-key 2>/dev/null || true)"
if [ -z "$SERVER_PUB" ]; then
  echo "!! $IFACE reports no public key: the tunnel is not actually up" >&2
  kill "$WG_PID" 2>/dev/null || true
  exit 1
fi
# The network door, once the interface is up and its public key is known. That
# ordering matters: the proxy substitutes this key for the private one the
# daemon reports, so starting it earlier would mean starting it with nothing to
# substitute.
if [ -n "$PROXY_LISTEN" ]; then
  for f in "$PROXY_CERT" "$PROXY_KEY" "$PROXY_TOKEN_FILE"; do
    if [ ! -s "$f" ]; then
      echo "!! WG_PROXY_LISTEN is set but $f is missing or empty." >&2
      echo "   The network door needs a certificate, its key and a bearer; install.sh writes all three." >&2
      kill "$WG_PID" "$RELAY_PID" 2>/dev/null || true
      exit 1
    fi
  done
  PROXY_LISTEN="$PROXY_LISTEN" PROXY_CERT="$PROXY_CERT" PROXY_KEY="$PROXY_KEY" \
  PROXY_TOKEN_FILE="$PROXY_TOKEN_FILE" UAPI_SOCKET="$SOCK" SERVER_PUBKEY_B64="$SERVER_PUB" \
    /usr/local/bin/uapi-proxy &
  PROXY_PID=$!
  echo ">> network door on $PROXY_LISTEN, forwarding to $SOCK"
else
  PROXY_PID=""
fi

# Restore the devices this box had authorized before it restarted. `addconf`
# rather than `setconf`: it ADDS the saved peers and leaves the interface's own
# key and port alone, where `setconf` would rewrite the whole interface from a
# file that deliberately carries no private key.
if [ -s "$PEERS_FILE" ]; then
  if wg addconf "$IFACE" "$PEERS_FILE"; then
    echo ">> restored $(grep -c '^\[Peer\]' "$PEERS_FILE") previously issued device(s)"
  else
    echo "!! could not restore $PEERS_FILE; issued devices will not reconnect" >&2
  fi
fi

# Peers are changed by the CONSOLE, over the UAPI, so this container never sees
# an event to save on. It snapshots instead: cheap, and the worst case is
# losing the last few seconds of changes, where the alternative is losing all
# of them on every restart. The peer list carries public keys and allowed IPs
# only - no private key of any kind is written here.
save_peers() {
  wg showconf "$IFACE" 2>/dev/null \
    | awk '/^\[Peer\]/{p=1} p' > "${PEERS_FILE}.tmp" 2>/dev/null \
    && mv "${PEERS_FILE}.tmp" "$PEERS_FILE"
}
while sleep "$PEERS_SAVE_SECONDS"; do save_peers; done &
SAVER_PID=$!
# A clean stop saves immediately, so a planned restart loses nothing at all.
# `:-` on every pid: this trap is armed before the forwarder below exists, and
# under `set -u` an unset variable in the handler would turn a clean shutdown
# into an error that skips the save.
trap 'save_peers; kill "${WG_PID:-}" "${RELAY_PID:-}" "${CONSOLE_FWD_PID:-}" "${SAVER_PID:-}" "${PROXY_PID:-}" 2>/dev/null; exit 0' TERM INT

# The tunnel has to LEAD somewhere. The interface address lives in this
# container's network namespace and the console runs in another, so a client
# that completes a handshake and dials the console still gets "connection
# refused" from an address that answers nothing: a tunnel into an empty room.
# Verified exactly that way before this existed.
#
# So the console's port is forwarded from the tunnel address to the console
# service, by name, over the compose network. Bound to the tunnel address
# alone: this must never become a second way to reach the console from the
# host or the internet, which is the whole reason the console is on loopback.
socat "TCP-LISTEN:${CONSOLE_PORT},bind=${TUNNEL_IP},fork,reuseaddr" \
      "TCP:${CONSOLE_HOST}:${CONSOLE_PORT}" &
CONSOLE_FWD_PID=$!

echo ">> $IFACE up on :$PORT, server public key: $SERVER_PUB"
echo ">> console reachable at http://${TUNNEL_IP}:${CONSOLE_PORT} from inside the tunnel"
echo ">> console relay $RELAY is group $SOCK_GID mode 0660; $SOCK stays 0700"

# Do not exec-replace: the socket permissions above must be in place first,
# and this process is what notices the tunnel dying.
wait "$WG_PID" "$RELAY_PID" "$CONSOLE_FWD_PID" ${PROXY_PID:+"$PROXY_PID"}
ENTRY

# A heredoc that silently produced nothing is the failure this catches: the
# build fails here instead of the container failing at runtime.
RUN test -s /usr/local/bin/wg-entrypoint.sh || (echo "entrypoint is EMPTY: build with DOCKER_BUILDKIT=1" >&2; exit 1)

ENTRYPOINT ["/usr/local/bin/wg-entrypoint.sh"]
