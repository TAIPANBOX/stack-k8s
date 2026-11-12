# @decided 2026-11-12 (paraphrased): a person approving a held tool call is shown its arguments, taken from the
# enforcement point and sealed so that only the console reads them; a decision made without seeing them is allowed
# and recorded as unseen. `@claude 2026-11-12`: the wiring is CLAUDE.md invariant 91. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name; this repository has no runner, so the binding is by eye.
Feature: the console's preview key is minted once, and wardryx seals held calls' arguments to its public half

  wardryx seals the arguments of each held call to the console's preview key, and only the console opens them. The
  pair is made once, on the console's own image, and a deploy never rewrites it.

  Scenario: a cluster with neither object gets a pair, and no private key passes through a log
    Given the cluster holds no preview key and no recipient
    When a deploy runs its preview step after apply
    Then a pod on the console image makes the key, it is read back by exec, the Secret and the ConfigMap are created together, and wardryx is restarted once
    # -> gates-have-teeth.sh "preview: the key is read back through the pod's log"
    # -> gates-have-teeth.sh "preview: the mint pod keeps its work on disk"
    # -> gates-have-teeth.sh "preview: the mint pod carries a service account token"
    # -> gates-have-teeth.sh "preview: wardryx is not restarted after the mint"

  Scenario: a cluster with the pair keeps it, and a half pair is refused
    Given the cluster holds both objects, or only one of them
    When a deploy runs its preview step again
    Then nothing is created for a pair, and a half pair stops the deploy, because a recipient the key does not match seals previews nobody can open
    # -> gates-have-teeth.sh "preview: the mint applies over an existing key"
    # -> gates-have-teeth.sh "preview: a half pair is repaired instead of refused"

  Scenario: a console that cannot make the key is refused
    Given a console image that prints no X-Wing recipient
    When a deploy runs its preview step
    Then it stops, deletes its pod, and creates nothing
    # -> gates-have-teeth.sh "preview: an old console's empty answer is accepted"

  Scenario: the private key reaches the console alone, and wardryx reads only the recipient
    Given the console's and wardryx's deployments
    When the manifests are read
    Then GENARYX_PREVIEW_KEY_FILE names a read-only mount of console-preview-key at 0440, not optional, no other workload names that Secret, and wardryx reads WARDRYX_PREVIEW_RECIPIENT from the optional ConfigMap at v2.7.0 or later
    # -> gates-have-teeth.sh "preview: the console reads the key from another path"
    # -> gates-have-teeth.sh "preview: the console's preview Secret becomes optional"
    # -> gates-have-teeth.sh "preview: the private preview key is mounted into wardryx"
    # -> gates-have-teeth.sh "preview: wardryx gets a literal recipient"
    # -> gates-have-teeth.sh "preview: wardryx is pinned back to 2.6.2"
    # -> gates-have-teeth.sh "preview: a comment reworded in the wiring (must pass)"

  Scenario: every launcher mints it
    Given deploy.sh and the two cloud launchers
    When they are read
    Then each sources lib/preview-mint.sh and calls preview_mint_settle after its last apply
    # -> gates-have-teeth.sh "preview: a cloud launcher never mints the preview key"
