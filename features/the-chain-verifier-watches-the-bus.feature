# @decided 2026-10-04, from the estate audit (wave 1, bus layer 3): the launchers
# run agent-stack-go's `agent-conform watch-dir`, so a broken hash chain on the
# shared events bus is seen by the notifier and the console instead of by nobody.
# `@claude 2026-10-04`: where its memory lives is in CLAUDE.md invariant 31.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this
# repository has no runner and no binding gate, so the binding is by eye.
Feature: the chain verifier watches the bus and a break stays visible

  Every stream on the bus is a hash chain and nothing on a box checked one. A
  CronJob runs the verifier every 15 minutes over the bus directory; a break
  becomes a chain_broken event in agent-conform.ndjson, where heraldyx and the
  console already read, and fails the Job once.

  Scenario: the verifier is suspended
    Given the verifier is a routine in the default install
    When its CronJob is suspended
    Then chain-verifier-watches-the-bus.sh fails saying it verifies nothing until a person runs it
    # -> gates-have-teeth.sh "chain-verifier: the verifier is suspended"

  Scenario: the verifier runs less often than every 15 minutes
    Given the bus is checked every 15 minutes
    When the schedule is hourly
    Then the gate fails
    # -> gates-have-teeth.sh "chain-verifier: the verifier runs hourly"

  Scenario: the verifier watches the wrong directory
    Given its last argument is the bus directory stack-wiring names
    When it names another
    Then the gate fails, because it would verify nothing the planes write
    # -> gates-have-teeth.sh "chain-verifier: the verifier watches a directory that is not the bus"

  Scenario: the verifier writes a stream named for another writer
    Given its output must be agent-conform.ndjson inside the bus
    When it is pointed at wardryx.ndjson
    Then the gate fails
    # -> gates-have-teeth.sh "chain-verifier: the verifier writes a stream named for another writer"

  Scenario: the verifier remembers in a place that forgets
    Given a CronJob is a new pod per run
    When its state is on an emptyDir
    Then the gate fails, because a persistent break would be announced again every run
    # -> gates-have-teeth.sh "chain-verifier: the verifier remembers in an emptyDir"

  Scenario: the verifier is given a disk of its own
    Given a claim is a billed disk and the operator's decision
    When the CronJob mounts a second claim
    Then the gate fails
    # -> gates-have-teeth.sh "chain-verifier: the verifier is given a claim of its own"

  Scenario: a failed pass is retried into silence
    Given a new break exits 1 on purpose
    When the Job retries on failure
    Then the gate fails, because the retry exits 0 and hides the failure
    # -> gates-have-teeth.sh "chain-verifier: a failed pass is retried into silence"

  Scenario: the verifier cannot create its file
    Given the bus is group-writable by 10001 through fsGroup
    When the pod has no fsGroup, or runs as the money plane's uid
    Then the gate fails
    # -> gates-have-teeth.sh "chain-verifier: the verifier cannot create its file on the bus" and "chain-verifier: the verifier shares the money plane's uid"

  Scenario: the image has no watch-dir
    Given watch-dir starts at agent-conform v1.1.0
    When the pin is older
    Then the gate fails
    # -> gates-have-teeth.sh "chain-verifier: the image has no watch-dir"

  Scenario: the verifier is only in an opt-in file
    Given a default install must run it
    When the CronJob lives outside kustomization.yaml's resources
    Then the gate fails
    # -> gates-have-teeth.sh "chain-verifier: the verifier is in an opt-in file"

  Scenario: a comment on the verifier changes
    Given the manifest is correct
    When only a comment changes
    Then the gate still passes
    # -> gates-have-teeth.sh "chain-verifier: a comment on the verifier changes"

  Scenario: there is no verifier to judge
    Given the gate finds the verifier by its image
    When no CronJob runs it
    Then the gate says it measured nothing instead of reporting OK
    # -> gates-have-teeth.sh "chain-verifier: no verifier left to judge"
