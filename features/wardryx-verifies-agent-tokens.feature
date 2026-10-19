# @decided 2026-10-19 (paraphrased, decision D3(b), step 2): wardryx verifies the agent's token and its
# DPoP proof itself, and never takes the enforcement point's word for which agent is calling.
# Bound by name to the teeth cases "wardryx-verifies-agent-tokens: ..." in scripts/gates-have-teeth.sh
# (CLAUDE.md invariant 63).
Feature: wardryx verifies the agent's own token and its proof, and the proof stays required

  Scenario: wardryx runs a release that checks the token
    Given the wardryx image in the default install
    When it is pinned before v2.3.0
    Then the gate refuses it, because the earlier release does not check the token
    -> wardryx-verifies-agent-tokens: wardryx is pinned before the token check

  Scenario: the five settings are set together and name vouchryx
    Given wardryx's agent-token settings
    When one of them is dropped, or names another issuer
    Then the gate refuses it
    -> wardryx-verifies-agent-tokens: the JWKS source is dropped, so the key set has no source
    -> wardryx-verifies-agent-tokens: the issuer is another vouchryx

  Scenario: the proof is required
    Given wardryx's agent-token settings
    When the proof is switched off
    Then the gate refuses it, because a bearer token alone would then be enough
    -> wardryx-verifies-agent-tokens: the proof is switched off

  Scenario: both doors are named as origins the proof may be sent to
    Given wardryx's door origins
    When the gateway's origin is not named
    Then the gate refuses it, because every gateway proof would be refused
    -> wardryx-verifies-agent-tokens: the gateway's door origin is not named

  Scenario: wardryx has a network path to vouchryx, and vouchryx admits it
    Given the network rules
    When either half is missing
    Then the gate refuses it
    -> wardryx-verifies-agent-tokens: wardryx has no network path to vouchryx
    -> wardryx-verifies-agent-tokens: vouchryx refuses wardryx

  Scenario: a comment that names the proof switch is not a fault
    Given a comment that mentions the proof switch
    When the gate reads the manifest
    Then it passes
    -> wardryx-verifies-agent-tokens: a comment naming the proof switch is not a fault
