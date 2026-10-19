# Agent tokens required by default, on kind (stack-k8s v1.5.0; CLAUDE.md invariants 24, 54, 62, 63)

`run-v1.19.0.sh` ran on a local kind cluster (kind v0.33.0, kindest/node v1.37.0, no cloud) with the images the
product manifests pin: tokenfuse v1.19.0 at the gateway and the MCP broker, wardryx v2.3.0, vouchryx v0.6.0. The
run reads each image from `manifests/10-planes.yaml`, so it cannot drift from the pin.

- `output-v1.19.0.txt` is the current run (run 7, on the branch with the broker's door in
  `manifests/58-agent-tokens-network.yaml`): every check as expected, exit 0.
- `output-v1.19.0-before-broker-door.txt` is the same harness on the product before that door, exit 1. It is the
  measured defect (see "The broker's second door" below).

## What the product files did in the run

- `manifests/54-delegation.yaml` applied as the default install applies it: vouchryx started with no identity
  provider and no trusted issuer, with the one enrolled agent that `lib/vouchryx-mint.sh` writes at deploy time.
- The keys of the plane, the agent registry and the static-key ConfigMap were minted by the product libraries
  (`lib/vouchryx-mint.sh`, `lib/static-keys.sh`), run through a shell shim with the same calls as the deploy.
- `manifests/58-agent-tokens-network.yaml` applied as the product has it: the agent-pod network and the MCP broker's
  door into the gateway (`gateway-ingress-mcp-broker`).
- The gateway and the broker are STAND-INS (`gateway-door.yaml`, `broker-door.yaml`): their door env is copied from
  `manifests/10-planes.yaml` and `manifests/52-tokenfuse-mcp-broker.yaml`, not applied from them. wardryx is the real
  image on a stand-in manifest (`wardryx.yaml`) with a throwaway Postgres and an empty policy list. The store's
  password, its DSN and wardryx's approval secret come from the Secret `stand-in-policy-db`, which the run generates
  in its scratch directory, so no password is written in a tracked file.
- Stand-ins for the provider (`upstream.yaml`), the MCP upstream (`mcp-stub.yaml`) and the egress rules the product
  gives by other means (`stand-in-network.yaml`, `stand-in-dns.yaml`). `manifests/30-network-policy.yaml` is not
  applied, so the broker's admission to the gateway comes from 58 alone.

## What was measured (run 7, `output-v1.19.0.txt`)

| Check | Result |
|---|---|
| enrolled operator agent asks vouchryx for a token, resource = `https://vouchryx.agent-stack.invalid` | 200 |
| the same agent asks for another audience | 400 `invalid_target` (journal: `audience_not_allowed`) |
| a wrong enrolment secret | 401 `invalid_client` |
| agent token and its DPoP proof, gateway | 200 |
| a token with a stranger's proof, gateway | 401 |
| a token with no proof, gateway | 401 |
| a token beside a static key, gateway | 401 |
| a header naming another agent beside the token, gateway | 403 `agent_id_contradicts_token` |
| a listed static key (`felyx`), gateway | 200 |
| an unlisted static key (`stranger`), gateway | 401 `agent_token_required` |
| agent token and its proof, MCP broker | 200, and the JSON-RPC result carries the MCP stub's answer (`stub answered lookup`) |
| a stranger's proof, MCP broker | 401 |
| agent's own token and proof, decided by wardryx | 200 `allowed` |
| asserted agent contradicts the token, wardryx | 403 `agent_contradicts_token` |
| a proof from another key, wardryx | 403 `agent_token_proof_invalid` |

Runs 4 and 6 (the earlier history of this harness) were the same run after fixes to the checks (fresh run identifiers,
a fresh proof per call) and to the wardryx stand-in's policy file (it must be a YAML list). Run 5 was stopped during
setup and has no result.

## The broker's second door: the measured cause and the fix

Before the fix (`output-v1.19.0-before-broker-door.txt`), an agent token and its proof passed the broker's door, and
the broker's tool-call check then answered JSON-RPC `-32004`, `blocked: the taint gate could not be reached`. The MCP
upstream never received the call.

The check is the broker's call to the gateway's `/v1/fuse/check-tool-call` on TCP 4100. `manifests/58` selects the
gateway for Ingress and admits only pods labelled `taipanbox.dev/agent-token=true`. The broker carries no such label,
so the call was dropped. Read from the manifests: in a full install, `planes-ingress` in
`manifests/30-network-policy.yaml` also admits the broker (it carries `plane: money`) to the gateway, which is why the
drop shows only where that file is absent, as in this harness. The full-install path is not measured here.

The fix is `gateway-ingress-mcp-broker`, a document in 58 that admits `app=tokenfuse-mcp-broker` to the gateway on
TCP 4100 and nothing else, so 58 holds the broker's check without 30. `scripts/agent-tokens-are-required.sh` checks
that document, and four teeth cases in `scripts/gates-have-teeth.sh` (removed, another port, another app, a whole
namespace) each make the gate fail for its own reason.

After the fix (run 7) the call reaches the gateway, the broker forwards it, and the MCP stub answers. `checks.py` now
requires the stub's text in the body, not only HTTP 200, and prints both broker bodies in full, so a closed refusal
cannot pass as an answer.

Two log lines quoted in earlier versions of this file are not part of this failure. The broker's
`refused an agent token door=mcp_broker why=Token(WrongKey)` and wardryx's
`agent token proof refused on /v1/decide ... the proof's key is not the token's cnf.jkt` come from the harness's
stranger-proof checks: a stranger's proof sent to the broker, and a proof from another key sent to wardryx. Those
refusals are the expected outcome of those checks. The broker log of run 7 has no `taint gate refused` line.

## Harness changes made with the fix

- `checks.py`: the broker rows require the stub's answer and print the full JSON-RPC body.
- `run-v1.19.0.sh`: waits for wardryx to log `serving on` before any check runs. Its first start can exit when it dials
  policy-db about a second after the store is Ready, before kube-proxy has programmed the Service. Two runs of the
  fixed branch failed that way before this wait was added (wardryx unreachable, and the broker's policy hook failing
  closed with `-32004` for that reason, not the one under test). Run 7 shows one restart of wardryx from that race.
- `stand-in-network.yaml`: unchanged. The broker's door comes from 58 as the product has it.

## Not covered by this run

- The rest of the stack: Longhorn, Calico, the console, the policy controller (admission was not re-measured here; the
  verified-images run in `evidence/verified-images-kind/` predates this change).
- A full install with `manifests/30-network-policy.yaml` applied (see above).
- wardryx with policies: this run loads an empty policy list, so wardryx allows every call (`allowed: no policy
  targets agent`). A policy that denies a tool is not measured.
- A real MCP upstream: the stub answers the broker's call.
- A real k3s issuer string and a projected service-account token in a pod (kind's issuer was not read here).
- A ban (`POST /v1/revoke` with `ban:true`) and a vouchryx restart: not run in this change. K2's measurements
  (`evidence/agent-tokens-kind/`) cover them for the previous pin.
- NetworkPolicy enforcement beyond the stand-in rules (kind's CNI was assumed to enforce them, as K2 found).
