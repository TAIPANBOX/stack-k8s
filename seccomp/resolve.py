#!/usr/bin/env python3
"""Resolve a Docker-format seccomp profile into the form a Kubernetes node reads.

    python3 -I seccomp/resolve.py seccomp/chromium-v1.docker.json > seccomp/chromium-v1.json

WHY A SECOND FILE AND NOT A COPY OF STACK-SINGLE'S

stack-single's `seccomp/chromium-v1.json` is in Docker's format. Docker reads three keys
that are not in the OCI runtime spec and decides them per container, at start: `archMap`
(which architectures the filter covers), and on each rule `includes` and `excludes`
(apply it only with these capabilities, on these architectures, from this kernel). A
Kubernetes node does not run Docker. containerd reads a `Localhost` profile with
`json.Unmarshal` into the runtime spec's `LinuxSeccomp` (`contrib/seccomp/seccomp.go`,
`WithProfile`), and that struct has none of the three, so they are DROPPED WITHOUT A
WORD and every conditional rule becomes unconditional. The rule Docker keeps for a
container holding CAP_SYS_ADMIN (mount, setns, unshare and clone of any namespace, bpf,
umount) would then apply to this container, which holds no capability at all. GOTCHAS 161.

So the node gets the profile Docker would have computed for this container, written out:

  - capabilities: none. The browser container drops ALL and Pod Security `restricted`
    lets it add back only NET_BIND_SERVICE, which no rule here names. A rule that
    `includes` a capability is left out; a rule that `excludes` one is kept.
  - architectures: amd64 and arm64, the two the image is published for, with the
    sub-architectures Docker's `archMap` gives each. One file serves both because a rule
    Docker keeps for one architecture only names a call the other does not have
    (`arch_prctl`, `modify_ldt`; `arm_fadvise64_64`, `set_tls`, ...), and runc skips a
    name the node cannot resolve. A rule for any other architecture is left out.
  - kernel: a rule with `minKernel` is kept. Docker's is 4.8 and no node this repository
    installs runs a kernel that old; the script refuses a floor above 5.0 rather than
    guess.

Everything else is carried as it is: the default action and errno, each rule's names,
action, errno and argument conditions, in the order Docker lists them. The output is
plain JSON, two-space indent, keys in a fixed order, one trailing newline, so the gate
can compare it byte for byte with what this script prints.
"""
import json
import sys

ARCHES = {"amd64": "SCMP_ARCH_X86_64", "arm64": "SCMP_ARCH_AARCH64"}
CAPS = ()  # the container holds none
KERNEL_FLOOR = (5, 0)
RULE_KEYS = {"names", "action", "errnoRet", "args", "comment", "includes", "excludes"}
CONDITION_KEYS = {"arches", "caps", "minKernel"}
TOP_KEYS = {"defaultAction", "defaultErrnoRet", "archMap", "syscalls"}


def die(why):
    sys.stderr.write("resolve.py: " + why + "\n")
    sys.exit(1)


def applies(rule, arch):
    inc = rule.get("includes") or {}
    exc = rule.get("excludes") or {}
    for cond in (inc, exc):
        unknown = set(cond) - CONDITION_KEYS
        if unknown:
            die("a rule for %s carries a condition this script does not know: %s"
                % (rule["names"], sorted(unknown)))
    if exc.get("arches") and arch in exc["arches"]:
        return False
    if inc.get("arches") and arch not in inc["arches"]:
        return False
    if any(c in CAPS for c in exc.get("caps") or []):
        return False
    if inc.get("caps") and not all(c in CAPS for c in inc["caps"]):
        return False
    floor = inc.get("minKernel")
    if floor:
        parts = tuple(int(x) for x in floor.split(".")[:2])
        if parts > KERNEL_FLOOR:
            die("a rule for %s needs kernel %s, above the %d.%d this script may assume"
                % (rule["names"], floor, KERNEL_FLOOR[0], KERNEL_FLOOR[1]))
    return True


def main():
    if len(sys.argv) != 2:
        die("usage: resolve.py <a Docker-format profile>")
    src = json.load(open(sys.argv[1]))
    unknown = set(src) - TOP_KEYS
    if unknown:
        die("the profile carries a top-level key this script does not know: %s" % sorted(unknown))
    arches = []
    for entry in src.get("archMap") or []:
        if entry["architecture"] in ARCHES.values():
            arches.append(entry["architecture"])
            arches.extend(entry.get("subArchitectures") or [])
    if sorted(set(a for a in arches if a in ARCHES.values())) != sorted(ARCHES.values()):
        die("the archMap does not name both amd64 and arm64")
    rules = []
    for rule in src["syscalls"]:
        unknown = set(rule) - RULE_KEYS
        if unknown:
            die("a rule for %s carries a key this script does not know: %s"
                % (rule.get("names"), sorted(unknown)))
        if not any(applies(rule, a) for a in ARCHES):
            continue
        out = {"names": list(rule["names"]), "action": rule["action"]}
        if "errnoRet" in rule:
            out["errnoRet"] = rule["errnoRet"]
        if "args" in rule:
            out["args"] = [dict(a) for a in rule["args"]]
        rules.append(out)
    profile = {
        "defaultAction": src["defaultAction"],
        "defaultErrnoRet": src["defaultErrnoRet"],
        "architectures": arches,
        "syscalls": rules,
    }
    sys.stdout.write(json.dumps(profile, indent=2) + "\n")


main()
