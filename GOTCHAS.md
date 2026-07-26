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

## 42. A GitHub release is not a published image

> **Upstream.** Someone else's project does this to everyone.

**Symptom:** the cloud controller sits in `ImagePullBackOff` on every control
plane node, and the install script times out waiting for a rollout that will
never finish:

```
Failed to pull image "registry.k8s.io/provider-aws/cloud-controller-manager:v1.36.1":
  failed to resolve reference: not found
```

**Why:** the version was chosen by reading `gh api
repos/kubernetes/cloud-provider-aws/releases`, which lists `v1.36.1` as the
newest, and matching it to the cluster's Kubernetes 1.36. That is a reasonable
way to pick a version and it is wrong: a GitHub release is a git tag plus
release notes, and says nothing about whether an image was built and pushed
under the same name. Asking the registry instead:

```
v1.36.2  404
v1.36.1  404      <- newest GitHub release
v1.36.0  404
v1.35.3  404
v1.35.2  200      <- newest image that exists
v1.35.1  404
```

Note that the published set is not even contiguous: `v1.35.1` and `v1.35.3`
are missing while `v1.35.2` is there, so "walk back one patch" is not a
reliable recovery either.

**Cost:** measured on 2026-07-25 during the first AWS run, on a five-node
cluster already metering at USD 2.52/hour. The error surfaced as
ImagePullBackOff, which reads like a network or credentials problem and sends
you to check the node's egress, the registry mirror and the image pull secrets
before you think to ask whether the tag was ever pushed.

**Fixed here:** pinned to `v1.35.2`, with the one-line check that establishes
it written into the comment above the pin, so the next person verifies rather
than infers:

```
curl -sLo /dev/null -w '%{http_code}\n' \
  https://registry.k8s.io/v2/provider-aws/cloud-controller-manager/manifests/<tag>
```

The `-L` matters: `registry.k8s.io` answers **307** and redirects to a regional
mirror, so a check without it reports 307 for tags that exist and for tags that
do not.

Running one minor behind the API server is fine for the only controller this
deployment enables. The service controller talks to the Kubernetes API through
long-stable types and to the AWS ELB API, neither of which changed in 1.36.

## 43. `rollout status` passes on a controller that never ran

> **Ours, and fixed.** We wrote this wrong in this repository.

**Symptom:** the install completes cleanly, every step green, and the cloud
controller has been in `CrashLoopBackOff` since the moment it was applied.
Nothing downstream complains until a `type=LoadBalancer` Service sits
`<pending>` with no reason given.

**Two separate mistakes, and the second is the dangerous one.**

**The crash.** The upstream example binds `cluster-admin` to the cloud
controller. We narrowed that to a ClusterRole covering Services, Nodes and
Events, on the same principle that a gateway must not be able to rewrite the
policy it enforces (item 20). One rule too few: any controller-manager that
serves an authenticated endpoint reads the request-header CA out of the
`extension-apiserver-authentication` ConfigMap in `kube-system` at startup, and
exits non-zero when it cannot:

```
unable to load configmap based request-header-client-ca-file:
configmaps "extension-apiserver-authentication" is forbidden
```

Kubernetes already ships the Role for exactly this, so the fix is a RoleBinding
to an existing Role, not a widening of the grant. Narrow RBAC stays narrow.

Worth noting how the error presents: the controller prints its **entire usage
text** before dying, so the terminal fills with flag documentation and the one
line that matters is the last one, far below. It reads like a bad flag. It is
not.

**The check that missed it.** This DaemonSet has no readiness probe, so a pod
is AVAILABLE as soon as its container starts. `kubectl rollout status` asks
whether pods are available, so a container that starts and exits two seconds
later satisfies it on the way past. The install script asked the wrong
question, got a true answer, and continued for another twenty minutes.

This is the same class as item 30 (a check that fails on its own tooling) and
item 22 (a component answering from a stub): **a green check that was never
capable of being red.** The cost is worse than a failure, because a failure
stops you.

**Fixed here:** after `rollout status`, sample the pods twice twenty seconds
apart and require that the expected number are `Running` AND that the restart
counts have stopped moving. A crash loop fails both halves. On failure the
script prints the last 15 log lines and says outright that the real error is
the last one.

The general rule this earns: **when a check can only ever pass, it is not a
check.** Before trusting one, ask what state would make it red, and if you
cannot name that state, the check is decoration.

## 44. EC2 drops your pod network, and blames nobody

> **Platform.** AWS does this to everyone who runs an unencapsulated overlay.

