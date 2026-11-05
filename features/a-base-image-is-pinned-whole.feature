# @claude 2026-11-05, from the estate register's G3.9: the console's TLS image compiled from a moving
# base with the DNS plugin at its latest, and nothing read a Dockerfile's FROM lines.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this
# repository has no runner and no binding gate, so the binding is by eye.
Feature: every image this repository builds from is pinned whole

  The manifests pin what a build produced. A rebuild of one tag still has to read
  the same inputs, or the file cannot say which Go compiled the binary.

  Scenario: a base moves again
    Given every FROM in images/ names a tag and a digest
    When a base loses its digest, or a new Dockerfile starts on a moving tag
    Then base-images-are-pinned.sh fails and names the line
    # -> gates-have-teeth.sh "base-images: a moving tag comes back on the runtime base"
    # -> gates-have-teeth.sh "base-images: a new Dockerfile on a moving tag, found by discovery"
    # -> gates-have-teeth.sh "base-images: the build frontend floats"

  Scenario: a Go bump moves the tag and not the digest
    Given a digest outranks the tag beside it
    When the tag says a new Go and the digest still holds the old one
    Then the gate fails, and the stage's own assertion stops the build
    # -> gates-have-teeth.sh "base-images: the tag moves and the digest and assertion stay"
    # -> gates-have-teeth.sh "base-images: a golang stage loses its assertion"

  Scenario: a Go advisory moves every image together
    Given the images compile with one Go
    When one image moves to another Go alone
    Then the gate fails and names both
    # -> gates-have-teeth.sh "base-images: one image moves to another Go alone"

  Scenario: the TLS image takes something at its latest
    Given xcaddy compiles a named Caddy with a named plugin
    When either loses its version, or the runtime base moves without the build
    Then the gate fails
    # -> gates-have-teeth.sh "base-images: xcaddy loses Caddy's version"
    # -> gates-have-teeth.sh "base-images: the DNS plugin loses its version"
    # -> gates-have-teeth.sh "base-images: the runtime base moves without the build"

  Scenario: there is nothing left to judge
    Given the gate finds its Dockerfiles by discovery
    When none is left, or no xcaddy build is
    Then it says it measured nothing and fails, never OK
    # -> gates-have-teeth.sh "base-images: every Dockerfile is gone, which must say it measured nothing"
    # -> gates-have-teeth.sh "base-images: no xcaddy build is left, which must say it measured nothing"
