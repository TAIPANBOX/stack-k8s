# Admission policy for the stack's namespace (opt-in, invariant 58)

**Status: opt-in, and it admits no TAIPANBOX image today.** Measured 2026-10-19 on kind (Kubernetes v1.37.0)
with policy-controller v0.15.1: once agent-stack is opted in, the controller refuses every TAIPANBOX image
the manifests name, signed or not, because none of them has a signature in the format the controller reads.
Do not run `policy/up.sh --enforce` on a cluster that serves the stack until the section "What it admits
today" shows the images you run.

## What is here

| File | What it is |
|---|---|
| `policy-controller.yaml` | The Sigstore policy-controller v0.15.1, rendered from its source at tag v0.15.1 (commit `cc75baa`), with its webhook image pinned by digest and `no-match-policy: deny`. |
| `PIN` | The release, its commit, the image digest and the sha256 of the rendered manifest. The gate holds the manifest to that sha256. |
| `image-policy.yaml` | `taipanbox-signed`: keyless, enforce, for `ghcr.io/taipanbox/**`, issuer GitHub Actions, subject either the `release.yml` workflow of a TAIPANBOX repository on a version tag, or stack-k8s's own `console-image.yml` and `tunnel-images.yml` on a version tag (the three images the stack builds itself). `upstream-pinned`: three upstream images, by digest, each with its reason. |
| `up.sh` | Installs the controller and the policies. With `--enforce`, it also opts `agent-stack` in, last. |
| `down.sh` | Removes the webhooks first, then the policies and the controller. |

No manifest names this directory, so `kubectl apply -k manifests/` does not turn the policy on.

## Why it is blocked

Root cause, measured 2026-10-19 (commands and outputs in `evidence/verified-images-kind/signing-format.txt`):

- The release workflows sign every image with cosign v3.1.3, `cosign sign --yes "ghcr.io/taipanbox/<name>@<digest>"`:
  twelve TAIPANBOX repositories (tokenfuse, wardryx, vouchryx, keyryx, costcrew,
  idryx, heraldyx, scopyx, typryx, trailryx, qryx, agent-stack-go), and stack-k8s's `console-image.yml` and
  `tunnel-images.yml`. cosign v3 writes each signature as a bundle at the OCI fallback tag `sha256-<digest>`,
  with no `sha256-<digest>.sig` tag.
- policy-controller v0.15.1, the newest release, reads only the legacy `.sig` tag for image signatures. Its
  `signatureFormat: bundle` option fails with `bundle support for image signatures is not yet implemented`.
- cosign v2.4.0, v2.6.5, and cosign v3.1.3 with `--new-bundle-format=false --use-signing-config=false` write the
  `.sig` tag. The controller reads it: a key-signed image with the legacy flags was admitted on kind.
- The signed digests are the index digests the manifests pin, and `cosign verify` with v3.1.3 passes on them.

## The decision

`@decided 2026-10-19` (paraphrased): image signatures are written in the legacy format, so the admission
policy can read them, and the bundle format stays until the controller reads it. The flags are deprecated in
cosign v3 but still accepted; source and read date are in the evidence file.

- stack-k8s: `console-image.yml` and `tunnel-images.yml` sign with the two flags, with a comment to remove
  them when the controller reads bundles (upstream PR sigstore/policy-controller#1968).
- The twelve TAIPANBOX repositories listed above: the same two flags on their image sign lines. Each one is a change in its own repository; it is not made here.
- Images already released keep the bundle format. They become admissible only after a signing run with the
  flags, from their release tag: the next release, or a re-sign run.

Until those land, the policy is not turned on for a running stack.

## What it admits today

Measured 2026-10-19 with a `.sig` probe on every pinned TAIPANBOX digest in the manifests: none has a `.sig`
tag. So:

- **TAIPANBOX images: none.** That includes `genaryx-console` v1.1.47, `stack-caddy` and `stack-wg` v1.1.47,
  and every other pinned version. Each is refused once the namespace is opted in, until it is signed in the
  legacy format.
- **Upstream images: three**, admitted by digest only (postgres, caddy, busybox, the table below).
- **`mockryx` v0.2.1** (suspended drills CronJob): unsigned, refused.

Opt-in `policy/up.sh` installs the controller and the policies, and admits nothing new until
`policy/up.sh --enforce` is run.

## Images the manifests name, and their signing

- `genaryx-console` v1.1.47, signed by stack-k8s's `console-image.yml`, in the bundle format: no `.sig` tag.
- `mockryx` v0.2.1, from its own repository (not this one): no signature found on the registry.
- `stack-caddy` and `stack-wg` v1.1.47 are not named by any manifest; the tunnel builds them locally as
  `stack/*:dev` (see "Not covered").

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
