# What bites you, and what this repo already does about it

Every item here is something that actually went wrong while bringing this
cluster up, not a theoretical warning. Each one is FIXED in the files here, so
following the README should not reproduce any of them. They are written down
anyway, because a fix you cannot see is a fix you will undo by accident.

## 1. The Go builder image is older than the code

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

**Symptom:** none, which is the problem. `kubectl apply` accepts every
NetworkPolicy, `kubectl get networkpolicy` lists them, and nothing is enforced.

**Why:** k3s defaults to Flannel, which does not implement NetworkPolicy.

**Fixed here:** k3s is installed with `--flannel-backend=none
--disable-network-policy` and Calico provides both. If you skip this, the
default-deny posture in `manifests/30-network-policy.yaml` is decoration.

## 3. Two default StorageClasses

**Symptom:** a PVC with no `storageClassName` binds to whichever default the
API server picks, and you find out later when a volume is on the wrong class.

**Why:** k3s ships `local-path` marked default; Longhorn also installs itself
as default.

**Fixed here:** the install marks `local-path` non-default and leaves Longhorn
as the single default:

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

## 4. The hcloud cloud-controller-manager fights k3s and Calico

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

**Symptom:** the cluster works, so nobody notices. etcd peer traffic, the
kubelet API and the VXLAN overlay are all crossing the public network.

**Why:** `--node-ip` defaults to the interface with the default route, which on
a Hetzner cloud server is the public one.

**Fixed here:** every node is attached to a private network and installed with
`--node-ip`/`--advertise-address` on its `10.10.0.x` address. The public IP
stays in `--tls-san` only, so an operator's kubectl can still reach the API.
A Hetzner private network costs nothing, so there is no reason to skip it.

## 6. The stack's own coupling: a shared event log

**Symptom:** put the planes on different nodes with the default storage class
and idryx sees an empty identity graph, because the file it loads from is on
another node's disk.

**Why:** the planes couple through `events/*.ndjson`, not through APIs. See
README, "Fact 1".

**Fixed here:** a `stack-rwx` StorageClass backed by Longhorn with three
replicas, and the manifests ask for it BY NAME so a cluster without RWX fails
at apply time instead of quietly scheduling everything onto one node.

## 7. The console hosts the tools it runs

**Symptom:** you split qryx, verdryx, engram and mockryx into their own
Deployments, everything comes up green, and the Crypto, Quality, Memory and
Drills tabs are permanently empty.

**Why:** the console EXECUTES those four (engram over MCP on stdio). A sidecar
cannot be another container's stdin.

**Fixed here:** they are built into the console image. See README, "Fact 2".

## 8. `USER nonroot` is not a non-root user, as far as kubelet is concerned

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
