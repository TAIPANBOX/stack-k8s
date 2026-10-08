# @claude 2026-10-08, from the request that followed the costcrew v0.4.0 pin:
# the console and its crew keep a read-only root, and gain a small, size-limited
# writable temp so SQLite can VACUUM. GOTCHAS 120 is what the pin found.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this
# repository has no runner and no binding gate, so the binding is by eye.
Feature: a read-only container that needs a temp directory has one

  SQLite writes a VACUUM's working copy and a big sort to a temp file. With a
  read-only root and nothing writable to put it in, it fails with disk I/O
  error (6410), and the costcrew session migration then leaves the old tokens'
  bytes in the file.

  Scenario: the console or the crew runner loses its temp
    Given both pods that open the costcrew store run with a read-only root
    When either container no longer mounts anything writable at /tmp
    Then read-only-root-has-a-temp.sh fails and names the container
    # -> gates-have-teeth.sh "temp: the console loses its /tmp mount"
    # -> gates-have-teeth.sh "temp: the crew runner loses its /tmp mount"

  Scenario: the temp is unbounded or not writable
    Given the temp is an emptyDir mounted at /tmp
    When it loses its sizeLimit, or the mount becomes readOnly
    Then read-only-root-has-a-temp.sh fails
    # -> gates-have-teeth.sh "temp: the console's temp loses its sizeLimit"
    # -> gates-have-teeth.sh "temp: the console's temp is mounted read-only"

  Scenario: there is nothing left to judge
    Given the gate judges containers by their image
    When no manifest runs an image that needs a temp
    Then it says it measured nothing and fails, never OK
    # -> gates-have-teeth.sh "temp: no container left that needs a temp"

  Scenario: a TMPDIR inside the data volume, or another size, is still a writable temp
    Given the property is a writable, bounded temp, not one literal path
    When TMPDIR points inside a read-write mount, or the sizeLimit changes
    Then read-only-root-has-a-temp.sh still passes
    # -> gates-have-teeth.sh "temp: TMPDIR inside the data volume instead of a /tmp mount"
    # -> gates-have-teeth.sh "temp: the temp size changes"
