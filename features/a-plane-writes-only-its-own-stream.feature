# @decided 2026-11-11, from the estate security review (GAPS G3.16): planes that write the events bus do not
# share a uid, and no plane can create, rename or remove a name in the bus directory, as stack-single already
# holds with a root init. `@claude 2026-11-11`: here an owner uid makes the bus, because Pod Security
# `restricted` allows no root. Scenarios are bound to cases in scripts/gates-have-teeth.sh and to the measured
# run in evidence/bus-per-producer-longhorn/ by name; this repository has no runner and no binding gate, so
# the binding is by eye.
Feature: a plane writes only its own stream, and only the bus owner changes a name on the bus

  Each plane appends to its own stream through a group of its own. The streams sit in `streams/`, which only
  the owner, a uid no plane runs as, may add a name to, rename or remove. Every pod mounts `streams/` and
  never the volume root.

  Scenario: one plane appends to another plane's stream
    Given costcrew and wardryx write the bus
    When a pod in costcrew's identity appends a line to wardryx.ndjson
    Then the append is refused, on Longhorn RWX and on local-path
    # -> evidence/bus-per-producer-longhorn/output-stack-rwx.txt, 2b "append a forged line to wardryx.ndjson"
    # -> security-tests.sh "a plane cannot write another plane's stream"

  Scenario: a plane replaces another plane's stream by renaming it
    Given the gateway writes tokenfuse.ndjson
    When a pod in another plane's identity renames it away or writes a file of its own under the name
    Then both are refused, because only the owner may change a name in streams/
    # -> evidence/bus-per-producer-longhorn/output-stack-rwx.txt, 2b "rename wardryx.ndjson away" and "create a new stream file"
    # -> security-tests.sh "a plane cannot rename a name in the bus"

  Scenario: the layout before this change, for comparison
    Given the planes mounted the volume root, whose mode on Longhorn RWX is 0777
    When a pod as typryx renamed the gateway's stream and a pod as costcrew appended to wardryx.ndjson
    Then both succeeded
    # -> evidence/bus-per-producer-longhorn/output-stack-rwx.txt, section 1 (RED)

  Scenario: two planes are given one uid
    Given each bus writer has a uid of its own
    When typryx is set to run as wardryx's uid
    Then bus-writers-are-separate.sh fails saying the two share a uid
    # -> gates-have-teeth.sh "bus-writers: two planes write the bus as one uid"

  Scenario: a plane is given another producer's group
    Given costcrew appends through group 10003
    When its pod also carries wardryx's group 20001
    Then the gate fails, because costcrew could then append to wardryx.ndjson
    # -> gates-have-teeth.sh "bus-writers: a plane carries another producer's group"

  Scenario: a plane mounts the volume root
    Given every plane mounts streams/ by subPath
    When a writer or a reader mounts the claim's root instead
    Then the gate fails, because a pod holding the root can rename streams/ itself
    # -> gates-have-teeth.sh "bus-writers: a plane mounts the volume root read-write" and "bus-writers: a reader mounts the volume root read only"

  Scenario: a pod starts before the owner has made the bus
    Given kubelet makes a missing subPath itself, as root 0777
    When a pod has no bus-ready init waiting for the owner's marker
    Then the gate fails
    # -> gates-have-teeth.sh "bus-writers: a pod starts without waiting for the owner" and "bus-writers: the wait names no marker"
    # -> evidence/bus-per-producer-longhorn/output-stack-rwx.txt, 2g

  Scenario: the owner opens the bus directory to its group
    Given streams/ is 2750, the owner's alone to write
    When the owner's script makes it 2770
    Then the gate fails
    # -> gates-have-teeth.sh "bus-writers: the owner leaves the bus directory writable to its group"

  Scenario: the owner needs more groups than NFS carries
    Given NFS with AUTH_SYS honours sixteen groups of a process
    When the owner is put in a seventeenth
    Then the gate fails, because its chgrp to the later groups would be refused on Longhorn RWX
    # -> gates-have-teeth.sh "bus-writers: the owner is in more groups than AUTH_SYS carries"
    # -> evidence/bus-per-producer-longhorn/output-stack-rwx.txt, 2h

  Scenario: a writer still opens its stream
    Given the stream belongs to the owner and is in the producer's group
    When wardryx (agent-stack-go v2) and tokenfuse open it
    Then each opens it and appends, though neither owns it
    # -> evidence/bus-per-producer-longhorn/output-stack-rwx.txt, 2f

  Scenario: a producer plants a link where the owner writes a temp file
    Given wardryx may add a version to its archive and the verifier may write conform/
    When wardryx links .copy.tmp in the archive to typryx.ndjson and the owner copies the old layout in
    Then typryx.ndjson stays the owner's, in typryx's group, untouched, because the owner writes only in streams/ and moves with mv -T
    # -> evidence/bus-per-producer-longhorn/output-owner-symlink.txt
    # -> gates-have-teeth.sh "bus-writers: the owner stages a copy where a producer can plant a link" and "bus-writers: the owner moves a file without -T"
