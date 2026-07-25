# What bites you, and what this repo already does about it

Every item here is something that actually went wrong while bringing this
cluster up, not a theoretical warning. Each one is FIXED in the files here, so
following the README should not reproduce any of them. They are written down
anyway, because a fix you cannot see is a fix you will undo by accident.

Each item says which KIND of trap it is, because the three kinds are worth very
different amounts to you:

- **Platform** (20 of 40). Kubernetes, Docker, k3s, WireGuard or the distro
  behaves this way for everyone. These are the ones worth reading even if you
  never run this stack, because the next thing you deploy will hit them too.
- **The stack's own contract** (10 of 40). A default or a coupling in our
  services. Not bugs, properties: the money plane binds loopback, the planes
  talk through a shared file, the gateway asks the policy plane only if you
  wire it to. Invisible until they bite, so they are written down.
- **Ours, and fixed** (10 of 40). We wrote it wrong in this repository. A
  missing Secret generator, a script that died silently, a check that reported
  FAIL on a healthy stack, an audit line written to a directory nobody reads.
  They stay in the list rather than being quietly deleted, because the honest
  count of your own mistakes is the only reason to trust the other thirty.

If you are here to learn rather than to deploy, read the platform ones. If you
are here because something broke, the symptom lines are ordered the way you
will meet them: build, install, wire, run, attack.

Items 31 to 40 came from one day of bringing up the operator's WireGuard
tunnel, TLS and the audit trail on a live box. Four of them were invisible to
a green install run and to every test: the checks passed, each command reported
success, and the damage only showed when a human opened the console and looked
at it. That ratio is the reason this file exists.

## 1. The Go builder image is older than the code

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** `go: go.mod requires go >= 1.27 (running go 1.26.5; GOTOOLCHAIN=local)`,
and the image build stops.

**Why:** the official `golang:` images pin `GOTOOLCHAIN=local`, so the compiler
in the image is the only compiler allowed. The moment any repo in the stack
moves to a newer Go than the tag you pinned, the build breaks. Chasing it by
bumping the tag does not work either: `golang:1.27-alpine` did not exist yet
when its `go.mod` already asked for 1.27.

**Fixed here:** the builder stages set `ENV GOTOOLCHAIN=auto`, so Go downloads
exactly the toolchain `go.mod` names. The image tag stops mattering and the
build keeps working as the repos move.

## 2. k3s ships a CNI that ignores NetworkPolicy

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** none, which is the problem. `kubectl apply` accepts every
NetworkPolicy, `kubectl get networkpolicy` lists them, and nothing is enforced.

**Why:** k3s defaults to Flannel, which does not implement NetworkPolicy.

**Fixed here:** k3s is installed with `--flannel-backend=none
--disable-network-policy` and Calico provides both. If you skip this, the
default-deny posture in `manifests/30-network-policy.yaml` is decoration.

## 3. Two default StorageClasses

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** a PVC with no `storageClassName` binds to whichever default the
API server picks, and you find out later when a volume is on the wrong class.

**Why:** k3s ships `local-path` marked default; Longhorn also installs itself
as default.

**Fixed here:** the servers are installed with `--disable=local-storage`, so
k3s never ships the provisioner or its class and Longhorn is the only default.

The patch everyone reaches for first does work, and does not LAST:

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

k3s re-applies its bundled manifests from
`/var/lib/rancher/k3s/server/manifests/` on every server restart, which
rewrites that annotation back to `true`. Measured on 2026-07-25: the patch was
applied at bring-up, a restart for `--secrets-encryption` at 02:56 silently
restored the second default, and `verify.sh` caught it hours later. That is the
whole argument for a standing check rather than a one-off fix: this repaired
itself into being broken again with nobody touching storage at all.

## 4. The hcloud cloud-controller-manager fights k3s and Calico

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** `failed to listen on 0.0.0.0:10258: address already in use`, the
pod crash-loops, and the log is a wall of usage text that hides the one real
line.

**Why:** two things at once. k3s runs its own cloud controller on :10258, and
the upstream manifest passes `--allocate-node-cidrs=true
--cluster-cidr=10.244.0.0/16`, which is neither this cluster's CIDR (k3s uses
`10.42.0.0/16`) nor this cluster's IPAM (Calico owns it).

**Fixed here:** the CCM is narrowed to the single job it is wanted for,
provisioning load balancers, and moved off the contended port:

```
--cloud-provider=hcloud
--leader-elect=false
--allow-untagged-cloud
--secure-port=10268
--webhook-secure-port=0
--controllers=service-lb-controller
```

Node lifecycle stays with k3s, pod routing stays with Calico, and nothing
overlaps.

## 5. Nodes join over the public internet

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** the cluster works, so nobody notices. etcd peer traffic, the
kubelet API and the VXLAN overlay are all crossing the public network.

**Why:** `--node-ip` defaults to the interface with the default route, which on
a Hetzner cloud server is the public one.

**Fixed here:** every node is attached to a private network and installed with
`--node-ip`/`--advertise-address` on its `10.10.0.x` address. The public IP
stays in `--tls-san` only, so an operator's kubectl can still reach the API.
A Hetzner private network costs nothing, so there is no reason to skip it.

## 6. The stack's own coupling: a shared event log

> **The stack's own contract.** A property of our services, not a bug.

**Symptom:** put the planes on different nodes with the default storage class
and idryx sees an empty identity graph, because the file it loads from is on
another node's disk.

**Why:** the planes couple through `events/*.ndjson`, not through APIs. See
README, "Fact 1".

