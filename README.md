# The agent stack on Kubernetes

`stack-up`'s `up.sh` runs the whole open stack on one machine in one command.
This is the same stack as a Kubernetes workload: the same binaries, the same
ports, the same wiring, expressed as manifests instead of background processes.

Nothing here is a rewrite. It is a translation, and the translation is where
the interesting part lives: putting the stack on Kubernetes forces two facts
about its architecture into the open, and both are load-bearing.

## Fact 1: the planes couple through an event log, not through APIs

On one machine that coupling is invisible, because everything shares a
filesystem:

- `tokenfuse-gateway` appends every metered call to `events/tokenfuse.ndjson`
- `wardryx` appends every policy decision to `events/wardryx.ndjson`
- `idryx` is started with `--load tokenfuse:<events file>` and builds its
  identity graph by READING that file
- the Genaryx console's bus tails the same directory

So the event directory is a shared, writable dependency of four components. On
Kubernetes that is not a detail, it is the deployment's shape: pods on
different nodes do not share a filesystem, and the default k3s storage class
(`local-path`) is `ReadWriteOnce`, one node only.

Three honest ways out, in the order a real operator would consider them:

1. **One node.** Pin the four event-coupled pods to a single node with a
   `local-path` volume. Simple, and it works, but the cluster is then a
   scheduler, not a distribution.
2. **A ReadWriteMany volume.** Run an in-cluster NFS provisioner (or Longhorn)
   and give the event directory an RWX claim. The pods spread across nodes and
   the coupling stays exactly as the code expects it. This is what the
   manifests here do, because it is the only option that is genuinely
   multi-node without touching the stack's own code.
3. **Replace the file with a stream.** The correct long-term answer: the
   event log becomes a real append-only service (or a broker) and the
   filesystem stops being an interface. That is a change to the stack, not to
   its deployment, so it is out of scope here and named as future work rather
   than pretended away.

## Fact 2: the console is not a client of four services, it is a host of five tools

The Genaryx console reaches the money, policy and identity planes over HTTP,
so those are ordinary `Service` objects. But it reaches four more tools by
EXECUTING them:

| Tool | How the console uses it |
|---|---|
| `qryx` | shells out to scan a path for crypto (`GENARYX_SCAN_TARGET`) |
| `verdryx` | shells out to read and run quality evals against `verdryx.db` |
| `engram-mcp` | speaks MCP over **stdio** to a child process |
| `mockryx` | shells out to fire the hostile drills at the gateway |

A sidecar container cannot be another container's stdin. So these four are not
pods: they are binaries that must exist **inside the console image**. That is
why `images/console.Dockerfile` is a four-language build (Rust console, Go
qryx and mockryx, Python verdryx and engram) rather than four Deployments.

Stated plainly because it is the opposite of the obvious guess, and getting it
wrong produces a cluster where half the console's tabs are permanently empty.

## What runs as what

| Kubernetes object | Component | Port |
|---|---|---|
| Deployment + Service | `tokenfuse-cloud` | 8080 |
| Deployment + Service | `tokenfuse-gateway` | 4100 |
| Deployment + Service | `wardryx` | 8090 |
| Deployment + Service | `idryx` | 8081 |
| Deployment + Service | `genaryx-console` (with qryx, verdryx, engram, mockryx inside) | 7420 |
| PersistentVolumeClaim (RWX) | the shared event directory | |
| PersistentVolumeClaim | `verdryx.db`, `engram.engram` stores | |
| CronJob | the governance routines (`routines.sh`'s FinOps export, crypto trend, quality drift, identity sweep) | |
| NetworkPolicy | default-deny, then exactly the paths above | |

## Keys stay yours

Nothing here bakes a credential into an image. The cloud and wardryx admin
keys, and the console's own operator record, come from Secrets that the
operator creates on their own cluster. `secrets.example.yaml` shows the shape
and holds no real value; `taipan up`'s dev credential mode
(`TOKENFUSE_CLOUD_ALLOW_DEVKEY=1`) is offered for a throwaway cluster and is
labelled as exactly that.

## Layout

```
install.sh      bring up the cluster itself: k3s, Calico, Longhorn, the storage
                classes, the cloud controller. Hetzner-specific by design.
build.sh        build the images and import them into every node over ssh
verify.sh       prove a cluster is running this stack, not merely green
manifests/      plain YAML + a kustomization, applied with kubectl -k (no Helm)
images/         one Dockerfile per language family, plus the console's mixed build
GOTCHAS.md      every trap this cost us, each with the fix that is already applied
PORTABILITY.md  the measured Hetzner baseline, and what to compare AWS/GCP on
evidence/       command output from the live cluster, not claims about it
```

Three commands, in this order:

```bash
./install.sh --servers ip1,ip2,ip3 --agents ip4,ip5 --token <hcloud-token>
./build.sh root@ip1 root@ip2 root@ip3 root@ip4 root@ip5
kubectl apply -k manifests/
```

Then reach the console over your own tunnel (`20-console.yaml` explains why
there is no public entry point by default), and check the deployment with
`./verify.sh --freeze`.

## Status

**Proven on a live five-node cluster, 2026-07-25.** Five Hetzner CPX42 in
`fsn1`, k3s v1.36.2 with embedded etcd on three of them, Calico v3.29.1,
Longhorn v1.7.2. Every plane answered, the RWX event log bound and was shared
across nodes, the money plane survived a pod restart, the cloud controller
provisioned a real load balancer that served the console, and an agent frozen
from the browser was denied by the policy plane's PDP and stayed denied after
that plane's pod was restarted. `verify.sh --freeze`: 10 passed, 0 failed.

The command output behind each of those sentences is in `evidence/`. Nine more
traps found during that run are written up in `GOTCHAS.md` (items 9-17), each
already fixed in these files - which is the whole point: the next person to run
this should not meet any of them.
