# @decided 2026-10-18 (paraphrased): the cluster admits only images whose signature verifies,
# through the Sigstore policy-controller. The controller is opt-in (policy/up.sh), installed from
# a pinned release, and its namespace opts in last (--enforce). Every TAIPANBOX image is meant to
# be signed keyless by its own release workflow, so the policy names that signer; a third-party
# image is admitted only when it is pinned by digest and listed with a reason.
#
# @claude 2026-10-19: BLOCKED for enforcement. policy-controller v0.15.1 finds no signature on any
# TAIPANBOX image as published (the bundle sits only at the OCI fallback tag), so an opted-in
# namespace refuses every TAIPANBOX image. The scenarios below that say "admitted" for a TAIPANBOX
# image are the target, not what holds today; evidence/verified-images-kind/run.sh measures both.
# Each scenario is bound to a case in scripts/gates-have-teeth.sh, or to the kind run.
Feature: the cluster admits only images whose signature verifies

  Scenario: an unsigned TAIPANBOX image is refused once the namespace is opted in
    Given policy/up.sh --enforce has opted the stack's namespace in
    When a pod names a TAIPANBOX image with no signature the controller can read
    Then the admission is refused, measured on kind by evidence/verified-images-kind/run.sh
    # -> gates-have-teeth.sh "verified-images: the keyless policy turns to warn" (the gate holds enforce)

  Scenario: a signed TAIPANBOX image from its release workflow is admitted (target, blocked today)
    Given the policy names the release workflow of a TAIPANBOX repository as its only signer
    When a pod names an image that workflow signed on a version tag, and the controller can read the signature
    Then the admission is allowed; today the controller reads no such signature, so this is refused
    # -> gates-have-teeth.sh "verified-images: the subject expression accepts any repository"

  Scenario: a keyless signature the controller can read is admitted when its signer matches
    Given a legacy keyless signature (cosign v2.4.0) and a policy that names its signer
    When the pod names that image
    Then the admission is allowed, and the same image is refused under a wrong issuer
    # -> evidence/verified-images-kind/run.sh step 3 (measured on kind, not a teeth case)

  Scenario: a signature from another repository or a branch is not a release of TAIPANBOX
    Given the subject expression is run against identities the registry actually holds
    When the expression accepts an identity from a fork or from a branch build
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: the subject expression accepts a fork's release"

  Scenario: the policy checks the issuer of the signing identity
    Given a keyless signature is only as good as the identity provider that issued it
    When the issuer is widened to a provider that is not GitHub Actions
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: the issuer is widened"

  Scenario: the policy enforces rather than warns
    Given a warning admits the image and writes a line nobody reads
    When the mode of the TAIPANBOX policy is changed to warn
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: the keyless policy turns to warn"

  Scenario: every TAIPANBOX image is pinned by digest
    Given a tag moves when its image is pushed again
    When a manifest names a TAIPANBOX image by tag alone
    Then verified-images-are-enforced.sh fails, because the image is not pinned
    # -> gates-have-teeth.sh "verified-images: a TAIPANBOX image carries a tag only"

  Scenario: an upstream image is trusted only where it is listed with a reason
    Given the policy does not sign the upstream images the stack uses
    When a manifest names an upstream image that no static allow lists
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: an upstream image nobody allowed"

  Scenario: a static allow without its reason is refused
    Given a static allow is a decision to trust an image without a signature
    When the reason line above it is removed
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: a static allow has no reason"

  Scenario: the namespace is opted in last, after the controller answers
    Given a namespace opted in before its webhook answers fails every pod create in it
    When policy/up.sh stops waiting for the webhook
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: up.sh opts the namespace in before the webhook answers"

  Scenario: the stack's namespace is opted in by the script, not left to the operator
    Given the opt-in is a label on the namespace
    When policy/up.sh no longer labels agent-stack
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: up.sh no longer opts agent-stack in"

  Scenario: the controller is the release that was pinned, byte for byte
    Given policy/PIN records the rendered manifest's sha256
    When the controller manifest changes without a new pin
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: the controller changes without a new pin"

  Scenario: the controller runs by digest, never from an unrendered build reference
    Given a ko:// reference is a build instruction, not an image
    When the controller names one
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: the controller names an unrendered ko reference"

  Scenario: the controller's image is pinned by digest
    Given a controller image named by tag alone can change under the operator
    When the controller names its image without a digest
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: the controller runs an image that is not pinned by digest"

  Scenario: the default install does not turn the policy on
    Given the policy is opt-in, like identity and closure
    When manifests/kustomization.yaml names policy/
    Then verified-images-are-enforced.sh fails
    # -> gates-have-teeth.sh "verified-images: the default apply set names policy"

  Scenario: a comment that names an image is not an image
    Given a comment may explain a tag without making it a reference
    When a comment carries an image line without a digest
    Then verified-images-are-enforced.sh still passes
    # -> gates-have-teeth.sh "verified-images: a comment naming an unpinned image (must pass)"

  Scenario: a reason reworded keeps the static allow
    Given the reason is prose and its meaning is kept
    When the reason line is reworded
    Then verified-images-are-enforced.sh still passes
    # -> gates-have-teeth.sh "verified-images: a reason reworded (must pass)"

  Scenario: a gate with no subject says so instead of passing
    Given a check that finds nothing has measured nothing
    When the keyless policy is absent from the image policy
    Then verified-images-are-enforced.sh fails and says it measured NOTHING
    # -> gates-have-teeth.sh "verified-images: the keyless policy is absent (measured nothing)"