**Fixed here:** a `stack-rwx` StorageClass backed by Longhorn with three
replicas, and the manifests ask for it BY NAME so a cluster without RWX fails
at apply time instead of quietly scheduling everything onto one node.

## 7. The console hosts the tools it runs

> **The stack's own contract.** A property of our services, not a bug.

**Symptom:** you split qryx, verdryx, engram and mockryx into their own
Deployments, everything comes up green, and the Crypto, Quality, Memory and
Drills tabs are permanently empty.

**Why:** the console EXECUTES those four (engram over MCP on stdio). A sidecar
cannot be another container's stdin.

**Fixed here:** they are built into the console image. See README, "Fact 2".

## 8. `USER nonroot` is not a non-root user, as far as kubelet is concerned

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** every pod sits in `CreateContainerConfigError` with
`container has runAsNonRoot and image has non-numeric user (nonroot), cannot
verify user is non-root`.

**Why:** distroless images set `USER nonroot`, and a `useradd`-based image sets
`USER stack`. Both are NAMES. The kubelet resolves the image's user before the
container exists, cannot map a name to a uid without running it, and with
`runAsNonRoot: true` it refuses rather than assume. A hardened pod spec and a
conventional Dockerfile therefore deadlock, which is a surprising place to
land when both halves are individually correct.

**Fixed here:** every image ends with a NUMERIC user (`USER 65532:65532` for
the distroless Go images, `USER 10001:10001` for the Debian-based tokenfuse
and console), and the manifests also state `runAsUser` explicitly so the
intent survives an image rebuild.

## 9. A service that binds loopback on purpose looks like a broken app in a pod

> **The stack's own contract.** A property of our services, not a bug.

**Symptom:** `tokenfuse-cloud` runs, its log says
`tokenfuse cloud control plane listening on 127.0.0.1:8080`, and its readiness
probe fails forever. The Service has no endpoints, so the console reports no
money plane while the container is demonstrably healthy.

**Why:** the code binds loopback by DEFAULT, deliberately, so that a naive
local run never publishes the money-plane API, and it offers
`TOKENFUSE_CLOUD_HOST` for a deployment that fronts it with a firewall or a
tunnel. In a pod the default is wrong in the least obvious way: kubelet probes
the POD's address, not the container's loopback, so the probe cannot ever pass.

**Fixed here:** the manifest opts in through that variable, and opts in as
narrowly as the code allows - the pod's OWN address, from
`fieldRef: status.podIP`, rather than `0.0.0.0`. The wildcard also works and is
what most charts write, but it means "every interface this container ever
gets", which stops being loopback-equivalent the moment something adds
hostNetwork or a second interface.

What replaces loopback as the boundary is not politeness: the default-deny
NetworkPolicy admits port 8080 only from `plane: console` and `plane: money`,
the Service is ClusterIP, and there is no host port and no NodePort. That is a
strictly SMALLER reachable set than loopback on a shared box, where every local
process of every local user can connect.

## 10. The cloud controller cannot see nodes that k3s named

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** a `type=LoadBalancer` Service gets a real Hetzner load balancer,
a real public IP, and zero targets. `curl` connects and gets an empty reply.
The CCM log says `Ensured load balancer` and nothing else; at `-v=4` it still
says nothing about targets.

**Why:** the hcloud CCM maps a Node to a Hetzner server by parsing
`spec.providerID` as `hcloud://<server-id>`. k3s sets its own
`k3s://<node-name>`, and the CCM SKIPS unknown prefixes - it records a Warning
event on the Node object (`UnknownProviderIDPrefix`) and moves on. Nothing
fails, so nothing draws attention.

`kubectl get events -A --field-selector reason=UnknownProviderIDPrefix` is the
one command that names this outright.

