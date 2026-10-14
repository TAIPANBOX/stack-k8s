# @claude 2026-10-14: after a GCP run in which a reboot of a server hung for seven minutes in systemd-shutdown,
# with a process still writing to the shared volume after the network had gone. The installers give every node a
# kubelet shutdown period and a systemd-logind delay long enough to use it. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name; this repository has no runner and no binding gate, so the binding is by eye.
Feature: a node that is shut down stops its pods before its network goes

  A node that is rebooted or stopped gives its pods time to stop, and the kubelet stops them before the
  network is brought down. The installers set that up on every node before its k3s starts, and verify.sh
  does not count the pods a shutdown stopped.

  Scenario: an installer writes no shutdown period
    Given every installer writes the kubelet's shutdown period onto each node
    When the GCP installer stops writing it
    Then nodes-stop-their-pods-first.sh fails, because a reboot would leave the pods running
    # -> gates-have-teeth.sh "nodes-stop-their-pods-first: an installer writes no shutdown config"

  Scenario: systemd-logind waits less than the period
    Given the logind delay is longer than the kubelet's period
    When the delay is lowered to the systemd default
    Then nodes-stop-their-pods-first.sh fails, because systemd would stop waiting after 5 seconds
    # -> gates-have-teeth.sh "nodes-stop-their-pods-first: the logind delay is shorter than the period"

  Scenario: the first server gets no file
    Given the installers write the files onto a node just before its k3s starts
    When the first server's write is removed
    Then nodes-stop-their-pods-first.sh fails, because that node would reboot without the setting
    # -> gates-have-teeth.sh "nodes-stop-their-pods-first: the first server gets no file"

  Scenario: an install replaces the directory k3s reads
    Given no k3s install passes a kubelet config-dir of its own
    When an install passes one
    Then nodes-stop-their-pods-first.sh fails, because k3s's own directory would be replaced
    # -> gates-have-teeth.sh "nodes-stop-their-pods-first: an install passes its own config-dir"

  Scenario: workloads get less time than a pod may take
    Given our pods keep their 45 seconds before the critical pods' 15
    When the period is cut to 40 seconds
    Then nodes-stop-their-pods-first.sh fails, because a pod with the default 30 second grace would be cut short
    # -> gates-have-teeth.sh "nodes-stop-their-pods-first: workloads get less time than a pod may take"

  Scenario: verify.sh counts a pod a shutdown stopped
    Given verify.sh does not count a pod that a node shutdown stopped
    When it counts every Failed pod again
    Then nodes-stop-their-pods-first.sh fails and says the pod count did not report exactly one bad pod
    # -> gates-have-teeth.sh "nodes-stop-their-pods-first: verify.sh counts a pod a shutdown stopped"

  Scenario: no installer is left
    Given no tracked script installs k3s
    Then nodes-stop-their-pods-first.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "nodes-stop-their-pods-first: no installer is left to judge"
