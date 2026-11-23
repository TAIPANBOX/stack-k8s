# @decided 2026-11-23 (paraphrased, the stack revision wave): the console image is built from its
# lockfile only, with no fallback to another package manager and with pnpm pinned by version.
# `@claude 2026-11-23`: pinned by the sha512 of its tarball as well, so corepack refuses another pnpm
# (CLAUDE.md invariant 93). Scenarios are bound to cases in scripts/gates-have-teeth.sh by name;
# scripts/features-are-bound.sh holds the binding.
Feature: the console's web assets are installed only from the lockfile, by one pinned pnpm

  A tag names one console. If the install can resolve versions afresh, the same tag names a
  different set of JavaScript dependencies from one build to the next.

  Scenario: the lockfile is missing from the checkout
    Given the console's web stage copies its lockfile
    When the lockfile is copied through a pattern that a missing file satisfies
    Then console-install-is-locked.sh fails, because a missing lockfile must stop the build
    # -> gates-have-teeth.sh "console-install-is-locked: the lockfile is copied through a glob again"

  Scenario: the frozen install is refused
    Given pnpm install --frozen-lockfile refuses a lockfile that does not match package.json
    When the install line falls back to npm install, or drops --frozen-lockfile
    Then console-install-is-locked.sh fails
    # -> gates-have-teeth.sh "console-install-is-locked: the install falls back to npm"
    # -> gates-have-teeth.sh "console-install-is-locked: the frozen install is dropped"

  Scenario: pnpm is whichever one corepack picks
    Given pnpm is activated by corepack prepare with a version and the sha512 of its tarball
    When the hash is dropped, or the prepare step is removed
    Then console-install-is-locked.sh fails
    # -> gates-have-teeth.sh "console-install-is-locked: pnpm is pinned by version alone"
    # -> gates-have-teeth.sh "console-install-is-locked: corepack takes whichever pnpm it likes"

  Scenario: nothing installs JavaScript
    Given the images under images/
    When no stage installs JavaScript packages
    Then the gate says it measured nothing and fails
    # -> gates-have-teeth.sh "console-install-is-locked: no stage installs JavaScript, which must say it measured nothing"

  Scenario: a comment is reworded
    Given the install line is unchanged
    When the comment beside it is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "console-install-is-locked: a comment reworded beside the install (must pass)"
