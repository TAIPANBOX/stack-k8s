# @decided 2026-10-20 (paraphrased): the Keyryx witness's findings reach the console and
# the notifier by giving those readers read-only access to the witness's own findings
# file; the witness is never given write access to the bus it witnesses. Each scenario is
# bound to a teeth case in scripts/gates-have-teeth.sh by its name, checked by hand.

Feature: The Keyryx witness's findings reach the console and heraldyx, read only

  The witness notices when a stream on the bus was rewritten after it was seen. If it
  could write the bus, a compromised witness could add lines to the record it vouches
  for. So its findings are a file of their own, keyryx.ndjson, on a claim of their own,
  keyryx-alerts, and the console and heraldyx mount that claim read only.

  Scenario: The witness writes its findings onto the bus
    Given the witness writes keyryx.ndjson on the claim keyryx-alerts
    When its findings file is moved under the bus directory it reads
    Then the gate fails, because the witness would write the bus it witnesses
    # @teeth: keyryx-alerts: the witness writes its findings onto the bus

  Scenario: The witness mounts the bus read-write
    Given the witness mounts stack-events read only
    When the mount loses readOnly
    Then the gate fails and names stack-events
    # @teeth: keyryx-alerts: the witness mounts the bus read-write

  Scenario: The witness's bus volume is read only on the claim as well
    Given the witness's volume of stack-events is readOnly on the claim and on the mount
    When the claim's readOnly is dropped
    Then the gate fails, because a mount of that volume added later could write the bus

    # @teeth: keyryx-alerts: the witness's bus volume is not read only on the claim

  Scenario: A reader is handed the findings directory instead of the file
    Given heraldyx and the console each name keyryx.ndjson itself
    When either is handed the directory that holds it
    Then the gate fails, because a reader handed a directory reads any stream file in it
    # @teeth: keyryx-alerts: heraldyx is handed the findings directory, not the file
    # @teeth: keyryx-alerts: the console is handed the findings directory, not the file

  Scenario: A reader is handed the findings directory beside the file
    Given heraldyx names keyryx.ndjson itself
    When its setting also names the directory that holds it
    Then the gate fails, because that entry reads anything else put beside the file
    # @teeth: keyryx-alerts: heraldyx is handed the findings directory beside the file
    # @teeth: keyryx-alerts: heraldyx is handed the findings directory behind a double slash

  Scenario: Only another container of a reader is in the bus group
    Given heraldyx's container reads the findings through the pod's supplementalGroups 10001
    When that group is dropped and only its init container runs in group 10001
    Then the gate fails, because the container that reads the file cannot
    # @teeth: keyryx-alerts: only an init container of heraldyx is in the bus group

  Scenario: The findings go back to the witness's own state claim
    Given the witness's state claim is ReadWriteOnce and holds its log and keys
    When its findings file is put back on that claim
    Then the gate fails, because no reader on another node could mount it, and none should see the state
    # @teeth: keyryx-alerts: the findings go back to the witness's state claim

  Scenario: A reader mounts the findings read-write
    Given the console mounts keyryx-alerts read only
    When the mount, or the volume, loses readOnly
    Then the gate fails, because only the witness writes its findings
    # @teeth: keyryx-alerts: the console mounts the findings read-write
    # @teeth: keyryx-alerts: the console's findings volume is not read only

  Scenario: A reader is not told to read the findings
    Given HERALDYX_EVENTS and GENARYX_EVENTS_EXTRA name the findings file
    When either reader loses its setting
    Then the gate fails and names the reader that would not read the findings
    # @teeth: keyryx-alerts: heraldyx is not told to read the findings
    # @teeth: keyryx-alerts: the console is not told to read the findings

  Scenario: The findings claim cannot reach a reader on another node
    Given keyryx-alerts is ReadWriteMany on stack-rwx
    When it is made ReadWriteOnce
    Then the gate fails, because the console and heraldyx run on other nodes
    # @teeth: keyryx-alerts: the findings claim is ReadWriteOnce

  Scenario: Custody mounts the witness's findings
    Given only the witness mounts keyryx-alerts read-write
    When custody mounts it too
    Then witness-is-separate.sh fails, because custody and the witness share nothing but the image
    # @teeth: witness-is-separate: custody mounts the witness's findings claim

  Scenario: The findings file is not made before the witness starts
    Given agent-stack-go v2 creates a stream only in a directory its own uid owns
    When the witness's precreate-streams init container is gone
    Then stream-files-are-precreated.sh fails for the witness's findings file
    # @teeth: stream-files-are-precreated: the witness's findings file is not made before it starts

  Scenario: The findings file loses the stem heraldyx reads as keyryx
    Given heraldyx 0.8.0 reads source keyryx from a file named keyryx.ndjson
    When the witness writes alerts.ndjson instead
    Then bus-names-match-the-source-rule.sh fails, because heraldyx would refuse every finding
    # @teeth: bus-names: the witness's findings file loses its keyryx stem

  Scenario: heraldyx is pinned before the release that reads the findings file safely
    Given heraldyx 0.8.0 is the first release that reads the keyryx source, and 0.8.1 the first that reads a named stream file only as a regular file
    When manifests/45-heraldyx.yaml pins heraldyx 0.8.0
    Then bus-names-match-the-source-rule.sh fails and names the pin
    # @teeth: bus-names: the heraldyx pin goes back before the keyryx source

  Scenario: The claim is gone
    Given the gate judges the claim by its name
    When the claim is renamed away
    Then the gate reports that it measured nothing, and does not pass
    # @teeth: keyryx-alerts: the findings claim is gone (measured nothing)

  Scenario: A reworded comment is not a fault
    Given the gate reads the manifests with comments stripped
    When a comment beside the claim is reworded
    Then the gate still passes
    # @teeth: keyryx-alerts: a comment beside the findings claim (must pass)
