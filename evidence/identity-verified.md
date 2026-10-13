# Client keys and the identity map on a real API server, 2026-10-13

`identity/up.sh` against a kind cluster on one machine's Docker, nothing billed.
`evidence/identity-kind/run.sh` builds the cluster from empty, installs the
namespace, `stack-wiring` and the `tokenfuse-gateway` Deployment and Service as
`manifests/00-base.yaml` and `manifests/10-planes.yaml` declare them, runs nine
steps and deletes the cluster. **46 passed, 0 failed, twice in a row from empty**
(5 min 24 s and 5 min 40 s).

```sh
./evidence/identity-kind/run.sh           # KEEP=1 leaves the cluster up
```

What differs from a real install, and why:

- The gateway's `events` volume is an emptyDir: kind's storage has no
  ReadWriteMany class, and the installers bring Longhorn for that.
- `stack-keys` holds throwaway values, and nothing else of the stack runs: no
  control plane, no wardryx, no Calico. A call that passes the identity door is
  then refused by the gateway's own fail-closed wardryx hook, which is what the
  run reports for it.
- A stand-in named `genaryx-console` (`python:3.12-slim`, sleeping) is the pod
  `verify.sh` asks the planes from. Only `verify.sh`'s "client keys and the
  identity map" section is read.

| What | Version |
|---|---|
| gateway image | `ghcr.io/taipanbox/tokenfuse:v1.11.0`, index `sha256:ce983204dcb603bead1d45b56ed2f6aee5e1db02416757c3f60f100eaa7fc605`, arm64 |
| cluster | kind v0.33.0, node `kindest/node@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5`, Kubernetes v1.37.0 |
| kubectl | v1.36.1 |
| stand-in | `python@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1` |

## What the nine steps showed, both runs

1. **No file given.** The gateway starts with both references optional and
   absent, its log has neither `client auth: ON` nor `identity map: ON`, the map
   directory holds no file, and `verify.sh` notes both off.
2. **Keys and a map given.** The gateway rolled once. Secret
   `gateway-client-keys` exists with no annotation, so no last-applied copy of
   the keys. The pod template carries the map's sha256 and the Secret's
   resourceVersion. The new pod reported `client auth: ON (2 key(s))` and
   `identity map: ON (2 unit(s), 2 key binding(s))`; the mounted map is the file
   given, byte for byte, alone in a read-only directory, and
   `TOKENFUSE_IDENTITY_MAP` came from the ConfigMap. `verify.sh`: a call with no
   key and one with an unknown key both `401` with `x-fuse: unauthorized`. A
   treasury key speaking as a research agent: `403 identity_mismatch`
   (`agent_id_not_allowed`). The same key as its own agent passed the identity
   door and met the absent wardryx (`403`, fail closed). The script printed no
   key.
3. **A re-run naming no file.** Nothing rolled; neither object's
   resourceVersion moved.
4. **The same map again, then `kubectl apply` of the same manifests.** Nothing
   rolled, nothing was written, and the apply kept both annotations and both
   objects (GOTCHAS 113's mechanism, used on purpose).
5. **A new map.** The gateway rolled once; the new pod reads the new map.
6. **A new keys file, three keys.** The gateway rolled once; the new pod reported
   3 keys; the new key passed the door.
7. **A refused keys file** (a key the map does not bind): refused by the gateway
   image's own warning, nothing written, nothing rolled, no key printed.
8. **The map edited by another hand** (`kubectl patch` of the ConfigMap). The
   running pod's file became the edited map after 29 s and 48 s (31 s on an
   earlier run), in the same pod, with no restart: GOTCHAS 124. `verify.sh` then
   failed with "the gateway was started on another identity map than ConfigMap
   gateway-identity-map holds". A re-run of `up.sh` with no file let the image
   read the edited map and rolled the gateway onto it, and `verify.sh` agreed
   again.
9. **Turned off** by deleting both objects and running `up.sh` with no file. The
   gateway rolled and reads neither; a call with no key passed client auth and
   stopped at the next door, `400 identity_required` (policy enforcement wants an
   agent id); `verify.sh` notes both off.

## Found by this run and fixed before it passed

- The harness's own first pod lookup used a jsonpath filter with `!`, which
  kubectl refuses, and so judged an empty pod name: the first check passed on
  nothing. It now picks the pod in python and fails on an empty log.
- The kubelet keeps `..data` and a timestamped directory in an empty
  ConfigMap volume, so "the directory is empty" is asked with `ls`, not `ls -A`.

## Not proven here

- The whole stack: Calico enforcing the NetworkPolicies, Longhorn, wardryx
  answering, the real console, Felyx refused 401 (named in the README, not run).
- A unit refused at its monthly cap.
- A cloud cluster, and `identity/up.sh` against a real API server from Linux
  (it ran on macOS with bash 3.2; the gate runs its logic on Linux in CI, against
  a stub `kubectl`).
- A remote Docker daemon (`DOCKER_HOST`, a remote context). The check container
  bind-mounts a directory on this machine, which a remote daemon does not see:
  the gateway then finds no map and `up.sh` refuses with its words, so it fails
  closed, but it cannot be used that way.
