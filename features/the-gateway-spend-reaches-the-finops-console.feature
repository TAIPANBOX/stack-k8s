# @decided 2026-11-23 (paraphrased, the stack revision wave): CostCrew gets real data from TokenFuse first.
# `@claude 2026-11-23`: the folder names and flags are stack-single's (its invariant 80); here the folder
# sits on the events claim beside the bus, because the gateway's traces are an emptyDir and a claim of its
# own would be a billed disk (CLAUDE.md invariant 95). Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name; scripts/features-are-bound.sh holds the binding.
Feature: the gateway's spend reaches the FinOps console on a cluster

  The gateway prices every call. The FinOps console shows spend. Between them sits one CSV, and every
  way of losing it leaves every container running and the console showing the estate it was born with.

  Scenario: the console reads the gateway's folder, not the folder above it
    Given focus-export writes focus-gateway.csv into focus/gateway
    When the console's -focus-dir names focus/ instead
    Then costcrew-reads-the-gateway-spend.sh fails, because the console would import nothing
    # -> gates-have-teeth.sh "costcrew-reads-spend: -focus-dir names the empty parent"

  Scenario: the first real call replaces the generated estate
    Given the console starts with a generated estate
    When -focus-replace-generated is dropped
    Then the gate fails, because every import would be refused while that estate is there
    # -> gates-have-teeth.sh "costcrew-reads-spend: the replace flag is dropped"

  Scenario: the console only reads the export
    Given the console mounts focus/
    When the mount is read-write, or the console carries the gateway's group
    Then the gate fails, because the console could rewrite the spend it reports, or the gateway's stream
    # -> gates-have-teeth.sh "costcrew-reads-spend: the console mounts the export read-write"
    # -> gates-have-teeth.sh "costcrew-reads-spend: the console is given the gateway's group"

  Scenario: the export lands where the console looks
    Given focus-export's one mount on the events claim is focus/gateway
    When its script writes somewhere else
    Then the gate fails, because the file would land in a directory no other pod sees
    # -> gates-have-teeth.sh "costcrew-reads-spend: the sidecar writes where it no longer has a mount"

  Scenario: the console never reads half an export
    Given each window rewrites the whole file
    When the export is written straight to focus-gateway.csv
    Then the gate fails, because a read in the middle of the write takes half the calls
    # -> gates-have-teeth.sh "costcrew-reads-spend: the export is written straight to the name the console reads"

  Scenario: a quiet or failing window keeps what was there
    Given a window with no calls, or one where the tool fails
    When the window ends
    Then the last good file stays, and a failure is printed in the tool's own words
    # -> gates-have-teeth.sh "costcrew-reads-spend: an idle window deletes the last good file"
    # -> gates-have-teeth.sh "costcrew-reads-spend: a failed export is swallowed as a quiet window"

  Scenario: a fresh cluster exports at once
    Given a gateway pod that has just started
    When focus-export starts
    Then it exports before it first waits
    # -> gates-have-teeth.sh "costcrew-reads-spend: the first export waits an interval"

  Scenario: the directories exist before any pod mounts them
    Given kubelet makes a missing subPath itself, as root
    When the owner makes focus/ after its marker, or the console stops waiting for focus/gateway
    Then the gate fails
    # -> gates-have-teeth.sh "costcrew-reads-spend: the owner makes focus/ after the marker"
    # -> gates-have-teeth.sh "costcrew-reads-spend: the console stops waiting for focus/gateway"

  Scenario: only the console mounts the export
    Given focus/ holds what the gateway priced
    When another pod mounts it
    Then bus-writers-are-separate.sh fails
    # -> gates-have-teeth.sh "bus-writers: a pod other than costcrew mounts the FOCUS export"

  Scenario: the exporter calls the binary the image ships
    Given the gateway container runs /usr/local/bin/tokenfuse
    When focus-export calls another name
    Then the gate fails, because every window would fail and read as a quiet one
    # -> gates-have-teeth.sh "costcrew-reads-spend: the sidecar calls a binary the image does not ship"

  Scenario: the console can read what the exporter wrote
    Given the console reads the CSV through "other"
    When the export keeps a tighter mode from the tool's umask
    Then the gate fails
    # -> gates-have-teeth.sh "costcrew-reads-spend: the export keeps the tool's own mode"

  Scenario: every deploy lets the owner run
    Given a bus-owner Job finished less than ten minutes ago
    When a launcher applies the manifests without deleting it
    Then the gate fails, because the owner would not run and focus/ would not be made
    # -> gates-have-teeth.sh "costcrew-reads-spend: the bus-owner waits for the next apply only after ten minutes"

  Scenario: no exporter at all
    Given the gateway pod without focus-export
    When the gate runs
    Then it says it measured nothing and fails
    # -> gates-have-teeth.sh "costcrew-reads-spend: the sidecar is gone, which must say it measured nothing"

  Scenario: a comment is reworded
    Given the console's flags are unchanged
    When the comment beside them is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "costcrew-reads-spend: a comment reworded beside the console's flags (must pass)"
