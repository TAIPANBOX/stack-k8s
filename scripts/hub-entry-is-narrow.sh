#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 23: manifests/53-hub-entry.yaml exposes exactly
# the seven routes a remote gateway needs and nothing else.
#
# WHY
#
# 53-hub-entry.yaml is the one manifest in this repository whose whole job is
# to publish something on purpose: a customer's second site reaches the hub
# over it, with no VPN (@decided 2026-09-26). Every other gate here proves a
# property that must hold NO MATTER WHAT the manifest says; this one proves
# the opposite kind of thing, that what it says is still narrow, because
# nothing stops a later edit from widening a Caddyfile route, dropping the
# catch-all, or handing the container a capability nobody asked for, and none
# of that would fail any other gate: it would still be valid YAML, still pass
# kubeconform, still keep automountServiceAccountToken false. Only reading the
# route list itself catches a route that grew.
#
# WHAT THIS CHECKS
#
# 1. The Caddyfile embedded in the hub-ingress ConfigMap's `data.Caddyfile`
#    routes exactly: cloud -> POST /v1/ingest, GET /v1/units /v1/budgets
#    /v1/unit-budgets /v1/kills; wardryx -> POST /v1/decide /v1/filter-tools.
#    A route is counted only if some `handle @matcher { reverse_proxy ... }`
#    actually wires the matcher to a backend: a matcher defined but never
#    handled changes nothing a caller can reach, so it is not a subject here.
# 2. Each routed matcher proxies to the right Service (tokenfuse-cloud:8080
#    for cloud's two, wardryx:8090 for wardryx's one).
# 3. Each site block ends in a catch-all `handle { respond 404 }`, and it is
#    the LAST block in the site: Caddy evaluates `handle` blocks in the order
#    written, so a catch-all anywhere else could still be reached by a request
#    the matchers above it did not claim, but stops nothing declared after it.
# 4. The hub-ingress container's capabilities are `drop: [ALL]` plus AT MOST
#    `NET_BIND_SERVICE` in `add`, `runAsNonRoot: true` somewhere in the pod's
#    own securityContext, and `readOnlyRootFilesystem: true` on the container.
# 5. manifests/kustomization.yaml does not list 53-hub-entry.yaml: it stays
#    opt-in, applied only by hub/up.sh, never by the default `apply -k`.
#
# What it does NOT check: automountServiceAccountToken (already every
# manifest's subject, scripts/no-sa-token-by-default.sh), the image pin
# (scripts/pinned-images.sh already globs manifests/*.yaml), and whether the
# Service is actually reachable from anywhere (that needs a live cluster; see
# features/a-site-reaches-the-hub-over-one-narrow-door.feature for what WAS
# measured on one).
#
# HOW, WITHOUT A YAML LIBRARY
#
# The manifest is split into `---`-separated documents the way every other
# gate here does it. The Caddyfile itself is not YAML, so once its block
# scalar is extracted it is parsed with a small brace-matching pass of its
# own: `{$HUB_HOST}` is masked to a single opaque character first so an env
# var placeholder's own braces cannot be mistaken for a block boundary.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

MANIFEST = pathlib.Path("manifests/53-hub-entry.yaml")
KUSTOMIZATION = pathlib.Path("manifests/kustomization.yaml")

errors = []

def measured_nothing(msg):
    print(f"FAIL: {msg}")
    print("This measured nothing about how narrow the hub entry is.")
    sys.exit(1)

if not MANIFEST.exists():
    measured_nothing(f"{MANIFEST} does not exist")

text = MANIFEST.read_text()

# ---- 1. not in the default apply -------------------------------------------
if KUSTOMIZATION.exists():
    ktext = KUSTOMIZATION.read_text()
    m = re.search(r"^resources:\s*$", ktext, re.M)
    resources = []
    if m:
        for line in ktext[m.end():].splitlines():
            if not line.strip():
                continue
            im = re.match(r"^\s*-\s+(\S+)\s*$", line)
            if not im:
                break
            resources.append(im.group(1))
    if MANIFEST.name in resources:
        errors.append(
            f"{MANIFEST} is listed in {KUSTOMIZATION}'s resources: it must "
            "stay opt-in, applied only by hub/up.sh, never by the default "
            "kubectl apply -k")

