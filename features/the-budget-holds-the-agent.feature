# @decided 2026-11-07 (paraphrased): both stacks connect the signal, the shared event file and the
# policy, so that a spent budget actually puts an agent's calls to a person.
# Bound by name to the teeth cases "slo-signal-is-wired: ..." in scripts/gates-have-teeth.sh
# (CLAUDE.md invariant 82).
Feature: an agent whose error budget is spent waits for a person

  Scenario: a cluster where nobody chose anything holds a spent budget
    Given a cluster deployed with nothing said about error budgets
    When an agent's budget is spent
    Then wardryx reads the file the routine wrote
    And one rule in the starter policy holds that agent's calls for a person
    -> slo-signal-is-wired: wardryx is not handed the file
    -> slo-signal-is-wired: the policy carries no rule

  Scenario: a hold does not keep itself alive
    Given an agent on hold because its budget is spent
    When its calls are held and it keeps working
    Then the holds do not spend more of its budget
    -> slo-signal-is-wired: a hold spends the budget that caused it

  Scenario: a file that cannot be believed holds nobody
    Given the file a hold stands on is broken
    Then tool calls go as they went before
    -> slo-signal-is-wired: the rule holds on a broken file

  Scenario: the writer and the reader cannot name different files
    Given one key of stack-wiring names the file
    Then the routine writes where wardryx reads
    -> slo-signal-is-wired: the writer names another file

  Scenario: no other plane writes the file a hold stands on
    Given the routine runs under a uid of its own
    Then no manifest gives that uid to another workload
    -> slo-signal-is-wired: the sidecar shares a uid

  Scenario: a healthy cluster does not report the file as unreadable
    Given no agent has spent its budget yet
    Then the routine has already made the file, empty, under its own uid
    And wardryx reads it as sound
    -> slo-signal-is-wired: the file does not exist until the first spent budget

  Scenario: a routine that cannot measure does not look like a healthy fleet
    Given the routine fails to read the traces
    Then its container stops and the pod shows it
    -> slo-signal-is-wired: a failed measurement is swallowed

  Scenario: the routine can start and reads what it needs
    Given the routine runs the console's image beside the gateway
    Then it replaces the image's entrypoint and runs the console's own pin
    -> slo-signal-is-wired: the sidecar keeps the console's entrypoint
    -> slo-signal-is-wired: the sidecar runs an older console than the console
    -> slo-signal-is-wired: the sidecar has left the gateway's pod
