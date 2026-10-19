# @decided 2026-10-19 (paraphrased): the cloud installers keep their secrets off the command
# line. The 2026-10-17 security review found the plane credentials, the Hetzner token, the
# console bearer and a token in a git clone URL on ssh and process argv (findings F-015).
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, checked by eye.
Feature: a secret never appears on a command line

  A process's arguments are readable by every user on both ends of an ssh, for as long as
  the process runs. A secret goes in on stdin, or in a file the reader opens.

  Scenario: a Secret is created from a manifest on stdin, not from --from-literal
    Given an installer that creates the stack-keys Secret
    When it builds the Secret
    Then every value travels in a manifest on stdin and no value is an argument
    # -> gates-have-teeth.sh "no-secret-on-argv: an installer puts a plane credential on argv with --from-literal"

  Scenario: a node's k3s token reaches the node on stdin
    Given an installer that starts a k3s server
    When it passes the cluster token to the node
    Then the token is the first line of stdin, read by the node's shell, and not a word of the command
    # -> gates-have-teeth.sh "no-secret-on-argv: the k3s token is assigned on the ssh command line"

  Scenario: a console bearer reaches curl on stdin
    Given a launcher that calls the GitHub API with the console token
    When it sends the Authorization header
    Then curl reads the header from stdin with --config, and the bearer is in no argument
    # -> gates-have-teeth.sh "no-secret-on-argv: a bearer header is built from an expansion"

  Scenario: a token never goes into a clone URL
    Given a launcher that clones the console repository with a token
    When it clones
    Then git reads the token through a credential helper, and the URL names no credential
    # -> gates-have-teeth.sh "no-secret-on-argv: a clone URL carries the token"

  Scenario: the gate has teeth
    Given a planted secret passed as a flag value
    When no-secret-on-argv.sh runs
    Then it exits non-zero and names the file and the line
    # -> gates-have-teeth.sh "no-secret-on-argv: a secret passed as a flag value"

  Scenario: a secret built as a shell function argument is not on argv
    Given a line that calls secret_doc, which pipes each value's base64 on a builtin's stdin
    When no-secret-on-argv.sh judges it
    Then the line passes, because no process receives the value
    # -> gates-have-teeth.sh "no-secret-on-argv: a secret_doc argument is not a process argument (must pass)"

  Scenario: a gate with no subject says so
    Given no tracked shell script outside scripts/
    When no-secret-on-argv.sh runs
    Then it reports that it measured nothing and does not say OK
    # -> gates-have-teeth.sh "no-secret-on-argv: no subject, measured nothing"