# ---- split into documents, find the ConfigMap and the Deployment ----------
docs = []
cur = []
for line in text.split("\n"):
    if line.rstrip() == "---":
        docs.append("\n".join(cur))
        cur = []
    else:
        cur.append(line)
docs.append("\n".join(cur))

def doc_matches(d, kind, name):
    return (re.search(rf"^kind:\s*{kind}\s*$", d, re.M) is not None
            and re.search(rf"^\s*name:\s*{name}\s*$", d, re.M) is not None)

configmap_doc = next((d for d in docs if doc_matches(d, "ConfigMap", "hub-ingress")), None)
deployment_doc = next((d for d in docs if doc_matches(d, "Deployment", "hub-ingress")), None)

if configmap_doc is None:
    measured_nothing("no ConfigMap named hub-ingress found in " + str(MANIFEST))

# ---- extract the Caddyfile block scalar ------------------------------------
lines = configmap_doc.split("\n")
caddy_idx = None
caddy_indent = None
for i, line in enumerate(lines):
    s = line.strip()
    if re.match(r"^Caddyfile:\s*\|", s):
        caddy_idx = i
        caddy_indent = len(line) - len(line.lstrip(" "))
        break

if caddy_idx is None:
    measured_nothing("no 'Caddyfile: |' block under the hub-ingress ConfigMap's data")

body = []
base_indent = None
j = caddy_idx + 1
while j < len(lines):
    line = lines[j]
    if line.strip() == "":
        body.append("")
        j += 1
        continue
    indent = len(line) - len(line.lstrip(" "))
    if indent <= caddy_indent:
        break
    if base_indent is None:
        base_indent = indent
    body.append(line[base_indent:] if len(line) >= base_indent else line.lstrip())
    j += 1

caddyfile = "\n".join(body).rstrip()
if not caddyfile.strip():
    measured_nothing("the Caddyfile block under the hub-ingress ConfigMap is empty")

# ---- parse the Caddyfile ----------------------------------------------------
# Mask {$VAR} placeholders so their own braces cannot be mistaken for block
# boundaries by the matcher below.
masked = re.sub(r"\{\$[A-Za-z_][A-Za-z0-9_]*\}", "\x00", caddyfile)

def top_level_blocks(s):
    """Return [(header, content), ...] for every brace-delimited block at
    depth 0 in s, in the order they appear."""
    blocks = []
    depth = 0
    header_start = 0
    content_start = None
    header = ""
    for i, ch in enumerate(s):
        if ch == "{":
            if depth == 0:
                header = s[header_start:i]
                content_start = i + 1
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                blocks.append((header.strip(), s[content_start:i]))
                header_start = i + 1
    return blocks

def strip_comments(s):
    return "\n".join(line.split("#", 1)[0] for line in s.split("\n"))

top = top_level_blocks(masked)
sites = {}
for h, c in top:
    hh = strip_comments(h).strip()
    if hh.startswith("cloud.") or hh.startswith("wardryx."):
        sites[hh] = c

EXPECTED_ROUTES = {
    "cloud": {("POST", "/v1/ingest"), ("GET", "/v1/units"), ("GET", "/v1/budgets"),
              ("GET", "/v1/unit-budgets"), ("GET", "/v1/kills")},
    "wardryx": {("POST", "/v1/decide"), ("POST", "/v1/filter-tools")},
}
EXPECTED_BACKEND = {"cloud": "tokenfuse-cloud:8080", "wardryx": "wardryx:8090"}

