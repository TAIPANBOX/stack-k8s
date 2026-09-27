# @decided 2026-09-27: the launchers route Felyx through the stack's gateway by
# default, with its agent id in the trust domain.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this
# repository has no runner and no binding gate yet, so the binding is by eye.
Feature: Felyx, the console's copilot, is governed like any other agent

  Felyx calls a model to answer an operator's questions. Its calls go through
  this stack's own gateway, by the gateway's Service name, under an agent id in
  the install's trust domain, so they are priced, budgeted and policy-checked.

  Scenario: the console manifest points Felyx somewhere other than the gateway
    Given manifests/20-console.yaml points Felyx at http://tokenfuse-gateway:4100
    When the base URL is changed to the provider's own address
    Then felyx-through-the-gateway.sh fails and names the variable
    # -> gates-have-teeth.sh "felyx-through-the-gateway: the base URL points past the gateway"

  Scenario: a manifest lets Felyx go around the gateway
    Given no manifest sets GENARYX_COPILOT_ALLOW_REMOTE
    When one manifest sets it again
    Then felyx-through-the-gateway.sh fails and names the file and line
    # -> gates-have-teeth.sh "felyx-through-the-gateway: a manifest sets the remote opt-in again"

  Scenario: a comment about the copilot changes
    Given the console manifest routes Felyx through the gateway
    When only a comment near the copilot settings is reworded
    Then felyx-through-the-gateway.sh still passes
    # -> gates-have-teeth.sh "felyx-through-the-gateway: a comment about the copilot changes"
