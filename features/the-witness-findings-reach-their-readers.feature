# @decided 2026-10-20 (paraphrased): the Keyryx witness's findings reach the console and
# the notifier by giving those readers read-only access to the witness's own findings
# file; the witness is never given write access to the bus it witnesses. On a cluster the
# findings travel on the witness's own claim, read only through a subPath, with each reader
# on the witness's node; no new volume is added. Each scenario is bound to a teeth case in
# scripts/gates-have-teeth.sh by its name, checked by hand.

Feature: The Keyryx witness's findings reach the console and heraldyx, read only, through the witness's own claim

  The witness notices when a stream on the bus was rewritten after it was seen. If it
  could write the bus, a compromised witness could add lines to the record it vouches
  for. So its findings are a file off the bus, alerts/keyryx.ndjson on its own claim,
  and the console and heraldyx mount only alerts/ of that claim, read only, beside the
  witness, through patches the Keyryx install applies and its opt-out reverses.

  Scenario: No new volume carries the findings
    Given the findings travel on the witness's own claim keyryx-witness-state
    When a PersistentVolumeClaim keyryx-alerts is added
    Then the gate fails, because no new volume is added for them
    # @teeth: keyryx-alerts: a claim of their own is added for the findings

  Scenario: The witness writes its findings onto the bus
    Given the witness writes alerts/keyryx.ndjson on its own claim
    When its findings file is moved under the bus directory it reads
    Then the gate fails, because the witness would write the bus it witnesses
    # @teeth: keyryx-alerts: the witness writes its findings onto the bus

  Scenario: The findings sit at the root of the witness's claim
    Given the findings are in alerts/, a directory of their own on the witness's claim
    When the file is moved to the claim's root
    Then the gate fails, because a reader would have to mount the whole claim, key included
    # @teeth: keyryx-alerts: the findings sit at the root of the witness's claim

  Scenario: The findings sit beside the witness key
    Given the witness key lives under data/ on its claim
    When the findings file is moved under data/
    Then the gate fails, because a reader of the findings would see the key
    # @teeth: keyryx-alerts: the findings sit beside the witness key

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

  Scenario: A reader's volume of the witness's claim is writable
    Given heraldyx mounts the witness's claim readOnly on the claim
    When the claim's readOnly is dropped
    Then the gate fails, because the mount could write the witness's state and its fsGroup would be applied to it
    # @teeth: keyryx-alerts: heraldyx's volume of the witness's claim is writable

  Scenario: A reader mounts the findings read-write
    Given the console mounts alerts/ read only
    When the mount loses readOnly
    Then the gate fails, because only the witness writes its findings
    # @teeth: keyryx-alerts: the console mounts the findings read-write

  Scenario: A reader mounts the whole witness claim
    Given heraldyx mounts the witness's claim through subPath alerts
    When the subPath is removed
    Then the gate fails, because heraldyx would see the witness key
    # @teeth: keyryx-alerts: heraldyx mounts the whole witness claim

  Scenario: A reader mounts the witness key directory
    Given the console mounts the witness's claim through subPath alerts
    When the subPath becomes data
    Then the gate fails, because the console would see the witness key
    # @teeth: keyryx-alerts: the console mounts the witness key directory

  Scenario: A reader is not placed beside the witness
    Given heraldyx is pod-affined, required, by host name, to the witness
    When the affinity's topology becomes a zone
    Then the gate fails, because the claim is ReadWriteOnce and mounts on one node
    # @teeth: keyryx-alerts: heraldyx is not placed beside the witness

  Scenario: heraldyx is not told to read the findings
    Given heraldyx's patch names the findings file in HERALDYX_EVENTS
    When the setting names the bus alone
    Then the gate fails, because no finding would be mailed
    # @teeth: keyryx-alerts: heraldyx is not told to read the findings

  Scenario: A reader is handed the findings directory beside the file
    Given the console names keyryx.ndjson itself
    When its setting also names the directory that holds it
    Then the gate fails, because that entry reads anything else put beside the file
    # @teeth: keyryx-alerts: the console is handed the findings directory beside the file

  Scenario: A reader is handed the findings directory behind a double slash
    Given heraldyx names keyryx.ndjson itself
    When its setting also names //var/lib/keyryx-findings
    Then the gate fails, because the kernel reads a leading double slash as one
    # @teeth: keyryx-alerts: heraldyx is handed the findings directory behind a double slash

  Scenario: Only another container of a reader is in the bus group
    Given heraldyx's container reads the findings through the pod's supplementalGroups 10001
    When that group is dropped and only its init container runs in group 10001
    Then the gate fails, because the container that reads the file cannot
    # @teeth: keyryx-alerts: only an init container of heraldyx is in the bus group

  Scenario: An unpatch leaves the witness's claim mounted
    Given heraldyx's unpatch deletes the volume and the mount
    When it no longer deletes the volume
    Then the gate fails, because --without-keyryx would leave heraldyx mounting the witness's claim
    # @teeth: keyryx-alerts: heraldyx's unpatch leaves the witness's claim mounted

  Scenario: An unpatch does not put the setting back
    Given heraldyx's unpatch sets HERALDYX_EVENTS to the value its manifest declares
    When it deletes the variable instead
    Then the gate fails, because heraldyx would lose the bus
    # @teeth: keyryx-alerts: heraldyx's unpatch does not put its setting back

  Scenario: An unpatch keeps the reader beside the witness
    Given the console's unpatch sets podAffinity to null
    When that line is removed
    Then the gate fails, because the console would stay bound to the witness's node
    # @teeth: keyryx-alerts: the console's unpatch keeps it beside the witness

  Scenario: The install never patches heraldyx
    Given keyryx_install_settle patches both readers
    When the heraldyx patch is dropped
    Then the gate fails and names keyryx_install_settle
    # @teeth: keyryx-alerts: the install never patches heraldyx

  Scenario: The opt-out never unpatches the console
    Given keyryx_remove_settle unpatches both readers
    When the console's unpatch is dropped
    Then the gate fails and names keyryx_remove_settle
    # @teeth: keyryx-alerts: the opt-out never unpatches the console

  Scenario: Turning Keyryx off leaves a reader bound to a deleted witness
    Given keyryx/down.sh unpatches both readers before it deletes the witness
    When heraldyx's unpatch is dropped
    Then the gate fails, because heraldyx could not be scheduled again
    # @teeth: keyryx-alerts: keyryx/down.sh deletes the witness with heraldyx still bound to it

  Scenario: A deploy applies heraldyx and never its findings patch
    Given each deploy script patches heraldyx right after it applies it
    When the GCP deploy drops that step
    Then the gate fails, because a fresh apply leaves heraldyx reading the bus alone
    # @teeth: keyryx-alerts: the GCP deploy applies heraldyx and never its findings patch

  Scenario: A default manifest mounts the witness's claim
    Given the default manifests never mount keyryx-witness-state
    When the console's manifest mounts it
    Then the gate fails, because an install without Keyryx would change
    # @teeth: keyryx-alerts: a default manifest mounts the witness's claim

  Scenario: A reader's patch is gone
    Given heraldyx's findings patch names its Deployment
    When the Deployment is renamed in the patch
    Then the gate says it measured NOTHING rather than OK
    # @teeth: keyryx-alerts: heraldyx's patch is gone (measured nothing)

  Scenario: A reworded comment is not a fault
    Given the header of heraldyx's patch says what it does
    When the comment is reworded
    Then the gate still passes
    # @teeth: keyryx-alerts: a comment beside heraldyx's patch (must pass)

  Scenario: The findings file loses the stem heraldyx reads as keyryx
    Given heraldyx reads keyryx.ndjson as source keyryx
    When the witness's file is renamed alerts.ndjson
    Then bus-names-match-the-source-rule.sh fails, because every finding would be refused
    # @teeth: bus-names: the witness's findings file loses its keyryx stem

  Scenario: heraldyx is pinned before the release that reads the findings file safely
    Given heraldyx 0.8.0 is the first release that reads the keyryx source, and 0.8.1 the first that reads a named stream file only as a regular file
    When manifests/45-heraldyx.yaml pins heraldyx 0.8.0
    Then bus-names-match-the-source-rule.sh fails and names the pin
    # @teeth: bus-names: the heraldyx pin goes back before the findings are read safely

  Scenario: The findings file is not made before the witness starts
    Given the witness's init precreate-streams makes alerts/ and keyryx.ndjson
    When the init is renamed
    Then stream-files-are-precreated.sh fails
    # @teeth: stream-files-are-precreated: the witness's findings file is not made before it starts

  Scenario: The witness's init never makes alerts/
    Given the init mounts the claim's root and makes alerts/ with mkdir -p
    When the mkdir is dropped
    Then stream-files-are-precreated.sh fails, because the subPath directory would not exist
    # @teeth: stream-files-are-precreated: the witness's init mounts its claim and never makes alerts/
