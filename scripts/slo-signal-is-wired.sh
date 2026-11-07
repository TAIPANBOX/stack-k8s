#!/usr/bin/env bash
#
# Enforces invariant 82 of CLAUDE.md: an agent whose error budget is spent is held
# for a person, on a cluster where nobody chose anything.
#
# WHAT THIS IS ABOUT
#
# wardryx 2.5.0 can hold an agent while verdryx says its budget is spent, and for
# two releases nothing here set the variable that reads the file, ran anything that
# wrote it, or carried a rule that read the signal. Each half was true on its own,
# so every check was green. Four things have to hold together, and any one gone
# leaves a cluster whose `/readyz` says ok and which never holds anybody:
#
#   A. the writer: `verdryx-slo` is a container of the gateway's pod, because the
#      traces are that pod's emptyDir. It runs the console's image with the
#      entrypoint replaced, the same pin the console runs, under a uid nothing else
#      runs as, reads the traces read only, and sets holds apart;
#   B. the file: the writer's path and wardryx's are one key of stack-wiring, so the
#      two cannot name different files;
#   C. the reader: wardryx is handed that key and mounts the volume;
#   D. the rule: the starter policy holds on slo_burn, with no when_absent, because a
#      file that cannot be believed must hold nobody.
#
# WHAT THIS DOES NOT SEE
#
# Whether the pinned image can read a trace: that is pyarrow in the image, and
# .github/workflows/console-image.yml runs the import where the image is built.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# A missing manifest, or no such container: each fails.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import sys

M0, M10, M20 = "manifests/00-base.yaml", "manifests/10-planes.yaml", "manifests/20-console.yaml"
for f in (M0, M10, M20):
    if not os.path.isfile(f):
        print(f"FAIL: {f} is not there, so this measured NOTHING.")
        sys.exit(1)
base, planes, console = (open(f).read() for f in (M0, M10, M20))


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


planes_code = code(planes)
start = planes_code.find("        - name: verdryx-slo\n")
if start < 0:
    print(f"FAIL: {M10} has no verdryx-slo container, so this measured NOTHING.")
    sys.exit(1)
end = planes_code.find("\n      volumes:\n", start)
side = planes_code[start:end]

gateway_start = planes_code.find("  name: tokenfuse-gateway\n")
wardryx_start = planes_code.find("  name: wardryx\n")
bad = []
if not gateway_start < start < wardryx_start:
    bad.append("verdryx-slo: it is not a container of the gateway's pod, and nothing else can read that pod's traces")

wants = {
    'command: ["/bin/sh", "-c"]': "it does not replace the console image's entrypoint, which refuses a shell as an argument",
    "--holds-spend-no-budget": "a hold would spend the budget that caused it, and a working agent could never earn it back",
    "--window": "it names no window",
    ': >>"$VERDRYX_EVENTS_PATH"': "it does not make the file at start, so a healthy cluster reports unreadable until its first spent budget",
    "name: VERDRYX_EVENTS_PATH": "it is not told where to write",
    "key: WARDRYX_SIGNAL_EVENTS": "its path is not the key wardryx reads, so the two can name different files",
    "{ name: traces, mountPath: /var/lib/stack/traces, readOnly: true }": "it can write the traces it reads",
    "{ name: events, mountPath: /var/lib/stack/events }": "it cannot reach the events volume",
    "readOnlyRootFilesystem: true": "its root is writable",
    "allowPrivilegeEscalation: false": "it can gain privileges",
    "runAsGroup: 10001": "it is not in the stack group, so it cannot create on the volume",
}
for want, why in wants.items():
    if want not in side:
        bad.append(f"verdryx-slo: {why} (no `{want}`)")
if "|| true" in side:
    bad.append("verdryx-slo: a failed measurement is swallowed, and a routine that cannot measure then looks like a fleet with nothing to report")

m = re.search(r"runAsUser: (\d+)", side)
uid = m.group(1) if m else None
if not m:
    bad.append("verdryx-slo: it names no runAsUser, so the file is not its alone")
else:
    others = 0
    for name in sorted(os.listdir("manifests")):
        if name.endswith(".yaml"):
            text = code(open(os.path.join("manifests", name)).read())
            others += len(re.findall(rf"runAsUser: {uid}\b", text))
    if others != 1:
        bad.append(f"verdryx-slo: uid {uid} is named {others} times in manifests/, so the file is not the routine's alone")

img = re.search(r"image: (ghcr\.io/taipanbox/genaryx-console:\S+)", side)
console_img = re.search(r"image: (ghcr\.io/taipanbox/genaryx-console:\S+)", code(console))
if not img or not console_img:
    bad.append("verdryx-slo: the console image is not pinned here or on the console, so nothing says they match")
elif img.group(1) != console_img.group(1):
    bad.append(f"verdryx-slo: it runs {img.group(1)} and the console runs {console_img.group(1)}")

if 'WARDRYX_SIGNAL_EVENTS: "/var/lib/stack/events/verdryx.ndjson"' not in base:
    bad.append("stack-wiring: WARDRYX_SIGNAL_EVENTS does not name verdryx.ndjson on the events volume")

ward = planes_code[wardryx_start:]
ward = ward[: ward.find("\n---\n")]
if "- name: WARDRYX_SIGNAL_EVENTS" not in ward or "key: WARDRYX_SIGNAL_EVENTS" not in ward:
    bad.append("wardryx: it is not handed WARDRYX_SIGNAL_EVENTS, so nothing reads the budget")
if "{ name: events, mountPath: /var/lib/stack/events }" not in ward:
    bad.append("wardryx: it does not mount the events volume, so it cannot read the file")

rule = re.search(r"- name: slo-burn-hold\n((?: {6}.*\n)+)", code(base))
if not rule:
    bad.append("wardryx-policy: the starter policy carries no slo-burn-hold rule, so the signal is recorded and holds nobody")
else:
    body = rule.group(1)
    for want, why in {
        'target: "agent://*"': "it does not cover every agent",
        "name: slo_burn": "it reads no slo_burn signal",
        "values: [exhausted, fast_burn]": "it does not hold on exhausted and fast_burn",
        "min_probability: 1": "it names no probability, and wardryx does nothing with a rule that has none",
    }.items():
        if want not in body:
            bad.append(f"slo-burn-hold: {why}")
    if "when_absent" in body:
        bad.append("slo-burn-hold: it sets when_absent, and a broken file would then hold every tool call on the cluster")

for b in bad:
    print("FAIL: " + b)
if bad:
    sys.exit(1)
print("OK: the writer, the file, the reader and the rule are wired, and the writer runs the console's pin under a uid of its own")
PY