**Symptom:** every `PersistentVolumeClaim` sits `Pending`, so every pod sits
`Pending`, so the whole workload never starts. Longhorn is the visible victim:
four of its five `longhorn-manager` pods die on a loop with

```
Failed to check endpoint https://longhorn-conversion-webhook...:9501/v1/healthz:
  context deadline exceeded
level=fatal msg="Error starting manager: conversion webhook service is not
  accessible after 1m0s sec"
```

which reads like a Longhorn problem, a webhook problem, or a timeout that
wants raising. It is none of those. Cross-node pod-to-pod traffic does not
work at all, and Longhorn is simply the first component to need it.

**Why:** an EC2 network interface silently discards any packet whose SOURCE
address is not one of the addresses assigned to that interface. It is a
reasonable anti-spoofing default (`SourceDestCheck`, on by default) and it is
exactly what a pod network does: pod packets carry `10.42.x.x`, the interface
holds `10.10.0.x`, and they are dropped on the way out. No log, no counter
anyone thinks to look at, no ICMP back.

Three facts have to line up, and the third is the one we chose ourselves:

| | |
|---|---|
| Calico | `encapsulation: VXLANCrossSubnet`, so it wraps packets ONLY between different subnets |
| Nodes | all five in ONE subnet, deliberately, to avoid AWS cross-AZ charges at USD 0.01/GB each way |
| EC2 | `SourceDestCheck = true` on every interface |

Because the nodes share a subnet, Calico correctly decides encapsulation is
unnecessary and sends raw pod addresses. On Hetzner that is right and fast: a
Hetzner private network has no such check, which is why the identical Calico
configuration worked there and why nothing in the Hetzner run hinted at this.
**The cost optimisation is what triggered the outage.**

**Fixed here:** `source_dest_check = false` on the instances in `main.tf`.

The alternative, switching Calico to unconditional `VXLAN`, also works and
needs no cloud API call, but it makes the two clouds run different CNI
settings. Turning the check off keeps the Kubernetes configuration
byte-identical across Hetzner and AWS and confines the difference to Terraform,
which is where a cloud difference belongs.

**How to recognise it quickly next time.** Any "service unreachable inside the
cluster" on AWS, on a CNI that is not the VPC CNI, is this until proven
otherwise. Three commands:

```bash
kubectl get ippool default-ipv4-ippool -o jsonpath='{.spec.vxlanMode}'   # CrossSubnet?
kubectl get nodes -o wide                                                # one subnet?
aws ec2 describe-instances --query 'Reservations[].Instances[].[PrivateIpAddress,SourceDestCheck]'
```

`CrossSubnet` + one subnet + `True` is the signature. Note that a managed
cluster hides this: EKS with the VPC CNI gives pods real VPC addresses, so
there is no foreign source address and the check never fires. It returns the
moment you run your own CNI, which is the shape this repo deliberately tests.

## 45. A healthy load balancer carrying no traffic at all

> **Platform.** AWS does this to everyone using an NLB with instance targets.

**Symptom:** `kubectl get svc` shows an address. AWS shows the balancer
`active`. Target health shows exactly what it should for
`externalTrafficPolicy: Local`: one healthy target on the node running the pod,
the rest unhealthy. Every request from outside times out. Nothing appears in
any log, on either side.

**Why:** an AWS Network Load Balancer with **instance** targets preserves the
CLIENT address by default, and the health check does not go where the traffic
goes.

| | Health check | Real traffic |
|---|---|---|
| Destination port | `healthCheckNodePort` (its own port) | the Service `nodePort` |
| Answered by | kube-proxy, on the host | the pod, through Calico |
| Source address | the balancer's own interfaces, inside the subnet | **the browser's public address** |

So the check exercises a path that touches neither the pod nor any rule keyed
on source address, and passes. The traffic is then dropped **twice**, by two
independent default-deny layers that both key on exactly what the check never
tested:

- the security group admits the NodePort range from the subnet, and the packet
  now carries a public source
- `console-ingress-lb` admits `ipBlock: 10.10.0.0/16`, which is right on
  Hetzner because the hcloud balancer is told `use-private-ip`, and wrong here
  for the same reason

This is item 11 re-derived for AWS, exactly as `PORTABILITY.md` predicted the
rule would have to be. What it did not predict is that the check would go on
passing while both layers dropped everything.

**The obvious fix is not one.** Setting
`service.beta.kubernetes.io/aws-load-balancer-preserve-client-ip: "false"`
looks like the answer and does nothing: that annotation belongs to the separate
AWS Load Balancer Controller, and the **in-tree** service controller used here
ignores it. Verified on 2026-07-25 by deleting the Service and recreating it
with the annotation present from the start; the target group came up with
`preserve_client_ip.enabled = true` regardless.

