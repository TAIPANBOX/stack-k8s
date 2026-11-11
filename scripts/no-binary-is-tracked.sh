#!/usr/bin/env bash
# Fails when `git ls-files` tracks a compiled executable: an ELF, a Mach-O or a
# Windows PE file, found by the first bytes of the file and not by its name.
#
# WHY
#
# `images/uapi-proxy/uapi-proxy` was a 7.3 MB Mach-O arm64 executable, built on a
# Mac and committed by mistake. Nothing built from it: the Dockerfile compiles its
# own copy from the source beside it. But a tracked binary is a file nobody can
# read, review or reproduce, it rides into every clone of a public repository, and
# it is the shape a supply-chain swap would take. Every other gate here reads text
# or a name, and a name says nothing about what a file is.
#
# WHAT COUNTS
#
#   ELF            7f 45 4c 46
#   Mach-O         cf fa ed fe, ce fa ed fe, fe ed fa cf, fe ed fa ce (thin),
#                  ca fe ba be and ca fe ba bf (a universal binary)
#   PE (Windows)   "MZ" and a "PE\0\0" signature where the header at offset 0x3c
#                  points. A text file that merely begins with MZ is not a PE
#                  file, and the pointer is what tells them apart.
#
# `ca fe ba be` is also the first word of a Java class file; this repository
# tracks none, and one that appeared would be a compiled artifact too.
#
# WHAT THIS CANNOT SEE
#
#   - A script or an archive that carries a binary inside it (a tarball, a zip, a
#     base64 blob): only the first bytes of each file are read.
#   - A binary in a format not listed above (WebAssembly, a Java class with another
#     magic, a raw firmware image).
#   - Untracked files and history: it reads the index, as
#     no-operator-files-tracked.sh does. A binary added and removed inside the
#     commits of one push is gone from the tree this reads.
#
# EXIT CODES: 0 clean, 1 a tracked executable was found, 2 this measured nothing
# (the file list could not be read, or came back empty, or no file could be opened).
#
# DEPENDENCIES: bash, git, python3. Nothing else.
set -euo pipefail

cd "$(dirname "$0")/.."

list="$(mktemp)"
trap 'rm -f "$list"' EXIT

if ! git ls-files -z >"$list" 2>/dev/null; then
	echo "no-binary-is-tracked: measured NOTHING: git ls-files could not be read, so no tracked file was looked at"
	exit 2
fi

python3 - "$list" <<'PY'
import os
import struct
import sys

MAGIC = (
    (b"\x7fELF", "ELF"),
    (b"\xcf\xfa\xed\xfe", "Mach-O"),
    (b"\xce\xfa\xed\xfe", "Mach-O"),
    (b"\xfe\xed\xfa\xcf", "Mach-O"),
    (b"\xfe\xed\xfa\xce", "Mach-O"),
    (b"\xca\xfe\xba\xbe", "Mach-O universal"),
    (b"\xca\xfe\xba\xbf", "Mach-O universal"),
)


def kind_of(path):
    with open(path, "rb") as f:
        head = f.read(64)
        for magic, name in MAGIC:
            if head.startswith(magic):
                return name
        if head.startswith(b"MZ") and len(head) >= 0x40:
            (off,) = struct.unpack("<I", head[0x3C:0x40])
            f.seek(off)
            if f.read(4) == b"PE\x00\x00":
                return "PE"
    return None


with open(sys.argv[1], "rb") as fh:
    paths = [p.decode("utf-8", "surrogateescape") for p in fh.read().split(b"\0") if p]

if not paths:
    print("no-binary-is-tracked: measured NOTHING: git ls-files listed no file")
    sys.exit(2)

opened = 0
found = []
for p in paths:
    if os.path.islink(p) or not os.path.isfile(p):
        continue
    try:
        k = kind_of(p)
    except OSError:
        continue
    opened += 1
    if k:
        found.append((p, k, os.path.getsize(p)))

if opened == 0:
    print("no-binary-is-tracked: measured NOTHING: none of the %d listed files could be opened" % len(paths))
    sys.exit(2)

if found:
    for p, k, size in found:
        print("FAIL: %s is a tracked %s executable (%d bytes). Build it in the Dockerfile or in CI, do not commit it, and add its name to .gitignore." % (p, k, size))
    print("no-binary-is-tracked: %d tracked executable(s) in %d files" % (len(found), opened))
    sys.exit(1)

print("OK: no tracked file is an ELF, Mach-O or PE executable (%d files read)" % opened)
PY
