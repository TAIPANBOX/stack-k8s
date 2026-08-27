# GCP range, 2026-08-27: what the failure runs found

## The short version

Seven findings, six of them measured on the cluster and one of them a correction
to my own reasoning. Two are defects in our deploy scripts rather than upstream
behaviour, and those are the two worth acting on.

| # | finding | worth acting on |
|---|---|---|
| F1 | the deploy's own key cleanup locks the operator out of the nodes it touches, while Kubernetes keeps reporting them healthy | **yes** |
| F2 | cluster DNS runs at one replica, so one dead node costs 298 s of name resolution | **yes** |
| F3 | a ghost node object appeared after a stop/start and never cleared; node identity is not pinned | **yes, but see the correction** |
| F4 | a clean stop is detected in 2 s | no, expected |
| F5 | quorum held at 2 of 3, `/readyz` in 89 ms; pod phase stayed stale for 5 min | no, documented |
| F6 | partition: the minority never served a stale read; the majority advertised it for 45 s | no, but worth knowing |
| F7 | at 1 of 3 the survivor refused within 1 s | no, correct behaviour |

The one number that surprised me: **noticing a peer is gone took 45 s, noticing
that you are the one cut off took 1 s.** Both are correct, and the asymmetry is
the whole risk surface.

Cluster: 3 x c3d-highcpu-8, europe-west3-a, k3s + etcd on all three, Calico,
Longhorn. Billing started 16:41:23Z at 1.1258 USD/h.

Every number below is `@measured 2026-08-27` on that cluster, with the command
or the log line that produced it named. Raw output is in `evidence/`.

## F1. The deploy takes the operator's SSH away from the nodes it touches,
## while Kubernetes keeps reporting them healthy

`evidence/14-node1-after-reboot.txt`

Two of three nodes refused `publickey` for a key that had not changed. Node 3
kept working.

Ruled out by direct check, not by reasoning: the operator IP was unchanged and
still inside `operator_cidr`; the ed25519 key in instance metadata matched the
local key byte for byte (fingerprint checked locally, not reproduced here);
`enable-oslogin` was FALSE; the serial console showed k3s healthy and etcd
snapshotting, with no sshd permission error and no OOM kill; and a metadata
re-sync did not restore access.

**A reboot restored SSH immediately.** So the cause was live state on the
machine, not keys, metadata or firewall. That is the dangerous shape: the
cluster stayed green throughout, so nothing would have alerted, and the
operator loses hands on the box exactly when a build is doing something heavy.

**The mechanism was found afterwards, in our own code, and my first reading of
this finding was wrong.** I attributed it to the image build, on the assumption
that the build ran on nodes 1 and 2. It did not. `deploy-gcp.sh` sets
`BUILDER="${ALL_NODES[${#ALL_NODES[@]}-1]}"`, the LAST node, so the build ran on
node 3, the one that kept working.

What the affected set actually matches is the distribution-key cleanup, which
skips the builder and touches every other node:

```sh
grep -vF "$DIST_PUB" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new \
  && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys
```

`mv` replaces the inode, so the operator's key file comes back owned and moded
by whatever the shell's umask gave the temporary. sshd is deliberately strict
about that file and refuses it, and the refusal it gives is exactly
`Permission denied (publickey)`. The reboot fix fits too: the GCE guest agent
rebuilds `authorized_keys` from instance metadata at boot.

Provenance, kept straight: the loop's skip list matching the surviving node
exactly is `@measured`. That `mv` losing the mode is what sshd then refused is
`@claude`, strongly supported but not reproduced under `sshd -ddd`.

Fixed in the same session: written through the file rather than over it, guarded
so an empty result can never truncate the operator's own key, and followed by an
ssh to every node so the break fails at the step that caused it. GOTCHAS 86.

## F2. Cluster DNS is a single replica, so one dead node costs ~5 minutes of DNS

`evidence/09..12`, causal chain closed:

| fact | value | source |
|---|---|---|
| coredns replicas | **1** | `kubectl get deploy coredns -o jsonpath=.spec.replicas` |
| eviction toleration | `not-ready=NoExecute/300s` | the pod's own tolerations |
| node went NotReady | 17:07:09 | `evidence/06-node-death.txt` |
| replacement pod started | 17:12:07 | `.status.startTime` |
| **outage** | **298 s** | difference of the two |