**Fixed here:** `cloud/aws/loadbalancer.sh` sets the target-group attribute
directly after the controller creates it, then proves the result with a request
rather than with a status field.

The alternative is to open both layers to `0.0.0.0/0`, which also works and
costs the cluster its default-deny posture on the one port facing the internet.
Turning off client-IP preservation instead makes traffic arrive from inside the
subnet, exactly as it does on Hetzner, so the security group and the
NetworkPolicy stay as written and both clouds keep the same posture. The price
is that the console sees the balancer rather than the client, which is also
true on Hetzner, so the comparison stays honest.

**Timing, for the record:** `kubectl apply` to a request returning 200 took
**3 min 34 s** on AWS. The equivalent on Hetzner was about 20 s to create and
attach the balancer plus 15-45 s for the first health check to flip.

**The rule worth carrying:** a load balancer reporting healthy targets has told
you that its health check works. It has told you nothing about whether traffic
arrives. Prove the second thing with a request.

## 46. The stack's own posture forbids the operator's way in

> **Ours, and unresolved by design.** A real constraint, not a mistake.

**Symptom:** the tunnel overlay applies cleanly, `kubectl kustomize` renders,
a server-side `--dry-run` passes without a single complaint, and then no pod
appears at all. The Deployment exists, the ReplicaSet exists, replicas: zero.

```
ReplicaFailure=True FailedCreate: violates PodSecurity "restricted:latest":
  wg must not include "NET_ADMIN"      volume "tun" uses hostPath
  containers "wg","caddy" must not set runAsUser=0
```

**Why:** `manifests/00-base.yaml` puts
`pod-security.kubernetes.io/enforce: restricted` on the namespace on purpose,
so the API server enforces the posture rather than each pod promising it. The
tunnel cannot meet it, and the reason is irreducible:

- `wireguard-go` must create a TUN interface, which needs `CAP_NET_ADMIN` and a
  `/dev/net/tun` hostPath
- the console manages peers over a **unix socket**, and a unix socket cannot
  cross a pod boundary, so wg must share the console's pod

So the console's POD is privileged. Not the console CONTAINER, which still
drops every capability and runs as 10001.

**`baseline` does not help, and this cost a second cycle.** Baseline permits
exactly one added capability, `NET_BIND_SERVICE`, and forbids hostPath
outright. Kubernetes has three levels and nothing between baseline and
privileged, so `privileged` is the only label that admits this pod.

**What that actually costs:** in `agent-stack` the API server enforces; in the
console's namespace the pod only promises. A future edit that adds a capability
there will be accepted where in `agent-stack` it would be refused.

**Done here:** the console moved to its own namespace so the planes keep their
enforced `restricted`, `warn: baseline` keeps every apply printing what a
stricter cluster would refuse, and `security-tests.sh` scans BOTH namespaces
and asserts the console namespace holds exactly the expected violations and no
others. The warning cannot fail; the test can.

**The real fix is a product change:** give the console a network transport to
the UAPI so wg can live alone and the console goes back inside `restricted`.
Agreed as the next piece of work rather than left as a note.

**The check that missed it, again.** `kubectl kustomize` renders a Deployment
and `kubectl apply --dry-run=server` accepts it, because PodSecurity applies to
a POD and the pod is created later, by the ReplicaSet. A dry run on a workload
tells you the shape is valid. It cannot tell you the cluster will run it.

## 47. A heredoc without BuildKit builds an empty entrypoint, quietly

> **Platform.** Docker does this to everyone still on the classic builder.

**Symptom:** the image builds, `docker images` shows a sane size, and every
container dies immediately with:

```
exec /usr/local/bin/wg-entrypoint.sh: exec format error
```

which reads like an architecture mismatch and sends you to check the platform.

**Why:** the entrypoint is written with `RUN cat > file <<'ENTRY' ... ENTRY`.
Heredocs in `RUN` are a **BuildKit frontend** feature. The legacy builder
accepts the Dockerfile, reports success, and writes a **zero-byte** file, so
the kernel cannot find an interpreter and reports the exec failure above.

```
docker run --rm --entrypoint /bin/sh stack/wg:dev -c 'wc -c < /usr/local/bin/wg-entrypoint.sh'
0
```

It stayed hidden because nothing ever built these two images: no manifest
referenced them and neither `build.sh` nor `deploy-aws.sh` listed them. They
were written for a deployment that did not exist yet.

