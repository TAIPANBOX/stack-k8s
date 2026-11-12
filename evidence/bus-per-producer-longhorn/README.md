# The events bus on the launcher's own storage, 2026-11-11

GAPS G3.16 and CLAUDE.md invariant 89, measured on a cluster with the storage class the launchers install
(`stack-rwx`, Longhorn RWX) and, beside it, k3s's own `local-path`.

## The stand

One QEMU/KVM guest on the build machine: Ubuntu 24.04 cloud image (sha256 checked against Canonical's
`SHA256SUMS`), 3 vCPU, 9 GiB, user-mode networking only, so no bridge, route or firewall rule of the host
was touched. Inside it, single-node:

```sh
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION=v1.36.2+k3s1 sh -s - server --write-kubeconfig-mode 0644 --secrets-encryption
curl -fsSLo longhorn.yaml https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml
echo '4fe30e43f0557d3242f3ac6011fc7badf1ec6107fc9ca1299f488ca7c9a57b00  longhorn.yaml' | sha256sum -c - && kubectl apply -f longhorn.yaml
```

then `stack-rwx` and `stack-policy` as `install.sh` writes them, with one replica each (one node). The k3s
and Longhorn versions are the launcher's pins (`install.sh`, `lib/verified-fetch.sh`).

## What ran

- `run.sh`, twice: `SC=stack-rwx` (output `output-stack-rwx.txt`) and `SC=local-path ACCESS=ReadWriteOnce`
  (output `output-local-path.txt`). Section 1 is the shape before this change, section 2 the layout it builds,
  with the owner's script cut out of `manifests/11-bus.yaml` itself.
- `gate-red-on-34f669e.txt`: `scripts/bus-writers-are-separate.sh` on the tree before the change, 60 problems.
- `owner-symlink.sh` (output `output-owner-symlink.txt`): a link planted by a producer where the owner writes a
  temp file, against the first owner script (`03868f9`) and the fixed one. `gate-red-on-03868f9-owner.txt`: the
  gate's owner rules on that first script.
- `deploy-full-run.txt`: `deploy.sh --skip-install --skip-images` against the guest (root ssh on a local
  port), from this branch's manifests, three times over the same cluster, each ending with `verify.sh` and
  `security-tests.sh`; the file holds the third. The cluster's two Secrets that `install.sh` makes
  (`stack-keys`, `stack-policy-db`) were made by hand with `lib/secret-doc.sh`, the way `install.sh` makes
  them, because install was skipped; the first run timed out waiting for them and the second named an SMTP
  host without a port.

## What it showed

- The root of a Longhorn RWX volume is `root:root 0777`, and the CSIDriver says
  `fsGroupPolicy: ReadWriteOnceWithFSType`, so kubelet applies no `fsGroup` there. On `local-path` the root
  is `2777` in the `fsGroup`.
- Before: a pod as costcrew appended a forged `policy_allow` to `wardryx.ndjson`; a pod as typryx renamed
  `tokenfuse.ndjson` (uid 10001) away, wrote its own under the name and removed the original.
- After: each producer appends to its own stream through its group; another producer's append, truncate,
  create, rename, remove, hard link and chmod are refused, and so is a reader's write with the mount
  read-write; a pod outside the bus group cannot list the bus; a read-only root mount cannot rename
  `streams/`. wardryx v2.6.1 (agent-stack-go v2.0.2) appended a decision to a stream it does not own and
  archived a policy version; tokenfuse-cloud v1.24.0 opened its stream. The owner's second run on the
  same volume changed nothing.
- kubelet makes a subPath that does not exist yet itself, as `root 0777`, for a read-only mount too.
- The first owner script followed a link wardryx planted in its archive as `.copy.tmp` and wrote the old policy
  into `typryx.ndjson`; the fixed one stages in `streams/` and moves with `mv -T`, and both streams stay
  `20000:<producer> 0664` and empty.
- NFS with AUTH_SYS: a process in 21 groups had its chgrp honoured for its primary group and the first 15
  supplementary ones, and refused for the rest. On `local-path` all 20 were honoured.
- The whole stack from this branch came up on Longhorn RWX: every plane started under its new uid, the
  owner made the bus before any plane started, and `security-tests.sh` 11c refused costcrew's identity on
  `wardryx.ndjson`.