298 s against a 300 s toleration is not a coincidence, it is the toleration.
Nothing was broken; the configuration says a dead node costs five minutes of
name resolution, and it charged exactly that.

The deployment does carry a `topologySpreadConstraint` with
`whenUnsatisfiable: DoNotSchedule`, which would spread replicas across hosts.
With `replicas=1` it has nothing to spread.

**Correction to my own claim.** I first queried DNS at 17:12:23 and got an
answer in 1 ms, and reported that the outage claim was unproven. That query
landed 16 seconds after the replacement pod started: it measured the new pod,
not the gap. The timeline above is what the artifacts say.

## F3. A node that reboots rejoins under a DIFFERENT name and leaves a ghost

`evidence/12-two-findings.txt`, `evidence/13-why-the-name-changed.txt`

After the restart the API had **four node objects for three machines**:

```
stack-k8s-server-1                                          Ready     created 17:12:26
stack-k8s-server-1.europe-west3-a.c.stack-k8s-gcp.internal  NotReady  created 16:43:08
stack-k8s-server-2.europe-west3-a...internal                Ready
stack-k8s-server-3.europe-west3-a...internal                Ready
```

The old object stays NotReady forever and still owns **17 pod records**.

The k3s unit carries no `--node-name` (`systemctl cat k3s | grep -c node-name`
= 0), so the identity is whatever `hostname` returns at the moment k3s starts.
`hostname` returns the FQDN now, after the fact, which is why this hides from any
check run later.

**I then tested that explanation, and the test refuted the strong form of it.**
I pinned `node-name` in `/etc/rancher/k3s/config.yaml` on node 3, left node 2
unfixed, and reset both at 17:21:21 as a controlled pair. Result
(`evidence/18-controlled-reboot.txt`):

```
stack-k8s-server-2...internal   Ready   38m   <- unfixed, SAME name, no ghost
stack-k8s-server-3...internal   Ready   37m   <- pinned,  SAME name, no ghost
```

The unfixed control kept its name. So:

- the trigger is **not** "any reboot", and my sentence claiming it fires on every
  restart was wrong;
- **the fix is untested**, because the control did not fail. Pinning `node-name`
  is still the right defensive change, since it removes the dependency on
  hostname timing altogether, but nothing here demonstrates it was needed;
- what distinguishes the one failure is that node 1 was **stopped and started**
  (off for 4.5 minutes, fresh DHCP lease) while nodes 2 and 3 were **reset**
  (~25 s, no power-down). Either the stop/start path differs, or the race is
  intermittent and node 1 simply lost it. `@claude`, one trial each way; this
  needs repeated stop/start cycles to settle, which is a separate run.

What survives as fact: a ghost node object appeared once, it holds 17 pod
records, it never clears itself, and the deploy scripts leave node identity to a
value that is not pinned.

## F4. A clean stop is seen in 2 seconds; 04.08's hard reset was not seen for 28

`evidence/06-node-death.txt`: last `Ready` 17:07:07, `NotReady` 17:07:09.

This does not contradict the 04.08 result, it bounds it. A graceful
`instances stop` lets the kubelet say goodbye, so detection is immediate. The
04.08 run used `sysrq` reset, where detection waits on a timeout. Same cluster
shape, two orders of magnitude apart in detection, decided entirely by whether
the machine got to say it was leaving.

## F5. Quorum behaved, and the report did not

With one of three etcd members gone, `/readyz` answered **ok in 89 ms**
(`evidence/07-quorum-under-loss.txt`). Correct.

But at 17:11:22, four minutes after the machine was powered off, the API still
listed **17 pods as `Running` on it** (`evidence/08`). That is the documented
300 s eviction behaviour rather than a defect, and it is worth writing down
anyway: for five minutes, `kubectl get pods` is a statement about the past. Any
alert or dashboard that trusts pod phase alone reports a healthy cluster while a
third of it is switched off.

## F6. Partition: the minority stays honest, but the majority advertises it for 45 s

Node 1 (10.10.0.4, the address the other two use as `--server`) was cut from
both peers with iptables, self-lifting so a lost SSH could not strand it.
`evidence/15-partition-minority.txt`, `evidence/16-partition-majority.txt`.

**Minority side, and this is the good news.** Every probe of node 1's own API
from node 1 itself, once cut off, hit the 3 s timeout:

