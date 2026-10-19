# Admission policy for the stack's namespace (opt-in, invariant 58)

**Status: blocked for enforcement.** Measured 2026-10-19 on kind (Kubernetes v1.37.0) with
policy-controller v0.15.1: once agent-stack is opted in, the controller refuses every TAIPANBOX image
the manifests name, signed or not. The reason is in "Why it is blocked" below. Until that is resolved,
`policy/up.sh --enforce` must not be run on a cluster that serves the stack.

## What is here

| File | What it is |
|---|---|
| `policy-controller.yaml` | The Sigstore policy-controller v0.15.1, rendered from its source at tag v0.15.1 (commit `cc75baa`), with its webhook image pinned by digest and `no-match-policy: deny`. |
| `PIN` | The release, its commit, the image digest and the sha256 of the rendered manifest. The gate holds the manifest to that sha256. |
| `image-policy.yaml` | `taipanbox-signed`: keyless, enforce, for `ghcr.io/taipanbox/**`, issuer GitHub Actions, subject the `release.yml` workflow of a TAIPANBOX repository on a version tag. `upstream-pinned`: three upstream images, by digest, each with its reason. |
| `up.sh` | Installs the controller and the policies. With `--enforce`, it also opts `agent-stack` in, last. |
| `down.sh` | Removes the webhooks first, then the policies and the controller. |

No manifest names this directory, so `kubectl apply -k manifests/` does not turn the policy on.

## Why it is blocked

The release workflows of the TAIPANBOX repositories sign each image keyless, and the signature is a
cosign v3 bundle whose Fulcio certificate names the release workflow at its tag. Measured on the
registry (2026-10-19, `ghcr.io/taipanbox/wardryx:v2.1.0`):

- the signature is not at the legacy `sha256-<digest>.sig` tag;
- ghcr answers the OCI referrers API for the digest with `MANIFEST_UNKNOWN`;
- the bundle is only listed in the OCI fallback index at the tag `sha256-<digest>`.

policy-controller v0.15.1 (cosign library v3.0.5) reads the legacy `.sig` tag and the referrers
API; it does not read the fallback index. Setting `enable-oci11` to true changed nothing (tested 2026-10-19). A signed TAIPANBOX image is therefore refused with
`no signatures found`, the same message an unsigned image gets. The same controller on the same kind
cluster does find and verify a legacy keyless signature: cosign v2.4.0 (`ghcr.io/sigstore/cosign`) was
admitted under a test policy that named its signer (`evidence/verified-images-kind/run.sh`, step 5).
So the path to Fulcio, Rekor and TUF works from kind; the gap is discovery.

What would unblock it, any one of:

1. The release workflows of the TAIPANBOX repositories also publish signatures in the legacy `.sig`
   form the controller reads. That is a change in each release workflow, and it needs a test push first.
2. A policy-controller release that reads cosign's bundle fallback index.
3. A registry that supports the OCI referrers API for these images.

Until one of them holds, `policy/up.sh` installs and does not opt anything in.

## The unsigned images the manifests still name

These are refused once the namespace is opted in, even after the discovery gap closes, unless they are
signed too:

- `ghcr.io/taipanbox/genaryx-console:v1.1.46` (manifests 20 and 40, and security-tests.sh). Built by
  `.github/workflows/console-image.yml`, which has no signing step.
- `ghcr.io/taipanbox/mockryx:v0.2.1` (the drills CronJob, suspended). Its repository is not in this
  one; no signature was found on the registry.

## Upstream images, and why each is trusted

| Image | Reason |
|---|---|
| `postgres:16-alpine`, by digest | the policy-db; upstream, not signed by us |
| `caddy`, by digest | the hub's TLS front; upstream, pinned in manifests/53 |
| `busybox`, by digest | the root-key copy in keyryx; a shell-only init container |

The three are matched by their digest, with the tag not part of the match. A new upstream image is
refused until it is pinned by digest and listed with a reason in `image-policy.yaml`.

## Not covered

- `kube-system` (the cloud controllers the AWS and GCP installers apply) and `agent-tunnel` (the
  tunnel). Neither namespace is opted in.
- `stack/*:dev` images from `build.sh`. They have no registry digest and no signature; an opted-in
  namespace refuses them. Build from a registry image or leave the namespace out.

## No internet egress

Keyless verification needs Fulcio's roots and Rekor, reached through the TUF repository. The decision
is to fail closed: an image whose signature cannot be fetched or verified is refused, and nothing is
admitted on trust. `@claude 2026-10-19`: this was not measured with egress blocked. Running pods are not
re-checked; a pod that is created again (a restart, a reschedule) is checked again. An air-gapped
deployment would need a `TrustRoot` with the roots vendored; that is not built.

## Running it

```bash
policy/up.sh             # installs the controller and the policies; agent-stack is not opted in
policy/up.sh --enforce   # also opts agent-stack in; refuses unverified images
policy/down.sh           # removes the admission; running pods are not touched
```

The measurement is `evidence/verified-images-kind/run.sh`, which creates and deletes its own kind
cluster.