**Fixed here:** `# syntax=docker/dockerfile:1.7` as the first line of both
Dockerfiles, plus `RUN test -s <entrypoint>` immediately before `ENTRYPOINT`,
so an empty script fails the BUILD instead of the container. Build with
`DOCKER_BUILDKIT=1` and `docker-buildx` installed; Ubuntu ships it as a
separate package and `docker.io` does not pull it in.

## 48. The ACME DNS-01 solver does not use your cluster DNS

> **Platform.** Any DNS-01 issuer inside a namespace with a default-deny policy.

**Symptom:** a certificate never arrives. The ACME account registers fine, the
challenge starts, and then:

```
could not determine zone for domain "_acme-challenge.box.it-rat.com":
could not find the start of authority: dial tcp 8.8.8.8:53: i/o timeout
```

The message names the ZONE, so the first hour goes into the API token and its
permissions, which are fine.

**Why:** before writing a TXT record the solver has to know which zone owns the
name, and it finds out by querying the start of authority **against a public
resolver of its own choosing**, not through the cluster's DNS. An egress policy
that allows port 53 only to `k8s-app: kube-dns` therefore blocks it, while
ordinary name resolution in the same pod keeps working perfectly.

**Fixed here:** the ACME egress rule allows UDP and TCP 53 to the public
internet alongside 443, with the private ranges still excepted so nothing
inside the cluster is widened.

**The tell:** the ACME account registered, which proves outbound 443 works. If
443 works and the challenge still fails, the missing hole is 53.

## 49. A NetworkPolicy selects a POD, so a sidecar's egress is the app's egress

> **Ours, and unfixed in this shape.** Recorded so it cannot reach a demo.

**Symptom:** after moving the console into a pod that also holds Caddy,
`security-tests.sh` reports:

```
FAIL console -> the model provider (must go through the gateway): expected blocked, got open
FAIL console -> the open internet: expected blocked, got open
```

**Why:** Caddy needs egress on 443 to answer an ACME challenge, so the pod got
a rule allowing it. NetworkPolicy has no notion of a container: `podSelector`
picks the POD, and every container in it shares the result. The console
inherited Caddy's way out.

**Why it matters more than a failed check.** The deployment's central claim is
that the gateway is the only metered path out, which is what makes "no prompt
leaves without being metered" a property of the deployment rather than a
sentence in a README (item 3 of this suite). A console with its own Copilot
that can reach `api.anthropic.com` directly punctures exactly that. It did not
happen in `agent-stack`; it happened because the tunnel forced the console into
a pod with a component that legitimately needs the internet.

**Why it cannot be narrowed away.** Caddy needs `api.cloudflare.com` and
`acme-v02.api.letsencrypt.org`, both behind CDNs with moving addresses.
NetworkPolicy matches addresses, not names; FQDN egress rules are a Calico
Enterprise feature, not an open-source one. "Allow only those two" is not
expressible here.

**Three ways out, none of them a patch:**

1. take certificate issuance out of the pod entirely, so Caddy reads a Secret
   somebody else filled and needs no internet at all
2. give Caddy its own pod, which the tunnel can reach by Service instead of
   `127.0.0.1`, and which would also let it drop root by listening high
3. the network transport to the UAPI (item 46), which separates wg and Caddy
   from the console by construction and closes this as a side effect

The third is the agreed direction, so this is recorded rather than patched:
fixing it inside the current shape is work that the right shape discards.

**Until then, treat these two failures as expected and named.** A suite with a
known failure that is written down is honest; the same failure quietly removed
from the suite is not.

## 50. The console reads whether it has an operator once, at startup

> **Ours.** Harmless on one box, a dead end on Kubernetes.

**Symptom:** `genaryx-web set-password --username ops` prints
`operator 'ops' set in /var/lib/stack/.taipan/genaryx-web/operator.json` and
exits zero. The file is on disk with the right size and timestamp. The browser
still shows **"This box has no operator yet"**, and `/api/auth/session` still
answers `{"configured": false}`.

**Why:** the console resolves whether an operator exists when it starts, and
does not look again. On one machine that is invisible, because the operator is
set before the process runs. On Kubernetes the console starts automatically
with its Deployment, so the account is necessarily created AFTER it is already
running, and the console never notices.

Everything about the failure argues for a different cause: a command that
reports success, a file that exists, and a UI that tells you to run the command
you just ran.

**Fixed here:** `deploy.sh` and `cloud/aws/deploy-aws.sh` restart the console
after setting the password and wait for the rollout. One line each, and without
it every fresh cluster hands its operator a login they cannot use.

## 51. Dropping ALL drops CAP_CHOWN, and root does not get it back