for site in ("cloud", "wardryx"):
    matching = [c for h, c in sites.items() if h.startswith(site + ".")]
    if not matching:
        errors.append(f"no '{site}.{{$HUB_HOST}}' site block found in the Caddyfile")
        continue
    content = matching[0]
    inner = top_level_blocks(content)

    matchers = {}
    handles = []
    for header, body_text in inner:
        h = strip_comments(header).strip()
        if h.startswith("@"):
            name = h[1:].strip()
            c = strip_comments(body_text)
            mm = re.search(r"^\s*method\s+(\S+)\s*$", c, re.M)
            pm = re.search(r"^\s*path\s+(.+)$", c, re.M)
            matchers[name] = (mm.group(1) if mm else None,
                               pm.group(1).split() if pm else [])
        elif h == "handle" or h.startswith("handle "):
            handles.append((h, body_text))

    if not handles:
        errors.append(f"{site}: no 'handle' block found at all")
        continue

    routed = set()
    catchall_idx = None
    for idx, (h, body_text) in enumerate(handles):
        c = strip_comments(body_text).strip()
        if h == "handle":
            if c != "respond 404":
                errors.append(f"{site}: the catch-all 'handle {{}}' body is {c!r}, not 'respond 404'")
            catchall_idx = idx
        else:
            mname = h.split("@", 1)[1].strip() if "@" in h else ""
            if mname not in matchers:
                errors.append(f"{site}: 'handle @{mname}' references a matcher that was never defined")
                continue
            rp = re.search(r"^\s*reverse_proxy\s+(\S+)\s*$", c, re.M)
            target = rp.group(1) if rp else None
            method, paths = matchers[mname]
            if target != EXPECTED_BACKEND[site]:
                errors.append(f"{site}: '@{mname}' proxies to {target!r}, expected {EXPECTED_BACKEND[site]!r}")
            for p in paths:
                routed.add((method, p))

    if catchall_idx is None:
        errors.append(f"{site}: no catch-all 'handle {{}}' block, an unlisted path is not guaranteed a 404")
    elif catchall_idx != len(handles) - 1:
        errors.append(f"{site}: the catch-all 'handle {{}}' is not the last block in the site, "
                       "so a route declared after it would never be reached and one declared "
                       "before an earlier catch-all could still leak through")

    missing = EXPECTED_ROUTES[site] - routed
    extra = routed - EXPECTED_ROUTES[site]
    if missing:
        errors.append(f"{site}: missing route(s): {sorted(missing)}")
    if extra:
        errors.append(f"{site}: route(s) beyond the allowed seven: {sorted(extra)}")

# ---- the container's own posture -------------------------------------------
if deployment_doc is None:
    errors.append("no Deployment named hub-ingress found, so its securityContext could not be checked")
else:
    if not re.search(r"runAsNonRoot:\s*true\b", deployment_doc):
        errors.append("no runAsNonRoot: true found on the hub-ingress pod")
    if not re.search(r"readOnlyRootFilesystem:\s*true\b", deployment_doc):
        errors.append("no readOnlyRootFilesystem: true found on the hub-ingress container")

    cap_m = re.search(
        r"capabilities:\s*\{\s*drop:\s*\[([^\]]*)\]\s*,\s*add:\s*\[([^\]]*)\]\s*\}",
        deployment_doc)
    if not cap_m:
        errors.append("no 'capabilities: { drop: [...], add: [...] }' found on the hub-ingress container")
    else:
        drop = [x.strip().strip('"').strip("'") for x in cap_m.group(1).split(",") if x.strip()]
        add = [x.strip().strip('"').strip("'") for x in cap_m.group(2).split(",") if x.strip()]
        if drop != ["ALL"]:
            errors.append(f"capabilities.drop is {drop}, expected exactly ['ALL']")
        if [c for c in add if c != "NET_BIND_SERVICE"]:
            errors.append(f"capabilities.add is {add}, only NET_BIND_SERVICE is allowed")

if errors:
    for e in errors:
        print(f"FAIL: {e}")
    print()
    print(f"{len(errors)} way(s) manifests/53-hub-entry.yaml is wider than the seven routes")
    print("a remote gateway needs. See CLAUDE.md invariant 23.")
    sys.exit(1)

print("OK: manifests/53-hub-entry.yaml routes exactly the seven allowed paths, "
      "each behind a catch-all 404, drop-ALL-plus-NET_BIND_SERVICE only, "
      "and stays out of the default apply.")
PY
