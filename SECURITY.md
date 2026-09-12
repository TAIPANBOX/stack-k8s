# Security Policy

stack-k8s puts the same governed agent stack that `stack-up` and
`stack-single` run elsewhere onto Kubernetes, as manifests, images and
cloud bring-up scripts for Hetzner, AWS and GCP, so its trust boundary is
the cluster and every cloud account a bring-up script touches.

## Reporting a vulnerability

Please report security issues privately, not in public issues or pull
requests: open a GitHub private security advisory at
<https://github.com/TAIPANBOX/stack-k8s/security/advisories/new>. Include
the affected version or commit, a description and a minimal reproduction. We
aim to acknowledge within a few days and to fix high-severity issues before
any public disclosure, with coordinated disclosure within 90 days of the
report. There is no bug-bounty programme; reporters are credited in the
advisory unless they prefer otherwise.

## Supported versions

Before this repository's 1.0, only `main` is supported: fixes land on `main`
and are not backported. From its 1.0 tag, the newest minor gets every fix and
the previous minor gets security-relevant fixes for 90 days after the newer
one is tagged.

## Verifying a build

Every change passes the repository's gates before merge: `scripts/gotchas-classified.sh`,
`scripts/closed-by-default.sh`, `scripts/portability-claims.sh`,
`scripts/pinned-images.sh`, `scripts/manifests-valid.sh`,
`scripts/manifest-is-true.sh`, `scripts/node-name-is-pinned.sh`,
`scripts/deploy-flags-agree.sh`, `scripts/no-sa-token-by-default.sh`,
`scripts/no-operator-files-tracked.sh` and `scripts/gates-have-teeth.sh`.
