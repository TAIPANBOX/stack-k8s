#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 30: every stream file this launcher puts on the
# events bus, and every `--load source:path` it hands idryx, is a pair the
# readers will accept.
#
# WHY
#
# The bus is one directory with one NDJSON file per writer, and the readers used
# to believe the `source` field inside each line. heraldyx v0.3.0 and idryx
# v1.1.0 (bus layer 2, BUS-DESIGN 2026-10-04) now refuse an event whose `source`
# is not allowed for the file it was read from: `<source>.ndjson` carries
# `<source>` for the registered sources, `tokenfuse-cloud.ndjson` and
# `tokenfuse-mcp.ndjson` carry `tokenfuse`, and anything else has to be declared
# (`HERALDYX_STREAMS` / `IDRYX_STREAMS`). A file this launcher names differently
# is not a cosmetic difference any more: its events are counted, alerted once as
# `foreign_source`, and dropped. A launcher that renames a stream, or adds a
# plane with its own file, and does not look, ships a notifier that goes quiet
# about that plane, and a quiet notifier reads exactly like a quiet night.
#
# WHAT THIS CHECKS, over manifests/*.yaml and the scripts that write manifests
# (typed/, delegation/, hub/, tunnel/):
#
#   1. every `*.ndjson` path under the bus directory (/var/lib/stack/events) has a
#      stem the readers know: a registered source, one of the two tokenfuse rows,
#      or one this launcher declares itself with HERALDYX_STREAMS. An unknown stem
#      is not silently dropped by the readers (a line claiming its own name is
#      still read) but it is raised, and a stem nobody declared is a typo until
#      proved otherwise;
#   2. every idryx `--load source:path` has a path whose stem may carry `source`,
#      by the table or by an IDRYX_STREAMS declaration. idryx refuses the lines
#      otherwise, and `identity-sweep` would find an empty graph;
#   3. the table below is what heraldyx v0.3.0 and idryx v1.1.0 each carry (they
#      each carry a copy and nothing holds the two equal; this is a third copy, so
#      it is held to them by reading: internal/stream/stream.go in heraldyx,
#      the same table in idryx). It is named here so a launcher change that needs
#      a row is a visible edit.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: a tree where no stream path was found
# measured nothing about the names.
#
# WHAT IT DOES NOT DO. It reads names. That the writer behind a file stamps the
# `source` its file name implies is each producer's own code, held across
# repositories by estate-gates C4's producer table; a writer that names its file
# right and stamps another source is invisible here. The streams a tool writes by
# its own default and this launcher does not configure (qryx, verdryx, engram, the
# console's own) are not listed by any manifest, so they are not subjects.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import pathlib
import re
import subprocess
import sys

BUS = "/var/lib/stack/events"

# heraldyx v0.3.0 internal/stream/stream.go: knownSources + exceptions.
KNOWN = ["agent-conform", "console", "costcrew", "engram", "heraldyx", "idryx",
         "mockryx", "qryx", "scopyx", "tokenfuse", "typryx", "vouchryx", "verdryx",
         "wardryx"]
ALLOWED = {s: {s} for s in KNOWN}
ALLOWED["tokenfuse-cloud"] = {"tokenfuse"}
ALLOWED["tokenfuse-mcp"] = {"tokenfuse"}


def code_of(text):
    return re.sub(r"(?m)^\s*#.*$", "", text)


def declared(var, text):
    """stem -> {sources} from `{ name: VAR, value: "stem=a|b,stem2=c" }`, widening only."""
    out = {}
    for m in re.finditer(r"name:\s*" + var + r"\s*,\s*value:\s*\"([^\"]*)\"", text):
        for entry in m.group(1).split(","):
            if "=" in entry:
                stem, srcs = entry.split("=", 1)
                out.setdefault(stem.strip(), set()).update(s.strip() for s in srcs.split("|") if s.strip())
    return out


files = sorted(pathlib.Path("manifests").glob("*.yaml"))
tracked = subprocess.run(["git", "ls-files", "typed", "delegation", "hub", "tunnel"],
                         capture_output=True, text=True).stdout.split()
files += [pathlib.Path(p) for p in tracked if p.endswith(".sh")]
files = [f for f in files if f.name != "secrets.example.yaml"]
if not files:
    print("FAIL: no manifest or script found, so this measured nothing about the bus file names.")
    sys.exit(1)

texts = {f: code_of(f.read_text()) for f in files}
hdecl, idecl = {}, {}
for t in texts.values():
    for stem, srcs in declared("HERALDYX_STREAMS", t).items():
        hdecl.setdefault(stem, set()).update(srcs)
    for stem, srcs in declared("IDRYX_STREAMS", t).items():
        idecl.setdefault(stem, set()).update(srcs)

problems = []
streams = []   # (file, stem)
for f, t in texts.items():
    for m in re.finditer(re.escape(BUS) + r"/([A-Za-z0-9][A-Za-z0-9._-]*)\.ndjson", t):
        streams.append((f, m.group(1)))

if not streams:
    print(f"FAIL: no *.ndjson path under {BUS} was found in manifests/ or the scripts that write them,")
    print("      so this measured nothing about the bus file names. That is not agreement.")
    sys.exit(1)

seen = set()
for f, stem in streams:
    if (str(f), stem) in seen:
        continue
    seen.add((str(f), stem))
    if stem in ALLOWED or stem in hdecl:
        continue
    problems.append(f"{f}: the stream {stem}.ndjson is named for no source the readers know, and "
                    "HERALDYX_STREAMS does not declare it, so heraldyx raises it as unknown and a "
                    "line claiming any other source is refused")

loads = []
for f, t in texts.items():
    toks = re.findall(r"\"([^\"]*)\"", t)
    for i, tok in enumerate(toks):
        if tok == "--load" and i + 1 < len(toks):
            loads.append((f, toks[i + 1]))
for f, spec in loads:
    m = re.fullmatch(r"([a-z0-9-]+):(/\S+)", spec)
    if not m:
        problems.append(f"{f}: idryx --load {spec!r} is not source:path")
        continue
    source, path = m.groups()
    mm = re.fullmatch(r"(.*/)?([^/]+)\.ndjson", path)
    if not mm:
        problems.append(f"{f}: idryx --load {spec} names no *.ndjson file, so the source rule has no stem to judge")
        continue
    stem = mm.group(2)
    ok = source in ALLOWED.get(stem, set()) or source in idecl.get(stem, set())
    if not ok:
        problems.append(f"{f}: idryx --load {spec}: {stem}.ndjson may carry "
                        f"{sorted(ALLOWED.get(stem, set()) | idecl.get(stem, set())) or '[nothing declared]'}, not "
                        f"{source!r}, so idryx v1.1.0 refuses every line and the graph comes up empty. Rename the "
                        "file or declare it with IDRYX_STREAMS")

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print(f"{len(problems)} bus name(s) the readers would refuse. See CLAUDE.md invariant 30.")
    sys.exit(1)

stems = sorted({s for _, s in streams})
print(f"OK: {len(stems)} stream name(s) on the bus ({', '.join(stems)}), each one the readers accept, and "
      f"{len(loads)} idryx --load pair(s), each a source its file may carry.")
PY
