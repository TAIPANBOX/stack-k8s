# Giving the console a network path to the tunnel daemon

A design, for review before any code. Written 2026-07-26, after the tunnel was
proven end to end on a live cluster and the shape it forced turned out to cost
more than expected.

## What this is trying to undo

The console manages WireGuard peers over a **unix socket**. A unix socket
cannot cross a pod boundary, so the daemon must share the console's pod. The
daemon needs `CAP_NET_ADMIN` and a `/dev/net/tun` hostPath, so that pod is
privileged, so it cannot live in a namespace enforcing `restricted`
(GOTCHAS 46). Everything else follows from that one sentence:

- the console left `agent-stack` for a namespace enforcing `privileged`, where
  the API server no longer checks the posture the pod promises
- Caddy came with it, and Caddy needs the open internet for ACME, and a
  NetworkPolicy selects a POD, so the console inherited a way out past the
  gateway (GOTCHAS 49). That punctures the claim the whole deployment is built
  to make.
- the shared event log had to be reached over NFS across namespaces, and the
  generated credentials now exist in two places

None of that is a mistake in the manifests. It is all downstream of "unix
socket". Remove the constraint and every one of those costs disappears: the
console goes back into `restricted` in `agent-stack`, Caddy goes with the
daemon where its egress harms nothing, and the event log stops crossing a
boundary.

## What is NOT proposed

**Moving the peer logic to the daemon.** `operator_wg_config` and
`operator_wg_revoke` take a `BusHandle` and journal who was given a way in and
who was cut off. That audit trail is the reason this component exists at all.
Move the logic and it either follows the daemon into a pod with no bus, or it
needs a callback, which is worse than the problem. **The logic and the audit
stay in the console; only the transport moves.**

## The three pieces

### 1. Transport

Today all UAPI traffic goes through one function:

```rust
pub struct UapiSocket { path: PathBuf }
fn request(&self, body: &str) -> Result<String, WgUapiError> {
    let mut sock = UnixStream::connect(&self.path)?;
```

`path: PathBuf` becomes an enum over `Unix(PathBuf)` and `Tcp(SocketAddr)`, and
`request` picks a stream. `GENARYX_WG_UAPI_SOCKET` keeps meaning a path when it
starts with `/`, and a `host:port` otherwise, so nothing already deployed
changes behaviour. Tens of lines, one file, existing tests keep passing because
the unix path is untouched.

### 2. The private key must never cross

This is the part that changed the design, and it is worth stating carefully.

The obvious safety measure is for the daemon side to strip `private_key=` from
`get=1` before it goes on the wire. **That breaks issuance**, and the reason is
not obvious: the daemon reports only the interface's PRIVATE key and never its
public one, so the console derives the public half and puts it in every client
config. Strip the private key and every issued config names no server.

```rust
"private_key" => {
    // The daemon reports the interface's PRIVATE key and never its public
    // one, so the public key has to be derived here or the server identity
    // comes out empty and every issued config names no peer to connect to.
```

So the fix is a swap, not a strip:

- the daemon side derives the public half **once, at startup**, from the key it
  already holds, and publishes it as configuration
- the console reads the server's public key from that configuration instead of
  deriving it
- the relay then strips `private_key=` from every response, and nothing breaks

The result is stronger than where we are today: **a fully compromised console
cannot learn the server's private key**, because it never receives it. That is
not true right now, with a unix socket, where the private key crosses on every
`get=1`. Measured on the live cluster today:

```
консоль ПРОЧИТАЛА стан демона через реле
бачить: errno, listen_port, private_key
```

The parser already discards it (`the_interface_private_key_is_never_carried_out_of_the_parser`),
which is careful, but discarding after receipt and never receiving are
different guarantees.

### 3. Authentication

Whoever reaches this endpoint controls the tunnel: `set=1` adds and removes
peers, which is granting and revoking human access to the box. A NetworkPolicy
is not enough and this project already learned why: a pod that labelled itself
`plane: console` used a shared bearer to delete a freeze (GOTCHAS 20). **A pod
label is not a credential.**

Two candidates.

**Bearer token in a Secret.** Matches every other plane in this stack, and
`install.sh` already generates exactly this kind of value per cluster. Simple,
familiar, reviewable. Weakness: a bearer is replayable if the channel is ever
observed, so it depends entirely on TLS being right.

**mTLS.** Stronger, and `crates/relay` already carries `tls.rs`. Weakness: a
certificate lifecycle nobody asked for, in a component whose whole appeal is
that it is small.

**Recommendation: bearer over TLS, with the daemon side refusing plaintext.**
The bearer matches the stack's existing shape, and the operations it guards are
already reachable to anyone holding the console's admin key. mTLS would raise
the floor for the channel while leaving the console's own key as the weaker
link, which is effort spent on the wrong door.

### 4. What the relay refuses

Even authenticated, the daemon side should carry only what the console needs:

| UAPI | allowed | why |
|---|---|---|
| `get=1` | yes, with `private_key` stripped | the console lists peers and reads the listen port |
| `set=1` with `public_key` + `allowed_ip` | yes | issuing a device |
| `set=1` with `remove=true` | yes | revoking a device |
| `set=1` with `private_key` | **no** | rotating the server identity is not a console action |
| `set=1` with `listen_port` | **no** | would silently invalidate every issued config |
| `replace_peers=true` | **no** | one call that revokes every operator at once |

That last row matters: the existing tests already assert the console never
sends it (`issuing a device must not disconnect the others`), so refusing it on
the daemon side costs nothing and turns a convention into a boundary.

## What it buys, concretely

| | today (option B) | with this |
|---|---|---|
| console namespace | `privileged`, posture promised | `restricted`, posture enforced |
| console egress | inherits Caddy's internet (GOTCHAS 49) | back to gateway-only |
| shared event log | NFS across namespaces | a plain PVC again |
| `stack-keys` | copied into two namespaces | one namespace |
| server private key | crosses to the console every `get=1` | never leaves the daemon |
| `security-tests.sh` | needs two-namespace awareness | back to one |

## Cost, honestly

The transport is small. The rest is not free: a public-key handoff, an
authenticated listener on the daemon side, a credential generated at install,
a filtering rule set, and tests for each. Call it a working session for the
code and a second pass for review, and it touches `genaryx-wg`, which already
carries ten unmerged commits without a PR.

## What to review before code starts

1. **Bearer over TLS, or mTLS?** The recommendation is bearer; say if the
   stronger option is wanted despite the lifecycle.
2. **Is the public-key handoff acceptable?** It is the one behaviour change in
   the console: it stops deriving the server identity and starts being told it.
3. **Where does the daemon-side listener live** - a new small binary in the wg
   image, or an extension of the relay that image already runs?
4. **Does the branch land first?** Ten commits of peer issuance are unreviewed;
   building on them means the review gets larger, not smaller.
