# Admission policy for the stack's namespace (invariant 58)

**Status: on in the default install.** `deploy.sh` runs `policy/up.sh --enforce` after it applies the manifests, so
the stack's namespace admits an image only when its signature verifies for its own repository. Measured on kind
(Kubernetes v1.37.0) with policy-controller v0.15.1 for stack-k8s v1.2.0: every digest the manifests pin is admitted,
an unsigned image and a bundle-only signature are refused, and a TAIPANBOX image signed only by another repository's
identity is refused. Run: `evidence/verified-images-kind/admission-v120.sh`, output beside it. The cloud deploy
scripts (`cloud/gcp/deploy-gcp.sh`, `cloud/aws/deploy-aws.sh`) run `policy/up.sh --enforce` on their first node after
the apply, the same step `deploy.sh` runs, so all three default installs are admitted (invariant 58).

## What is here

| File | What it is |
|---|---|
| `policy-controller.yaml` | The Sigstore policy-controller v0.15.1, rendered from its source at tag v0.15.1 (commit `cc75baa`), with its webhook image pinned by digest and `no-match-policy: deny`. |
| `PIN` | The release, its commit, the image digest and the sha256 of the rendered manifest. The gate holds the manifest to that sha256. |
| `image-policy.yaml` | One `ClusterImagePolicy` per TAIPANBOX repository (fifteen), and `upstream-pinned`. Each TAIPANBOX policy names the image names of one repository, digest-anchored (`name@sha256:*`), and one keyless identity: that repository's `release.yml` on a version tag, or for stack-k8s, `console-image.yml` (the console) or `tunnel-images.yml` (the tunnel images). `upstream-pinned`: three upstream images, by digest, each with its reason. |
| `up.sh` | Installs the controller and the policies, in that order, and waits for the webhook. With `--enforce`, it also opts `agent-stack` in, last. `KUBECTL` names the client (deploy.sh sets it to k3s's kubectl on the node). |
| `down.sh` | Removes the webhooks first, then the policies and the controller. |
| `operator-image-policy.example.yaml` | The template for your own agent images, tracked, all comments. See "Your own agent images". |
| `operator-image-policy.yaml` | Your copy of the template, with your entries. Gitignored: it is yours, not the repository's. When it exists and holds an entry, `up.sh` applies it. |

No manifest names this directory. The default install runs `up.sh --enforce` from `deploy.sh`, not from `kubectl apply -k`.

## Why one policy per repository

The first version named one identity for every TAIPANBOX image: the `release.yml` of any TAIPANBOX repository. A
signature made by one repository's workflow then admitted another repository's image name. GOTCHAS 138 has the
measurement. Now an image is admitted only on the signature of its own repository's workflow, and the gate
(`scripts/verified-images-are-enforced.sh`) holds a table of image name to repository and workflow, requires every
TAIPANBOX image the tracked files name to have a row, and fails a policy whose identity accepts another row's identity.

The controller matches a glob against the image as `name@sha256:digest`: the tag is not part of the match. The
manifests write `name:tag@sha256:digest`, and the probes in the kind run use those strings, so they match.

## The signing format

The release workflows sign every image with cosign v3.1.3, `cosign sign --yes`. The controller v0.15.1 reads only
the legacy `sha256-<digest>.sig` tag for image signatures, not the OCI bundle that cosign v3 writes by default, and
its `signatureFormat: bundle` option fails with `bundle support for image signatures is not yet implemented`.
So the signing steps write the legacy format: cosign v3.1.3 with `--new-bundle-format=false --use-signing-config=false`
(the flags are deprecated in cosign v3 and still accepted). stack-k8s's `console-image.yml` and `tunnel-images.yml`
do this, and so do the TAIPANBOX repositories' image sign lines. Images released before that carry only the bundle,
and the controller refuses them: a re-sign run from the release tag, or the next release, makes them admissible.
`@decided 2026-10-19` (paraphrased): the legacy format is written until the controller reads bundles, and the
bundle format stays otherwise. Upstream issue sigstore/policy-controller#1968.

## What it admits today

Measured 2026-10-19 by `evidence/verified-images-kind/admission-v120.sh` on the v1.2.0 pins, with the default
install's call (`policy/up.sh --enforce`):

- **Every digest `manifests/` and `keyryx/manifests/` pin: admitted** (19 of 19 distinct references, the three
  upstream digests included). The probes are the manifests' own `name:tag@sha256:digest` strings.
- **Unsigned** genaryx-console v1.1.46 (`sha256:54218cfb...`): refused.
- **Bundle format only** genaryx-console v1.1.47 (`sha256:0f688de1...`): refused.
- **Unlisted upstream** `alpine:3.20`: refused (no matching policy).
- **Another repository's identity**: with the policy for `mockryx` replaced for the test by one that names
  tokenfuse's release, the mockryx digest (signed by mockryx's release) is refused; with mockryx's own policy back,
  it is admitted. Same image, same signature, only the identity differs.
