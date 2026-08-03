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

Every gotcha says whose fault it was, and the vocabulary is **four-way**, not
two. Getting this wrong is easy and was got wrong once already, so it is spelled
out:

| Label | Means |
|---|---|
| `**Platform.**` | Kubernetes, the distro or the cloud does this to everyone |
| `**Ours, ...**` | Our mistake. Qualified further: `and fixed`, `and unfixed in this shape`, `and unresolved by design`, `meeting a platform fact` |
| `**The stack's own contract.**` | A property of OUR SERVICES that is not a bug, and not a platform trap either |
| `**Upstream.**` | Another project does this to everyone |

The honest count of our own mistakes is what makes the platform classifications
worth believing. A ledger where everything is somebody else's fault is
marketing.

**Measured 2026-08-03, not estimated: 78 entries, 37 platform, 28 ours, 10 the
stack's own contract, 3 upstream. Nothing unclassified.** (70 on 2026-07-31;
the eight added since are 71, bash counting quotes inside a heredoc it was told
to treat literally; 72, `kubectl get -o yaml` printing configuration that was
deleted, which made a new check pass on the very defect it was written to
catch; 73, a whole verify.sh section rendering as an empty heading while the
run reported everything passing; 74, an RWX volume failing `stat` on its own mount
point while listing the files inside it, which left the notifier deaf with a
readable log underneath it; 75, a check reading an absent answer as a zero and failing the run on a
notifier that was working; 76, a CronJob sharing a ReadWriteOnce volume
with a Deployment and waiting forever; 77, three scheduled routines
that had never once run, two of them broken in more than one way; and 78, the
drill from 77 finding real gaps and telling nobody, because its job had no
events destination and no events volume at all.)

A note on how that number was arrived at, because it is the point of this whole
file. The first version of the gate knew only `Platform` and `Ours`, reported
the ten "stack's own contract" and two "upstream" entries as unclassified, and
that wrong figure went into this file and into a pull request before anybody
read the ledger properly. Nineteen entries genuinely had no label; they were
classified from what each one already says about its own cause. A check that
does not know the domain does not measure it, it just produces a number.

Do not let the split drift by reclassifying inconvenient entries. The gate
cannot tell a correct label from a self-serving one, and it says so.

## The working loop

1. Branch off `main`, one logical increment per branch.
2. Run the gate below.
3. **Anything you learned the hard way goes into `GOTCHAS.md` in the same
   change.** A trap found and fixed but not written down will be paid for
   again, by you, in about a month.
4. Commit with Conventional Commits, ending with the standard co-author
   trailer.
5. Open a PR with `gh`. **Ask the user before merging.**

Two callers, one copy of each check: `.github/workflows/gates.yml` and
`.githooks/pre-push`. Never inline a check into either.

## Gates

```sh
./scripts/gotchas-classified.sh
./scripts/closed-by-default.sh
./scripts/portability-claims.sh
./scripts/pinned-images.sh
```

Anything that provisions real infrastructure is not a gate and never runs
unattended: see the money rule at the bottom.

## Running the gates

```sh
git config core.hooksPath .githooks   # once, per clone
```

**Until 2026-08-01 the hook was the only caller, and that was a hole.**
`core.hooksPath` is local configuration: it is not committed and does not travel
with a clone, so these gates enforced nothing for anybody who cloned this repo.
`.github/workflows/gates.yml` calls the same scripts, one copy each, and is what
makes them travel. This repo is public, so standard runners cost nothing.
`git push --no-verify` still skips the local half.

## Hard invariants

Each one carries how it is held today. Use `(gate: ...)`, `(test: ...)`,
`(partly gated: ...)` or `(not enforced)`, and use the weakest one that is
true. An invariant with no check, written as though it had one, is worse than
an absent invariant.

1. **Every gotcha carries a classification**, from the four-way vocabulary
   above, in the first few lines of the entry. An unlabelled entry is an
   observation, not a ledger line, and it silently improves our own record.
   *(gate: `scripts/gotchas-classified.sh`)*
2. **A gotcha is written when it is found, not when it is convenient.** The
   entry is part of the fix, in the same commit. *(not enforced)*
3. **The stack comes up closed.** Nothing in the default
   `kubectl apply -k manifests/` set publishes beyond the cluster, and the
   placeholder secrets file is never in it. A default that exposes a service is
   a security decision made on somebody else's behalf, and on a managed cloud it
   is also their money: `50-loadbalancer.yaml` is excluded precisely because a
   Hetzner lb11 bills hourly from the moment it exists.
   *(gate: `scripts/closed-by-default.sh`)*
4. **The second run is the real test.** Works twice, from empty, untouched. A
   script that succeeds once and cannot be re-run is not a deployment, it is a
   demonstration. *(not enforced)*
5. **A verification check must be able to fail.** A bring-up that reports
   healthy without a companion case proving the same check catches an unhealthy
   stack is reporting silence, not health. *(not enforced)*
6. **Never claim a cloud is validated without a run.** `PORTABILITY.md` states
   what differs per provider, and marks its GCP column apart: bold was measured
   on a live cluster, italics was established at a desk with nothing spent,
   blank means it needs the run.
   *(gate: `scripts/portability-claims.sh`, which also requires each provider
   column to carry a dated provenance line)*

7. **What runs is pinned, or built here from a checkout the deploy names.**
   The five Go planes are pulled from `ghcr.io/taipanbox/<name>` at an
   immutable version tag; `tokenfuse` and the console are built on the node
   because neither is published. Nothing may use `:latest`, `:main` or any
   other tag that moves.

   The failure this refuses is silent by construction: a pod that comes back
   different after a restart nobody ran, and a rollback that has nowhere to go
   because there is no earlier tag. Upgrading is therefore a visible edit to a
   manifest, which is also what makes the version somebody reported reproducible
   a month later.

   One upstream image is deliberately not pinned by digest and the gate says so
   out loud rather than passing it in silence: `postgres:16-alpine` moves inside
   the 16 series to pick up patch releases of the database holding what the
   fleet is permitted to do.
   *(gate: `scripts/pinned-images.sh`; verified by pointing a manifest at
   `:latest`, which fails it)*

## Decisions that have no gate yet

This list is debt, and it is here to stay visible rather than to be tidy.

**Held by this file alone: invariants 2, 4 and 5.**

Invariants 4 and 5 both need a real cluster and therefore real money, so they
stay disciplines rather than gates, and the honest place for their results is
`GOTCHAS.md`. Invariant 2, writing the entry in the same commit as the fix, is
not checkable at all: nothing can tell a commit that should have carried a
gotcha from one that should not.

Invariant 6 is now `scripts/portability-claims.sh`, and the document turned out
to have the discipline already. It says so itself: bold was measured on a live
cluster, italics was established at a desk with nothing spent, blank needs the
run. All 37 GCP claims obey it, the Hetzner column is the baseline, and the AWS
column carries a run date and an evidence file.

What was missing is anything keeping that true. A row added as plain text reads
as measured to everyone who skims, and skimming is what a comparison sheet is
for. A formatting convention nothing enforces is a number in a document with
fewer characters.

Header rows are found exactly, as the row above the `|---|` delimiter, not
guessed. The first draft guessed by looking for provider names and reported the
silicon-comparison header as an unmarked claim, because its cells name machine
types.

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
