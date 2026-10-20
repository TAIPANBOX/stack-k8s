# @claude 2026-10-20: turning Keyryx off, by keyryx/down.sh or by a deploy with
# --without-keyryx, leaves no record-seal Job bound to the witness it deletes, and a read of
# the cluster it cannot make stops it. From a review of v1.7.0 (GOTCHAS 155 and 156). Each
# scenario is bound to a teeth case in scripts/gates-have-teeth.sh by its name, checked by hand.

Feature: Turning Keyryx off leaves no record seal waiting for a witness that is gone

  A Job keeps the template it was made from, so a record-seal Job made before the
  unpatch still needs the witness's node. Once the witness is deleted its pod waits
  Pending, and concurrencyPolicy Forbid then holds back every later seal.

  Scenario: A seal bound to the witness is not left behind
    Given a record-seal Job made before the unpatch, which has not started
    When Keyryx is turned off
    Then that Job is deleted with its pods, after the CronJob is unpatched and before the witness
    # @teeth: keyryx-off: the opt-out never releases the record-seal Jobs
    # @teeth: keyryx-off: the release runs before the record-seal is unpatched
    # @teeth: keyryx-off: a seal is deleted without waiting for its pods

  Scenario: A seal that is running is let finish
    Given a record-seal Job bound to the witness whose pod is running
    When Keyryx is turned off
    Then it is let finish for KEYRYX_SEAL_WAIT seconds, and deleted only if it is still running then
    # @teeth: keyryx-off: a running seal is deleted instead of let finish

  Scenario: What the delete left is checked
    Given a record-seal Job bound to the witness is still there after the delete
    When Keyryx is turned off
    Then the run stops before it deletes anything of Keyryx and says a seal is still bound
    # @teeth: keyryx-off: the release never checks what the delete left

  Scenario: A failed read stops the run
    Given the cluster does not answer a read of a Deployment
    When keyryx/down.sh waits for that Deployment, or the install patches a reader of the findings
    Then the run stops and names the read, instead of reading the object as not installed
    # @teeth: keyryx-off: down.sh swallows a failed read of a Deployment
    # @teeth: keyryx-off: a failed read of a reader reads as not installed

  Scenario: keyryx/down.sh does not say custody stays
    Given keyryx/down.sh deletes custody and the witness
    When it removes the Keyryx wiring first
    Then nothing it prints says custody or the witness stays
    # @teeth: keyryx-off: the opt-out says custody and the witness stay
