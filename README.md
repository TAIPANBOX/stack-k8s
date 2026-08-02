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

Nothing here bakes a credential into an image, and nothing here ships one.
`install.sh` GENERATES the admin bearers for the money and policy planes, the
policy store's database password and its approval secret, straight into Secrets
on your own cluster. This repo never sees them.

That is a correction, not a design note. The manifests used to hand out
`TOKENFUSE_CLOUD_ALLOW_DEVKEY=1`, which makes the literal string `devkey` an
admin bearer, and to leave `WARDRYX_KEYS` unset, which makes the policy plane
accept ANY bearer. On one machine that is a dev convenience. In a cluster it is
a published credential: on 2026-07-25 a pod that labelled itself
`plane: console` used it to delete a freeze, and the frozen agent resumed while
the console still displayed FROZEN (GOTCHAS 20).

The operator's own login is separate and stays theirs: one account per box, set
with `genaryx-web set-password` reading the password from stdin, stored as an
Argon2id hash on the console's volume. There is no path by which we could
issue, see or reset it.

## Layout

```
deploy.sh       THE entry point. Asks what it needs, then: install.sh, images,
                manifests, verify.sh, security-tests.sh, and your way in.
install.sh      the cluster itself: k3s, Calico, Longhorn, the storage classes,
                the cloud controller. Hetzner-specific by design.
build.sh        build the images and import them into every node over ssh
verify.sh       prove a cluster is running this stack, not merely green
security-tests.sh  attack it: every fix below re-run as a standing check, from
                a forged pod label to the bytes in etcd. Two dozen of them, and
                the exact count varies with what a given cloud exposes
tunnel/         the operator's way in: WireGuard, TLS, and the console behind
                both. Nothing here is published; see tunnel/README.md
manifests/      plain YAML + a kustomization, applied with kubectl -k (no Helm)
images/         one Dockerfile per language family, plus the console's mixed build
GOTCHAS.md      every trap this cost us, each with the fix that is already applied
PORTABILITY.md  the measured Hetzner baseline, and what to compare AWS/GCP on
cloud/          the same cluster on AWS and on GCP: Terraform, the installer
                differences, the teardown, and COSTS.md for what each one burns
evidence/       command output from the live cluster, not claims about it
```

## Running it

One command. It asks what it needs BEFORE the long part, so a missing DNS
record costs ten seconds rather than fifteen minutes of building images.

```bash
git clone https://github.com/TAIPANBOX/stack-k8s && cd stack-k8s
./deploy.sh --servers ip1,ip2,ip3 --agents ip4,ip5 --hcloud-token <token>
```

What it asks, in order:

| | |
|---|---|
| the operator tunnel? | `Y/n`. No means you will reach the console with `ssh -L`, which is a real way to run this |
| your console domain | must have an A record at `10.9.0.1`. Checked against DNS while you are still watching |
| your gateway host | must have an A record at a public address of one of your nodes. Also checked |
| the console account | username, and a password typed blind and twice. Blank generates one |

Then it installs, and ends by issuing your first WireGuard device: a `.conf`
saved beside the script at mode 0600, a QR for a phone, and the address to open.

The whole conversation can be skipped for automation:

```bash
./deploy.sh --servers ip1,ip2,ip3 --hcloud-token <token> \
  --console-domain box.you.com --endpoint-host gw.you.com
```

or `--no-tunnel` to leave the way in for later. There is deliberately no
`--console-password`: an argument is visible in `ps` to every user on the
machine for as long as the deploy runs.

Piped from curl it still works, and with no terminal to ask on it says so and
names the flags rather than hanging or guessing:

```bash
curl -fsSL https://raw.githubusercontent.com/TAIPANBOX/stack-k8s/main/deploy.sh | bash -s -- \
  --servers ip1,ip2,ip3 --hcloud-token <token> --no-tunnel
```

### The parts, if you want them separately

```bash
./install.sh --servers ip1,ip2,ip3 --agents ip4,ip5 --token <hcloud-token>
./build.sh root@ip1 root@ip2 root@ip3 root@ip4 root@ip5
kubectl apply -k manifests/
KUBECONFIG=./kubeconfig.yaml ./tunnel/up.sh
```

Every one of them is idempotent, and that is now true rather than merely
claimed: the first time anyone ran this twice on the same machine it broke six
times, each a step correct once and impossible the second time. GOTCHAS 56-62.

Nothing here needs a credential. Every repository this pulls is public and
Apache-2.0, the Genaryx console included since 2026-07-27, so the console comes
up by default rather than on production of a token. `--console-token` survives
for the one case it is still good for: building the console from a private fork
of your own.

Then reach the console over your own tunnel (`20-console.yaml` explains why
there is no public entry point by default), and check the deployment with
`./verify.sh --freeze` and `./security-tests.sh`.

### Being told, rather than watching