**Fixed here:** `install.sh` installs every node with
`--kubelet-arg=provider-id=hcloud://<server-id>`, reading the id from the
Hetzner metadata service on the node itself so it is never typed by hand. The
kubelet then REGISTERS with the right providerID and the CCM needs no node
controller enabled (so gotcha 4's narrowing still stands).

**Why at install time and not later:** `spec.providerID` is immutable once set,
so retrofitting means deleting the Node object, and that is expensive in three
ways this cluster paid for:

- on a k3s SERVER, deleting the Node object also removes its etcd member;
- Longhorn deletes its own `nodes.longhorn.io` object with the Node, and does
  not recreate it until that node's `longhorn-manager` pod restarts. Until then
  volumes fail to attach with `node.longhorn.io "<name>" not found`;
- a volume attached at that moment can lose its mount outright. On this cluster
  the console's ext4 came back mounted `rw,relatime,shutdown` - every write
  returning `EIO` - and needed the pod deleted so Longhorn could detach and
  reattach cleanly.

Also: after `kubectl delete node`, a k3s agent does not re-register on its own.
Restart `k3s-agent` on that node.

## 11. Default-deny drops the load balancer's health check

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** the pod is Ready, the Service has an endpoint, and the cloud
console shows the target `unhealthy`. No log line anywhere says why, because
nothing logs a dropped packet.

**Why:** `externalTrafficPolicy: Local` deliberately does not masquerade, so
the packet arriving at the pod carries the BALANCER's private address as its
source. Under a default-deny NetworkPolicy that is an unmatched source, and
Calico drops it - including the health check.

**Fixed here:** `console-ingress-lb` in `manifests/30-network-policy.yaml`
admits the Hetzner private network on 7420 only. Narrow it to the balancer's
/32 if you want it tighter; do not widen it to `0.0.0.0/0`.

## 12. The money plane was a factory reset waiting to happen

> **The stack's own contract.** A property of our services, not a bug.

**Symptom:** everything works, then a rollout happens and the console reads
`$0` across a fleet of 9,288 runs.

**Why:** `tokenfuse-cloud` keeps runs, budgets, incidents and the savings
ledger in memory and snapshots them only when `TOKENFUSE_CLOUD_DATA` names a
path. Unset, it keeps nothing. On one long-lived box that is survivable. On
Kubernetes a restart is not an incident, it is Tuesday.

**Fixed here:** a `cloud-state` claim, `TOKENFUSE_CLOUD_DATA` pointing into it,
`strategy: Recreate` (one RWO volume, so never two pods), and `fsGroup: 10001`
so a non-root container can write a freshly provisioned volume. Verified by
killing the pod: 9,288 runs and $4,254.67 came back.

## 13. The operator's tunnel has to land where the pod is

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** `ssh -L 7420:<console clusterIP>:7420 root@<any node>` gives a
tunnel that connects and then times out - but only when you pick the wrong
node.

**Why:** the private network's interfaces are /32, so Calico treats every node
as its own subnet and `VXLANCrossSubnet` encapsulates node-to-node traffic.
Host-originated traffic to a pod on ANOTHER node therefore arrives with
Calico's tunnel address (inside the pod CIDR) as its source, which the console's
ingress rule does not admit. From the node hosting the pod, the source is the
node itself and it passes.

**Fixed here:** documented, not widened. Admitting the whole pod CIDR would let
any pod in the cluster reach the console, which is a real loss for one
convenience. `install.sh` prints the tunnel command and says which node to aim
it at; `kubectl -n agent-stack get pod -l app=genaryx-console -o wide` answers
that in one line.

## 14. An enforcement control that forgets is worse than no control

> **The stack's own contract.** A property of our services, not a bug.

**Symptom:** none, which is what makes it the worst item on this list. Freeze
an agent, restart the policy plane's pod for any ordinary reason, and the
agent is running again while the console still shows it frozen.

**Why:** `wardryx serve` without `-db` keeps policies AND approvals in memory.
It says so on startup (`no -db given; using an in-memory approval store (state
is lost on restart)`) and that line scrolls away. What the console writes there
is not decoration: freezing an agent PUTs deny-all policies named
`console-block:<kind>:<key>`, and the console rehydrates what is frozen by
reading them back. Measured on this cluster before the fix: 7 policies and 5
approvals before a pod restart, 0 and 0 after.

**Fixed here:** `manifests/15-policy-store.yaml` runs a Postgres StatefulSet on
its own volume; wardryx gets `WARDRYX_DB` and `WARDRYX_APPROVAL_SECRET` from a
Secret `install.sh` generates on the cluster (never in this repo); a
NetworkPolicy admits exactly one client pod on 5432. wardryx applies its own
schema on connect, so there is no migration step.

Verified by killing the wardryx pod after a freeze: 7 policies including the
`console-block:*` one, 5 approvals, and the PDP still answering `deny` with
that policy named as the reason.

The same startup run also revealed the second half: without
`WARDRYX_APPROVAL_SECRET` a `require_human_above_usd` policy is accepted and
its holds can never be GRANTED. Same Secret, same fix.

## 15. Building the frontend without its mode ships a different product

> **The stack's own contract.** A property of our services, not a bug.

**Symptom:** the console loads, shows its whole chrome, and every panel says
"No environment found. Run `taipan up` ...". No sign-in screen appears, and the
backend's own API answers correctly to `curl` from the same pod.

**Why:** `apps/web` decides whether a backend exists at all from
`VITE_GENARYX_API`, which is set by `.env.web`, which is loaded only by
`vite build --mode web` (what `pnpm build` runs). A bare `vite build` produces
the NO-BACKEND preview bundle: it never calls `genaryx-web`, so the sign-in
gate never renders and every plane draws its own empty state. The cluster then
looks broken while the cluster is fine and the browser is simply not talking
to it.

**Fixed here:** `images/console.Dockerfile` builds with `--mode web`, with a
comment saying why the flag is not a preference.

## 16. With no environment descriptor, the console invents a fleet

> **The stack's own contract.** A property of our services, not a bug.

**Symptom:** the Graph tab draws 35 agents named
`agent://taipanbox.dev/demo/*` on a cluster whose identity plane holds 29
completely different, real ones. The Bus Explorer shows matching traffic. Both
look entirely plausible.

**Why:** two panels resolve from a `taipan up` descriptor
(`$TAIPAN_HOME/environments/<name>.json`) and from NOTHING ELSE - the Bus, and
the delegation Graph built from it. No descriptor means no environment, and the
bus feeder then starts its DEMO generator, writes fixtures into a scratch
directory and serves them. `bus_status` reports `{"kind":"demo"}` honestly, but
the Graph does not, and a governance console showing invented agents as real is
the worst failure mode available to it. On a cluster, it was the DEFAULT.

The Identity plane has no env-var fallback at all (unlike money and policy), so
it simply reported no environment.

**Fixed here:** `manifests/00-base.yaml` carries the descriptor as a ConfigMap
and the console mounts it read-only at `TAIPAN_HOME`, with the keyfile it
references coming from an optional Secret. Bus goes `{"kind":"live"}` on the
real event directory, Identity resolves idryx, and the Graph draws the 30 real
nodes - including a `lifecycle: frozen` marker on the frozen one.

Related, and fixed in `genaryx-a360` rather than here: the money plane's
env-var fallback hardcoded `127.0.0.1:8080` and ignored `TOKENFUSE_CLOUD_URL`,
while the policy plane's honoured `WARDRYX_URL`. On Kubernetes the Cloud is a
Service on another pod, so the loopback default could never be right. The two
planes now resolve the same way (`crates/api/src/money/env.rs`).

## 17. Five nodes, one node's worth of resilience

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** `kubectl get pods -o wide` after a few rollouts: five pods, five
nodes, all five pods on the same node.

**Why:** every Deployment here is a single replica, so a topology-spread
constraint does nothing (it spreads replicas of one workload, and there is only
ever one). Nothing told the scheduler that DIFFERENT planes should not share a
node, so it packed them onto whichever node scored best.

**Fixed here:** one kustomize patch adds a `preferred` podAntiAffinity on
`plane: Exists` to every Deployment. Preferred, not required, so a two-node
cluster or one node under maintenance can still run the stack. After it: console
on node 1, idryx on 2, gateway on 3, wardryx on 4, cloud on 5, all five sharing
the RWX event volume.

## 18. Secrets sit in etcd as plaintext unless you say otherwise

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** none from inside the cluster. From a copy of etcd, everything.

**Why:** k3s does not encrypt Secrets at rest by default. Proven by attack on
the first live cluster: the policy store's Postgres password, its full DSN and
`WARDRYX_APPROVAL_SECRET` were read straight out of etcd with `etcdctl get`, as
ordinary strings. An etcd snapshot, a stolen disk image or a backup tarball is
therefore the entire credential set.

**Fixed here:** `install.sh` starts every server with `--secrets-encryption`,
so an aescbc provider is active from the first boot and no Secret is ever
written in the clear. `security-tests.sh` writes a canary Secret and greps it
out of etcd to prove it.

**And this is where the honesty has to be uncomfortable: do NOT retrofit this
onto a running cluster. We did, and it cost us the cluster's secrets.**

The retrofit looks like it works. Write your own
`/var/lib/rancher/k3s/server/cred/encryption-config.json` with an aescbc key,
and the API server hot-reloads it (`--encryption-provider-config-automatic-reload`
is on), new Secrets get written encrypted, a canary in etcd shows `k8s:enc:`,
and everything reads back correctly for hours. What none of that tells you is
that k3s keeps its own copy of that file in the DATASTORE, and the datastore is
authoritative. Measured, in this order:

1. hand-written config installed, hot-reloaded, all 20 Secrets rewritten
   encrypted, verified in etcd. Cluster healthy for two hours.
2. the next k3s restart (for an unrelated flag) refused to start at all:
   `encryption-config.json newer than datastore and could cause a cluster
   outage. Remove the file(s) from disk and restart to be recreated from
   datastore.`
3. making the file not-newer let k3s start - and k3s then OVERWROTE it with the
   datastore's copy, which was the identity-only config from before the
   retrofit. The key was gone; 18 Secrets were now ciphertext nobody could read.
4. making the file immutable so it could not be overwritten produced
   `failed to reconcile with local datastore: ... operation not permitted` and a
   refusal to start. There is no third option: the datastore wins.
5. the supported command, `k3s secrets-encrypt enable`, returned
   `Put "https://127.0.0.1:6443/v1-k3s/encrypt/config": EOF` with nothing in the
   server log, on v1.36.2+k3s1, both before and after the flag was present.

What was actually lost: `kube-system/k3s-serving`, all five
`*.node-password.k3s`, Calico's `tigera-ca-private`/`typha-certs`/`node-certs`,
Longhorn's webhook certs, and our own two. The control plane then would not
become Ready at all, because k3s cannot read its own serving secret.

**Recovery, if you are reading this too late:** delete the undecryptable Secrets
straight out of etcd with `etcdctl` (the API server cannot, and etcd keeps
running while the API server fails), restart the servers, and let each owner
regenerate its own - k3s recreates `k3s-serving` and the node passwords, the
tigera operator recreates Calico's CA and certs, Longhorn recreates its webhook
pair. Recreate your own Secrets from your own copies; if you do not have copies,
you do not have those secrets any more.

The one-line version: **encryption at rest is an install-time decision on k3s.**
Before this cluster, that sentence was a preference. Now it is a scar.

## 19. The kubelet API is on the public internet by default

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** none. `10250` answers `401` to an anonymous request, so a scan
looks clean.

**Why:** a Hetzner cloud server has a public interface, and the kubelet binds
`0.0.0.0:10250` on it. A scan of the first live cluster found `10250` open to
the whole internet on all five nodes, and `6443` on the three servers. `401`
is not safety: it is one authorization bug, or one leaked node credential,
away from remote code execution on every node.

**Fixed here:** `install.sh` creates a Hetzner cloud firewall FIRST, before
k3s exists, admitting `22` and `6443` only from the operator's own address and
dropping everything else inbound. It is enforced outside the host, so a
compromised node cannot switch it off. Cluster traffic already runs on the
private network (GOTCHAS 5), so nothing internal depends on the public ports.

## 20. A pod label is not a credential, and `devkey` is not a secret

> **Ours, meeting a platform fact.** Our defaults did the damage; self-assigned pod labels are simply how Kubernetes works.

**Symptom:** an agent frozen from the console keeps being enforced, until any
workload in the namespace deletes the block. No console, no passkey, no
operator, and it works.

**Why:** two defaults meeting. `TOKENFUSE_CLOUD_ALLOW_DEVKEY=1` with an empty
key list makes the literal string `devkey` an admin bearer, and wardryx with
no `WARDRYX_KEYS` accepts ANY bearer. The NetworkPolicy that decides who may
reach the planes authorises by the pod label `plane: console` - which a pod
assigns to ITSELF (the stack's own `drills` CronJob does exactly that). So the
whole authorisation story was "a pod that calls itself console, using a
password that is the word devkey". Proven: a pod labelled `plane: console`
read every policy and `DELETE`d a `console-block:*` freeze with
`Authorization: Bearer devkey`, and the PDP went from `deny` to `allow`.

**Fixed here:** `install.sh` generates real bearer keys per cluster into the
`stack-keys` Secret; the manifests reference them and set `WARDRYX_KEYS` so the
policy plane enforces bearer auth; `ALLOW_DEVKEY` is gone. After the fix the
same attack gets `401` on every plane and every verb, while the console's own
Secret-provided key still works. The forged label still grants network reach -
that is the label's job - but reach without a credential is nothing.

`security-tests.sh` runs this exact attack as a standing check.

## 21. The gateway never asks the PDP unless you wire it to

> **The stack's own contract.** A property of our services, not a bug.

**Symptom:** the policy plane answers the console, shows its policies, denies in
`/v1/decide` when asked - and a frozen agent's real traffic sails straight
through it.

**Why:** the enforcement hook on the DATA PATH is off by default and reads its
OWN variables. It needs `TOKENFUSE_WARDRYX_MODE=enforce` and
`TOKENFUSE_WARDRYX_URL` - NOT the `WARDRYX_URL` in `stack-wiring` that every
other component uses. Wire the cluster the obvious way and you get a policy
plane that is consulted by the console and ignored by the traffic, which is the
one place enforcement actually has to happen.

**Fixed here:** the gateway is given the hook explicitly, with a VIEWER key
(the enforcement point must not be able to rewrite the policy it enforces),
`FAILMODE=closed` (an unreachable PDP denies rather than permits; the durable
policy store in 15-policy-store.yaml is what makes that survivable), and a
timeout widened to 250ms against a measured p99 of 18.8ms cross-node. Proven
end to end against the real provider: a frozen agent gets `403` in ~20ms and
the provider is never contacted; an untouched agent's call reaches the model,
returns real usage, and is metered. Time-to-effect of a freeze on live traffic:
one PDP round trip, measured at 5ms, because a freeze policy sets per-request
dimensions and wardryx marks it `cacheable: false`.

## 22. No upstream means the gateway invents the answer

> **The stack's own contract.** A property of our services, not a bug.

**Symptom:** every call succeeds, returns a plausible model reply, and is
metered - and none of it is real.

**Why:** with `TOKENFUSE_UPSTREAM` unset the gateway does not fail and does not
warn. It answers from `StubProvider`: a canned body and a fixed 1000 input /
500 output tokens, metered as spend. Measured: `{"stub": true, "usage":
{"input_tokens": 1000, "output_tokens": 500}}` billed at $0.0035. A console
full of fabricated money and answers that never came from a model, all of it
looking exactly like the real thing.

**Fixed here, and then fixed properly in the code.** The manifest pins
`TOKENFUSE_UPSTREAM` to the FULL provider endpoint
(`https://api.anthropic.com/v1/messages` - a base URL alone answers 404, the
gateway POSTs to exactly this path). But a manifest value only protects the
deployment that has it, so the gateway itself now REFUSES TO START with no
upstream, printing what it would otherwise have invented and how to opt in:

    tokenfuse: refusing to start: TOKENFUSE_UPSTREAM is not set.
    Without it this gateway would answer every request from a built-in stub and
    meter a fixed 1000 input / 500 output tokens as real spend, so both the model
    answers and the money would be invented.

`TOKENFUSE_ALLOW_STUB=1` keeps the offline dev loop, and logs a warning that says
every figure from then on is fictional. Verified on the cluster: removing the
variable puts the new pod in `CrashLoopBackOff` with that message while the old
pod keeps serving, so a forgotten variable can never replace a working gateway
with one that fabricates spend.

## 23. The neighbouring namespace is the platform's job, not the manifests'

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** `agent-stack` is locked down - default-deny, restricted Pod
Security, non-root everything - and a privileged pod with the host filesystem
mounted starts freely in the `default` namespace right next to it.

**Why:** NetworkPolicy and Pod Security are PER-NAMESPACE. The manifests here
harden their own namespace and cannot harden a neighbour. Tested: a privileged,
hostPID pod with `/` mounted came up in `default` with no objection. Our own
containment held from the outside - it could reach NONE of our five services,
because our policies key on label AND namespace, and it read no host secret
because it ran as our image's uid 10001, not root - but a root image in that
same unprotected namespace would own the node.

**Fixed here:** it cannot be, and pretending otherwise would be the dishonest
move. Documented instead: apply `pod-security.kubernetes.io/enforce: restricted`
and a default-deny NetworkPolicy to every namespace that will run workloads, or
keep this cluster single-tenant. `security-tests.sh` reports the posture of
neighbouring namespaces so the gap is visible rather than assumed closed.

## 24. A shared RWX reader can lag the writer

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** the gateway writes an event, and a `stat` from the console pod on
another node shows the file unchanged for seconds. Looks like the write was
lost.

**Why:** the RWX event volume is NFS-backed (Longhorn), and NFS caches file
attributes on the client. The writer's node sees the new size immediately; a
reader on a different node can serve a cached `stat` for a few seconds. The
data is there - a `grep`, which forces a read, finds it - but a size check
does not. This is a read-consistency property of the shared volume, not a lost
write, and it is why "the console has not shown the event yet" is usually
latency, not failure.

**Not a fix, a caveat:** the console tails the file, so it converges within the
attribute-cache window. Anything that needs the writer's exact byte offset must
read on the writer's node or force a read, never trust a cross-node `stat`.

## 25. `tr </dev/urandom | head -c N` kills a `pipefail` script, silently

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** the deploy runs cleanly through every image build, prints its
`credentials` heading, and stops. No error, no stack trace, no partial output.
Nothing is deployed. Re-running does the same thing at the same place.

**Why:** the idiom everyone writes to generate a password is a pipeline whose
last stage exits early. Once `head` has its N bytes it closes the pipe, `tr`
is killed by SIGPIPE and reports 141, `set -o pipefail` promotes that to the
pipeline's status, and `set -e` ends the script right there. Nothing prints
because SIGPIPE is not an error message, it is a signal. Reproduce it in one
line:

```
bash -c 'set -euo pipefail; v="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)"; echo unreachable'; echo $?
# 141
```

Note which pipelines are safe: `head -c 18 /dev/urandom | od -An -tx1 | tr -d " "`
has the same commands and never fails, because there `head` reads a file and
exits normally while every later stage consumes all of its input.

**Fixed here:** the generator turns `pipefail` off for exactly that one
pipeline, in a subshell, and then asserts the length it got, so a genuinely
unreadable `/dev/urandom` still fails loudly rather than producing a short
secret:

```
v="$( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n" )"
[ "${#v}" = "$n" ] || die "could not generate a $n-character secret"
```

## 26. A `set -e` script that dies mid-run looks like one that finished

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** the log's last line is a section heading. Whether that means
"still working", "done", or "dead" is not knowable from the output, and the
honest reading, that it is still running, is the wrong one.

**Why:** this is what `set -e` does by design. It ends the script at the
failing command, and the failing command is usually the one that printed
nothing. Gotcha 25 is one instance; any command with a bad exit code is
another. An installer is the worst place for it, because the reader has no
prior sense of how long each step should take.

**Fixed here:** both `install.sh` and `deploy.sh` carry an EXIT trap that names
the line and the exit code every time, and translates 141 rather than leaving
a bare number. Failures already explained by `die()` are not narrated twice.

```
trap 'rc=$?; { [ $rc -eq 0 ] || [ "${EXPLAINED:-0}" = 1 ]; } && exit $rc
      printf "\n!! stopped at line %s (exit %s)\n" "$LINENO" "$rc" >&2
      ...' EXIT
```

## 27. `"${ARRAY[@]}"` inside a larger quoted string is not one argument

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** every check that runs a command inside a container reports FAIL,
while the stack is demonstrably healthy and the same command works by hand.

**Why:** `check "name" "\"${COMPOSE[@]}\" exec -T svc curl ..."` reads like one
string, and is not. With `COMPOSE=(docker compose)` the array expands to
separate words even inside the quotes, the function receives three arguments
instead of two, and `$2` is the fragment `"docker`. `eval` on that fragment
fails, so the check fails, and the failure is indistinguishable from a real
one:

```
bash -c 'COMPOSE=(docker compose); f() { echo "argc=$# arg2=[$2]"; }
         f "name" "\"${COMPOSE[@]}\" exec -T svc true"'
# argc=3 arg2=["docker]
```

**Fixed here:** build the command string with `[*]`, which joins the elements
into the single word `eval` needs, and assert the argument count inside the
helper so a future slip is loud rather than a phantom FAIL:

```
DC="${COMPOSE[*]}"
check() { [ "$#" -eq 2 ] || die "internal: check() got $# arguments, expected 2"; ... }
```

## 28. A random string is not a key spec, and the plane will not tell you twice

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** every service is `Up`, every health endpoint answers, and the
console can authenticate to nothing. The money plane logs one ERROR at startup
and then behaves normally, serving 401 to every caller including the gateway.

**Why:** both planes take a bearer-key SPEC of the form `key:org[:role]`, and
parse it by splitting on `,` and then `:`. An entry with no `:org` half is
skipped, so a plain random secret in `TOKENFUSE_CLOUD_KEYS` or `WARDRYX_KEYS`
yields an EMPTY key map. Empty is not "allow everyone", it is "authenticate
no one", which is the right default and also the quietest possible failure:
the plane is healthy, reachable, and useless.

The client side takes the BARE key, not the spec. Reusing one value for both,
which is the obvious thing to do, is wrong in both directions at once.

**Fixed here:** `install.sh` generates three secrets into five values and both
deployments use the same split:

```
cloud_keys      = <secret>:default:admin      # what the plane accepts
cloud_admin     = <secret>                    # what the gateway presents
wardryx_keys    = <admin>:default:admin,<gw>:default:viewer
wardryx_admin   = <admin>                     # the console administers policy
wardryx_gateway = <gw>                        # VIEWER: /v1/decide needs no more
```

The gateway's viewer key is not tidiness. `/v1/decide` accepts any
authenticated principal, and an enforcement point holding an admin key can
rewrite the policy it is enforcing. The single-instance installer asserts all
three states: 200 for the admin key, 401 for an unknown one, 403 when the
gateway's key tries to read policy.

Related: until this was written, `stack-keys` was referenced by five
`secretKeyRef`s and created by nothing at all. A fresh cluster applied the
manifests and sat in `CreateContainerConfigError` with no clue what the values
should look like. Reachability checks cannot catch either failure. Check the
credential, not the port.

## 29. Compose has no `fsGroup`, and a fresh volume belongs to root

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** on Docker Compose, the policy plane crash-loops with
`permission denied` writing its own event file, the identity plane exits
because the log it was told to load does not exist, and the gateway drops
every trace behind a single WARN while continuing to serve.

**Why:** two platform differences at once. Kubernetes has `fsGroup`, which
chowns a volume to the pod's group on mount; Compose has no equivalent, and a
fresh Docker named volume is `root:root 0755` unless the image happens to
contain that path (in which case it silently inherits the image's ownership
instead, which is its own surprise). The cluster never showed this because its
RWX volume came from a provisioner that hands out a permissive share.

Two UID families share the event log, so a single `chown` cannot serve both:
the Go planes are 65532 (distroless nonroot) and the Rust and Python ones are
10001. And the identity plane's `--load` is not lazy: on a box that has served
no traffic there is no log to load, and it treats that as fatal.

**Fixed here** (in the single-instance sibling, `stack-single`): a one-shot
`init-volumes` service runs as root before anything else, gives the event
directory to GROUP 10001 with the setgid bit so every file created inside
inherits it, chowns the trace and cloud-state volumes to their single writer,
and pre-creates the two `.ndjson` files empty. The Go planes then run as
`65532:10001`: static binaries read no `/etc/passwd`, so a numeric pair the
image was not built with is fine. Each plane appends only to its own file, so
no writer ever needs write access to another's.

## 30. Distroless images have no `curl`, so a check that uses one is a lie

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** `docker compose exec <svc> curl ...` reports FAIL for three
services on a stack that is provably healthy.

**Why:** these images are distroless on purpose. Two have no shell at all and
none has curl, so the check fails on the tooling rather than the service, and
a tooling failure is indistinguishable from a real one in a pass/fail line.
The negative checks in the same run kept passing, which made the result look
even more credible.

**Fixed here:** probe from a throwaway `busybox` attached to the same network.
That is what a neighbouring container sees, which is what the check was
supposed to be asking about in the first place, and it needs nothing from the
images being tested.

## 31. `wireguard-go` daemonises, so your supervisor supervises nothing

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** the container restart-loops with exit code **0**. A UAPI socket
appears and vanishes between restarts, and `wg set` fails with
`Unable to access interface: Protocol error` against a daemon that was alive a
moment ago.

**Why:** `wireguard-go <iface>` forks and the parent exits immediately. A
script that starts it in the background captures the PARENT's pid, so `$!`
names a process that is already gone, `wait` returns at once, the script ends,
and the container stops - taking the tunnel with it. `WG_PROCESS_FOREGROUND=1`
is documented but did not hold here; the `-f` flag did.

**Fixed here:** `images/wg.Dockerfile` starts it as `wireguard-go -f`, which
makes the container's lifecycle the tunnel's.

## 32. `wireguard-go` refuses to run on a kernel that has WireGuard

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** a box drawn in the logs telling you the kernel supports WireGuard
natively and to install the kernel module - on a machine where it is already
there. The tunnel never comes up.

**Why:** the userspace implementation deliberately steps aside when the kernel
can do the job. That is right for a normal tunnel and wrong when you need the
UAPI socket specifically: a kernel interface is driven over netlink inside one
network namespace, so a console in a DIFFERENT container could never manage
peers on it. The whole point of userspace here is that the socket crosses that
boundary as a plain file.

**Fixed here:** the entrypoint sets
`WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1`, deliberately and with the
reason written next to it.

## 33. A UAPI socket on a volume outlives the daemon that made it

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** after one ungraceful stop, every subsequent start fails with
`UAPI listen error: unix socket in use`. A single hard restart becomes a
permanent restart loop, and the logs blame the kernel module (see #32), which
is not the cause.

**Why:** the socket directory must be a volume for another container to reach
it, and a volume survives the container. The next `wireguard-go` finds a file
where its socket goes and refuses.

**Fixed here:** the entrypoint removes a stale socket on start, but ONLY after
checking that nothing answers on it - so a second copy started by mistake
fails loudly instead of silently stealing a live tunnel's socket.

## 34. The socket file appears before the daemon will answer on it

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** `wg set <iface> private-key ...` reports success, and the
interface then has no public key. Reads as a corrupt key file or a broken
image; it is neither, and it passes every time you add a `sleep`.

**Why:** the file is created first and the daemon becomes ready a moment
later. A wait on `[ -S "$SOCK" ]` therefore returns after about 100ms and
everything after it lands in the gap, where writes are accepted and dropped.

**Fixed here:** the entrypoint waits for `wg show <iface>` to ANSWER, which is
the same round trip the configuration that follows performs. Wait for the
answer, never for the file.

## 35. `chmod` on a UAPI socket breaks the daemon behind it

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** you widen the socket so another container can use it, and the
interface immediately starts answering `Unable to access interface: Protocol
error` - to everyone, including the daemon's own tooling.

**Why:** `wireguard-go` requires its socket to stay `0700` and treats a
changed mode as a reason to stop serving. Verified directly: the interface
reports its public key before the `chmod` and errors after it. So the obvious
fix - loosen the socket - does not grant access, it removes it.

**Fixed here:** a `socat` relay beside the real socket, group-readable and
forwarding to it. The daemon keeps the posture it insists on, the console gets
exactly the access it needs, and the forwarder is a place a later version can
log or restrict what crosses.

## 36. A tunnel that terminates nowhere looks identical to one that works

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** a client completes a handshake, traffic counters move, and every
request to the console times out or is refused.

**Why:** the tunnel address lives in the WireGuard container's network
namespace and the console runs in another. Nothing was listening on
`10.9.0.1:7420` at all. From the server side this is invisible: the interface
is up, the peer is configured, the handshake is real.

**Fixed here:** the entrypoint forwards the console port from the tunnel
address to the console service by compose name - bound to the tunnel address
alone, never the host or the wildcard, so it cannot become a second way in.

## 37. Peers live only in the running daemon

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** after any restart, every device ever issued silently stops
connecting. The configs on those phones still look valid, and the server
simply never completes a handshake with them again.

**Why:** the server key was persisted and the peer list was not, so a restart
produced a working tunnel with no members. Nothing reports it: an absent peer
is indistinguishable from one that has not dialled in yet.

**Fixed here:** the peer list is snapshotted to the volume and restored with
`wg addconf` on start. Snapshotted rather than saved on change, because peers
are changed by the console over the UAPI and this container never sees an
event to hook; a clean stop saves immediately via a trap.

## 38. WebAuthn cannot run over a tunnel to an IP, in any configuration

> **Platform.** Kubernetes, Docker or the distro does this to everyone.

**Symptom:** the passkey button does nothing, or the assertion is refused with
a binding mismatch, on a console reached at `http://10.9.0.1:7420` over the
tunnel.

**Why:** two independent barriers. WebAuthn only runs in a secure context
(HTTPS or `localhost`), and it scopes credentials to a DOMAIN, refusing a bare
IP as the relying party. No environment variable makes an IP work. A passkey
enrolled at one origin is also useless at another, so `ssh -L` on a different
port does not rescue it either.

**Fixed here** (in `stack-single`): a Caddy sidecar terminates TLS on the
tunnel address for a real name, and the console's relying party and origin are
derived from that same name - one value instead of three kept in agreement by
hand. Let's Encrypt via DNS-01, because the box publishes nothing on 80/443 and
HTTP-01 has nothing to answer.

## 39. `/v1/policies` is not the question "is anything enforced"

> **The stack's own contract.** Not a bug; a property worth knowing.

**Symptom:** a console posture check reports "governance fail-open: no
policies, every agent action is allowed" on a box that is demonstrably denying
`shell_exec` by name and holding a $5 call for human approval.

**Why:** `GET /v1/policies` lists the STORE's operator-managed policies only.
A deployment seeded from a `-policy` file has none there while enforcing all of
them, so reading that list to judge enforcement reports an enforcing plane as
wide open. That is the most damaging thing a posture check can do: an operator
who disproves one warning stops reading the rest.

**Fixed here** (wardryx `e9e29a6`): `GET /v1/status` reports what the PDP
actually evaluates against - the file-loaded base, the store's layer, and the
effective total. Zero effective policies, and only that, is a real fail-open.

## 40. An audit line written to the wrong directory is still "written"

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** every privileged console action reports success, and the events
file the bus tails stays zero bytes forever. No error anywhere.

**Why:** the console's own store directory (fresh per launch, under `/tmp`)
and the directory the products write into are two different places, and one
struct field named `events_dir` carried the former while the code derived both
paths from it. So the database path was right and the events path was wrong:
lines went somewhere nothing tails and nothing keeps, and vanished on restart.
Invisible in demo mode, where the two directories happen to be the same.

Compounding it: the journal outcome is returned to the caller only on the
success path, so when the command itself failed, the fact that its audit line
had gone nowhere was discarded with it.

**Fixed here** (genaryx): the bootstrap carries both directories, the handle
takes both, and every journal failure is logged as well as returned - so a
broken audit trail cannot be silent whether or not the command succeeded.

## 41. `declare -A` needs bash 4, and macOS ships 3.2

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** on the first line of the preflight, against servers that were
created seconds ago and are already billing:

```
install.sh: line 101: declare: -A: invalid option
declare: usage: declare [-afFirtx] [-p] [name[=value] ...]
!! install.sh stopped at line 102 (exit 2)
```

**Why:** associative arrays arrived in bash 4.0 in 2009. Apple has shipped
bash **3.2.57** as `/bin/bash` ever since, because 4.0 changed licence to
GPLv3, and a stock Mac has no newer bash anywhere in `PATH`. Both install
scripts kept their per-node facts (private address, instance or server id,
availability zone) in `declare -A`, so both died immediately when driven from
the machine most operators actually use.

It stayed hidden because the failure needs two things at once: a macOS
operator AND a real run. `bash -n` parses the file happily, shellcheck says
nothing, and every CI runner is Linux with bash 5.

**Cost:** measured on 2026-07-25 during the first AWS run. Five instances were
up and metering at USD 2.52/hour while the script that was supposed to
configure them had already exited. Nothing was damaged, but the cluster billed
for the whole diagnosis.

**Fixed here:** parallel INDEXED arrays plus a `node_index` lookup, in both
`install.sh` and `cloud/aws/install-aws.sh`. Indexed arrays work in bash 3.2,
so the scripts now need no bash newer than what the operator already has.

The wider lesson for anything in this repo that runs on an operator's own
machine rather than on a node: the nodes are a distribution we choose, and the
laptop is not. Test the operator side on macOS, or do not claim it works
there.