- **After `policy/down.sh`**: the unsigned image is admitted, so the refusals above were the policy's doing.

The identities were checked with cosign v3.1.3 for all sixteen TAIPANBOX digests the tracked files pin, each
against its repository's own `release.yml` (or the stack-k8s workflows) on a version tag:
`evidence/verified-images-kind/identity-per-repo-v120.txt`.

Upstream images are trusted only by digest, and only where listed with a reason:

| Image | Reason |
|---|---|
| `postgres:16-alpine`, by digest | the policy-db; upstream, not signed by us |
| `caddy`, by digest | the hub's TLS front; upstream, pinned in manifests/53 |
| `busybox`, by digest | the init containers that copy keys and create streams; a shell-only image |

A new upstream image is refused until it is pinned by digest and listed with a reason in `image-policy.yaml`.

## Your own agent images

With admission on, an image that no policy covers is refused, and an agent's image is not a TAIPANBOX image. An
agent pod (one that carries `taipanbox.dev/agent-token: "true"`, see `agent-tokens/example-agent.yaml`) is refused
until its image is listed. To list it:

```bash
cp policy/operator-image-policy.example.yaml policy/operator-image-policy.yaml
# add one ClusterImagePolicy per image above the end marker, then:
policy/up.sh --enforce   # or the deploy, which runs it
```

Each entry is one of three forms, and the template has all three:

- **static**: the image is trusted by its digest alone. The glob names one exact digest:
  `registry.example.com/acme/agent@sha256:<64 hex digits>`.
- **keyless**: the image is signed by a workflow, and the entry names that workflow. The subject expression is
  anchored and names one repository, on a version tag.
- **key**: the image is signed with a key, and the entry carries the public key (PEM). Never the private key.

The gate (`scripts/verified-images-are-enforced.sh`, section 8) holds every entry to four rules, and refuses the
entry, not the deploy:

1. a glob names an image by digest; a wildcard name (`*`) is refused, and so is a digest wildcard under `static`;
2. a `static` entry names one exact digest per glob;
3. a signed entry names its signer, and a subject expression that accepts a stranger's repository, a branch or any
   identity is refused (the gate tries it on probe identities);
4. no entry covers `ghcr.io/taipanbox/`. TAIPANBOX images go through their repository's row in
   `image-policy.yaml`, which the gate keeps separately.

Measured on kind (`evidence/verified-images-kind/admission-operator-v120.sh`): an agent pod whose image is not listed
is refused; the same image, listed as a `static` entry in the copy, is admitted. The keyless and key forms are checked
by the gate's teeth cases, not measured on a cluster.

## Running it

```bash
policy/up.sh             # installs the controller and the policies; agent-stack is not opted in
policy/up.sh --enforce   # also opts agent-stack in; an unsigned or foreign-signed image is refused
policy/down.sh           # removes the admission; running pods are not touched
```

The default install does the `--enforce` step itself, after the manifests are applied, because the namespace must exist
first. The controller's webhook must answer before the label is set: `up.sh` waits for its rollout, and a namespace
labelled before that refuses every pod create in it.

## Not covered

- **Keyless and key operator entries on a cluster.** The gate checks their rules; the kind run measured the `static` form only.
- **The cloud deploy scripts, on a real cloud.** `cloud/gcp/deploy-gcp.sh` and `cloud/aws/deploy-aws.sh` run
  `policy/up.sh --enforce` after the apply (the step is in both, the gate holds the order). Not run on a cloud node:
  the step's first run on a GCP or AWS k3s node is the one to check, and a cluster deployed by an older release of
  those scripts is not admitted until `policy/up.sh --enforce` is run on it by hand.
- **Egress.** Keyless verification needs Fulcio's roots and Rekor, reached through Sigstore's TUF repository. The
  decision is to fail closed: an image whose signature cannot be fetched or verified is refused. Measured with egress
  open only. A cluster that cannot reach Sigstore refuses every new pod in the namespace. An air-gapped deployment
  would need a `TrustRoot` with the roots vendored; that is not built.
- **Running pods.** A pod already running is not re-checked. A pod that is created again (a restart, a reschedule, a
  rollout) is checked again, so a rollout that changes an image is judged on the new image.
- **The tunnel images.** `stack-caddy` and `stack-wg` have a policy (signed by `tunnel-images.yml`), but no v1.2.0
  manifest names them. The tunnel builds them locally as `stack/*:dev`, which have no registry digest and no signature,
  so an opted-in namespace refuses them. Build from a registry image or keep the tunnel out of `agent-stack`.
- **The controller's availability.** The webhook is on the path of every pod create in the namespace. Its outage stops
  new pods there; `down.sh` is the way out, and it is not run by anything automatically.
- **`kube-system`** (the cloud controllers the AWS and GCP installers apply) and `agent-tunnel`. Neither is opted in.