`deploy.sh` asks for an address for alerts alongside the tunnel and the console
account. Answer it and the box mails you when one of your own agents crosses a
line: a budget gone, a policy denial, a run killed, an agent behaving unlike
itself. The mail comes from the box, and it carries a link into your console,
never a button that acts.

Leave it blank and nothing is installed for it. This is the one workload in the
stack allowed to open a connection to something outside the cluster, so it is
opt-in the same way the load balancer is, and for the same kind of reason:

```bash
kubectl apply -f manifests/45-heraldyx.yaml
```

Read that file's header before you do. It carries the only egress rule in the
namespace that reaches past DNS, it says exactly how narrow that rule is, and
it says what it leaves open.

## Status

**Proven on a live five-node cluster, 2026-07-25.** Five Hetzner CPX42 in
`fsn1`, k3s v1.36.2 with embedded etcd on three of them, Calico v3.29.1,
Longhorn v1.7.2. Every plane answered, the RWX event log bound and was shared
across nodes, the money plane survived a pod restart, the cloud controller
provisioned a real load balancer that served the console, and an agent frozen
from the browser was denied by the policy plane's PDP and stayed denied after
that plane's pod was restarted. `verify.sh --freeze`: 10 passed, 0 failed.

Then attacked, the same night: a pod that labelled itself `plane: console`
deleted a freeze with the literal bearer `devkey` and the agent resumed, while
the console still displayed FROZEN. Secrets were readable in plaintext straight
out of etcd. The kubelet API was open to the whole internet on every node. The
gateway never asked the policy plane anything, and with no upstream configured
it answered calls itself from a stub and metered the invented tokens as spend.

All of that is closed in these files now, and `security-tests.sh` re-runs each
attack as a standing check: **23 passed, 0 failed, 1 noted** (the note is the
neighbouring namespace, which no manifest here can harden - see GOTCHAS 23).

### Then the same thing on AWS and GCP

**Six clusters across three clouds, 25 to 27 July 2026.** The same manifests,
the same k3s, the same Calico and Longhorn, the same `verify.sh` and
`security-tests.sh`, so the three runs are compared on identical proofs rather
than on impressions. All of it destroyed afterwards and both cloud accounts
verified empty by direct API query. Written up in `PORTABILITY.md`, priced in
`cloud/COSTS.md`, command output in `cloud/{aws,gcp}/evidence/`.

| | Hetzner | AWS | GCP |
|---|---|---|---|
| `verify.sh --freeze` | 10 passed, 0 failed | 10 passed, 0 failed | 10 passed, 0 failed |
| `security-tests.sh` | 23 passed, 1 noted | 22 passed, 0 failed, 2 noted | 24 passed, 0 failed, 2 noted |

Four things the runs settled, each of which changed something we had written
down:

- **Exactly one line of Kubernetes configuration differs between the three
  clouds.** Calico runs `VXLANCrossSubnet` on Hetzner and AWS; a GCE VPC has no
  layer 2 at all, every packet is routed by destination, a pod address matches
  no route, and no instance flag changes that, so on GCP the encapsulation
  becomes unconditional. On AWS the equivalent fix was one Terraform line
  (`source_dest_check = false`) and the Kubernetes side stayed byte for byte
  identical to Hetzner.
- **The throughput collapse past 64 concurrent callers, recorded here on 25
  July as a design limit, was wrong.** On both dedicated-core clouds there is
  no cliff out to 256 concurrent, on two chip generations: only latency rises.
  It was a property of a shared-vCPU instance. `PORTABILITY.md` carries the
  retraction next to the claim it replaces.
- **On identical silicon the two hyperscalers are the same machine.** 2,449
  decisions/s on AWS `c6a` against 2,479 on GCP `c2d`, a difference of 1.2%,
  with p50 apart by a hundredth of a millisecond. The first comparison put AWS
  62% ahead, and that was a chip generation wearing a cloud costume.
- **Secrets encryption at rest is now verified rather than asserted.** Four
  clusters went past this check because it wanted `etcdctl` and no cloud image
  has it. Checked properly on one small node per cloud: a Secret with a unique
  marker, absent from 130 MB of raw datastore on disk, with a control step
  confirming the search reaches the datastore at all (the secret's NAME is
  found 22 times, because names are not encrypted, only values). AWS and GCP
  returned identical results. That is a property of k3s installed with the
  right flag, not of either cloud.

The command output behind every sentence above is in `evidence/` and
`cloud/*/evidence/`. Every trap the runs cost us is written up in
`GOTCHAS.md`, now **70 items**, each already fixed here, which is the whole
point: the next person to run this should not meet any of them.

## License

Apache License 2.0. See [LICENSE](LICENSE).

The node addresses in `HANDOFF.md` and `evidence/` are placeholders: those
documents are a field report from the cluster this was proven on, and that
cluster is ephemeral. Substitute your own.