`securityContext: { runAsUser: 0, capabilities: { drop: ["ALL"], add: ["NET_ADMIN"] } }`
reads like "root, with one extra power". It is the opposite: root with exactly
one power and none of the fifteen it normally has. `chown`, `chgrp`, and
anything that calls them, fail with `Operation not permitted` **as uid 0**,
which is a sentence that sends you looking for a filesystem problem.

Found through `socat`. The tunnel image relays the daemon's UAPI socket to a
second socket the console can open, and that relay is created with
`group=10001`, which is a `chown` underneath. On Docker Compose, where the
container is root with the default capability set, it works. On Kubernetes with
`drop: ALL` the relay never comes up:

```
socat[32] E chown("/var/run/wireguard/console.sock", -1, 10001): Operation not permitted
!! the console relay socket never appeared at /var/run/wireguard/console.sock
```

The second line is the entrypoint's own, and it killed the container, so the
tunnel died over a component that deployment did not need at all: the console
was in another pod, reaching the daemon over the network door, and a unix
socket cannot cross a pod boundary in the first place.

**Fixed here:** the two transports are written as alternatives. `WG_PROXY_LISTEN`
set means the console is elsewhere, so the unix relay is not started, not
required, and not waited for. If a future deployment genuinely needs both, the
capability to add is `CAP_CHOWN`, named explicitly.

**The general form:** `drop: ["ALL"]` is not a hardening decoration on top of
root. It is the whole capability set, and every `add:` is the complete list of
what the container may do. Anything the image did as root before, that is not
on that list, now fails.

## 52. A readiness probe is a client, and a silent one

Adding a `tcpSocket` readiness probe to the tunnel fixed a real problem: without
it `rollout status` reported success on a container that was already dying
(item 43, in a new place). It created a quieter one.

The probe opens the port, sends nothing, and closes. Every three seconds.
Forever. The proxy behind that port logged every connection that carried no
valid request as a refusal, so the log filled with:

```
>> uapi-proxy: refused: empty request
>> uapi-proxy: refused: empty request
```

ten a minute, in front of every real refusal. A log where the interesting line
is one in three hundred is a log nobody reads, so an actual attempt to send
`replace_peers=true` would have scrolled past unseen. The check meant to make a
failure visible made a different failure invisible.

**Fixed here:** nothing attempted is nothing logged. A connection that closes
without sending a byte, and a connection that sends only the blank line that
terminates a request, both return the same sentinel and produce no output and
no reply. Everything else still logs loudly. The trade is stated in the source:
a bare connect from an unauthorised source goes unlogged, and what keeps such a
source away is the NetworkPolicy in front of the port, not a line in a file.

Both halves are asserted in `images/uapi-proxy/main_test.go`, including the
opposite direction, because a test that only proves silence would also pass on
a proxy that logged nothing at all.

## 53. A test that follows the namespace stops following the thing

Item 46 added test 5b to `security-tests.sh` because tests 4 and 5 scan one
namespace, and when the console moved out of it both kept passing purely by not
looking. 5b was written to audit "the console's namespace".

Then the console moved BACK, and the capabilities did not come with it. On the
next run 5b reported:

```
ok  the console runs inside agent-stack under enforced restricted:
    no exception to audit
```

which is true and useless. The NET_ADMIN, the `/dev/net/tun` hostPath and the
two root containers all still existed, one namespace over, unaudited, and the
suite said so in green. The exact failure 5b was written to prevent, recurring
inside the fix for it.

**Fixed here:** the test finds the namespace that holds `NET_ADMIN` by looking
for it, and audits that, whichever namespace it turns out to be. "No namespace
holds NET_ADMIN" is a separate, honest pass. The console's own posture is
asserted separately again.

**The general form:** name what a check is about by the PROPERTY, not by where
the property happened to live when the check was written. A location is a fact
about today's layout; a capability is the thing worth auditing, and it can move
without anybody editing the test that claims to cover it.

## 54. Let's Encrypt backdates notBefore, so counting by it counts wrong

The duplicate-certificate rate limit is five per identical name set per seven
days, and hitting it makes the console unreachable in a way that reads like a
Caddy bug. So it is worth counting before deliberately discarding a `caddy-data`
volume, and the public CT log is the way to count without touching the CA.

The trap is which timestamp to count. A certificate obtained at 12:42 reads:

```
not_before:      2026-07-26T11:44:21     <- backdated ~1 hour
entry_timestamp: 2026-07-26T12:42:52     <- when it was actually logged
```

Let's Encrypt sets `notBefore` about an hour in the past to tolerate clock skew
on the machines that will validate it. Read `not_before` as issuance time and a
certificate issued minutes ago looks an hour old, so a fresh volume looks like
it reused an existing certificate rather than burning one of five.

