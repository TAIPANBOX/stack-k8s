# @claude 2026-11-08: the browser on a cluster keeps Chromium's own sandbox and runs the same
# syscall filter stack-single runs, under Pod Security restricted (CLAUDE.md invariant 84).
# Each scenario is bound by name to a case in scripts/gates-have-teeth.sh, and
# scripts/browser-keeps-its-sandbox.sh holds that binding both ways. The live half is
# evidence/browser-sandbox-k3s/run.sh, run by .github/workflows/browser-sandbox.yml.
Feature: The browser keeps its own sandbox on a cluster

  A page the browser renders is written by whoever owns the site. Chromium's renderer sandbox is
  what stands between that page and the pod, and on a cluster it stays on: the browser runs under
  the filter stack-single runs, delivered to every node by the installer, and nothing in the
  cluster's own configuration turns the sandbox off.

  Scenario: The browser renders a page with Chromium's sandbox on
    Given a cluster installed by any of the three installers
    When the browser's manifest is applied and an agent reads a page through it
    Then the renderer runs in a user and a PID namespace of its own, under Chromium's own filter
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: the sandbox is turned off again"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: the browser falls back to the runtime's filter"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: a recorded run failed"

  Scenario: A comment that names the switch is not the switch
    Given the manifest explains, in a comment, what the old switch did
    Then nothing is reported
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: a comment naming the switch"

  Scenario: The filter is the one stack-single runs, in the form a node reads
    Given stack-single's profile for the browser
    When a node loads it
    Then the node applies Docker's default plus chroot, clone into a user, pid and net namespace, and unshare into a user namespace, and nothing wider
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: the node file is Docker's format"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: clone loses its mask"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: stack-single's file differs"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: the profile changes and keeps its name"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: mount is allowed without a condition"

  Scenario: Every node has the profile before anything can be scheduled on it
    Given an installer bringing up servers and agents
    Then each node receives the profile, before k3s starts there, at the path the manifest names
    And an installer that cannot write it stops
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: an installer leaves its agents without the profile"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: an installer writes the profile after k3s starts"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: an installer goes on when the write fails"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: the nodes are sent Docker's file"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: the profile lands outside the kubelet's directory"
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: the manifest names a profile nobody writes"

  Scenario: A node without the profile never runs the browser without a filter
    Given a node the profile never reached
    When the browser is scheduled there
    Then its container is not created, and the pod says which profile it could not load
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: the browser is left unconfined"

  Scenario: There is a browser to judge
    Given no manifest runs the browser image
    Then the check says it measured nothing
    # -> gates-have-teeth.sh "browser-keeps-its-sandbox: no manifest runs the browser"
