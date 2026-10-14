# @decided 2026-10-14: the deploy scripts mint the typed-answer door's two Secrets when they are
# absent and never overwrite one, as stack-single's installer already does. Scenarios are bound
# to cases in scripts/gates-have-teeth.sh by name; this repository has no runner and no binding
# gate, so the binding is by eye.
Feature: a typed deploy comes up green without a Secret made by hand

  typryx and the MCP broker in front of it each read a Secret for their door, and neither starts
  without it. A deploy that asks for the typed plane makes both when they are missing, keeps
  them when they are there, makes the broker's from typryx's key when only typryx's exists, and
  stops with the reason when only the broker's exists. It says how to read a key back and never
  prints one.

  Scenario: a typed manifest reads a Secret nothing makes
    Given every Secret a typed manifest reads is made by the deploy or an installer
    When typryx's manifest also reads a Secret named typryx-extra
    Then typed-door-is-minted.sh fails and names typryx-extra
    # -> gates-have-teeth.sh "typed-door-is-minted: a typed manifest reads a Secret nothing mints"

  Scenario: a Secret the manifest marks optional is not a gap
    Given typryx's manifest reads typryx-extra and marks it optional
    Then typed-door-is-minted.sh still passes
    # -> gates-have-teeth.sh "typed-door-is-minted: an optional reference is not a fault"

  Scenario: a deploy script loses the door
    Given each deploy script sets up the door in its typed branch
    When deploy.sh's door block is taken out
    Then typed-door-is-minted.sh fails and says deploy.sh never sets up the door
    # -> gates-have-teeth.sh "typed-door-is-minted: a launcher loses its door"

  Scenario: a deploy script sets up the door after the pods that read it
    Given the door comes before the typed render
    When cloud/gcp/deploy-gcp.sh moves it below the render
    Then typed-door-is-minted.sh fails and says the door comes after the render
    # -> gates-have-teeth.sh "typed-door-is-minted: a launcher mints the door after the render"

  Scenario: a deploy script applies the door instead of creating it
    Given the door's Secrets are created, so an existing one is never replaced
    When cloud/aws/deploy-aws.sh hands them to apply
    Then typed-door-is-minted.sh fails and says apply would overwrite and keep a copy
    # -> gates-have-teeth.sh "typed-door-is-minted: a launcher applies the door's Secrets"

  Scenario: a deploy script creates only part of the door
    Given a deploy from an empty cluster ends with both Secrets
    When cloud/gcp/deploy-gcp.sh passes only the first document on
    Then typed-door-is-minted.sh fails, because the stand-in cluster ends without both
    # -> gates-have-teeth.sh "typed-door-is-minted: a launcher hands create only part of the door"

  Scenario: a comment that mentions apply beside the door changes nothing
    Given a comment in the door block says the Secrets never go to apply
    Then typed-door-is-minted.sh still passes
    # -> gates-have-teeth.sh "typed-door-is-minted: a comment about apply beside the door is not a fault"

  Scenario: the broker cannot open typryx's door
    Given the broker's vault carries typryx's own key
    When it carries the broker's key instead
    Then typed-door-is-minted.sh fails, because every call through the broker would be refused
    # -> gates-have-teeth.sh "typed-door-is-minted: the broker's vault does not carry typryx's bearer"

  Scenario: the two doors share one key
    Given typryx and the broker get keys of their own
    When both are given the same key
    Then typed-door-is-minted.sh fails, because two doors would become one
    # -> gates-have-teeth.sh "typed-door-is-minted: typryx and the broker get one key between them"

  Scenario: a key is too short
    Given each minted key is at least 32 characters
    When typryx's is minted at 16
    Then typed-door-is-minted.sh fails and says so
    # -> gates-have-teeth.sh "typed-door-is-minted: typryx's bearer is short"

  Scenario: the broker's key id is an agent address
    Given the broker's key id is a bare name
    When it becomes an agent:// address
    Then typed-door-is-minted.sh fails, because the broker would read the key wrongly and refuse it
    # -> gates-have-teeth.sh "typed-door-is-minted: the broker's key id is an agent URI"

  Scenario: a key is printed
    Given the deploy says how to read a key and never prints one
    When the door prints typryx's key on stderr
    Then typed-door-is-minted.sh fails and says a value reached stderr
    # -> gates-have-teeth.sh "typed-door-is-minted: a minted value reaches stderr"

  Scenario: only the broker's Secret exists and the door mints a new typryx key anyway
    Given the deploy stops when only the broker's Secret exists
    When the door mints both instead
    Then typed-door-is-minted.sh fails, because the new typryx key would not match the broker's vault
    # -> gates-have-teeth.sh "typed-door-is-minted: the broker's Secret alone mints typryx's anyway"

  Scenario: a door flag given to another step goes unnoticed
    Given --have and --trust-domain belong to the door step alone
    When the render accepts --have without a word
    Then typed-door-is-minted.sh fails, because a flag that does nothing must be refused
    # -> gates-have-teeth.sh "typed-door-is-minted: --have rides along with another verb unnoticed"

  Scenario: a minted Secret is not one Kubernetes would accept
    Given the minted Secrets validate strictly against the schema
    When a field name in them is misspelt
    Then typed-door-is-minted.sh fails and says they do not validate
    # -> gates-have-teeth.sh "typed-door-is-minted: the minted Secrets are not schema-valid"

  Scenario: the typed manifests are gone
    Given typryx's manifest is taken away
    Then typed-door-is-minted.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "typed-door-is-minted: the typed manifests are taken away"

  Scenario: no deploy script offers the typed plane
    Given no deploy script takes --with-typed
    Then typed-door-is-minted.sh fails and says it measured nothing about the launchers
    # -> gates-have-teeth.sh "typed-door-is-minted: no launcher is left to judge"
