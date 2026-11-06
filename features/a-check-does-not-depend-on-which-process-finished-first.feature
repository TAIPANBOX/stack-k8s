# @measured 2026-11-06, forge: scripts/costcrew-ceiling-is-set.sh in stack-k8s at bbed808 failed 151 of 300
# runs beside four busy loops on a tree with nothing wrong in it, and it had failed teeth shard 4 on a pull
# request that carried only release notes (CI run 42179469254). This came from that defect and not from a
# request, so no decision is quoted. Scenarios are bound to cases in scripts/gates-have-teeth.sh by name.
Feature: a check says what the text holds, not which process finished first

  A gate reads a file, looks for a line, and reports a sentence about the tree. That sentence is
  worth reading only while it depends on the file. Under pipefail a pipe into grep -q also depends
  on which of two processes the machine ran first, so a busy runner turns a healthy tree red with
  a sentence that accuses it.

  Scenario: a gate pipes its text into grep -q again
    Given a gate looks for a line through a here-string
    When the here-string becomes printf into grep -q, or into grep --quiet
    Then no-reader-leaves-a-pipe-early.sh fails and names the file and the line
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: a gate pipes its text into grep -q again"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: a long option leaves as early as a short one"

  Scenario: the pipe is written where a line search would miss it
    Given a pipe into an early reader
    When it is carried over a line, sits in a substitution in quotes, or runs in a workflow step, or in a sourced library
    Then the gate still fails and names the place
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: the pipe is carried over a line"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: a substitution in quotes reads through the pipe"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: a workflow step reads through the pipe"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: a sourced library reads through the pipe"

  Scenario: the words appear where no pipe of this shell runs
    Given the words of the construct
    When they are in a comment, in a command handed to another shell, or in a here-document
    Then the gate passes, because nothing there is a pipe of this shell
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: the words are only in a comment"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: the words are a command handed to another shell"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: the words are in a here-document"

  Scenario: the two remedies stay legal
    Given a search that must not depend on a race
    When it uses a here-string, or a pipe into grep -c
    Then the gate passes
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: a here-string has no pipe to leave"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: grep -c reads to the end of a pipe"

  Scenario: the reader stops working
    Given a reader that has stopped matching reports what a clean tree reports
    When it forgets -q, stops reporting what it finds, or starts reading quoted text
    Then the gate fails on its own known lines before it reads a file
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: the reader stops knowing -q"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: the reader stops reporting what it finds"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: the reader starts reading quoted text"

  Scenario: the fault cannot be shown on this machine
    Given the control writes far more than a pipe holds into grep -q under pipefail
    When the writer is cut to three lines, which fit in one write
    Then the gate fails, because a control that does not break the pipe proves nothing
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: the control writes less than a pipe holds"

  Scenario: there is nothing to read
    Given the gate reads every tracked shell file and every workflow step
    When no shell file, no pipe or no step is read, or a quote left open loses its place
    Then the gate fails and says it measured nothing, and does not report a clean tree
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: no shell file is read"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: no pipe is read"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: no workflow step is read"
    # -> gates-have-teeth.sh "no-reader-leaves-a-pipe-early: a quote left open loses the reader its place"
