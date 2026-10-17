# @decided 2026-10-17 (paraphrased): close the agent-security findings of the 2026-10-17 review,
# starting with the defaults; here, the gateway authenticates every caller and binds each key to the
# agent ids it may speak as, with keys a deploy mints when the operator brings none, as
# stack-single's installer does. Scenarios are bound to cases in scripts/gates-have-teeth.sh by
# name; this repository has no runner and no binding gate, so the binding is by eye.
Feature: the gateway needs a key, and a deploy mints one when nobody gave it any

  The gateway is the door every metered call goes through. Without client keys it admits anything
  the network lets in, and the agent id on a call is whatever the caller wrote, so one agent can
  speak as another. So the gateway does not start without its keys, its identity map is strict,
  and a deploy that was given no files mints a key for the console's copilot and one for the
  operator's agents, each bound to its own agent ids, and never rewrites either.

  Scenario: the gateway's keys become optional
    Given the gateway reads its client keys from a Secret that is not optional
    When the manifest marks the reference optional
    Then metered-doors-require-keys.sh fails, because a cluster with no Secret would answer anyone
    # -> gates-have-teeth.sh "metered-doors-require-keys: the gateway's client keys become optional"
    # -> gates-have-teeth.sh "metered-doors-require-keys: TOKENFUSE_CLIENT_KEYS goes missing"

  Scenario: the identity map stops being strict
    Given the gateway sets TOKENFUSE_IDENTITY_STRICT to enforce
    When it sets warn instead
    Then metered-doors-require-keys.sh fails, because a key speaking as another agent would only be noted
    # -> gates-have-teeth.sh "metered-doors-require-keys: a gateway's identity map is only warned about"

  Scenario: the console's copilot loses its key
    Given the console reads Felyx's key from the Secret the deploy mints for it
    When the manifest stops passing it
    Then metered-doors-require-keys.sh fails, because Felyx would be refused 401
    # -> gates-have-teeth.sh "metered-doors-require-keys: the console loses Felyx's key"

  Scenario: a deploy that was given no files mints the keys
    Given a cluster with no client keys and no map
    When the mint stops making the agents' key, or a deploy script stops calling the mint
    Then metered-doors-require-keys.sh fails
    # -> gates-have-teeth.sh "metered-doors-require-keys: the deploy stops minting the agents' key"
    # -> gates-have-teeth.sh "metered-doors-require-keys: a deploy script stops minting"

  Scenario: a re-run never rewrites a minted key
    Given a cluster whose keys a deploy minted
    When a re-run writes a new agents' key
    Then metered-doors-require-keys.sh fails, because every agent holding the old key would be refused
    # -> gates-have-teeth.sh "metered-doors-require-keys: a re-run writes a new agents' key"

  Scenario: the operator's own keys are left alone
    Given a cluster whose keys the operator wrote with identity/up.sh
    When the mint treats them as its own
    Then metered-doors-require-keys.sh fails
    # -> gates-have-teeth.sh "metered-doors-require-keys: the operator's own keys are minted over"

  Scenario: the agents' key cannot speak as the console's copilot
    Given the map binds the agents' key to the agents namespace
    When it is bound to every id in the trust domain
    Then metered-doors-require-keys.sh fails
    # -> gates-have-teeth.sh "metered-doors-require-keys: the agents' key may speak as Felyx"

  Scenario: the agents' key is the operator's alone
    Given the deploy writes the agents' key to a file on the operator's machine and says where
    When the file is readable by other accounts, the key rides a kubectl command line, the note prints the key, or the note stops naming the file
    Then metered-doors-require-keys.sh fails
    # -> gates-have-teeth.sh "metered-doors-require-keys: the agent key file is readable by others"
    # -> gates-have-teeth.sh "metered-doors-require-keys: a minted secret rides the kubectl command line"
    # -> gates-have-teeth.sh "metered-doors-require-keys: the closing note prints the agents' key"
    # -> gates-have-teeth.sh "metered-doors-require-keys: the closing note stops naming the key file"

  Scenario: a map with no keys is refused
    Given a cluster that holds a map and no client keys
    When the mint goes on anyway
    Then metered-doors-require-keys.sh fails, because a map's bindings would name keys nobody has
    # -> gates-have-teeth.sh "metered-doors-require-keys: a map with no keys is accepted"

  Scenario: the gateway itself accepts what the deploy mints
    Given the mint made two keys and a map
    When the pinned gateway image reads them before anything is applied
    Then it holds two keys and the map, and a map naming a key id nobody minted is refused
    # -> gates-have-teeth.sh "metered-doors-require-keys: the minted map binds a key id nobody minted"

  Scenario: identity/up.sh respects keys a deploy minted
    Given a cluster whose keys a deploy minted
    When an operator gives one file alone, or a run would leave the gateway no keys
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: a keys file alone takes over minted keys"
    # -> gates-have-teeth.sh "identity-files: up.sh leaves the gateway no keys"

  Scenario: a comment, and a gate with nothing to judge
    Given the gate passes on this tree
    When a comment in the mint library is reworded, or the gateway or the mint block is gone
    Then metered-doors-require-keys.sh passes on the comment and says it measured nothing otherwise
    # -> gates-have-teeth.sh "metered-doors-require-keys: a comment in the mint library is reworded"
    # -> gates-have-teeth.sh "metered-doors-require-keys: no gateway container left to judge"
    # -> gates-have-teeth.sh "metered-doors-require-keys: the mint block is gone"
