# @decided 2026-09-13, from the second AWS deploy of the R2 proving run, which
# killed the first server because one of three installers minted a fresh k3s
# token on every run. Scenarios are bound to cases in scripts/gates-have-teeth.sh
# by name; this repository has no runner and no binding gate yet.
Feature: every installer reuses the cluster's token on a second run

  The second run is the real test. An installer that mints a new k3s token on
  every run is correct exactly once (GOTCHAS 59): run two rewrites the first
  server's service environment with a token its datastore was not encrypted
  with, and that server refuses to start while the rest of the cluster keeps
  quorum and looks healthy from anywhere but the operator's kubeconfig.

  Scenario: the second run reuses the token the cluster was created with
    Given a k3s cluster this installer brought up
    When the installer runs a second time over it
    Then it reads the token from the first server before installing, and the first server stays up
    # -> gates-have-teeth.sh "k3s-token-is-reused: an installer stops reading the cluster's token"
    # -> measured live on AWS 2026-09-13: evidence/1.0/r2-aws-2026-09-13/logs/deploy-4.log (go-to-market-2026-09, private)

  Scenario: a read placed after the install reads a rewritten file
    Given an installer that reads the token
    When the read sits below the first-server install, on one line or wrapped over two
    Then k3s-token-is-reused.sh fails naming both line numbers
    # -> gates-have-teeth.sh "k3s-token-is-reused: the token is read after the install rewrote it",
    #    "k3s-token-is-reused: a wrapped first-server install hides a read placed after it"

  Scenario: a read over a helper that cannot read the file is no read
    Given the token file is root-owned, mode 0600
    When the installer reads it over the login helper instead of the sudo helper
    Then k3s-token-is-reused.sh fails naming both helpers
    # -> gates-have-teeth.sh "k3s-token-is-reused: the token is read over a helper that cannot read it"

  Scenario: a comment naming the install phrase is not an installer
    Given a script whose only mention of the k3s server install is a comment
    When k3s-token-is-reused.sh runs
    Then the script is not judged
    # -> gates-have-teeth.sh "k3s-token-is-reused: a comment mentioning the install is not an installer"

  Scenario: no installer left to judge
    Given every installer is removed
    When k3s-token-is-reused.sh runs
    Then it fails saying it measured nothing, never OK
    # -> gates-have-teeth.sh "k3s-token-is-reused: no installer left to judge"
