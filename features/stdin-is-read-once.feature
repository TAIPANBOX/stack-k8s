# Scenarios are bound to scripts/stdin-is-read-once.sh and to its cases in gates-have-teeth.sh.
Feature: a command fed on stdin over ssh reads that stdin once

  The installers send the cluster token and the k3s install script to a node on stdin. Anything
  else that reads the same stdin first leaves the node with nothing to install.

  Scenario: the agent's name is read before the token and the script are sent
    Given an installer that joins k3s agents
    When it builds the command it sends to a node on stdin
    Then nothing in that command runs another ssh to the node
    # -> gates-have-teeth.sh "stdin-is-read-once: the GCP agent name is read inside the pipeline again"

  Scenario: an agent that never registers stops the deploy
    Given an installer that joins k3s agents
    When an agent has not registered with the cluster after the wait
    Then the deploy stops and says the agent did not register
    # -> gates-have-teeth.sh "stdin-is-read-once: the AWS installer no longer stops on an agent that never registers"
