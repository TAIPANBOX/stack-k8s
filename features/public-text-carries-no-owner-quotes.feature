# @decided 2026-09-09 (paraphrased): a public repository carries no verbatim
# quote of the owner, no provenance marker naming the owner, and no sentence
# attributing a decision to the owner by name. A decision is still recorded, as
# `@decided YYYY-MM-DD` followed by a paraphrase, and that line is not edited
# afterwards. The owner's name as copyright holder is ownership, not a quote.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this
# repository has no runner and no binding gate, so the binding is by eye.
Feature: a public repository carries no quote of the owner

  Anyone can read this repository. A decision is recorded so a later reader does
  not re-derive it, and it is recorded in our own words, with a date, never as
  the owner's words or under the owner's name.

  Scenario: an owner marker, a quote or an attribution by name is added
    Given every tracked text file is read line by line
    When a line carries the owner's provenance marker, Cyrillic text, a guillemet, or the owner's name outside a copyright line
    Then no-owner-quotes.sh fails and names the file and the line
    # -> gates-have-teeth.sh "no-owner-quotes: an owner provenance marker"
    # -> gates-have-teeth.sh "no-owner-quotes: a quote in Ukrainian"
    # -> gates-have-teeth.sh "no-owner-quotes: a quote in guillemets"
    # -> gates-have-teeth.sh "no-owner-quotes: an attribution by name"

  Scenario: the gate has nothing to read
    Given a repository with no tracked text file
    When no-owner-quotes.sh runs there
    Then it says it measured nothing and fails, never OK
    # -> gates-have-teeth.sh "no-owner-quotes: no tracked text file to judge"

  Scenario: the owner as copyright holder, and a decision written as @decided
    Given ownership is not a quote and a paraphrase under @decided is the public form
    When a copyright line names the owner, or a decision is recorded as @decided and a date
    Then no-owner-quotes.sh still passes
    # -> gates-have-teeth.sh "no-owner-quotes: the owner as copyright holder"
    # -> gates-have-teeth.sh "no-owner-quotes: a decision recorded as @decided and a paraphrase"
