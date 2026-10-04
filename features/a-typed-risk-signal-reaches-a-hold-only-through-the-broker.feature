# @decided 2026-10-04, from the estate audit (wave 1, J2): a typed risk signal may
# turn a call into a hold for a person and never into a deny, its first consumer
# is wardryx (v1.2.0 hold_if_signal), and the signal is recorded so a replay
# reproduces the decision. The launchers offer it, off by default, behind one flag.
# `@claude 2026-10-04`: the choices the audit did not make are in CLAUDE.md
# invariant 29. Scenarios are bound to cases in scripts/gates-have-teeth.sh by
# name; this repository has no runner and no binding gate, so the binding is by eye.
Feature: a typed risk signal reaches a policy hold only through the MCP broker

  typryx's wardryx-proxy sits between tokenfuse's MCP broker and wardryx and adds
  the risk class of a pending tool call to the decision request. Nothing about it
  is on by default: it needs typryx deployed, the operator's flag, and a
  hold_if_signal rule the operator writes. The model path never waits on it.

  Scenario: the flag is not given
    Given a typed mode is chosen
    When --typed-risk-signal is not passed
    Then no render carries the proxy, a wardryx setting on the broker, or a widened egress policy
    # -> gates-have-teeth.sh "typed-mode-is-honest: the risk signal is on without the flag"

  Scenario: the flag is given with typryx off
    Given nothing is deployed for typryx
    When --typed-risk-signal is passed
    Then typed/mode.sh refuses, names the flag, and prints no manifest
    # -> gates-have-teeth.sh "typed-mode-is-honest: the risk flag is accepted with no typryx"

  Scenario: the LLM gateway keeps asking wardryx directly
    Given the gateway asks wardryx for every model call, fail closed
    When the risk signal is on
    Then the gateway's wardryx URL is still wardryx's own Service
    # -> gates-have-teeth.sh "typed-mode-is-honest: the gateway is pointed at the proxy"

  Scenario: the broker asks through the proxy, fail closed, with the viewer key
    Given the broker asked wardryx nothing before
    When the risk signal is on
    Then only the broker's wardryx URL names the proxy, and its mode is enforce, its fail mode closed, its key the viewer key
    # -> gates-have-teeth.sh "typed-mode-is-honest: the broker keeps asking wardryx directly", "typed-mode-is-honest: the broker fails open" and "typed-mode-is-honest: the broker uses the admin key"

  Scenario: the broker waits longer than the proxy may take
    Given the proxy may take 1000 ms to ask typryx before it forwards without a signal
    When the broker's own wait is not longer
    Then the gate fails, because every slow answer would turn into a refusal
    # -> gates-have-teeth.sh "typed-mode-is-honest: the broker waits less than the proxy may take"

  Scenario: the proxy answers from the backend the operator chose
    Given the typed mode chose jev or an own model
    When the proxy renders
    Then it carries the same backend and key mount as typryx, and the model egress policy selects both pods and no wider
    # -> gates-have-teeth.sh "typed-mode-is-honest: the proxy answers from another backend than typryx" and "typed-mode-is-honest: the model egress leaves the proxy out"

  Scenario: the proxy keeps no state
    Given the proxy asks about tool-call arguments
    When it is given a journal, or inherits the training log
    Then the gate fails, because a second writer would fork typryx's chain and the log would hold the arguments
    # -> gates-have-teeth.sh "typed-mode-is-honest: the proxy gets a journal on the shared bus" and "typed-mode-is-honest: the proxy inherits the training log"

  Scenario: the door admits only the broker
    Given the proxy runs open on purpose because the broker cannot send a key
    When a NetworkPolicy admits every pod to its port
    Then the gate fails
    # -> gates-have-teeth.sh "typed-mode-is-honest: the door admits every pod"

  Scenario: nothing is held by default
    Given no hold_if_signal policy is shipped
    When one is seeded into the starter policy
    Then the gate fails
    # -> gates-have-teeth.sh "typed-mode-is-honest: a hold_if_signal policy is seeded"

  Scenario: the proxy runs a typryx that has the subcommand, as typryx itself does
    Given typryx v0.4.0 is the first release with wardryx-proxy
    When the proxy runs another tag, another subcommand, or forwards to something other than wardryx
    Then the gate fails
    # -> gates-have-teeth.sh "typed-mode-is-honest: the proxy runs another typryx tag than typryx", "typed-mode-is-honest: the proxy runs the service, not the proxy" and "typed-mode-is-honest: the proxy forwards to something other than wardryx"

  Scenario: every launcher offers the flag
    Given the launchers hand every typed flag to typed/mode.sh
    When one stops parsing or forwarding --typed-risk-signal
    Then the gate fails naming the launcher
    # -> gates-have-teeth.sh "typed-mode-is-honest: a launcher loses --typed-risk-signal" and "typed-mode-is-honest: a launcher stops forwarding --typed-risk-signal"

  Scenario: the manifest drifts from the lines the modes rewrite
    Given typed/mode.sh rewrites three lines of manifests/56
    When one is reworded
    Then the render refuses instead of emitting the stub while claiming a mode
    # -> gates-have-teeth.sh "typed-mode-is-honest: manifests/56 drifts from the lines the modes rewrite"

  Scenario: a comment in the proxy manifest changes
    Given the manifest is correct
    When only a comment changes
    Then the gate still passes
    # -> gates-have-teeth.sh "typed-mode-is-honest: a comment in manifests/56 changes" and "typed-mode-is-honest: manifests/56 taken away"
