# @decided 2026-10-19 (paraphrased): the launchers verify a node's SSH host key before they
# connect, instead of accepting whatever the first connection offered (finding F-029).
# Scenarios are bound to scripts/hostkeys-are-verified.sh cases and to gates-have-teeth.sh.
Feature: a node's host key is verified before the first connection

  A recycled address can hand a new machine to a host the operator never pinned. The cloud
  already knows the node's keys, so the launcher reads them from there first.

  Scenario: AWS keys that match the console are accepted
    Given a node whose console printed its fingerprints at boot
    When the installer keyscans the node and the fingerprints are the same
    Then the keys are written to the per-run known_hosts and a strict connection succeeds
    # -> hostkeys-are-verified.sh case A

  Scenario: a different key is refused, and nothing is written
    Given a node that presents a key its console did not print
    When the installer compares the two
    Then it refuses at once, names the node, writes nothing, and the strict connection is refused
    # -> hostkeys-are-verified.sh case B

  Scenario: a console with no fingerprints times out with the reason
    Given an instance whose console never printed the fingerprint block
    When the deadline passes
    Then the installer refuses and says the block was not printed, and connects to nothing
    # -> hostkeys-are-verified.sh case C

  Scenario: GCE keys come from the guest attributes through the API
    Given a GCE instance whose guest agent published its host keys
    When the installer reads the guest attributes
    Then the keys are written and a strict connection succeeds
    # -> hostkeys-are-verified.sh case E

  Scenario: GCE guest attributes that never appear are refused with the reason
    Given a GCE instance with no published host keys
    When the deadline passes
    Then the installer refuses and says so, and connects to nothing
    # -> hostkeys-are-verified.sh case F

  Scenario: install.sh pins to an operator file when SSH_KNOWN_HOSTS is set
    Given an operator who sets SSH_KNOWN_HOSTS to a file of host keys
    When install.sh makes its first connection
    Then the connection is strict against that file
    # -> hostkeys-are-verified.sh case G
    # -> gates-have-teeth.sh "hostkeys-are-verified: SSH_KNOWN_HOSTS is ignored by install.sh"

  Scenario: without SSH_KNOWN_HOSTS nothing is refused, and the pin is printed
    Given an existing invocation that does not set SSH_KNOWN_HOSTS
    When install.sh runs
    Then the first connection is accepted as before, and each accepted key is printed with how to pin it
    # -> hostkeys-are-verified.sh case G

  Scenario: no launcher accepts a host key on first use
    Given the cloud installers and deploy scripts
    When the gate reads them
    Then none uses accept-new, and each takes its keys before the first connection
    # -> hostkeys-are-verified.sh case H
    # -> gates-have-teeth.sh "hostkeys-are-verified: a cloud launcher goes back to accept-new"

  Scenario: a gate with no installer says so
    Given no cloud installer in the tree
    When hostkeys-are-verified.sh runs
    Then it reports that it measured nothing and does not say OK
    # -> gates-have-teeth.sh "hostkeys-are-verified: no cloud installer left, measured nothing"

  Scenario: the builder checks its peers before it pushes an image
    Given a cloud cluster whose builder pushes each image to its peers over the private network
    When the builder connects to a peer at its private address
    Then the connection is strict against a peer file the launcher wrote over its verified connection, naming each peer by its public and its private address
    # -> hostkeys-are-verified.sh case I
    # -> hostkeys-are-verified.sh case J
    # -> hostkeys-are-verified.sh case L
    # -> gates-have-teeth.sh "hostkeys-are-verified: the peer file is written after the first node-to-node ssh"
    # -> gates-have-teeth.sh "hostkeys-are-verified: the peer file drops the private names"

  Scenario: no tracked script turns host key checking off
    Given every tracked script in the repository
    When hostkeys-are-verified.sh reads them
    Then none carries the option that disables host key checking, and the prose that names it is left alone
    # -> hostkeys-are-verified.sh case K
    # -> gates-have-teeth.sh "hostkeys-are-verified: a node-to-node ssh goes back to host key checking off"
    # -> gates-have-teeth.sh "hostkeys-are-verified: a helper names the forbidden option in a comment"
    # -> gates-have-teeth.sh "hostkeys-are-verified: the option named in a prose note is not a script (must pass)"
