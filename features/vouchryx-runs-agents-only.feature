# @decided 2026-10-19 (paraphrased, decision D8): the default install carries the service that issues
# agent tokens, with no identity provider. Trusting an identity provider stays a separate, opt-in step.
# Bound by name to the teeth cases "vouchryx-runs-agents-only: ..." in scripts/gates-have-teeth.sh
# (CLAUDE.md invariant 24, as amended).
Feature: vouchryx runs in the default install with no identity provider, and trusting one stays opt-in

  Scenario: vouchryx is in the default install and starts with no identity provider
    Given the default apply set
    When the gate reads it
    Then vouchryx is in it, and its IdP inputs are optional
    -> vouchryx-runs-agents-only: the manifest leaves the default apply set
    -> vouchryx-runs-agents-only: the IdP ConfigMap is required again

  Scenario: the keys of the plane are minted once, by the deploy, and kept
    Given a deploy that runs on a fresh cluster
    When the deploy no longer mints vouchryx's keys
    Then the gate refuses it, because vouchryx would wait forever for its signing key
    -> vouchryx-runs-agents-only: the deploy stops minting vouchryx's keys
    -> vouchryx-runs-agents-only: the mint library is taken away

  Scenario: the console's revoke wiring stays opt-in
    Given the default console manifest
    When it sets vouchryx's revoke wiring
    Then the gate refuses it
    -> vouchryx-runs-agents-only: the console's revoke wiring goes into the default console

  Scenario: a comment about an optional input is not a fault
    Given a comment that mentions the trusted-issuers input
    When the gate reads the manifest
    Then it passes
    -> vouchryx-runs-agents-only: a comment naming the IdP input is not a fault
