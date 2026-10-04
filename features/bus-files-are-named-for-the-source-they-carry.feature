# @decided 2026-10-04, from the estate audit (wave 1, bus layer 2): heraldyx v0.3.0
# and idryx v1.1.0 refuse an event whose `source` is not allowed for the file it
# was read from. `@claude 2026-10-04`: this launcher needed no rename; the gate
# keeps it so. Scenarios are bound to cases in scripts/gates-have-teeth.sh by name;
# this repository has no runner and no binding gate, so the binding is by eye.
Feature: every bus file is named for the source it carries

  `<source>.ndjson` carries `<source>`, `tokenfuse-cloud.ndjson` and
  `tokenfuse-mcp.ndjson` carry `tokenfuse`, and anything else is declared. A file
  named otherwise has its events counted, alerted once and dropped.

  Scenario: a stream is renamed to a name no reader knows
    Given wardryx writes wardryx.ndjson
    When the launcher names its file policy-events.ndjson
    Then bus-names-match-the-source-rule.sh fails saying no reader knows the stem
    # -> gates-have-teeth.sh "bus-names: a stream is named for no source the readers know"

  Scenario: the notifier declares the new name
    Given a stream is renamed
    When the notifier is told with HERALDYX_STREAMS
    Then the gate passes
    # -> gates-have-teeth.sh "bus-names: a renamed stream that the notifier declares is not a fault"

  Scenario: idryx is told to load a file as a source it may not carry
    Given idryx loads tokenfuse.ndjson as tokenfuse
    When the pair names wardryx for that file
    Then the gate fails, because idryx v1.1.0 would refuse every line and the graph would be empty
    # -> gates-have-teeth.sh "bus-names: an idryx --load pair names a source the file may not carry" and "bus-names: an idryx --load path is not a stream file"

  Scenario: the control plane and the broker keep their own files
    Given they write tokenfuse-cloud.ndjson and tokenfuse-mcp.ndjson as tokenfuse
    When the manifests are otherwise unchanged
    Then the gate passes
    # -> gates-have-teeth.sh "bus-names: the control plane and the broker keep their tokenfuse rows"

  Scenario: a comment names a stream that does not exist
    Given the manifests are correct
    When a comment mentions a bad file name
    Then the gate still passes
    # -> gates-have-teeth.sh "bus-names: a comment names a stream that does not exist"

  Scenario: no stream path is left to judge
    Given the gate reads the paths under the bus directory
    When none is found
    Then it says it measured nothing instead of reporting OK
    # -> gates-have-teeth.sh "bus-names: no stream path left to judge"
