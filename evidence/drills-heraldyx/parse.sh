#!/usr/bin/env bash
# Feeds this cluster's two copies of mockryx's reaction chain (the ConfigMaps
# drills-scenarios in manifests/40-routines-and-secrets.yaml and
# drills-heraldyx-scenarios in manifests/45-heraldyx.yaml) to the mockryx image
# the CronJobs pin, with no network and no gateway, and shows three things:
# each copy loads; each starts with the watch list its CronJob sets (empty
# files stand in for the logs); and the heraldyx copy is refused with no watch
# list, as mockryx v0.5.0 refuses any scenario that waits for an event.
# With no gateway every step is a Finding, so exit 1 on the first two is the
# expected answer. Run from the repository root on a machine with Docker.
set -euo pipefail
cd "$(dirname "$0")/../.."
img=$(sed -n 's/^ *image: \(ghcr\.io\/taipanbox\/mockryx:v[^ ]*\)$/\1/p' manifests/45-heraldyx.yaml | head -1)
[ -n "$img" ] || { echo "no mockryx image in manifests/45-heraldyx.yaml"; exit 2; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/gateway" "$work/heraldyx" "$work/logs"
: > "$work/logs/wardryx.ndjson"
: > "$work/logs/sent.ndjson"
python3 - "$work" <<'PY'
import re, sys
sys.path.insert(0, "scripts/lib")
import miniyaml
out = sys.argv[1]
for f, cm, key, d in [("manifests/40-routines-and-secrets.yaml", "drills-scenarios", "reaction-chain-reaches-wardryx.yaml", "gateway"),
                      ("manifests/45-heraldyx.yaml", "drills-heraldyx-scenarios", "reaction-chain-reaches-heraldyx.yaml", "heraldyx")]:
    for part in re.split(r"(?m)^---[ \t]*$", open(f).read()):
        if re.search(r"(?m)^kind:\s*ConfigMap\s*$", part) and re.search(r"(?m)^\s+name:\s*" + cm + r"\s*$", part):
            open(f"{out}/{d}/{key}", "w").write(miniyaml.load_all(part)[0]["data"][key])
PY
echo "image: $img"
run() { docker run --rm --network none -v "$work/$1:/s:ro" -v "$work/logs:/w:ro" "${@:2}" "$img" run --gateway http://127.0.0.1:9 /s 2>&1; }
set +e
echo "=== gateway drills' copy, watching wardryx.ndjson"
run gateway -e MOCKRYX_WATCH_EVENTS=/w/wardryx.ndjson; echo "exit=$?"
echo "=== heraldyx drill's copy, watching wardryx.ndjson and sent.ndjson"
run heraldyx -e MOCKRYX_WATCH_EVENTS=/w/wardryx.ndjson,/w/sent.ndjson; echo "exit=$?"
echo "=== heraldyx drill's copy, no watch list (must be refused, exit 2)"
run heraldyx; echo "exit=$?"