That is the wrong direction to be wrong in: it says there is headroom that has
already been spent.

**Count `entry_timestamp`**, and confirm identity by serial rather than by time
at all:

```bash
SER=$(openssl x509 -in cert.crt -noout -serial | cut -d= -f2 | tr 'A-Z' 'a-z' | sed 's/^0*//')
curl -s "https://crt.sh/?serial=$SER&output=json"
```

`crt.sh/?q=<name>&output=json` also returns HTML rather than JSON under load, so
a script that pipes it straight into a parser fails with a decode error that
says nothing about rate limits. Retry, and check the body starts with `[`.

## 55. The process printing to your terminal is not the one that can see it

`kubectl exec` without `-t` gives the container a pipe. So a program that
decides how to format its output by asking "am I on a terminal" gets the answer
`no` in exactly the case where a human is watching, and `yes` never.

Found while wiring `up.sh` to print the first device's QR. The QR renderer chose
ANSI colour with `std::io::stderr().is_terminal()`, which is the right check in
a program run directly on the box, and is always false when `up.sh` runs it. A
QR is dark modules on a LIGHT field; without colour the light field is the
terminal's background, so on a dark theme the code comes out inverted and a
scanner that does not try both polarities reads nothing.

The failure is quiet in the worst way: the QR appears, correctly shaped and
plausible, and simply does not scan. Nothing logs anything.

**Fixed here:** the decision moved to the caller that can make it. The CLI takes
`--color` and `--no-color`, keeps the automatic check only as the default for
someone running it directly, and `up.sh` passes `[ -t 2 ] && --color`. Whoever
owns the terminal owns the question.

**Guarded:** `the_terminal_qr_carries_the_same_modules_the_encoder_produced`
reads the drawing back, rebuilding the module matrix from the characters (each
carries two stacked modules) and comparing it with the encoder's own output.
Verified to go red by inverting the renderer on purpose: `module (7,0) differs`.
A test that only checked the output was non-empty would have passed on every
version of this bug.

**The general form:** any `isatty` in a program that something else invokes is
a guess about a terminal it cannot see. Environment-based colour detection has
the same hole. Let the outermost caller decide and pass it down.

## 56. k3s-uninstall.sh hangs forever on a Longhorn RWX volume

Uninstalling k3s from a cluster that ran Longhorn with an RWX class stops dead,
with no error and no timeout. The last thing on screen is an ordinary-looking
line:

```
sh -c 'umount -f "$0" && rm -rf "$0"' /var/lib/kubelet/plugins/.../globalmount
```

and nothing follows it. Ten minutes later, nothing still. `ps` tells the story:

```
618245 D  rpc_wait_bit_killable  umount.nfs4
```

**Why:** Longhorn serves an RWX volume over NFS from a share-manager POD. The
uninstall script kills the pods first and unmounts afterwards, so by the time
it reaches that mount the NFS server it belongs to no longer exists. `umount -f`
on a dead NFS server does not fail: it blocks in the RPC layer, in
uninterruptible sleep, indefinitely. `-f` reads like "force" and here means the
opposite of giving up.

Nothing on screen mentions NFS, Longhorn, or a volume. The path scrolls past
looking like the fifty before it.

**The way out**, in order:

```bash
pkill -9 -x umount.nfs4          # -x, an exact name: see below
pkill -9 -f 'k3s-unin''stall'    # the script itself
mount | grep -E 'kubelet|longhorn' | awk '{print $3}' | sort -r |
  while read -r m; do umount -l "$m"; done
/usr/local/bin/k3s-uninstall.sh  # now completes
```

`umount -l` is the lazy unmount: it detaches the tree immediately and never
speaks to the server, which is exactly right when the server is gone.

**And the trap inside the fix.** `pkill -f k3s-uninstall` matches ANY process
whose command line contains that string, including the shell running the script
that contains the pkill. Written the obvious way it kills its own session
mid-cleanup, which is how this was found the second time. Split the literal, or
match the interpreter's argument precisely.

## 57. Apply-then-patch deadlocks a hostNetwork Deployment

`install.sh` applied the upstream hcloud CCM manifest and then patched its
arguments, because the default `--secure-port=10258` collides with k3s's own
listener (item 4). The patch is correct. The ORDER made it unreachable.

What happens: the apply creates a pod with the default port. It crash-loops,
and the error is the fourth line of a wall of usage text:

```
failed to listen on 0.0.0.0:10258: bind: address already in use
```

The patch then creates a second ReplicaSet with `--secure-port=10268`. That pod
never starts:

```
0/1 nodes are available: 1 node(s) didn't have free ports for the requested pod ports
```

