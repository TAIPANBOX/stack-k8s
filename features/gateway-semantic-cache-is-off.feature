# @decided 2026-09-24, from a measured overload run on a 4-core appliance.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this
# repository has no runner and no binding gate yet, so the binding is by eye.
Feature: the gateway's semantic cache is off in every install

  The gateway's semantic response cache defaults to shadow mode whenever its
  env var is unset: every call takes one global mutex, walks up to 10,000
  cached entries computing cosine similarity, serves nothing, and appends
  another entry. Measured on a 4-core N150 appliance: 50 agents gave
  177 calls/s with 403 refusals and CPU 79-92% inside the cache's own lookup;
  with the cache explicitly off the same load gave 1102 calls/s, zero
  refusals, no slowdown over time.

  Scenario: a gateway container loses TOKENFUSE_CACHE
    Given every tokenfuse gateway container sets TOKENFUSE_CACHE to off
    When one gateway container's env list drops TOKENFUSE_CACHE
    Then gateway-cache-is-off.sh fails and names the manifest, the container and the missing variable
    # -> gates-have-teeth.sh "gateway-cache-is-off: a gateway container loses TOKENFUSE_CACHE"

  Scenario: a gateway container sets the variable to something other than off
    Given every tokenfuse gateway container sets TOKENFUSE_CACHE to off
    When one gateway container's TOKENFUSE_CACHE is changed to "on"
    Then gateway-cache-is-off.sh fails and names the value it found instead of off
    # -> gates-have-teeth.sh "gateway-cache-is-off: a gateway container sets TOKENFUSE_CACHE to something other than off"

  Scenario: a sidecar running a subcommand is not this gate's business
    Given a sidecar container runs the gateway image with a subcommand, not the bare binary
    When gateway-cache-is-off.sh runs
    Then that sidecar is not judged, because a subcommand never reaches the semantic cache
    # -> gates-have-teeth.sh "gateway-cache-is-off: a subcommand sidecar is not a gateway container"

  Scenario: no gateway container left to judge
    Given every container running the tokenfuse gateway image in serve mode is removed
    When gateway-cache-is-off.sh runs
    Then it fails saying it measured nothing, never OK
    # -> gates-have-teeth.sh "gateway-cache-is-off: no gateway container left to judge"
