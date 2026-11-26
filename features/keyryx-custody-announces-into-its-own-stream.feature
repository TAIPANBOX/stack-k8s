# @decided 2026-11-23 (paraphrased): rotation and revocation of Keyryx keys are a CLI over custody's unix
# socket only, with no network admin key; the console shows that state read only. keyryx v0.2.0 announces
# every change on the bus, in custody's own stream (CLAUDE.md invariant 97). Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name; scripts/features-are-bound.sh holds the binding.
Feature: Keyryx custody announces every key change into its own stream, and heraldyx reads it

  A key change nobody hears of looks exactly like a quiet night. keyryx v0.2.0 writes its announcements
  only into a file its own uid owns, and every file in the bus belongs to the bus owner, so the stream
  lives in custody/ beside the bus.

  Scenario: custody is told where to announce
    Given keyryx v0.2.0 refuses to start without KEYRYX_EVENTS
    When the custody manifest loses KEYRYX_EVENTS, or moves it inside KEYRYX_DATA
    Then keyryx-custody-announces.sh fails
    # -> gates-have-teeth.sh "custody-announces: custody loses KEYRYX_EVENTS"
    # -> gates-have-teeth.sh "custody-announces: the stream is moved inside KEYRYX_DATA"

  Scenario: custody writes custody/, in the bus group, after the owner made it
    Given the bus owner makes custody/ 20000:20101 0771 and custody makes its file in group 10001
    When custody mounts custody/ read only, runs in its own group, or starts before custody/ exists
    Then keyryx-custody-announces.sh fails
    # -> gates-have-teeth.sh "custody-announces: custody mounts custody/ read only"
    # -> gates-have-teeth.sh "custody-announces: custody runs in its own group again"
    # -> gates-have-teeth.sh "custody-announces: custody's bus-ready waits for the marker alone"

  Scenario: no network admin key exists
    Given keyryx v0.2.0 refuses to start with KEYRYX_ADMIN_KEYS set
    When a manifest or a script sets KEYRYX_ADMIN_KEYS
    Then keyryx-custody-announces.sh fails
    # -> gates-have-teeth.sh "custody-announces: a manifest sets KEYRYX_ADMIN_KEYS"
    # -> gates-have-teeth.sh "custody-announces: a script exports KEYRYX_ADMIN_KEYS"

  Scenario: heraldyx reads custody's stream, and turning Keyryx off takes it away
    Given heraldyx v0.10.0 reads keyryx-custody.ndjson as source keyryx
    When the patch stops naming the file, or the unpatch leaves the mount behind
    Then keyryx-custody-announces.sh fails
    # -> gates-have-teeth.sh "custody-announces: heraldyx stops reading custody's stream"
    # -> gates-have-teeth.sh "custody-announces: the unpatch leaves heraldyx's custody mount"

  Scenario: the operator is shown how to rotate and revoke
    Given the admin socket is reached only from inside custody's container
    When the README stops showing the kubectl exec command for one of them
    Then keyryx-custody-announces.sh fails
    # -> gates-have-teeth.sh "custody-announces: the README stops showing how to revoke"

  Scenario: the directory beside the bus is custody's alone
    Given only custody writes custody/
    When the owner stops making it or leaves custody's group, another pod mounts it, or custody carries a producer's group
    Then bus-writers-are-separate.sh fails
    # -> gates-have-teeth.sh "bus-writers: the owner stops making custody/"
    # -> gates-have-teeth.sh "bus-writers: the owner leaves custody's group"
    # -> gates-have-teeth.sh "bus-writers: the witness mounts custody/"
    # -> gates-have-teeth.sh "bus-writers: custody carries a producer's group"

  Scenario: custody cannot write what the witness reads
    Given the witness reads streams/
    When custody mounts streams/ instead of custody/
    Then witness-is-separate.sh fails
    # -> gates-have-teeth.sh "witness-is-separate: custody mounts the bus the witness reads"

  Scenario: the stream exists before custody starts, under a name heraldyx knows
    Given custody's init makes keyryx-custody.ndjson, and heraldyx v0.10.0 knows the stem
    When the init is gone, the name changes, or heraldyx goes back to v0.9.1
    Then stream-files-are-precreated.sh or bus-names-match-the-source-rule.sh fails
    # -> gates-have-teeth.sh "stream-files-are-precreated: custody's stream is not made before custody starts"
    # -> gates-have-teeth.sh "bus-names: heraldyx reads custody's stream under a name it does not know"
    # -> gates-have-teeth.sh "bus-names: heraldyx goes back before it reads custody's stream"

  Scenario: the stream works on a cluster
    Given k3s with Pod Security restricted, the bus owner and keyryx v0.2.0 as the manifests apply them
    When an operator rotates and revokes a key with kubectl exec, and heraldyx reads the file
    Then both lines are in the file, another plane cannot touch it, and heraldyx mails the revocation
    # -> evidence/keyryx-custody-k3s/output.txt
