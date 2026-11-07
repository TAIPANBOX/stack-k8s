# Runs INSIDE the console's pod, read from stdin by `python3 -` (CLAUDE.md invariant 83). That pod
# has WARDRYX_ADMIN_KEY from the Secret stack-keys and reaches wardryx, so the key stays in the
# cluster and is on no command line. tool-hold/agents.sh and lib/tool-hold.sh are its callers.
#
#   python3 - store              the store, one JSON array, as a policy file reads it
#   python3 - grants             the grants in the store: agent, tools, name, tab-separated
#   python3 - allow <base64>     {"agent","tools","why","static","sources"}
#   python3 - deny  <base64>     {"agent","tools","why"}
#
# Exit 0 is done, and 1 is a sentence on stderr with nothing changed.
import base64
import datetime
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

URL = os.environ.get("TOOL_HOLD_WARDRYX_URL", "http://wardryx:8090")
KEY = os.environ.get("WARDRYX_ADMIN_KEY", "")


def stop(text):
    sys.stderr.write(text + "\n")
    sys.exit(1)


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    headers = {"Authorization": "Bearer " + KEY}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(URL + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=10) as answer:
            return answer.status, answer.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode("utf-8", "replace")
    except OSError as err:
        stop("wardryx did not answer: %s. Nothing was changed." % err)


def stored():
    status, text = call("GET", "/v1/policies")
    if status != 200:
        stop("wardryx did not list its store: HTTP %s %s" % (status, text[:300]))
    return json.loads(text or "[]") or []


def policy_id(agent):
    """The id of an agent's one policy in the store, which no two agents share."""
    slug = re.sub(r"[^A-Za-z0-9._-]", "-", agent[len("agent://"):] if agent.startswith("agent://") else agent)
    return "grant-%s-%s" % (slug, hashlib.sha256(agent.encode()).hexdigest()[:8])


def put(agent, tools, sources, why):
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    body = {"name": "grant %s %s: %s" % (agent, today, why), "target": agent, "grant_tool": tools}
    if sources:
        body["require_identity_source"] = sources
    body["deny_if_chain_unproven"] = True
    status, text = call("PUT", "/v1/policies/" + policy_id(agent), body)
    if status == 200:
        return
    if "grant_tool" in text:
        stop("wardryx refused the grant, and it is older than 2.6.0 or the target names no trust domain. It said: %s. "
             "To move the cluster first: TOOL_HOLD=0 and run the launcher. Nothing was changed." % text[:300])
    stop("wardryx did not take the grant: HTTP %s %s. Nothing was changed." % (status, text[:300]))


def allow(req):
    agent, tools, sources = req["agent"], req["tools"], req["sources"]
    status, text = call("GET", "/v1/policies/" + policy_id(agent))
    kept = []
    if status == 200:
        held = json.loads(text)
        kept = held.get("grant_tool") or []
        # A grant that took a static key keeps taking one: this command adds tools, and takes nothing away.
        if "client-key" in (held.get("require_identity_source") or []) and "client-key" not in sources:
            sources = ["agent-token", "client-key", "none"]
    elif status != 404:
        stop("wardryx did not answer about this agent: HTTP %s. Nothing was changed." % status)
    if tools == ["all"] or kept == ["*"]:
        tools = ["*"]
    else:
        tools = sorted(set(kept) | set(tools))
    put(agent, tools, sources, req["why"])
    print(",".join(tools))


def deny(req):
    agent, tools = req["agent"], req["tools"]
    status, text = call("GET", "/v1/policies/" + policy_id(agent))
    if status == 404:
        stop("agents.sh agent-allow wrote no grant for %s. A grant in the ConfigMap is written by the launcher. Nothing was changed." % agent)
    if status != 200:
        stop("wardryx did not answer about this agent: HTTP %s. Nothing was changed." % status)
    held = json.loads(text)
    kept = held.get("grant_tool") or []
    left = []
    if tools != ["all"]:
        if kept == ["*"]:
            stop("%s holds every tool, so one cannot be taken out: agent-deny '%s' all, then agent-allow what it needs. Nothing was changed." % (agent, agent))
        for one in tools:
            if one not in kept:
                stop("%s has no grant of %s through agent-allow. Nothing was changed." % (agent, one))
        left = [one for one in kept if one not in tools]
    if left:
        put(agent, left, held.get("require_identity_source") or [], req["why"])
        return
    status, text = call("DELETE", "/v1/policies/" + policy_id(agent))
    if status != 204:
        stop("wardryx did not take the grant away: HTTP %s %s" % (status, text[:300]))


def main():
    verb = sys.argv[1] if len(sys.argv) > 1 else ""
    if not KEY:
        stop("this pod holds no WARDRYX_ADMIN_KEY, so wardryx cannot be asked. Nothing was changed.")
    if verb == "store":
        rows = [{k: v for k, v in row.items() if k not in ("id", "updated_at")} for row in stored()]
        print(json.dumps(rows, separators=(",", ":")))
    elif verb == "grants":
        for row in stored():
            if row.get("grant_tool"):
                print("%s\t%s\t%s" % (row.get("target", ""), ",".join(row["grant_tool"]), row.get("name", "")))
    elif verb in ("allow", "deny"):
        req = json.loads(base64.b64decode(sys.argv[2]))
        (allow if verb == "allow" else deny)(req)
    else:
        stop("wardryx.py does not read %r" % verb)


main()
