# @decided 2026-11-23 (paraphrased, the stack revision wave): `curl | bash` installs the latest
# release tag, and the tree it fetches is verified with a cosign-signed bundle; main only by an
# explicit flag. `@claude 2026-11-23`: the shape follows the stack-single installer's design
# (CLAUDE.md invariant 94). Scenarios are bound to cases in scripts/gates-have-teeth.sh by name;
# scripts/features-are-bound.sh holds the binding.
Feature: a piped deploy runs only a release tree whose signature verified

  Piped from curl, deploy.sh is a bootstrap. What runs is the tree of a release, verified by cosign
  for this repository's release workflow at that tag, or main when an operator asked for it by name.

  Scenario: the tree is verified before it is unpacked
    Given a release whose bundle cosign refuses
    When a piped deploy fetches it
    Then nothing is extracted and nothing runs
    # -> gates-have-teeth.sh "piped-tree: the tree is extracted before cosign verifies it"

  Scenario: only this repository's release workflow at that tag signs a tree
    Given the identity the deploy asks cosign for
    When it is widened to a pattern
    Then piped-tree-is-verified.sh fails, because a fork's workflow or another tag would match
    # -> gates-have-teeth.sh "piped-tree: the signer is widened to a regexp"

  Scenario: a refused tree does not fall back to main
    Given cosign refuses the release's tree
    When the bootstrap would take main instead
    Then piped-tree-is-verified.sh fails, because a refusal must stop the run
    # -> gates-have-teeth.sh "piped-tree: a refused tree falls back to main"

  Scenario: a signed tree of another tag is not run
    Given a signed tree whose RELEASE file names another tag
    When the deploy asked for this tag
    Then it refuses before the tree's deploy.sh runs
    # -> gates-have-teeth.sh "piped-tree: the RELEASE check is dropped"

  Scenario: verified bytes cannot write outside the tree
    Given a signed tarball with a member outside stack-k8s/
    When the bootstrap reads its listing
    Then it refuses before extraction
    # -> gates-have-teeth.sh "piped-tree: members outside the tree are let through"

  Scenario: the old way of naming main is refused, not ignored
    Given REF=main, which used to pick the tree
    When a piped deploy starts
    Then it refuses and names STACK_TAG and INSTALL_FROM_MAIN
    # -> gates-have-teeth.sh "piped-tree: REF is read again"

  Scenario: nothing tells an operator to pipe main
    Given the README's one-line deploy
    When it points at raw main again
    Then piped-tree-is-verified.sh fails
    # -> gates-have-teeth.sh "piped-tree: the README pipes main again"

  Scenario: the release workflow checks its own signature as a deploy will
    Given the workflow that signs the tree
    When it verifies against another identity than the one a deploy asks for
    Then piped-tree-is-verified.sh fails
    # -> gates-have-teeth.sh "piped-tree: the release workflow stops verifying its own signature"

  Scenario: the workflow's archive is the shape the bootstrap reads
    Given the release archive is built by release.yml's own git archive line
    When that line writes RELEASE at the archive's root instead of under stack-k8s/
    Then the bootstrap refuses the archive, and piped-tree-is-verified.sh fails
    # -> gates-have-teeth.sh "piped-tree: the release archive puts RELEASE at its root, where --add-virtual-file left it"

  Scenario: a piped run from inside a stale clone is still a signed run
    Given an operator pipes deploy.sh while standing in a directory that has a manifests/ folder
    When the bootstrap decides whether it was run from a checkout
    Then only a deploy.sh read from disk counts as a checkout, and the signed release is fetched
    # -> gates-have-teeth.sh "piped-tree: a piped run from a directory with manifests/ is taken for a checkout"

  Scenario: main runs its own launcher
    Given INSTALL_FROM_MAIN=1
    When main's tree is fetched
    Then main's own deploy.sh runs it, marked unsigned, and not the release's older launcher
    # -> gates-have-teeth.sh "piped-tree: main is driven by the release's launcher instead of its own"

  Scenario: a fetched tree never fetches another
    Given a tree the bootstrap fetched and ran
    When its deploy.sh finds no manifests/ beside it
    Then it stops instead of downloading again
    # -> gates-have-teeth.sh "piped-tree: a fetched tree can enter the bootstrap again"

  Scenario: only a tag on main is signed
    Given the signer identity names release.yml at the tag
    When a tag is pushed on a commit that is not on main
    Then the workflow refuses to sign it
    # -> gates-have-teeth.sh "piped-tree: the workflow signs a tag that is not on main"

  Scenario: no bootstrap at all
    Given deploy.sh without its bootstrap block
    When the gate runs
    Then it says it measured nothing and fails
    # -> gates-have-teeth.sh "piped-tree: the bootstrap block is gone, which must say it measured nothing"

  Scenario: a comment is reworded
    Given the bootstrap is unchanged
    When a comment in it is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "piped-tree: a comment reworded in the bootstrap (must pass)"
