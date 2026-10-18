#!/usr/bin/env bash
#
# Enforces invariant 51 of CLAUDE.md: tokenfuse's MCP broker refuses a raw secret in
# tool arguments, refuses a tool listing its scanner flags, and asks the policy plane
# about every tool call, failing closed when it cannot.
#
# WHAT THIS IS ABOUT
#
# The broker (the typed plane's door, manifests/52-tokenfuse-mcp-broker.yaml) ran
# tokenfuse's own defaults, three of which are weak for a door holding a vault of
# real credentials (finding F-009 of the 2026-10-17 review): TOKENFUSE_MCP_DLP unset
# is shadow, which forwards a raw secret it found in tool arguments; TOKENFUSE_MCP_SCAN
# unset is warn, which passes a tool listing its scanner flags; and it had no wardryx
# hook unless the typed risk signal was on, so a tool the policy denied was called.
# @decided 2026-10-17 (paraphrased): close the review's findings, defaults first.
# stack-single made the same change (its invariant 36).
#
# WHAT THIS CHECKS
#
#   A. THE MANIFEST AND EVERY RENDER. The broker container in 52, and in every
#      typed render typed/mode.sh makes (stub, jev, own-model, each with and without
#      --typed-risk-signal): TOKENFUSE_MCP_DLP block, TOKENFUSE_MCP_SCAN block,
#      TOKENFUSE_WARDRYX_MODE enforce, TOKENFUSE_WARDRYX_FAILMODE closed,
#      TOKENFUSE_WARDRYX_KEY from stack-keys/wardryx_gateway and not optional, and
#      TOKENFUSE_WARDRYX_URL wardryx itself without the risk signal and typryx's
#      proxy with it. 52 carries the egress rule to wardryx on 8090, and wardryx
#      admits the broker's plane on 8090 (30-network-policy.yaml).
#   B. THE IMAGE 52 pins, run with the four switches 52 sets, no network, its policy
#      plane and upstream pointed at nothing: a tools/call carrying a raw AWS key id
#      is refused -32002 before anything is forwarded, and a harmless one -32004
#      with failmode=Closed, because the policy plane could not answer.
#
# WHAT IT DOES NOT CHECK
#
# TOKENFUSE_MCP_LOCK (pinning tool definitions) needs a lock file somebody approved
# and is not set, by decision. The scan's block mode is held by A only: B has no
# upstream that serves a poisoned listing.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No broker container, no render, no Docker, or an image that never answered: each
# is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }
scratch="$(mktemp -d)"
ctr=""
trap 'rm -rf "$scratch"; [ -z "$ctr" ] || docker rm -f "$ctr" >/dev/null 2>&1' EXIT

M52=manifests/52-tokenfuse-mcp-broker.yaml
if [ ! -f "$M52" ]; then
  echo "FAIL: $M52 is missing, so this measured NOTHING about the MCP broker. Silence here is not health."
  exit 1
fi
cp "$M52" "$scratch/r-52.yaml"
n=0
for v in "--with-typed" "--typed-mode jev --typed-jev-key-file $scratch/jev" "--typed-mode own-model --typed-model-url http://ollama.invalid:11434/v1 --typed-model-name m"; do
  for r in "" "--typed-risk-signal"; do
    n=$((n + 1))
    printf 'gate-not-a-key\n' >"$scratch/jev"
    # shellcheck disable=SC2086  # each variant is a list of flags on purpose
    if ! ./typed/mode.sh render $v $r >"$scratch/r-$n.yaml" 2>"$scratch/r-$n.err"; then
      fail "typed/mode.sh render $v $r failed: $(head -1 "$scratch/r-$n.err")"
    fi
    printf '%s\n' "$r" >"$scratch/r-$n.risk"
  done
done

# ---- A. the manifest and every render -----------------------------------------------
python3 - "$scratch" <<'PY' || problems=$((problems + 1))
import glob, os, re, sys

scratch = sys.argv[1]