because the first pod is `hostNetwork: true` and holds the node's port budget
while it crash-loops. Under RollingUpdate the two wait for each other forever:
the old pod is not removed until the new one is Ready, and the new one cannot be
scheduled until the old is gone. What the operator sees is:

```
Waiting for deployment "hcloud-cloud-controller-manager" rollout to finish:
  1 old replicas are pending termination...
error: timed out waiting for the condition
```

Nothing in that message is about a port, and the pod that is actually wrong is
the one being waited ON, not the one being waited FOR.

**Fixed here:** the patch also sets `strategy: type: Recreate` (with
`rollingUpdate: null`, or the API server rejects the mixture). The old pod stops
before the new one starts. That is the right strategy regardless: two
single-replica hostNetwork controllers can never run side by side on one node,
so RollingUpdate was describing something that cannot happen.

**The general form:** RollingUpdate assumes old and new can coexist. Anything
claiming a node-wide resource, a host port, a host path lock, a fixed device,
breaks that assumption, and the failure is a deadlock rather than an error.

## 58. A Hetzner token is project-wide, so "all servers" is not "your cluster"

The firewall step read the server list from the API:

```python
servers = [s["id"] for s in api("servers?per_page=50")["servers"]]
api(f"firewalls/{fw['id']}/actions/apply_to_resources", ...)
```

and applied the firewall to every one of them. The installer is TOLD which
machines it owns, on the command line, and asked the API instead.

A Hetzner API token is scoped to a project, not to a server. So a project
holding anything besides this cluster gets that machine's inbound traffic
restricted to one operator's address by a script it was never named in. Found
with five servers in the project and one in the cluster: both firewalls this
repo creates were attached to all five.

Nothing warns you. The firewall applies cleanly, and the other machines stay
reachable from the operator's own address, so it looks fine from the desk of
the person who caused it.

**Also not idempotent.** `apply_to_resources` answers **HTTP 422 Unprocessable
Entity** for a resource the firewall already covers, so the second run of an
installer whose own error message says "Re-running is safe: every step here is
idempotent" died on its own previous success, with a Python traceback and no
sentence about what was unprocessable.

**Fixed here:** the nodes named in `--servers`/`--agents` are matched against
the project by public address, and anything not found is a hard stop rather
than a silent skip (a firewall applied to the wrong project is worse than
none). Servers the firewall already covers are subtracted before the call, so
a re-run reports "already covers all N node(s)" and makes no request at all.

**The general form:** when a script has been given the list, do not ask an API
for a bigger one. The token's scope and the task's scope are different
questions, and cloud APIs answer the first.

## 59. A fresh random k3s token makes the installer unrepeatable

`install.sh` generated the cluster token like this:

```bash
K3S_TOKEN_VALUE="${K3S_TOKEN_VALUE:-$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
```

which is correct exactly once. k3s encrypts its bootstrap data with the token
the cluster was created with, so the second run hands it a different one and
k3s refuses to start:

```
level=fatal msg="Error: preparing server: failed to bootstrap cluster data:
  failed to reconcile with local datastore:
  bootstrap data already found and encrypted with different token"
```

The operator sees only `Job for k3s.service failed because the control process
exited with error code`, and the journal buries the one line that matters under
a hundred repetitions of `Unit process NNNN (containerd-shim) remains running
after unit stopped`.

The script meanwhile prints, in its own preflight, `(k3s already present on X:
this script is idempotent, it will re-run the installer)`, and its error trap
promises `Re-running is safe: every step here is idempotent`. Both were false
for the one step that mattered.

**Fixed here:** the token is read from `/var/lib/rancher/k3s/server/token` when
that exists, and only generated when it does not.

**Read it from the DATASTORE, not from the environment file.** The k3s installer
rewrites `/etc/systemd/system/k3s.service.env` with whatever it was just given,
so after a failed run that file holds the WRONG token and the right one survives
only in the datastore's own copy. Measured on the box: 38 characters in the env
file, 112 in the datastore, and only the second one worked.

**The general form:** anything generated with `/dev/urandom` at the top of an
installer is a first-run value. If the thing it identifies persists, the second
run has to find it rather than mint it, and "idempotent" in a comment is not a
property, it is a claim that has to be true of every line under it.

## 60. multipathd arrives with open-iscsi and takes every Longhorn volume

Longhorn needs `open-iscsi` on the host, so `install.sh` installs it. On Ubuntu
that pulls in `multipath-tools`, which nobody asked for and which starts
`multipathd` by default.

Longhorn presents each volume over iSCSI as `IET / VIRTUAL-DISK`. multipathd
sees a SCSI device, claims it as a multipath map, and from then on the device
has a holder. Formatting fails:

```
format of disk "/dev/longhorn/pvc-..." failed: type:("ext4") ... output:(
mke2fs 1.47.0 (5-Feb-2023)
/dev/longhorn/pvc-... is apparently in use by the system;
will not make a filesystem here!)
```

Every PVC stays Pending, every pod waits on its volume, and the deployment
reports `0 of 1 updated replicas are available` forever. The pod event blames
the CSI driver. Nothing anywhere says `multipath`, and the package that caused
it was never named in any command the operator ran.

Confirm it in one line:

```bash
multipath -ll     # mpatha (36000...) dm-0 IET,VIRTUAL-DISK
```

**Fixed here:** node prep appends a blacklist to `/etc/multipath.conf`,
restarts multipathd, and runs `multipath -F` so maps already claimed are
dropped (without the flush, volumes created before the fix stay unformattable
until the node reboots).

**Blacklist by VENDOR, not by devnode.** The fix most often quoted for this is
`devnode "^sd[a-z0-9]+"`, which turns multipath off for every SCSI disk on the
host. Matching `vendor "IET" product "VIRTUAL-DISK"` excludes exactly the
Longhorn devices and leaves a genuine multipath configuration working.

## 61. verify.sh had a check a single-node cluster could never pass

`install.sh` supports one server and says so out loud: "one server means one
etcd member. Fine for a demo, not HA." `verify.sh` then asserted the workload
was spread over more than one node, and reported:

```
FAIL every pod is on one node: check the podAntiAffinity patch
```

There is no podAntiAffinity patch that can spread six pods over one node. The
line was a permanent red on a topology the installer offers, which trains an
operator to read the summary as "8 passed, 1 expected failure" and stop looking
at the failure count altogether.

**Fixed here:** with one node it is a `note`, counted separately from passes so
it cannot inflate them either. With more than one node it is still a hard
failure, because there it means something.

**The general form:** GOTCHAS collects checks that cannot go red. This is the
mirror image, and it costs more: a check that cannot go green teaches people to
ignore red.

## 62. Editing a shell script while it is running corrupts the running copy

A deploy was in its last step when its own file was edited on disk. It ended:

```
24 passed, 0 failed, 2 noted
./deploy.sh: line 308: unexpected EOF while looking for matching `"'
```

The script was syntactically perfect both before and after. `bash -n` passed on
both versions.

**Why:** bash does not read a script into memory. It reads it lazily, and it
remembers its position as a BYTE OFFSET into the open file. Insert forty lines
near the top while it is running and the offset it returns to no longer points
at the start of a command; it points into the middle of one. The interpreter
then reports a syntax error at a line number that is correct for neither the old
file nor the new one.

The failure lands wherever the script happens to be when it next reads, so it
looks unrelated to the edit and unrelated to whatever the script was doing. Here
it swallowed the block that prints the operator password, once, which is exactly
the output that cannot be reproduced by re-running.

**The rule:** never edit a script that is executing. If a fix cannot wait, write
it to a different file and swap the whole file with `mv`, which replaces the
directory entry and leaves the running process reading the original inode
undisturbed. In-place editors that truncate and rewrite (`>`, most editors' save)
do not do that.

Same hazard, same reason: `git pull` or `git checkout` in a repository whose
script is currently running.

## 63. An apostrophe inside a heredoc inside `$( )` breaks bash

This is a syntax error:

```bash
X="$(cat <<INNER
Set the operator's password here.
INNER
)"
```

```
unexpected EOF while looking for matching `''
syntax error: unexpected end of file
```

Remove the apostrophe and it parses. Nothing else about the file is wrong, and
`bash -n` reports the failure at the LAST line of the script rather than at the
line that caused it, so a long file gives no hint at all.

**Why:** bash tokenises the whole `$( ... )` before it knows the heredoc body is
data. The `'` opens a quote that never closes, and the search for its partner
runs off the end of the file.

**Found** writing three branches of a message, one of which said "the operator's
password". Two of the three parsed.

**The way out**, in preference order:

1. `printf -v VAR '%s\n' "line" "line"` and no heredoc at all. Readable,
   substitutes normally, and has no quoting hazard.
2. Quote the delimiter (`<<'INNER'`), which makes the body fully literal. Only
   works when nothing in it needs expanding.
3. Reword. Cheap, and the least honest of the three: the next person adds an
   apostrophe back.

**The general form:** a heredoc inside a command substitution is parsed twice,
and the first pass does not know it is looking at prose. `$'...'`, backticks and
unbalanced parentheses in the body are the same hazard.
