# @claude 2026-10-14: the cost report must never under-report. A running machine type with no
# published rate stops the report with a non-zero exit that names the type, in both clouds, and a
# type that has a rate still prices. CLAUDE.md invariant 44; GOTCHAS 127. Scenarios are bound to
# cases in scripts/gates-have-teeth.sh by name; this repository has no runner and no binding gate,
# so the binding is by eye.
Feature: a cost report refuses a machine type it has no rate for

  A cost report that counts an unpriced machine as nothing prints a calm total under the real
  one. The report has to say which type it could not price, and print no total.

  Scenario: an AWS instance type with no rate stops the report
    Given a running instance of a type the AWS report has no rate for
    When the AWS cost report runs
    Then it exits non-zero, names the type, and prints no total
    # -> gates-have-teeth.sh "cost-live-refuses-unknown-rates: the AWS script counts an unknown type as zero"

  Scenario: a GCP machine type with no rate stops the report
    Given a running machine of a type the GCP report has no rate for
    When the GCP cost report runs
    Then it exits non-zero, names the type, and prints no total
    # -> gates-have-teeth.sh "cost-live-refuses-unknown-rates: the GCP script counts an unknown type as zero"

  Scenario: a type with a rate still prices
    Given a running m7i.xlarge instance
    When the AWS cost report runs
    Then it exits zero and prints the total at the table rate of 0.2415 USD/hour
    # -> gates-have-teeth.sh "cost-live-refuses-unknown-rates: the m7i.xlarge row is removed"