```
17:15:48 partition APPLIED
17:15:48 local-api: real 3.01
17:15:53 local-api: real 3.01
17:16:03 local-api: real 3.01      (unchanged for the whole partition)
```

It never answered. A server that has lost quorum blocks rather than serving what
it last knew, so there is no stale-read split brain to worry about here. That is
the property worth having and it holds.

**Majority side, and this is the cost.**

| event | time | gap |
|---|---|---|
| partition applied | 17:15:48 | |
| last seen `Ready` by the majority | 17:16:31 | |
| marked `NotReady` | 17:16:33 | **45 s** |

For 45 seconds the two surviving nodes advertised a peer that was answering
nothing. Against **2 s** for the graceful stop in F4, detection of a partition is
22x slower, and the window is spent routing at a node that cannot serve.

This is the 04.08 finding ("partition worse than death") reproduced on different
hardware with numbers attached. The mechanism is not exotic: a clean shutdown is
announced, a partition has to be inferred from silence, and inference waits out
the node monitor grace period.

### F1 confirmed a second time, by the node that was not rebooted

At 17:18Z, node 2 (key-rewritten, never rebooted) still answered
`Permission denied (publickey)`, while node 1 (key-rewritten, rebooted at
17:11:56) answered normally. Two machines, same cleanup step, same symptom; the
only one that recovered is the one that was restarted. The remedy is a reboot, and
nothing short of it was found to work.

### F6 addendum: the minority never wavered

Node 1's own API kept timing out at 3.01 s on every probe for the full
four and a half minutes of the partition, without a single answer in between.
Refusal under lost quorum is not a race that sometimes leaks a stale read here;
it held flat for the whole window.

## What this run did NOT prove

Stated plainly, because the coverage is partial and the gaps are not small.

- **The stack's own services were never exercised.** The build reached only two
  of roughly ten images (`stack/tokenfuse:dev`, `stack/genaryx-console:dev`)
  before F1 took SSH away from the build node. So every scenario in
  `PLAN.md` that needed trailryx, vouchryx or a live PDP did not run. Nothing
  here says anything about revocation, erasure or delegation on a cluster.
- **Everything above is about the k3s platform**, which is the layer under our
  services, not our code. It is still worth having: F1 and F3 are defects in
  our own deploy scripts, not upstream behaviour.
- **F1's mechanism is identified but not reproduced under instrumentation.**
  The symptom, its scope, its remedy and the code path are established; that
  `mv` losing the file's mode is what sshd then refused has not been shown with
  `sshd -ddd`.
- **Storage was never tested.** Longhorn ran throughout and no volume was
  killed, detached or failed over. A stateful workload behaves differently
  under node loss than the stateless pods measured here.
- **Single trial each.** Every number is n=1 on one cluster in one zone. The
  45 s and 2 s figures are what happened, not distributions.

## F7. Losing two of three nodes: the survivor refuses within a second

`evidence/21-node1-reboot-observer.log`. Nodes 2 and 3 were reset at 17:21:21,
leaving node 1 alone. Its own API stopped answering at **17:21:22**, one second
later, and stayed silent for four consecutive probes until the peers returned
around 17:21:46.

Same property as F6 at a harsher ratio: with quorum gone, the survivor refuses
rather than serving what it last knew. The refusal is immediate, unlike the 45 s
the majority took to notice a partitioned peer. Noticing someone else is gone is
slow; noticing you are the one who is cut off is instant.

## A note on the operator's link

Yurii's own internet dropped for 5-10 minutes during this run. It does not
affect anything above, and the reason is specific rather than general: nodes 1
and 2 answered `Permission denied (publickey)`, which is a completed TCP
connection and a finished handshake in which the server rejected the key. A
dropped link produces `Connection timed out` or `No route to host`. Node 2 was
still giving the same key rejection at 17:18Z, with the link up.

The decisive point is stronger than the error string, and it was already in the
evidence before the question was asked: **in the same minute, over the same link
and the same ssh config, node 3 accepted that key while nodes 1 and 2 rejected
it.** A link fault cannot be selective by destination host. What separates the
three machines is not the network between them and the operator, it is that the
deploy rewrote the key file on two of them.

The measurements themselves never crossed that link: the observers ran on the
nodes, wrote to local files, and timestamped with `date -u` on the node. A
broken link would have failed a `gcloud` call with an error, not altered a
number.
