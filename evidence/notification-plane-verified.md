# The notification plane, on two clouds, 2026-08-02 into 2026-08-03

Command output from live clusters, not claims about them. Raw runs are in
`../cloud/aws/evidence/notification-plane-2026-08-02.txt` and
`../cloud/gcp/evidence/notification-plane-2026-08-02.txt`.

Both clusters were destroyed after this was written. What a run proves is
bounded by what it did, and that is stated here rather than rounded up.

## What was actually established

| Claim | Where | How |
|---|---|---|
| An alert leaves the cluster and reaches a real mailbox | AWS, 5 nodes | Gmail submission on 587 through the egress NetworkPolicy; the recipient pasted the message back |
| Two recipients on one alert | AWS | `HERALDYX_TO` split on commas, one dispatch record naming both |
| The alert carries the fleet around it and who is answerable | AWS | passports ConfigMap mounted read-only, owner read from `owner` alone |
| The events a detector raises reach the notifier | AWS | real spend driven through the control plane's own API, its own detectors fired |
| The published image runs the stack | both | `ghcr.io/TAIPANBOX/heraldyx:v0.2.2`, pulled by the kubelet, amd64 |
| The notifier keeps its place across restarts | AWS | three restarts, digest counters unmoved |
| The egress policy admits mail and nothing else | AWS | twelve directions probed, ten as designed, two documented |

## What was NOT established, and should not be read into the above

- **Deliverability.** ONE message, from THIS cluster, through THAT provider,
  reached ONE inbox. Volume, reputation, corporate filters and a second sender
  address are all untested.
- **arm64.** The image is published for both architectures and was run on
  amd64 only.
- **The console on GCP.** That cluster ran without one: its deploy script
  predated the fix that made the console build unconditional, so its final run
  reports two failures, both the console's absence. Recorded rather than
  smoothed over.
- **Long-running behaviour.** The longest either cluster ran is about five
  hours.

## The defects this run found

Ten before the notification plane was wired, ten after, recorded per finding in
the execution journal outside this repository. The four that a customer would
have hit first:

1. Nothing was configured to write the shared event log on Kubernetes, so the
   notification plane had no input at all and stayed silent, correctly and
   uselessly.
2. The notifier's state volume was not writable by it, so read offsets and
   dedup counters could not survive a restart.
3. The notifier re-read the whole event log on every restart and re-sent every
   alert older than the dedup window, because a poll that resolved no files
   erased the persisted positions.
4. A shared volume answered `Remote I/O error` for its own mount point while
   listing the files inside it, and a single `stat` was deciding whether there
   was anything to read.

Each one is now held by a check that fails on the defect, and each of those
checks was run against the broken state before being trusted.