def broker_env(text):
    """The env entries of the container that runs the tokenfuse image as mcp-broker."""
    for doc in re.split(r"(?m)^---\s*$", text):
        if not re.search(r"(?m)^\s*args:\s*\[\s*\"?mcp-broker\"?\s*\]", doc):
            continue
        if not re.search(r"(?m)^\s*image:\s*ghcr\.io/taipanbox/tokenfuse:", doc):
            continue
        lines = [l for l in doc.split("\n") if l.strip() and not l.strip().startswith("#")]
        env, cur = {}, None
        for l in lines:
            m = re.match(r"^\s*- \{\s*name:\s*([A-Z_]+)\s*,\s*value:\s*\"?([^\"}]*)\"?\s*\}", l)
            if m:
                env[m.group(1)] = ("value", m.group(2).strip())
                cur = None
                continue
            m = re.match(r"^\s*- name:\s*([A-Z_]+)\s*$", l)
            if m:
                cur = m.group(1)
                continue
            if cur and "valueFrom" in l:
                env[cur] = ("from", l.strip())
                cur = None
        return env
    return None

files = sorted(glob.glob(os.path.join(scratch, "r-*.yaml")))
bad = []
for f in files:
    risk = os.path.exists(f[:-5] + ".risk") and open(f[:-5] + ".risk").read().strip() != ""
    label = "manifests/52" if f.endswith("r-52.yaml") else "render " + os.path.basename(f) + (" with the risk signal" if risk else "")
    e = broker_env(open(f).read())
    if e is None:
        bad.append(f"{label}: no container runs the tokenfuse image as mcp-broker")
        continue
    def val(k):
        v = e.get(k)
        return v[1] if v and v[0] == "value" else None
    for k, want, why in [
        ("TOKENFUSE_MCP_DLP", "block", "tokenfuse reads it unset as shadow, which forwards a raw secret it found in tool arguments"),
        ("TOKENFUSE_MCP_SCAN", "block", "tokenfuse reads it unset as warn, which passes a tool listing its scanner flags"),
        ("TOKENFUSE_WARDRYX_MODE", "enforce", "tokenfuse reads it unset as off, so a tool the policy denies is called anyway"),
        ("TOKENFUSE_WARDRYX_FAILMODE", "closed", "tokenfuse reads it unset as open, which turns an unreachable policy plane into permission"),
    ]:
        if val(k) != want:
            bad.append(f"{label}: the broker sets {k} {val(k)!r}, not {want}: {why}.")
    url = val("TOKENFUSE_WARDRYX_URL")
    want_url = "http://typryx-wardryx-proxy:4330" if risk else "http://wardryx:8090"
    if url != want_url:
        bad.append(f"{label}: the broker asks {url!r}, not {want_url}" + (": with the risk signal it asks through the proxy." if risk else ": without the risk signal it asks wardryx itself, and tokenfuse turns the hook off with no URL."))
    key = e.get("TOKENFUSE_WARDRYX_KEY")
    if not key or key[0] != "from" or not re.search(r"name:\s*stack-keys\s*,\s*key:\s*wardryx_gateway", key[1]) or "optional: true" in key[1]:
        bad.append(f"{label}: the broker does not read TOKENFUSE_WARDRYX_KEY from stack-keys/wardryx_gateway, required: the pep key every installer mints.")

text = open(os.path.join(scratch, "r-52.yaml")).read()
ok_egress = False
for doc in re.split(r"(?m)^---\s*$", text):
    if re.search(r"(?m)^kind:\s*NetworkPolicy", doc) and re.search(r"podSelector:\s*\{\s*matchLabels:\s*\{\s*app:\s*tokenfuse-mcp-broker\s*\}\s*\}", doc) \
            and re.search(r"policyTypes:\s*\[\s*\"Egress\"\s*\]", doc) and re.search(r"app:\s*wardryx\b", doc) and re.search(r"port:\s*8090\b", doc):
        ok_egress = True
if not ok_egress:
    bad.append("manifests/52: no NetworkPolicy lets the broker out to wardryx on 8090, so under default-deny every tool call fails closed")
np = open("manifests/30-network-policy.yaml").read()
m = re.search(r"(?ms)name:\s*planes-ingress\b(.*?)(?=^---|\Z)", np)
if not m or not re.search(r"plane:\s*money", m.group(1)) or not re.search(r"port:\s*8090\b", m.group(1)):
    bad.append("manifests/30-network-policy.yaml: planes-ingress no longer admits plane: money on 8090, so wardryx does not let the broker in")
if not re.search(r"(?m)^\s*labels:\s*\{[^}]*plane:\s*money", text):
    bad.append("manifests/52: the broker pod is not labelled plane: money, the plane wardryx admits")
if len(files) < 2:
    bad.append("no render to judge, so this measured NOTHING about the broker a typed deploy applies")
for b in bad:
    print("FAIL: " + b)
if bad:
    sys.exit(1)
