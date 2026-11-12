# The heraldyx drill, 2026-11-12

estate-gates GAPS G3.20 and CLAUDE.md invariant 90: heraldyx's `alert_sent` is only in `sent.ndjson` on
heraldyx's own ReadWriteOnce claim, so the gateway drills could not see it. `drills-heraldyx`
(`manifests/45-heraldyx.yaml`) runs the whole chain beside heraldyx, and the gateway drills run a copy that
stops at wardryx's record (`drills-scenarios`, `manifests/40-routines-and-secrets.yaml`).

- `gate-red-on-0e80406.txt`: `scripts/drills-can-start.sh` from this change, on the manifests of `0e80406`.
  Three problems in `drills`, which waits for heraldyx: it watches no journal of heraldyx's, it lives
  outside `45-heraldyx.yaml`, and it mounts no part of `heraldyx-state`.
- `parse.sh` and `output-parse.txt`: both ConfigMap copies fed to the pinned mockryx image on the build
  machine, with no network and no gateway. Each copy loads and starts with the watch list its CronJob sets
  (every step is then a Finding, because there is no gateway: exit 1), and the heraldyx copy with no watch
  list is refused before a request (exit 2).
