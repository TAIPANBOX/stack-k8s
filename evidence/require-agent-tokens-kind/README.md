# Agent tokens required by default, on kind (stack-k8s v1.5.0; CLAUDE.md invariants 24, 54, 62, 63)

`run-v1.19.0.sh` ran on a local kind cluster (kind v0.33.0, kindest/node v1.37.0, no cloud) with the images the
product manifests pin: tokenfuse v1.19.0 at the gateway and the MCP broker, wardryx v2.3.0, vouchryx v0.6.0. The
run reads each image from `manifests/10-planes.yaml`, so it cannot drift from the pin. Its output is
`output-v1.19.0.txt` (run 6, the last run on the final launcher state, exit 0).

## What the product files did in the run

- `manifests/54-delegation.yaml` applied as the default install applies it: vouchryx started with no identity
  provider and no trusted issuer, with the one enrolled agent that `lib/vouchryx-mint.sh` writes at deploy time.
- The keys of the plane, the agent registry and the static-key ConfigMap were minted by the product libraries
  (`lib/vouchryx-mint.sh`, `lib/static-keys.sh`), run through a shell shim with the same calls as the deploy.
- `manifests/58-agent-tokens-network.yaml` applied (the agent-pod network).
- The gateway and the broker are STAND-INS (`gateway-door.yaml`, `broker-door.yaml`): their door env is copied from
  `manifests/10-planes.yaml` and `manifests/52-tokenfuse-mcp-broker.yaml`, not applied from them. wardryx is the real
  image on a stand-in manifest (`wardryx.yaml`) with a throwaway Postgres and an empty policy list.
- Stand-ins for the provider (`upstream.yaml`), the MCP upstream (`mcp-stub.yaml`) and the egress rules the product
  gives by other means (`stand-in-network.yaml`, `stand-in-dns.yaml`).

## What was measured (run 6, `output-v1.19.0.txt`)

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
| agent token and its proof, MCP broker | HTTP 200, but JSON-RPC `-32004` (refused closed, see below) |
| a stranger's proof, MCP broker | 401 |
| agent's own token and proof, decided by wardryx | 200 `allowed` |
| asserted agent contradicts the token, wardryx | 403 `agent_contradicts_token` |
| a proof from another key, wardryx | 403 `agent_token_proof_invalid` |

Runs 4 and 6 are the same run after fixes to the checks (fresh run identifiers, a fresh proof per call) and to the
wardryx stand-in's policy file (it must be a YAML list). Run 6 also gave the broker's policy wait 7000 ms against the
product's 1000 ms, and the broker result did not change. Run 5 was stopped during setup (its namespace was still
terminating from run 4) and has no result.

## NOT proven: the broker's second door

The broker accepted the agent token at its door (a stranger's proof was refused there), and its tool call was then
refused closed with `-32004`, so no tool was forwarded to the MCP upstream. The broker's log shows
`mcp broker: taint gate refused tool call` and `refused an agent token door=mcp_broker why=Token(WrongKey)`, and wardryx's
log shows `agent token proof refused on /v1/decide ... the proof's key is not the token's cnf.jkt` for the broker's decide
call. So the proof the broker relays to wardryx (and to the gateway's tool-call check) does not verify against the token's
bound key in this configuration. The cause was not isolated: it is either the relay in tokenfuse v1.19.0 (the proof it
forwards) or the broker's own key use, and the source was not read for it. This is an open defect on the broker's
path, and it is NOT fixed by this change. The 200 in the table is the HTTP status of a closed refusal, not a forwarded call.

## Not covered by this run

- The rest of the stack: Longhorn, Calico, the console, the policy controller (admission was not re-measured here; the
  verified-images run in `evidence/verified-images-kind/` predates this change).
- A real k3s issuer string and a projected service-account token in a pod (kind's issuer was not read here).
- A ban (`POST /v1/revoke` with `ban:true`) and a vouchryx restart: not run in this change. K2's measurements
  (`evidence/agent-tokens-kind/`) cover them for the previous pin.
- NetworkPolicy enforcement beyond the stand-in rules (kind's CNI was assumed to enforce them, as K2 found).
