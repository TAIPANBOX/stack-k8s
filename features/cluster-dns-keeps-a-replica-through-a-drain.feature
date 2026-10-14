# @claude 2026-10-14: after a GCP run in which a stopped node took one of two coredns replicas
# with it. The installers give cluster DNS a disruption budget of their own and leave k3s's
# coredns Deployment to k3s. Scenarios are bound to cases in scripts/gates-have-teeth.sh by name;
# this repository has no runner and no binding gate, so the binding is by eye.
Feature: cluster DNS keeps a replica through a drain, and k3s's own coredns is left to k3s

  Every pod in the cluster resolves names through coredns. The installers run two replicas on
  two to four nodes and three from five nodes, and give them a budget, so draining nodes for maintenance always leaves one
  answering. They change nothing in the Deployment k3s ships beyond its replica count, because
  k3s puts its own manifest back.

  Scenario: a five-node cluster runs two replicas
    Given the installers ask for three coredns replicas from five nodes
    When the installers ask for two at every size
    Then cluster-dns-has-a-budget.sh fails, because the replica policy is not the one it holds
    # -> gates-have-teeth.sh "cluster-dns-has-a-budget: five nodes get two replicas"

  Scenario: an installer gives coredns no budget
    Given every installer applies a disruption budget for coredns
    When the GCP installer stops applying it
    Then cluster-dns-has-a-budget.sh fails, because a drain of two nodes would take every replica
    # -> gates-have-teeth.sh "cluster-dns-has-a-budget: an installer applies no budget"

  Scenario: the budget keeps nothing up
    Given the budget keeps at least one replica available
    When it is lowered to zero
    Then cluster-dns-has-a-budget.sh fails and shows the document it found
    # -> gates-have-teeth.sh "cluster-dns-has-a-budget: the budget keeps nothing up"

  Scenario: the budget covers other pods
    Given the budget selects the coredns pods by their k8s-app label
    When the AWS installer's budget selects another label
    Then cluster-dns-has-a-budget.sh fails and shows the document it found
    # -> gates-have-teeth.sh "cluster-dns-has-a-budget: the budget selects other pods"

  Scenario: a single-node cluster gets a budget it can never satisfy
    Given the budget is applied only when there are two replicas or more
    When install.sh applies it whatever the count
    Then cluster-dns-has-a-budget.sh fails, because one replica and a budget of one block every drain
    # -> gates-have-teeth.sh "cluster-dns-has-a-budget: the budget is applied with one replica too"

  Scenario: an installer edits the Deployment k3s owns
    Given the installers change k3s's coredns only by scaling it
    When the GCP installer patches the coredns Deployment
    Then cluster-dns-has-a-budget.sh fails, because k3s would put its manifest back
    # -> gates-have-teeth.sh "cluster-dns-has-a-budget: an installer patches k3s's coredns Deployment"

  Scenario: a comment that mentions patching coredns changes nothing
    Given a comment in an installer says not to patch the coredns Deployment
    Then cluster-dns-has-a-budget.sh still passes
    # -> gates-have-teeth.sh "cluster-dns-has-a-budget: a comment about patching coredns is not a fault"

  Scenario: the running cluster is no longer checked
    Given verify.sh checks the budget on a cluster of more than one node
    When it stops reading the budget
    Then cluster-dns-has-a-budget.sh fails and says a cluster without one would pass
    # -> gates-have-teeth.sh "cluster-dns-has-a-budget: verify.sh stops checking the budget"

  Scenario: no installer is left
    Given no tracked script installs a k3s server
    Then cluster-dns-has-a-budget.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "cluster-dns-has-a-budget: no installer is left to judge"
