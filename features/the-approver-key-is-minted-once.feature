# @decided 2026-10-19, from the review's approval finding (paraphrased): an approval names the person who gave
# it, and a bearer key does not decide a hold unless the operator switches that on. `@claude 2026-10-19`: the
# choices the decision did not make are in CLAUDE.md invariant 67. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name; this repository has no runner, so the binding is by eye.
Feature: the console's approver key is minted once and wardryx verifies its statements with the public half

  The console signs a statement that names the person who approved a hold, and wardryx checks it against
  the console's public key. The pair is made once, and a deploy never rewrites it.

  Scenario: a cluster with neither object gets a pair
    Given the cluster holds no approver key and no public JWK set
    When a deploy runs its approver step after apply
    Then a PKCS#8 P-256 key and its JWK set are created together, and no private key is printed
    # -> gates-have-teeth.sh "approver: the key is written as SEC1, not PKCS#8"

  Scenario: a cluster with the pair keeps it
    Given the cluster already holds both objects
    When a deploy runs its approver step again
    Then nothing is created, so the console keeps the key wardryx trusts
    # -> gates-have-teeth.sh "approver: the mint rewrites a kept pair"

  Scenario: a half pair is refused and nothing is written
    Given the cluster holds the Secret but not the JWK set, or the reverse
    When a deploy runs its approver step
    Then the deploy refuses and says why, because a mismatched pair would refuse every statement
    # -> gates-have-teeth.sh "approver: the mint applies over an existing key"

  Scenario: the console reads its key from a mount, not a variable
    Given the console's deployment
    When the manifests are read
    Then GENARYX_APPROVER_KEY_FILE names a read-only mount of console-approver-key at mode 0440, not optional
    # -> gates-have-teeth.sh "approver: the console's approver Secret becomes optional"

  Scenario: wardryx reads the public half from a mount and refuses to start without it
    Given wardryx's deployment
    When the manifests are read
    Then WARDRYX_APPROVER_JWKS names a read-only mount of wardryx-approver-jwks, not optional
    # -> gates-have-teeth.sh "approver: wardryx's JWK set becomes optional"

  Scenario: no deploy turns on the bearer-key override
    Given any live manifest, library or deploy script
    When it is read
    Then WARDRYX_ALLOW_KEY_APPROVALS is not set
    # -> gates-have-teeth.sh "approver: WARDRYX_ALLOW_KEY_APPROVALS is set on wardryx"
