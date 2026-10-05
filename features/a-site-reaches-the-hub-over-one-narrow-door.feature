# @measured 2026-09-26 on GCP (N2/G2): one hub (three e2-standard-2 nodes,
# europe-west4-a) and one remote site (a k3d cluster at home), reached over
# manifests/53-hub-entry.yaml with no VPN. Local allowlist test (Caddy plus
# the manifest's own security context, two stub planes, no cloud): 17 of 17
# outcomes as intended. From the public internet against the live entry: 12
# of 12 (the three polls and decide 200, no key 401, the console and every
# non-routed path 404, plain HTTP 308 to HTTPS). The capability trap: the
# first apply refused the exec itself, "operation not permitted", because the
# official Caddy image's binary carries a file capability that `drop: [ALL]`
# alone cannot satisfy (GOTCHAS 110). The LoadBalancer Service is created by
# Kubernetes, not Terraform, and bills hourly the moment it exists (GOTCHAS
# 111). The product choice behind the entry is `@decided 2026-09-26`:
# customers will not install a VPN to use this stack, so a remote site reaches
# the hub over one public HTTPS entry. The scenarios below describe the gate
# that keeps that entry narrow; they come from the lab run and its evidence,
# not from the wording of that decision. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name.
Feature: a site reaches the hub over one narrow public door, and nothing else is reachable through it

  A customer with several sites runs one hub and a gateway at each site. A
  site reaches the hub by outbound HTTPS to manifests/53-hub-entry.yaml's one
  public address, authenticated by the planes' own keys; everything else,
  the console included, stays inside the cluster. The Caddyfile embedded in
  that manifest is the one place this promise can be checked without a
  cluster: it names exactly eight routes, and every other path a caller
  might try answers 404. @decided 2026-10-05: the eighth is the site-scoped
  run seed, GET /v1/run-spend, and the org-wide GET /v1/runs stays closed.

  Scenario: a route is added
    Given the Caddyfile routes exactly cloud's six paths and wardryx's two
    When a path is added to one of the allowed matchers
    Then hub-entry-is-narrow.sh fails and names the route beyond the allowed eight
    # -> gates-have-teeth.sh "hub-entry-is-narrow: a route is added"

  Scenario: the site run-spend route is dropped
    Given a remote site's gateway seeds its runs' spend at startup through GET /v1/run-spend
    When that path is removed from the cloud site's allowed matchers
    Then hub-entry-is-narrow.sh fails and names the missing run-spend route
    # -> gates-have-teeth.sh "hub-entry-is-narrow: the site run-spend route is dropped"

  Scenario: a route's method widens
    Given every routed matcher pairs one HTTP method with its paths
    When a matcher's method changes to one wider than the route needs
    Then hub-entry-is-narrow.sh fails and names both the route that vanished and the one that appeared in its place
    # -> gates-have-teeth.sh "hub-entry-is-narrow: a route's method widens"

  Scenario: the catch-all is removed
    Given every site block ends in a catch-all that answers 404 to anything the matchers above it did not claim
    When a site's catch-all is removed
    Then hub-entry-is-narrow.sh fails and says no catch-all was found
    # -> gates-have-teeth.sh "hub-entry-is-narrow: the catch-all is removed"

  Scenario: a capability is added
    Given the hub-ingress container drops every capability and adds back only NET_BIND_SERVICE
    When a second capability is added
    Then hub-entry-is-narrow.sh fails and names the capability that should not be there
    # -> gates-have-teeth.sh "hub-entry-is-narrow: a capability is added"

  Scenario: the file joins the default apply
    Given manifests/53-hub-entry.yaml is opt-in, applied only by hub/up.sh
    When it is added to manifests/kustomization.yaml's resources
    Then hub-entry-is-narrow.sh fails and says it is listed in the kustomization
    # -> gates-have-teeth.sh "hub-entry-is-narrow: the file joins the default apply"

  Scenario: a comment line in the Caddyfile is not a fault
    Given the Caddyfile may carry ordinary comments
    When a comment line is added beside a site block
    Then hub-entry-is-narrow.sh still passes, because it judges the routes, not the prose beside them
    # -> gates-have-teeth.sh "hub-entry-is-narrow: a comment line in the Caddyfile is not a fault"

  Scenario: the file is removed
    Given manifests/53-hub-entry.yaml is the one subject this gate reads
    When the file is removed entirely
    Then hub-entry-is-narrow.sh fails saying it measured nothing, never OK
    # -> gates-have-teeth.sh "hub-entry-is-narrow: the file is removed"
