# @claude 2026-11-27: after the AWS run on the current Ubuntu 26.04 image, where Postgres could not signal its own processes
# under containerd's AppArmor profile and the bus owner could not list the shared volume. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name; scripts/features-are-bound.sh holds the binding.
Feature: every node can run the stack on the current Ubuntu kernel

  On the kernel 7.0 images a container's own processes must still be able to signal each other, and the shared
  volume must list. The installers give every node containerd's own AppArmor profile with the one fix upstream
  made for the stacked label, and an NFS client that does not ask for directory delegations, before k3s starts.
  A node that would still deny the signal stops the install.

  Scenario: the profile loses the stacked peer
    Given the profile lets a process signal a peer labelled cri-containerd.apparmor.d//&unconfined
    When that rule is removed
    Then nodes-fit-the-current-kernel.sh fails, because Postgres could not stop its own server again
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: the profile loses the stacked signal rule"

  Scenario: the profile is opened wider than the fix
    Given the profile adds the stacked peer and nothing else
    When it allows every stacked label
    Then nodes-fit-the-current-kernel.sh fails, because that is wider than containerd's own fix
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: the profile allows every stacked peer"

  Scenario: the profile stops being containerd's
    Given the profile keeps every rule of containerd's template
    When one of its deny rules is dropped
    Then nodes-fit-the-current-kernel.sh fails and names the lost rule
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: the profile drops one of containerd's denies"

  Scenario: the NFS client asks for directory delegations again
    Given every node sets directory_delegations=N for the nfsv4 client
    When the option says Y
    Then nodes-fit-the-current-kernel.sh fails, because the bus owner would get Remote I/O errors again
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: the NFS option leaves directory delegations on"

  Scenario: a node that still denies the signal goes on installing
    Given a node probes the signal in the fixed profile
    When a denied probe no longer stops the script
    Then nodes-fit-the-current-kernel.sh fails
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: a still-denied probe does not stop the install"
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: a node that fails the settings does not stop the install"

  Scenario: an installer or a node is left out
    Given all three installers give the settings to every node
    When one installer stops, or gives them to the servers only, or gives them after the first k3s install
    Then nodes-fit-the-current-kernel.sh fails and names the installer
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: an installer stops giving the nodes the settings"
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: the agents get no settings"
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: the settings come after the first k3s install"

  Scenario: a reworded comment
    Given the profile's comments say why each rule is there
    When a comment is reworded
    Then nodes-fit-the-current-kernel.sh still passes
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: a reworded comment is not a fault"

  Scenario: nothing is left to judge
    Given no library gives the nodes the settings
    Then nodes-fit-the-current-kernel.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "nodes-fit-the-current-kernel: no library is left to judge"

  Scenario: the current image on AWS
    Given a five-node cluster on the current Ubuntu 26.04.1 image
    When the stack is deployed with the installer
    Then every node shows the denial under containerd's profile as shipped and none under the fixed one, and every check passes
    # -> measured live on AWS 2026-11-27: cloud/aws/evidence/aws-run-2026-11-27-current-image/README.md
