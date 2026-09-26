# @measured 2026-09-26, k3d on forge (1 server + 2 agents, k3s v1.36.2, Calico v3.29.1),
# stack-k8s v1.1.10: `docker kill` of the node running the gateway left the gateway
# unreachable for 360 s and idryx for 347 s: 47 s to NotReady, then the default 300 s
# NoExecute toleration before either pod was evicted. The same cluster's rolling upgrade
# from v1.1.7 cost the gateway 0.8 s (3 refused probes) while the old pod stopped before
# its endpoint had left the Service. Evidence: go-to-market-2026-09/evidence/forge-k3d-2026-09-26/.
# There is no instruction behind this; it comes from the defect, stated here on purpose.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name.
Feature: a plane leaves a dead node in seconds, takes its volume with it, and drains before it stops

  Every Deployment here is one replica. A plane that holds no ReadWriteOnce
  claim (it rolls, rather than being recreated) can run on any node, so the
  only thing keeping it on a dead one is the toleration Kubernetes adds by
  default: 300 seconds of waiting before eviction. For the gateway that is
  five minutes in which every agent's call is refused. And a rolling update
  that stops the old pod the moment it is told to still sends it traffic for
  the fraction of a second the endpoint takes to leave the Service.

  Scenario: a rolling plane loses its short toleration for an unreachable node
    Given every Deployment that rolls tolerates an unreachable node for at most 60 seconds
    When one of them drops its node.kubernetes.io/unreachable toleration
    Then planes-leave-a-dead-node.sh fails and names the Deployment and the missing taint
    # -> gates-have-teeth.sh "planes-leave-a-dead-node: a rolling plane drops the unreachable toleration"

  Scenario: a rolling plane waits too long on a not-ready node
    Given every Deployment that rolls tolerates a not-ready node for at most 60 seconds
    When one of them raises that toleration to 300 seconds
    Then planes-leave-a-dead-node.sh fails and names the value it found
    # -> gates-have-teeth.sh "planes-leave-a-dead-node: a not-ready toleration above 60 seconds"

  Scenario: a serving container stops without draining
    Given every container that declares a port in a rolling Deployment sleeps before it stops
    When one of them loses its preStop sleep
    Then planes-leave-a-dead-node.sh fails and names the container
    # -> gates-have-teeth.sh "planes-leave-a-dead-node: a serving container loses its preStop sleep"

  Scenario: the policy store's StatefulSet waits the default on a dead node
    Given every Deployment and StatefulSet tolerates an unreachable node for at most 60 seconds
    When the policy-db StatefulSet drops its node.kubernetes.io/unreachable toleration
    Then planes-leave-a-dead-node.sh fails and names the StatefulSet
    # -> gates-have-teeth.sh "planes-leave-a-dead-node: a StatefulSet drops its unreachable toleration"

  Scenario: a plane recreated rather than rolled needs no drain
    Given a Deployment is recreated rather than rolled, so two of its pods never run at once
    When it has no preStop sleep
    Then planes-leave-a-dead-node.sh passes it, and still judges its tolerations
    # -> gates-have-teeth.sh "planes-leave-a-dead-node: a Recreate Deployment needs no preStop sleep"

  Scenario: no plane left to judge
    Given no Deployment or StatefulSet is left in what the kustomization includes
    When planes-leave-a-dead-node.sh runs
    Then it fails saying it measured nothing, never OK
    # -> gates-have-teeth.sh "planes-leave-a-dead-node: no Deployment or StatefulSet left to judge"

  Scenario: an installer leaves Longhorn holding a dead node's volumes
    Given every installer that applies Longhorn sets node-down-pod-deletion-policy to delete-both-statefulset-and-deployment-pod after it
    When one installer no longer patches the setting
    Then longhorn-releases-a-dead-node.sh fails and names the installer
    # -> gates-have-teeth.sh "longhorn-releases-a-dead-node: an installer never sets the policy"

  Scenario: an installer sets the policy to a value that does not release the volume
    Given every installer sets node-down-pod-deletion-policy after applying Longhorn
    When one of them sets it to do-nothing
    Then longhorn-releases-a-dead-node.sh fails and names the value it expected
    # -> gates-have-teeth.sh "longhorn-releases-a-dead-node: an installer sets the policy to the wrong value"

  Scenario: the confirmation line is reworded
    Given every installer sets the policy and prints a line saying so
    When that printed line is reworded
    Then longhorn-releases-a-dead-node.sh still passes, because it judges the patch, not the message
    # -> gates-have-teeth.sh "longhorn-releases-a-dead-node: the confirmation line reworded is not a fault"

  Scenario: no Longhorn installer left
    Given no tracked installer applies Longhorn any more
    When longhorn-releases-a-dead-node.sh runs
    Then it fails saying it measured nothing, never OK
    # -> gates-have-teeth.sh "longhorn-releases-a-dead-node: no Longhorn installer left"
