# @claude 2026-10-14: the teeth run is the slowest step of the gates check, so it is
# split into four CI shards that run in parallel. A gate proves that together the
# shards run every case exactly once, because a case lost in the split changes no
# exit code. Scenarios are bound to cases in scripts/gates-have-teeth.sh by name;
# this repository has no runner and no binding gate, so the binding is by eye.
Feature: the teeth run is split across shards that together run every case once

  Each case of the teeth run belongs to exactly one shard, chosen by its position,
  so four CI jobs run a quarter each and no case runs twice or not at all.

  Scenario: the shard filter drops cases
    Given the teeth run is listed whole and then shard by shard
    When the shard filter takes one shard more than the workflow runs
    Then teeth-shards-cover-every-case.sh fails and says the shards do not cover the whole list
    # -> gates-have-teeth.sh "teeth-shards-cover-every-case: the shard filter uses one shard too many"

  Scenario: a listing that names nothing
    Given the cases are listed in list mode
    When the listing prints no case name
    Then the gate fails rather than passing on an empty list
    # -> gates-have-teeth.sh "teeth-shards-cover-every-case: the listing prints nothing"

  Scenario: the CI matrix runs too few shards
    Given the teeth job names four shards
    When the matrix runs only three of them
    Then the gate fails and names the matrix
    # -> gates-have-teeth.sh "teeth-shards-cover-every-case: the CI matrix runs three shards"

  Scenario: a reworded comment is not a fault
    Given the shard filter is documented in a comment
    When the comment is reworded and the filter is unchanged
    Then the gate still passes
    # -> gates-have-teeth.sh "teeth-shards-cover-every-case: a reworded comment is not a fault"
