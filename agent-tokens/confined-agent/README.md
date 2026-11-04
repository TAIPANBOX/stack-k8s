# A client's agent pod, under the agent-pod network

Optional, and in no default apply. For an operator who runs an agent inside this cluster and wants the
NetworkPolicy to cover it. CLAUDE.md invariant 77 is the rule; `manifests/30-network-policy.yaml` and the README's
section "What the NetworkPolicy confines, and where your agents run" say which side of the line the policy sits on.

## What it gives the pod

The pod lives in `agent-stack` and carries `taipanbox.dev/agent-token=true`. `manifests/58-agent-tokens-network.yaml`
selects that label and leaves the pod three ways out: DNS (`allow-dns` in `30`), vouchryx on 4310 and the gateway on 4100.
Nothing may open a connection to it. A pod in `agent-stack` that carries no label gets default-deny and DNS only.

## Use it

```sh
kubectl apply -k agent-tokens/confined-agent
./agent-tokens/confine-check.sh --external 1.1.1.1:443     # what the label confines, row by row
```

The container is a stand-in (busybox, sleeping). To run your agent, copy `agent.yaml`, replace the image, the command
and the env, keep the namespace, the labels and the projected token volume, and apply your copy. With admission on,
list your image first (`policy/README.md`, "Your own agent images"). Then enrol it so vouchryx will issue it a token:

```sh
./agent-tokens/up.sh --registry agents.txt    # a line ending workload:<issuer>#system:serviceaccount:agent-stack:agent-confined
```

The check proves the label, not your image: it probes from this overlay's pod and from two control pods, so it needs
no tool inside your agent's image. A pod that carries the label is confined the same way whatever it runs.

## What it does not do

- It does not confine an agent that runs outside `agent-stack`: another namespace, another cluster, a laptop. No policy
  in this repository applies there. Such an agent is held by the door (an agent token at the gateway and the broker).
- DNS stays open to every pod of the namespace, labelled or not.
- The label is the pod's own claim. Whoever can create pods in `agent-stack` chooses their labels (GOTCHAS 20), so the
  namespace's RBAC is part of the boundary.

`evidence/agent-confinement-k3d/` is the measured run: the commands, the output, and what was a stand-in.
