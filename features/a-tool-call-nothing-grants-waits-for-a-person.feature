# @decided 2026-11-07 (paraphrased): a tool call of an agent nothing grants is held for a person on a
# default install, model calls pass, only an explicit grant lifts the hold, and an existing install stops
# the upgrade with a list and changes nothing. The cluster's half of what stack-single does on a box.
# Each scenario is bound by name to a case in scripts/gates-have-teeth.sh, and tool-hold-is-seeded.sh
# holds that binding both ways.
Feature: A tool call nothing grants waits for a person

  On a cluster where nobody chose anything, an agent's tool call waits for a person until
  something grants that agent that tool. Its model calls go on as before. An operator gives
  an agent a tool in one command, and a cluster that already runs agents is told what would
  stop before anything is applied.

  Scenario: A tool call of an agent nothing grants is held for a person
    Given a cluster installed with nothing said about tool calls
    When an agent nothing grants calls a tool
    Then wardryx holds the call for a person
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the floor is written as a word wardryx refuses"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the block is never written"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a cloud launcher never writes the block"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: wardryx does not read the ConfigMap"

  Scenario: A model call of the same agent passes
    Given the same agent
    When it calls a model
    Then the call passes
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a seed grants every agent"

  Scenario: An agent id with no scheme is held and cannot be granted
    Given an agent whose id has no agent:// scheme
    When it calls a tool
    Then the call is held
    And agent-allow refuses to name it
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the floor narrows to agent ids with a scheme"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: agent-allow takes a target with no trust domain"

  Scenario: A rule that only restricts an agent does not end the hold
    Given the starter rules on the fire-drill identities, and a seed that grants them
    When a seed loses its grant
    Then their tool calls wait for a person, restrictions or not
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the drills lose their seed"

  Scenario: The stack's own identities keep working
    Given the block is the one stack-single writes
    When the install check's identity asks its one tool through the broker's static key
    Then the call passes, and that id can call nothing else
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the install-check seed is gone"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the install-check seed asks for an agent token"

  Scenario: An operator's web tools are granted with a scopyx and nowhere else
    Given a cluster that reads the web
    When the operator agent fetches a page and scopyx asks about the same fetch
    Then both pass
    And a static key that names the operator is refused
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the web grant denies scopyx's question"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the web grant lets a static key borrow the name"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the web grant is on every cluster"

  Scenario: Felyx and CostCrew get nothing
    Given two services that make model calls only
    Then neither has a grant
    # -> gates-have-teeth.sh "tool-hold-is-seeded: felyx gets a grant it does not need"

  Scenario: TOOL_HOLD=0 takes the block out and the cluster keeps that word
    Given a cluster with the hold on
    When a launcher runs with TOOL_HOLD=0
    Then the block and every grant it wrote are gone, and wardryx is restarted
    And the next run that says nothing leaves it off and asks nothing
    # -> gates-have-teeth.sh "tool-hold-is-seeded: TOOL_HOLD=0 leaves the block"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: TOOL_HOLD=0 keeps serving the block"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a cluster that said 0 is asked again"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a misspelt switch reaches the cluster"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a launcher takes no switch"

  Scenario: A second run changes nothing
    Given a cluster that carries the block
    When a launcher runs again
    Then the ConfigMap is what it was and wardryx is not restarted
    And a block that did change restarts wardryx
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the block moves on every run"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a changed block does not restart wardryx"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a comment that names the hold is not a fault"

  Scenario: A cluster with an ungranted caller stops the upgrade and applies nothing
    Given a cluster whose history holds a tool call of an agent outside the seeds
    When a launcher of this release runs on it
    Then the run stops before the first apply, with the agent, the tool, the count and when last
    And it says how to grant and how to set TOOL_HOLD=0
    And no floor is written, wardryx is not restarted, and the Job that asked is gone
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the replay check is gone"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the lib no longer asks"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the question comes after the apply"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the question leaves its Job behind"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the question leaves the seeds out"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the question leaves the starter policy out"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the Job can write the events it reads"

  Scenario: A history that could not be asked is not a clean one
    Given a cluster whose decisions could not be replayed, or a Job that left no report
    When a launcher of this release runs on it
    Then the run stops and says how much could not be asked
    # -> gates-have-teeth.sh "tool-hold-is-seeded: unexamined decisions read as nothing to hold"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a question nobody answered passes"

  Scenario: TOOL_HOLD=1 is the operator's word over the list
    Given a list that would stop the run
    When a launcher runs with TOOL_HOLD=1
    Then the hold goes on, and the run says so
    # -> gates-have-teeth.sh "tool-hold-is-seeded: TOOL_HOLD=1 does not answer the list"

  Scenario: Text a caller wrote is never printed to paste
    Given a recorded agent id that a shell would run
    Then the table shows it and no command names it
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a hostile id is printed to paste"

  Scenario: A grant made through the store is in the question
    Given a grant in wardryx's store
    When the launcher asks
    Then that agent is off the list
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the store is left out of the question"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: an empty store breaks the question"

  Scenario: An operator gives an agent a tool and the hold ends with no restart
    Given an agent whose tool call is held
    When the operator runs agent-allow with a reason
    Then the next call passes, wardryx did not restart, and policy_updated is on the record
    And the admin key was on no command line
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the admin key goes on a command line"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the console no longer holds the admin key"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: agent-allow goes on with no reason"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a second grant replaces the first"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a grant is written under a key wardryx refuses"

  Scenario: The widest grant says so
    When the operator runs agent-allow with all
    Then the command prints a warning
    # -> gates-have-teeth.sh "tool-hold-is-seeded: all gives no warning"

  Scenario: The pin is one pin
    Given the image the question runs and the image the manifests name
    Then they are one digest, of 2.6.0 or later
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the question runs another image"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the pin goes below 2.6.0"

  Scenario: A plain apply installs no floor
    Given nobody asked the cluster's history
    When the manifests are applied by hand
    Then wardryx starts without the ConfigMap, and no manifest carries the floor
    # -> gates-have-teeth.sh "tool-hold-is-seeded: the ConfigMap is required"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a plain apply installs the floor"

  Scenario: The gate refuses to report on nothing
    Given the block is gone from lib/tool-hold.sh
    Then the gate says it measured nothing
    And a scenario that names no case fails it
    # -> gates-have-teeth.sh "tool-hold-is-seeded: no block measured nothing"
    # -> gates-have-teeth.sh "tool-hold-is-seeded: a scenario names a case that is not there"

  Scenario: agent-list reads what the running wardryx loaded from its own start line
    Given wardryx 2.6.1 or later, which says the floors it loaded in its log and not on the bus
    When an operator runs agent-list, even with a start record an older wardryx left on the bus
    Then the line reads the running wardryx's start line, and the record on the bus decides nothing
    # -> gates-have-teeth.sh "tool-hold-is-seeded: what wardryx loaded is looked for under the 2.6.0 record"
