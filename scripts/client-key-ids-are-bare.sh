#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 33: every example of a tokenfuse client key spec
# in this repository splits the way tokenfuse splits it, with a bare name as
# the key id.
#
# WHY
#
# `TOKENFUSE_MCP_KEYS` (the MCP broker's own door) and `TOKENFUSE_CLIENT_KEYS`
# (the gateway's) are both read by tokenfuse's `ClientKeys::from_spec`
# (crates/gateway/src/clientkeys.rs, main.rs:478 and :837 at tokenfuse
# a99a6a7). Each comma-separated entry is split on its LAST colon, because a
# secret may contain colons (`sk-proj:abc:def`): everything before the last
# colon is the secret, everything after it is the key id.
#
# So an agent id used as the key id breaks the entry without breaking the
# start. Until this gate, README.md and manifests/52-tokenfuse-mcp-broker.yaml
# both showed the secret followed by a colon and an `agent://` URI. tokenfuse
# reads that as the secret `<secret>:agent` and the key id `//<domain>/<name>`:
# the pod starts, the spec is "usable", and every caller presenting the secret
# the operator thinks they configured is refused 401. Measured by running
# `ClientKeys::from_spec` itself on the README's string, 2026-10-05.
#
# WHAT THIS CHECKS
#
# Every literal value assigned to either variable in a tracked file, in the
# shapes this repository writes it:
#   NAME=value, NAME='value', NAME="value"   (shell, --from-literal)
#   name: NAME, value: "value"               (YAML flow, one line)
#   - name: NAME / value: "value"            (YAML block, next line)
# Each entry is split exactly as tokenfuse splits it, and the key id must be a
# bare name: letters, digits, `.`, `_`, `-`. `...` is a placeholder and is not
# judged.
#
# Exempt: GOTCHAS.md (the dated ledger names the broken shape on purpose),
# evidence/ (command output from runs), this script and gates-have-teeth.sh
# (both plant the broken shape to prove it is caught).
#
# WHAT IT DOES NOT COVER
#
# A value built from a shell variable (`$X`, `${X}`, `$(...)`) is not judged,
# since its text is not what tokenfuse reads. A secret that itself ends in a
# colon-free word followed by a bare id is indistinguishable from a correct
# entry by text alone. And it reads this repository only: what an operator
# types into their own Secret is theirs.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import subprocess
import sys

NAMES = ("TOKENFUSE_MCP_KEYS", "TOKENFUSE_CLIENT_KEYS")
NAME_RE = "(?:" + "|".join(NAMES) + ")"
EXEMPT = {
    "GOTCHAS.md",
    "scripts/client-key-ids-are-bare.sh",
    "scripts/gates-have-teeth.sh",
}
BARE = re.compile(r"[A-Za-z0-9._-]+")
VALUE = r"""(?:'([^'\n]*)'|"([^"\n]*)"|([^\s'"\\,}]+(?:,[^\s'"\\,}]+)*))"""

SHAPES = [
    # shell or --from-literal: NAME=value
    re.compile(r"\b(" + NAME_RE + r")=" + VALUE),
    # YAML flow, and YAML block where value: follows on the next line
    re.compile(r"name:\s*[\"']?(" + NAME_RE + r")[\"']?\s*(?:,|\n\s*(?:#[^\n]*)?)\s*value:\s*" + VALUE),
]

files = subprocess.run(
    ["git", "ls-files", "-z"], capture_output=True, text=True, check=True
).stdout.split("\0")

problems = []
judged = 0
for path in files:
    if not path or path in EXEMPT or path.startswith("evidence/") or "/evidence/" in path:
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        continue
    if not any(n in text for n in NAMES):
        continue
    for shape in SHAPES:
        for m in shape.finditer(text):
            name = m.group(1)
            value = next(g for g in m.groups()[1:] if g is not None)
            line = text.count("\n", 0, m.start()) + 1
            if "$" in value:
                continue
            judged += 1
            for entry in value.split(","):
                entry = entry.strip()
                if entry in ("", "...", "\u2026"):
                    continue
                secret, colon, key_id = entry.rpartition(":")
                secret, key_id = secret.strip(), key_id.strip()
                if not colon or not secret or not key_id:
                    problems.append(
                        f"{path}:{line}: {name} entry {entry!r} has no `secret:key_id` "
                        "split at all; tokenfuse skips it"
                    )
                elif not BARE.fullmatch(key_id):
                    problems.append(
                        f"{path}:{line}: {name} entry {entry!r} splits on its LAST colon "
                        f"into secret {secret!r} and key id {key_id!r}; the key id must be "
                        "a bare name (letters, digits, . _ -), not an agent:// URI"
                    )

if judged == 0:
    print(
        "FAIL: measured nothing: found no literal TOKENFUSE_MCP_KEYS or "
        "TOKENFUSE_CLIENT_KEYS value in any tracked file to judge. The examples "
        "in README.md and manifests/52-tokenfuse-mcp-broker.yaml are this gate's "
        "subject; if they moved, this gate has to learn the new shape."
    )
    sys.exit(1)

if problems:
    print("FAIL: a client key spec example does not split the way tokenfuse splits it:")
    for p in problems:
        print("  " + p)
    sys.exit(1)

print(f"OK: {judged} client key spec value(s), every key id a bare name.")
PY
