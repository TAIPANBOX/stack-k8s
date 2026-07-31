# CLAUDE.md, working instructions for stack-k8s

These instructions apply to any model working in this repo. Read this file
before changing anything. It holds process and invariants only: **no status.**
Status goes stale, and a stale instruction file is worse than none.

## Read before you change anything

1. **`GOTCHAS.md`, before touching any bring-up path.** It is the whole value of
   this repo. Every trap in it was paid for once already, and the classification
   next to each one is the point, not decoration.
2. `PORTABILITY.md` for what differs between Hetzner, AWS and GCP.
3. `HANDOFF.md` for the operator-facing sequence.

## What this is

The agent-governance stack on Kubernetes: manifests, images, bring-up scripts
for Hetzner, AWS and GCP, and `GOTCHAS.md`, a running ledger of every trap the
deployment actually hit.

## Why the classification matters more than the list

A gotcha should be labelled by whose fault it is: **Platform**, or **Ours**,
with "ours" further split into fixed, unfixed in this shape, and unresolved by
design. The honest count of our own mistakes is what makes the platform
classifications worth believing. A ledger where everything is somebody else's
fault is marketing.

**The real numbers, measured 2026-07-31, not estimated: 70 entries, 25 labelled
platform, 15 labelled ours, and 30 carrying no label at all.** That last number
is the interesting one. It was found by writing the gate and running it, and it
means the ledger is less classified than it reads: a reader skimming the labels
that do exist would infer a split that the file does not actually contain.

Those 30 are pinned in `scripts/gotchas-unclassified.txt`. They are not
classified here because only the person who hit each trap knows whether it was
the platform's behaviour or our own mistake, and a guess would produce exactly
the flattering ledger the labels exist to prevent. The gate stops the list
growing; shrinking it is a job for whoever remembers.

Do not let the split drift by reclassifying inconvenient entries.

## The working loop

1. Branch off `main`, one logical increment per branch.
2. Run the gate below.
3. **Anything you learned the hard way goes into `GOTCHAS.md` in the same
   change.** A trap found and fixed but not written down will be paid for
   again, by you, in about a month.
4. Commit with Conventional Commits, ending with the standard co-author
   trailer.
5. Open a PR with `gh`. **Ask the user before merging.**

There is no CI in this repo, so the local gate is the only gate.

## Gates

```sh
./scripts/gotchas-classified.sh
```

Anything that provisions real infrastructure is not a gate and never runs
unattended: see the money rule at the bottom.

## Hard invariants

Each one carries how it is held today. Use `(gate: ...)`, `(test: ...)`,
`(partly gated: ...)` or `(not enforced)`, and use the weakest one that is
true. An invariant with no check, written as though it had one, is worse than
an absent invariant.

1. **Every NEW gotcha carries a classification.** An unlabelled entry is an
   observation, not a ledger line, and it silently improves our own record. The
   gate is a ratchet, not a flat rule: 30 pre-existing entries are baselined,
   and it fails when that list grows, or when a baselined entry gets labelled
   without being removed from the baseline in the same commit. The list can only
   shrink. *(gate: `scripts/gotchas-classified.sh`)*
2. **A gotcha is written when it is found, not when it is convenient.** The
   entry is part of the fix, in the same commit. *(not enforced)*
3. **The stack comes up closed.** Nothing is published beyond loopback or the
   cluster until the operator says otherwise. A default that exposes a service
   is a security decision made on somebody else's behalf. *(not enforced)*
4. **The second run is the real test.** Works twice, from empty, untouched. A
   script that succeeds once and cannot be re-run is not a deployment, it is a
   demonstration. *(not enforced)*
5. **A verification check must be able to fail.** A bring-up that reports
   healthy without a companion case proving the same check catches an unhealthy
   stack is reporting silence, not health. *(not enforced)*
6. **Never claim a cloud is validated without a run.** `PORTABILITY.md` states
   what differs per provider; anything not actually run there is marked as not
   run, not inferred from a sibling. *(not enforced)*

## Decisions that have no gate yet

This list is debt, and it is here to stay visible rather than to be tidy.

**Held by this file alone: invariants 2, 3, 4, 5 and 6.**

Invariant 3 is checkable statically: fail if any manifest or script sets a
default bind or service type that reaches beyond the cluster. Invariant 4 needs
real infrastructure and therefore real money, so it stays a discipline rather
than a gate, and the honest place for its result is `GOTCHAS.md`.

## Standing rule

An approved architecture decision is **not finished** until it is two things: a
numbered invariant in this file, and a gate in a script if it can be checked
structurally. Until then it is a document, and documents do not stop code.

## Money, read this before running anything

**Every provisioning script in this repo spends real money.** `deploy.sh`, the
cloud subdirectories and anything that creates nodes, load balancers, volumes or
addresses bills by the hour from the moment it succeeds.

Never run one unattended, never run one to "check something", and never leave
one running after a test. Tell the user the expected cost before starting and
confirm the teardown afterwards. Creating infrastructure is the user's decision
every single time, in every permission mode.

## Conventions

- **No long dashes** anywhere: not in scripts, manifests, docs, commit messages,
  or PR bodies. Use a comma, a colon, parentheses, or a short hyphen.
- Do not delete or revoke keys, tokens, or certificates on your own initiative.
