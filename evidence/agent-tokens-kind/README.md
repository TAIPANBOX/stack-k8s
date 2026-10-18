# Agent tokens on kind: the measured end-to-end run (CLAUDE.md invariant 54)

The scripts here drove the REAL images on a local kind cluster (kindest/node 1.37.0, no cloud):
`ghcr.io/taipanbox/vouchryx:v0.4.0` and `ghcr.io/taipanbox/tokenfuse:v1.16.0`, with stand-ins
for everything else. The product manifests were applied to the same objects with
`agent-tokens/up.sh` and `agent-tokens/down.sh`, which turned the door off and on again.

Files: `vouchryx.yaml`, `gateway.yaml`, `upstream.yaml` and `upstream-stub.py` are the stand-in
Deployments (env names and values mirror 54-delegation*.yaml and 58-agent-tokens-*.yaml, but
they are not the product manifests); `dpop.py` makes ES256 DPoP proofs with openssl and the
standard library; `request.py` asks vouchryx for a token by enrolment key or by a projected-style
service-account token (`kubectl create token --audience http://vouchryx:4310`); `calls.py`
makes the admission and refusal calls; `e2e2.py` does the workload path and a replayed proof;
`ban_trials.py N` measures stop-to-refusal over N trials; `failclosed.py` takes vouchryx down.

Measured 2026-10-18:
- admitted: enrolled agent token + its proof, 200; workload token (service-account token as
  client assertion), 200; the upstream recorded that it received the provider key from its file.
- refused: a header naming another agent, 403 agent_id_contradicts_token; a token beside a static
  key, 401; a stranger's proof, 401; a forged token and no credential, 401; a replayed proof on
  its second use, 401.
- off (after down.sh): the agent token is refused 401 and a static key still gets 200.
- ban (ban_trials.py): six trials on the first configuration: refused after 1.69, 9.68, 9.42, 9.47, 9.63, 9.41 s; three trials on the final configuration (the patch bodies applied by up.sh): 10.48, 9.51, 9.59 s. Nine trials: 1.69 to 10.48 s, mean 8.88 s; the gateway polls every 12 s.
- fail closed (failclosed.py): vouchryx down; the agent token refused at 51.6 s and, on a second run, at 57.9 s; the static key 200 throughout. The list is refused at its 60 s age limit, so this is the bound.

NOT covered by this run: the k3s issuer string (kind's `https://kubernetes.default.svc.cluster.local`
was read, not k3s's); the kubelet's own rotation of a projected token; a ban that must survive a
vouchryx restart on a PVC (kind used an emptyDir); NetworkPolicy enforcement (kind's default CNI does
not enforce it).

Broker, measured 2026-10-18 (the MCP broker's relayed check, CLAUDE.md invariant 54):
- `broker-base.yaml` is the stand-in broker before the door (the product's env subset, the stand-in
  upstream `mcp-stub` and its keys Secret). `agent-tokens/up.sh` then patched it with
  `manifests/58-agent-tokens-broker-patch.yaml`: the door on, the broker's own key from
  `broker-taint-key` at `/run/taint/key`, and `TOKENFUSE_MCP_TAINT_FAILMODE=closed`.
- `stand-in-52-upstream.yaml` and `stand-in-54-ingress.yaml` mirror the product rules that let the
  broker reach its upstream and let the gateway and vouchryx admit it. `stand-in-dns.yaml` gives every
  pod the DNS egress rule that the product's `30-network-policy.yaml` has: this kind enforces
  NetworkPolicy, so a restricted pod could not resolve a service name, and a call by name hung. With
  that rule the same call by name returned 200. `mcp-stub.yaml` and `mcp-stub.py` answer `tools/call`
  as the upstream.
- `broker_call.py` sends one `tools/call` through the broker's port-forward
  (`kubectl -n agent-stack port-forward svc/tokenfuse-mcp-broker 14420:4200`) with an enrolled agent
  token and a DPoP proof whose `htu` is the broker's own address. Result: HTTP 200 with the stub's
  answer. The broker fails closed on the taint check, so the 200 means the gateway answered allow.
- At the gateway's check route, the broker's key with the token gets 200 (allow), and no key gets 401
  (measured the same day). Under the broker's closed failmode a 401 at the check is a refusal; that
  refusal was not run through the broker.
- Stand-in only: the broker's upstream and taint gateway were set with `kubectl set env` (the upstream
  to `mcp-stub`, the taint gateway to `tokenfuse-gateway`). The product manifests were not changed by
  this run.
