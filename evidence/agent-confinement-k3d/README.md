# What the agent-pod network confines, on k3d (CLAUDE.md invariant 77)

`run.sh` ran on forge (Debian, Docker 26.1.5) against a k3d v5.9.0 cluster, k3s v1.35.5, one server, no load balancer, with its
own kubeconfig. Two outputs are kept:

- `output-enforcing.txt`: `./evidence/agent-confinement-k3d/run.sh`, k3s's embedded NetworkPolicy controller on.
- `output-not-enforcing.txt`: `NO_ENFORCE=1 ./evidence/agent-confinement-k3d/run.sh`, k3s started with
  `--disable-network-policy`, the control for a cluster that enforces nothing.

Each output opens with the sha256 of the files under test, so it can be tied to a commit:
`git show <commit>:<path> | sha256sum`.

## What is real and what is a stand-in

Real, applied as the product has them:

- every NetworkPolicy of the default apply set, from `kubectl kustomize manifests/`: `30-network-policy.yaml`,
  `54-delegation.yaml` and `58-agent-tokens-network.yaml` among them (the run prints the list);
- `agent-tokens/confined-agent`, the overlay, applied by `agent-tokens/confine-check.sh` itself;
- `agent-tokens/confine-check.sh --external 1.1.1.1:443`, run as an operator runs it;
- the namespace `agent-stack` with Pod Security `restricted`, read from `manifests/00-base.yaml`.

Stand-ins:

- the stack's own pods (vouchryx, the gateway, wardryx, idryx, tokenfuse-cloud, the policy store, the console). `standins.py`
  generates one busybox pod and one Service for each from the rendered manifests: the pod carries the real pod labels, listens
  on the real container ports and answers HTTP. No stack image ran, so these runs say nothing about what the stack's
  processes do with a connection, only about which connections the policies let through.
- the scratch namespace `agent-confine-scratch`, which the check makes: a listener and a probe in a namespace that no policy
  covers.

## The runs, in order (`output-enforcing.txt`)

| Run | Policies | Expected | Why |
|---|---|---|---|
| 1 | as shipped | exit 0 | the agent pod opens vouchryx and the gateway and nothing else; the unlabelled pod opens nothing; the pod in the uncovered namespace opens the listener and the outside address and none of the stack's services |
| 2 | the agent-pod policy widened to all egress | exit 1 | the agent pod reaches the listener, the Kubernetes API and the outside address |
| 3 | `default-deny` with its Egress type removed | exit 0 | still confined: `allow-dns` selects every pod for egress as well, so a pod stays isolated. Recorded because it is not what the file's name suggests |
| 4 | `default-deny` and `allow-dns` both with their Egress type removed | exit 1 | a pod with no label is no longer isolated |
| 5 | the agent-pod policy without its gateway rule | exit 1 | an agent could not call the model |
| 6 | the agent-pod policy deleted | exit 1, naming the policy | an agent pod there is not confined |
| 7 | as shipped again | exit 0 | the second run from the same cluster |

`output-not-enforcing.txt` is one run of the same check on a cluster whose policy controller is off: the objects exist, every
policy is present, and the check goes red on every row the policies were meant to refuse.

## What the output shows about the policies

- The labelled pod opens vouchryx:4310 and tokenfuse-gateway:4100 and is refused everywhere else it was probed, including a
  listener in a namespace with no policy (which no ingress rule of the stack guards, so the refusal is egress confinement), the
  Kubernetes API and an address outside the cluster.
- A pod of `agent-stack` with no label opens nothing it was probed against: not vouchryx, not the gateway, not the other
  services.
- A pod outside `agent-stack` is held by nothing in this repository except the ingress rules of the planes themselves, and those
  refused it at every service of the stack; it reached the listener and the outside address freely.
- DNS resolved for both pods of `agent-stack`, for a cluster name and for `example.com`. `allow-dns` opens port 53 to the
  cluster resolver for every pod of the namespace, so a connection is refused and a lookup is not.

## Repeat it

```sh
# on a machine with docker, k3d and kubectl; the run uses its own kubeconfig and deletes its cluster on every exit path
evidence/agent-confinement-k3d/run.sh | tee evidence/agent-confinement-k3d/output-enforcing.txt
NO_ENFORCE=1 CLUSTER=g23-noenf API_PORT=6553 evidence/agent-confinement-k3d/run.sh | tee evidence/agent-confinement-k3d/output-not-enforcing.txt
```

`KEEP_CLUSTER=1 STOP_AFTER_SETUP=1` stops after the stand-ins are up and leaves the cluster for inspection.
