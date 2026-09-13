# @decided 2026-09-13, from the first fresh GCP cluster after the manifests
# started reading a Secret key that two of the three installers never wrote.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this
# repository has no runner and no binding gate yet, so the binding is by eye.
Feature: every installer creates every Secret key the manifests read

  A fresh cluster on any cloud must come up with the same planes as the Hetzner
  one. Three installers each carry a copy of the block that generates the
  stack-keys Secret, and a key added to one copy and not the others leaves the
  gateway and the console unable to start on the clouds that missed it.

  Scenario: an installer stops creating a key the manifests read
    Given the manifests read gateway_admin from the stack-keys Secret
    When one installer's create block loses --from-literal=gateway_admin
    Then secret-keys-agree.sh fails and names the installer, the Secret and the key
    # -> gates-have-teeth.sh "secret-keys-agree: an installer stops creating a key the manifests read"

  Scenario: a manifest starts reading a key no installer writes
    Given every installer creates the six keys of stack-keys
    When a manifest starts reading gateway_admin_v2 from stack-keys
    Then secret-keys-agree.sh fails and names the key nobody writes
    # -> gates-have-teeth.sh "secret-keys-agree: a manifest starts reading a key no installer writes"

  Scenario: a key an installer writes that nothing reads is not this gate's business
    Given every manifest key is created by every installer
    When an installer additionally creates a key no manifest reads
    Then secret-keys-agree.sh passes
    # -> gates-have-teeth.sh "secret-keys-agree: an installer writes a key nothing reads"

  Scenario: no installer left to judge
    Given every script that creates a Secret the manifests read is removed
    When secret-keys-agree.sh runs
    Then it fails saying it measured nothing, never OK
    # -> gates-have-teeth.sh "secret-keys-agree: no installer left to judge"

  Scenario: the placeholder trust domain is red where the operator looks
    Given a cluster deployed without --trust-domain
    When verify.sh runs
    Then it fails on TRAILRYX_TRUST_DOMAIN being set-me.invalid
    # -> measured live on GCP 2026-09-13: evidence/1.0/r2-gcp-2026-09-13/ins-6-verify-red-on-placeholder.log
    # in go-to-market-2026-09 (private); not a repository test, invariants 4 and 5 say why