print(f"broker: {len(files)} manifest and render(s) block raw secrets and flagged listings, ask wardryx (or the proxy with the risk signal) and fail closed")
PY

# ---- B. the image 52 pins -------------------------------------------------------------
img="$(sed -n 's/^ *image: \(ghcr\.io\/taipanbox\/tokenfuse:[^ ]*\)$/\1/p' "$M52" | head -n 1)"
if [ -z "$img" ]; then
  fail "$M52 names no ghcr.io/taipanbox/tokenfuse image, so the broker's behaviour could not be measured"
elif ! docker version >/dev/null 2>&1; then
  fail "no Docker here, so the broker image could not be run. This gate does not pass on a box that cannot run it."
elif ! docker image inspect "$img" >/dev/null 2>&1 && ! docker pull -q "$img" >/dev/null 2>&1; then
  fail "could not pull $img, so the broker's behaviour could not be measured"
else
  eargs=()
  for k in TOKENFUSE_MCP_DLP TOKENFUSE_MCP_SCAN TOKENFUSE_WARDRYX_MODE TOKENFUSE_WARDRYX_FAILMODE; do
    v="$(sed -n "s/^ *- { name: $k, value: \"\([^\"]*\)\" }\$/\1/p" "$M52" | head -n 1)"
    [ -z "$v" ] || eargs+=(-e "$k=$v")
  done
  ctr="stack-k8s-gate-broker-$$"
  docker rm -f "$ctr" >/dev/null 2>&1 || true
  if ! docker run -d --name "$ctr" --network none \
      -e TOKENFUSE_MCP_ADDR=127.0.0.1:4200 \
      -e TOKENFUSE_MCP_UPSTREAMS=typryx=http://127.0.0.1:9/mcp \
      -e TOKENFUSE_WARDRYX_URL=http://127.0.0.1:9 \
      -e TOKENFUSE_WARDRYX_KEY=gate-not-a-key \
      -e TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS=500 \
      ${eargs[@]+"${eargs[@]}"} "$img" mcp-broker >/dev/null 2>"$scratch/run.err"; then
    fail "behaviour: $img never answered as the broker: it would not start ($(head -1 "$scratch/run.err" | cut -c1-160))"
  else
    up=0
    for _ in $(seq 1 60); do
      if docker logs "$ctr" 2>&1 | grep -q 'credential-broker listening'; then up=1; break; fi
      [ "$(docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null)" = true ] || break
      sleep 0.25
    done
    if [ "$up" != 1 ]; then
      fail "behaviour: $img never answered as the broker (no 'credential-broker listening' line), so nothing showed that the broker blocks anything. Its last words: $(docker logs "$ctr" 2>&1 | tail -1 | cut -c1-160)"
    else
      call() { # BODY: the broker's answer to one tools/call, over bash's /dev/tcp
        docker exec -e BODY="$1" "$ctr" bash -c '
          exec 3<>/dev/tcp/127.0.0.1/4200 || exit 9
          printf "POST /mcp HTTP/1.0\r\nHost: broker\r\nContent-Type: application/json\r\nX-Fuse-Mcp-Upstream: typryx\r\nx-fuse-agent-id: agent://gate.invalid/probe\r\nContent-Length: %d\r\n\r\n%s" "${#BODY}" "$BODY" >&3
          cat <&3' 2>&1
      }
      # AWS's own documented example key id: a secret's shape, and nobody's secret.
      raw="$(call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask","arguments":{"note":"AKIAIOSFODNN7EXAMPLE"}}}')"
      grep -q '"code":-32002' <<<"$raw" \
        || fail "behaviour: a tools/call carrying a raw AWS key id was not refused -32002 by $img with 52's switches; it answered: $(tail -1 <<<"$raw" | cut -c1-200)"
      calm="$(call '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask","arguments":{"note":"hello"}}}')"
      grep -q '"code":-32004' <<<"$calm" && grep -q 'failmode=Closed' <<<"$calm" \
        || fail "behaviour: with the policy plane unreachable, a harmless tools/call was not refused closed by $img; it answered: $(tail -1 <<<"$calm" | cut -c1-200)"
    fi
  fi
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 51."
  exit 1
fi
echo "OK: the MCP broker blocks raw secrets in tool arguments and flagged tool listings, asks wardryx about every"
echo "    tool call (through the proxy with the risk signal) and fails closed, in 52, in every typed render and in"
echo "    the image 52 pins."
