# identity/mint.sh on kind, from empty, twice

`@measured ./evidence/identity-kind/mint.sh` 2026-10-17, twice, each from an empty kind cluster
(kind v0.33.0 on Docker Desktop, macOS, arm64), tokenfuse `ghcr.io/taipanbox/tokenfuse:v1.14.0` as
`manifests/10-planes.yaml` pins it, the gateway Deployment and Service cut from that file, the
console's Felyx lines from `manifests/20-console.yaml` on a python stand-in. No wardryx and no
control plane run (the harness blanks `TOKENFUSE_CLOUD_URL`, see its comment), so a call that gets
past identity is refused by the policy hook failing closed (`403 wardryx_denied`). No key is printed;
the harness checks that none is. CLAUDE.md invariant 50. Not on a real k3s cluster, not over ssh.

## Run 1

```
PASS  with no gateway-client-keys the gateway waits in CreateContainerConfigError, it does not start open
PASS  identity/mint.sh minted on an empty cluster
PASS  the agents' key file is 0600
PASS  the Secret holds <felyx>:felyx,<agents>:agents, the file the agents' key, felyx-client-key Felyx's
PASS  the Secret is labelled minted
PASS  identity/mint.sh printed no key
PASS  identity/mint.sh named the key file and the agents' ids
PASS  the gateway rolled out on the minted keys
PASS  the gateway reports client auth ON with 2 keys
PASS  the gateway reads the minted map, 2 units, 2 bindings, strict=Enforce
PASS  no unbound key and no orphan binding
PASS  the console stand-in holds Felyx's minted key, from felyx-client-key
      no key: 401 unauthorized | agents' key as an agent: 403 wardryx_denied | agents' key as Felyx: 403 identity_mismatch | Felyx's key as Felyx: 403 wardryx_denied | Felyx's key as an agent: 403 identity_mismatch
PASS  a call with no key is refused 401
PASS  the agents' key speaking as an agent gets past identity (403 wardryx_denied)
PASS  the agents' key speaking as Felyx is refused 403 identity_mismatch
PASS  Felyx's key speaking as Felyx gets past identity (403 wardryx_denied)
PASS  Felyx's key speaking as an agent is refused 403 identity_mismatch
PASS  a re-run changed no object and rolled neither Deployment
PASS  a re-run kept the agents' key file byte for byte
      client keys and the identity map
        ok   the gateway runs the identity map ConfigMap gateway-identity-map holds
        ok   the gateway runs the client keys Secret gateway-client-keys holds
        nokey 401 unauthorized
        badkey 401 unauthorized
        ok   the gateway refuses a call with no client key (401)
        ok   the gateway refuses a call with an unknown client key (401)
      
      the console is reading a real environment, not fixtures
PASS  verify.sh's client keys section passes

20 passed, 0 failed
```

## Run 2

```
PASS  with no gateway-client-keys the gateway waits in CreateContainerConfigError, it does not start open
PASS  identity/mint.sh minted on an empty cluster
PASS  the agents' key file is 0600
PASS  the Secret holds <felyx>:felyx,<agents>:agents, the file the agents' key, felyx-client-key Felyx's
PASS  the Secret is labelled minted
PASS  identity/mint.sh printed no key
PASS  identity/mint.sh named the key file and the agents' ids
PASS  the gateway rolled out on the minted keys
PASS  the gateway reports client auth ON with 2 keys
PASS  the gateway reads the minted map, 2 units, 2 bindings, strict=Enforce
PASS  no unbound key and no orphan binding
PASS  the console stand-in holds Felyx's minted key, from felyx-client-key
      no key: 401 unauthorized | agents' key as an agent: 403 wardryx_denied | agents' key as Felyx: 403 identity_mismatch | Felyx's key as Felyx: 403 wardryx_denied | Felyx's key as an agent: 403 identity_mismatch
PASS  a call with no key is refused 401
PASS  the agents' key speaking as an agent gets past identity (403 wardryx_denied)
PASS  the agents' key speaking as Felyx is refused 403 identity_mismatch
PASS  Felyx's key speaking as Felyx gets past identity (403 wardryx_denied)
PASS  Felyx's key speaking as an agent is refused 403 identity_mismatch
PASS  a re-run changed no object and rolled neither Deployment
PASS  a re-run kept the agents' key file byte for byte
      client keys and the identity map
        ok   the gateway runs the identity map ConfigMap gateway-identity-map holds
        ok   the gateway runs the client keys Secret gateway-client-keys holds
        nokey 401 unauthorized
        badkey 401 unauthorized
        ok   the gateway refuses a call with no client key (401)
        ok   the gateway refuses a call with an unknown client key (401)
      
      the console is reading a real environment, not fixtures
PASS  verify.sh's client keys section passes

20 passed, 0 failed
```
