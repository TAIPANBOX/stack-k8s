# The operator's way in

```bash
KUBECONFIG=./kubeconfig.yaml ./tunnel/up.sh
```

The console is published nowhere. Every Service in `agent-stack` is ClusterIP,
and `security-tests.sh` asserts it. So there has to be a way in that is not a
public port, and this is it: a WireGuard tunnel the operator issues themselves a
device for, leading to a console that answers only inside it.

Before the tunnel exists, the way in is `ssh -L`. That is the whole reason
`up.sh` issues the first device itself: told to "issue yourself a device from
the console", an operator who has just installed this has no console to click in.

## Two names, and they are yours

This is the only part of this directory that is not the same on every
deployment. Everything else in here is the repository's; these two are the
operator's.

| name | what addresses it | A record points at |
|---|---|---|
| `console_domain` | the BROWSER, from INSIDE the tunnel | `10.9.0.1` |
| `endpoint_host` | the DEVICE, from OUTSIDE, before a tunnel exists | a public address of one of your nodes |

One name cannot do both jobs. It would have to resolve to a public address for
the handshake and to a private one for the console, on the same device, at the
same time.

Set them in `resources.yaml` before the first run. `up.sh` prints both, resolves
both, and refuses to create anything if they do not match reality, which is
worth knowing about in advance rather than in the error:

- **`console_domain` must resolve to `10.9.0.1`.** Publishing a private address
  in public DNS is deliberate and safe. It is reachable only to a device that
  has completed a handshake, and every major resolver returns it (checked
  against 1.1.1.1, 8.8.8.8, 9.9.9.9 and OpenDNS). On Cloudflare, proxying must
  be **off**, or the name resolves to Cloudflare instead of to the tunnel.
- **`endpoint_host` must resolve to a public address this cluster answers on.**
  Left pointing somewhere else, every config the console issues tells a device
  to dial a machine that is not yours, and the device shows "no handshake"
  forever: WireGuard answers nothing at all to a key it does not know, so there
  is no error to read. That silence is the reason the check exists.

WebAuthn binds every passkey to `console_domain` exactly. Changing it later
invalidates the passkeys already enrolled, so it is worth choosing a name you
will keep.

## The certificate

Caddy gets a real Let's Encrypt certificate over DNS-01, because the box
publishes nothing on 80 or 443 and HTTP-01 has nothing to answer.

**DNS-01 here means Cloudflare.** The image is built with one provider plugin:

```dockerfile
RUN xcaddy build --with github.com/caddy-dns/cloudflare
```

Another provider means rebuilding `images/caddy.Dockerfile` with its plugin.
This is a real constraint, not an oversight, and it is written here rather than
discovered.

Put a Cloudflare API token with edit rights on the zone in:

```
~/.config/stack-k8s/cloudflare-token
```

A file, not an argument, so it never reaches a command line or a shell history.
Without it Caddy falls back to its own internal CA, which works only on a device
told to trust it: fine while iterating, useless for anyone else, and the
difference is silent, so `up.sh` says which one it used.

Let's Encrypt allows five certificates per week for the same name. A fresh
`caddy-data` volume issues one, so tearing the tunnel down and up repeatedly is
not free. Count with the CT log, and count `entry_timestamp` rather than
`not_before`, which is backdated about an hour (GOTCHAS 54).

## What it builds

Two namespaces, and the split is the point.

- **`agent-tunnel`**, PodSecurity `privileged`: `wireguard-go`, which needs
  `NET_ADMIN` and `/dev/net/tun`, and Caddy beside it, so the internet egress
  ACME needs belongs to a pod that holds no console and runs no model.
- **`agent-stack`**, PodSecurity `restricted` and unchanged: the console stays
  where the API server enforces that, and gains only environment plus one
  read-only Secret projection.

They talk over TLS 1.3 with a bearer, through a proxy that reads the protocol
and refuses the four operations that would take the tunnel away from everyone
at once (`replace_peers`, `private_key`, `listen_port`, `fwmark`) even from a
caller holding the right token. The daemon reports its private key over the
UAPI; the proxy substitutes the public half, so the private one never crosses.
See `DESIGN-uapi-transport.md` and `evidence/live-run-2026-07-26.md`.

## What you get

`up.sh` ends by issuing the operator's first device, saving
`<console_domain>.conf` beside the script at mode 0600 and printing it as a QR
for a phone. Then, in order: import and connect, open the console, and enrol a
passkey THERE and not earlier.

`FIRST_DEVICE=0` skips the issuance on a re-run, so a second `up.sh` does not
mint a peer nobody asked for. Devices already issued are never touched either
way.

## Going back

```bash
./tunnel/down.sh
kubectl apply -k manifests/
```

`down.sh` deletes the namespace, and with it the volume holding `peers.conf`.
Every device ever issued through this tunnel stops working, and their configs
stay valid-looking and simply never complete a handshake again. That is the
intended meaning of taking the road down, and it is worth saying out loud
because the alternative reads like a bug.
