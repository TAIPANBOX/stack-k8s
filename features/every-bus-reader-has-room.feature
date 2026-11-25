# @claude 2026-11-25: on a single box the keyryx witness was killed at its memory
# ceiling while it re-hashed a bus nothing rotates. CLAUDE.md invariant 96.
Feature: every reader of the whole bus has room for it

  Scenario: a reader of every stream is held below 1Gi
    Given the witness, the chain verifier, the record seal, idryx-rescan and heraldyx read every stream
    When one of them is limited below 1Gi
    Then bus-readers-have-room.sh fails
    # -> gates-have-teeth.sh "bus-readers: the witness goes back to 512Mi"
    # -> gates-have-teeth.sh "bus-readers: the chain verifier goes back to 256Mi"

  Scenario: a reader is gone
    Given the gate finds each reader by name
    When one is renamed
    Then the gate says it measured nothing
    # -> gates-have-teeth.sh "bus-readers: heraldyx is renamed (measured nothing)"

  Scenario: more room is not a fault
    Given a limit may be raised
    When the witness is given 2Gi
    Then the gate still passes
    # -> gates-have-teeth.sh "bus-readers: the witness is given 2Gi (must pass)"
