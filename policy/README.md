# Admission policy for the stack's namespace (opt-in, invariant 58)

**Status: blocked for enforcement.** Measured 2026-10-19 on kind (Kubernetes v1.37.0) with
policy-controller v0.15.1: once agent-stack is opted in, the controller refuses every TAIPANBOX image
the manifests name, signed or not. The cause is a signature format the controller does not read; see
"Why it is blocked" below. Until that is resolved,
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

Root cause, measured 2026-10-19 (commands and outputs in `evidence/verified-images-kind/signing-format.txt`):

- The release workflows sign every image with `cosign-release: v3.1.3` and `cosign sign --yes "ghcr.io/taipanbox/<name>@<digest>"`. Eleven image-signing jobs do this (tokenfuse, wardryx, vouchryx, keyryx, costcrew, idryx, heraldyx, scopyx, typryx, trailryx, qryx, agent-stack-go). cosign v3 writes each signature as an OCI referrer, stored at the fallback tag `sha256-<digest>` (an index of sigstore bundles). It writes no `sha256-<digest>.sig` tag, with either value of `--registry-referrers-mode` (tested on a local registry).
- policy-controller v0.15.1, the newest release, reads the legacy `.sig` tag for image signatures. Its `signatureFormat: bundle` option fails with `bundle support for image signatures is not yet implemented` (kind, 2026-10-19).
- cosign v2.4.0 and v2.6.5 write the `.sig` tag, and the controller reads it. A keyless signature in that form, made by a third party, was found and verified on the same kind cluster.
- The signed digests are the index digests the manifests pin. `cosign verify` with v3.1.3 passes for `wardryx:v2.2.0`, `tokenfuse:v1.16.0` and `tokenfuse:v1.17.0`, so the signatures are real and they are not missing.

What would unblock it, either one:

1. Sign with cosign v2 (v2.6.5 is the newest v2 release). That is the `cosign-release:` line of each image job above, in each of the eleven repositories. Images already released stay on the v3 format and need a re-sign from their tags.
2. A policy-controller release that verifies bundle image signatures. None exists yet: v0.15.1 (2026-03-26) is the newest release, and the `unstable` image of main refused the policy with `secret "" not found` (not investigated further).

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
