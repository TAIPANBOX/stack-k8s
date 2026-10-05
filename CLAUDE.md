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

**Measured 2026-09-01 by `./scripts/gotchas-classified.sh`, not estimated: 95
entries, 40 platform, 38 ours, 13 the stack's own contract, 4 upstream. Nothing
unclassified.** (81 on 2026-08-06. The twelve added since are 82 to 88, then 89
to 91 from the first live run of the finops plane on GCP, and 92 and 93 from
the AWS run the same day. Between them: a plane with no cluster shape at all,
five of our own defects that every static gate here passed, the removal half of
"install by function" which nothing had ever measured because every test in
this repo was about putting things IN, and one place where two correct rules of
ours disagree with each other.)
(70 on 2026-07-31;
the nine added between 70 and 79 are 71, bash counting quotes inside a heredoc it was told
to treat literally; 72, `kubectl get -o yaml` printing configuration that was
deleted, which made a new check pass on the very defect it was written to
catch; 73, a whole verify.sh section rendering as an empty heading while the
run reported everything passing; 74, an RWX volume failing `stat` on its own mount
point while listing the files inside it, which left the notifier deaf with a
readable log underneath it; 75, a check reading an absent answer as a zero and failing the run on a
notifier that was working; 76, a CronJob sharing a ReadWriteOnce volume
with a Deployment and waiting forever; 77, three scheduled routines
that had never once run, two of them broken in more than one way; 78, the
drill from 77 finding real gaps and telling nobody, because its job had no
events destination and no events volume at all; and 79, Longhorn reporting a
volume attached before the mount it made can be stat'd. Two more added since,
on 2026-08-06: 80, heraldyx's mail egress needing a fourth port, 2525, fixed
in the manifest well before this entry was; and 81, the gateway's own Parquet
trace directory being unable to back a `focus-export` CronJob the way
`console-state` backs the new `quality-drift` one.)

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
./scripts/manifests-valid.sh      # invariant 10; needs kubeconform on PATH
./scripts/manifest-is-true.sh     # invariant 13
./scripts/node-name-is-pinned.sh  # invariant 11
./scripts/deploy-flags-agree.sh   # invariant 14
./scripts/no-sa-token-by-default.sh # invariant 15
./scripts/no-operator-files-tracked.sh # invariant 16; GOTCHAS 99 and 100
./scripts/secret-keys-agree.sh    # invariant 17; GOTCHAS 101
./scripts/k3s-token-is-reused.sh  # invariant 18; GOTCHAS 102
./scripts/preflight-keeps-tfvars.sh # invariant 19; GOTCHAS 103
./scripts/gateway-cache-is-off.sh # invariant 20
./scripts/declassify-is-keyed.sh  # invariant 27
./scripts/planes-leave-a-dead-node.sh # invariant 21
./scripts/longhorn-releases-a-dead-node.sh # invariant 22; GOTCHAS 109
./scripts/hub-entry-is-narrow.sh  # invariant 23
./scripts/delegation-off-by-default.sh # invariant 24; GOTCHAS 105
./scripts/felyx-through-the-gateway.sh # invariant 25
./scripts/typed-mode-is-honest.sh # invariants 26 and 29; needs kubeconform on PATH
./scripts/run-budget-ceiling-is-set.sh # invariant 28 (its flag half is deploy-flags-agree.sh)
./scripts/bus-names-match-the-source-rule.sh # invariant 30
./scripts/chain-verifier-watches-the-bus.sh # invariant 31
./scripts/mounted-keys-are-readable.sh # invariant 32; GOTCHAS 117
./scripts/client-key-ids-are-bare.sh # invariant 33
./scripts/gates-have-teeth.sh     # invariant 9; needs a clean tree
```

`felyx-through-the-gateway.sh` was in both callers and missing from this list until
2026-10-04, the same omission the paragraph below records for two others; the
callers are authoritative, and every gate named here is in both.

`manifest-is-true.sh` and `node-name-is-pinned.sh` were missing from this list until 2026-09-01, and
`manifest-is-true.sh` was missing from both callers as well, so for its whole
life it enforced nothing anywhere. It is the exact shape invariant 9 is about:
a gate that has quietly stopped catching anything looks like a gate with
nothing to catch. Adding a workload without declaring it is what finally ran it.

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
   Every image these manifests name is pulled from `ghcr.io/taipanbox/<name>`
   at an immutable version tag, and since 2026-09-01 that is all of them: a
   node builds nothing. Nothing may use `:latest`, `:main` or any other tag
   that moves.

   The "or built here" half of the invariant is the escape hatch and stays.
   `BUILD_FROM_SOURCE=1` on a cloud deploy, or `build.sh` locally, builds at
   `:dev` for a change that is not released yet or a cluster that cannot reach
   `ghcr.io`. Those tags are named by no manifest, so using that path also
   means editing an image line, which each script says where an operator meets
   it rather than leaving it to be discovered.

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
   `:latest`, which fails it, and by taking every manifest out of its reach,
   which now fails it too. Until 2026-08-09 that second case PASSED: the script
   printed "OK: 0 image references, all pinned, built here, or allowed by name"
   and exited 0 when `manifests/*.yaml` matched no file. Renaming the manifests
   to `.yml` or moving them into a subdirectory is ordinary housekeeping, and
   either one turned a check on eleven images into a check on none while
   printing a sentence that asserts the opposite. Found by writing invariant
   9's harness, and this is the only real hole it has found anywhere in the
   estate.)*

9. **A check must be able to tell "did not fail" from "did not run", and every
   gate here has been made to fail on purpose to prove it can.** This is the
   repository that justifies the invariant rather than merely obeying it:
   writing the harness found `pinned-images.sh` reporting a clean run over zero
   images, which is recorded in invariant 7 above.

   Two of the other three already refuse on an absent subject and say so in
   their own words: no numbered gotcha sections, no section 3 in
   `PORTABILITY.md`, no GCP cells inspected. Those sentences were true, were
   established by hand once in the session that wrote each script, and nothing
   re-ran them.
   *(gate: `scripts/gates-have-teeth.sh`, 7 cases: three real faults, one
   non-fault, and three subjects taken away entirely. The non-fault is the one
   worth keeping: `postgres:16-alpine` is an upstream tag allowed BY NAME with
   its reason in the script header, and a gate that flagged it would be
   flagging a decision and would be edited out by whoever hit it.)*

   **What it does not cover.** It cannot test itself. It proves each gate
   catches the faults named in it, not every fault of that kind. `closed-by-
   default.sh` has no absent-subject case here: its subject is
   `manifests/kustomization.yaml`, and it already fails loudly on a missing or
   empty `resources:` block, which is checked by reading it rather than by a
   mutation.

10. **Every manifest is a document Kubernetes would accept, unknown fields
    included.** The API server does not reject an unknown field, it IGNORES it:
    `readOnlyRootFileSystem` with a capital S is dropped silently, the pod
    starts, and a container an operator believes is read-only is writable. Every
    other gate here reads a document the platform may be quietly discarding half
    of, so this one runs first in spirit even where it runs last in the list.

    `kubectl apply --dry-run=client` cannot hold this: it fetches the schema
    FROM a cluster and fails for want of one, which is not the same as a
    manifest being wrong and would make the check skip in CI.
    *(gate: `scripts/manifests-valid.sh`, kubeconform with `--strict`, which is
    the load-bearing flag: without it unknown fields are accepted exactly as the
    API server accepts them. Verified four ways in
    `scripts/gates-have-teeth.sh` and by hand: the capital-S typo, a skipped
    patch no longer listed as a patch, a patch body that grew an `apiVersion`,
    and kubeconform absent, which FAILS rather than passing quietly.)*

    Two files are skipped as patch fragments, each with its own checked reason
    rather than a shared one. The shared rule tried first, "a fragment carries
    no `apiVersion`", is WRONG about kustomize: a strategic-merge patch carries
    both `apiVersion` and `kind`, because that is how it names its target. See
    GOTCHAS 82.

11. **A node's identity is decided by the install, never by a later boot.**
    Every k3s install passes `--node-name`. Left to k3s, the name defaults to
    whatever `hostname` returns at that moment, and that value is not reliably
    stable: on 2026-08-27 a GCP node that had registered under its fully
    qualified internal name came back from a stop/start under its short one. The
    result is a SECOND node object for one machine, while the first sits
    NotReady for the rest of the cluster's life still holding the 17 pod records
    it had when it left, cleaned up by nothing, on a cluster that reports itself
    healthy the whole time.

    The honest limit: a controlled reboot afterwards did NOT reproduce it, so
    the trigger is not "any restart" and the cause is not established. This
    invariant is not holding a proven mechanism, it is removing the dependency
    on one. A name we choose cannot be re-chosen by a boot, whatever the race
    turns out to be.

    `verify.sh` carries the other half, on a running cluster: two node objects
    with the same `providerID` are one machine registered twice, which is the
    exact shape of the fault and distinguishable from a node that is merely
    down.
    *(gate: `scripts/node-name-is-pinned.sh`, which FINDS the installs rather
    than listing them, reads code rather than comments, and fails when it can
    find no install at all. Three cases in `scripts/gates-have-teeth.sh`.
    Measured evidence: `cloud/gcp/evidence/range-2026-08-27/FINDINGS.md`, F3.)*

12. **Cluster DNS runs on more than one node wherever there is more than one
    node.** Measured 2026-08-27: with `replicas=1`, stopping a single node cost
    298 seconds of name resolution for the whole cluster, which is the 300 s
    `not-ready` toleration charged in full while the sole coredns pod waited to
    be rescheduled. Nothing was broken. The configuration said one dead node
    costs five minutes of DNS, and it charged exactly that.

    The installers scale it after the nodes are Ready. k3s owns the manifest and
    re-applies it on its own version change, not on restart, so this survives a
    reboot but not a k3s upgrade.
    *(partly gated: `verify.sh` checks the replica count on a running cluster,
    which turns a revert into a failed check rather than into the next outage.
    Nothing static can hold it, because the number lives on the cluster.)*

13. **`components.json` says what this launcher actually installs, and a CronJob
    is either a routine or a suspended template, never neither.** A launcher
    builds nothing of its own, so what it INSTALLS is the only thing it can
    declare, and estate-gates' C5 reads that declaration from outside. A
    workload nobody declared is invisible from outside by construction: it is
    not reported as missing, because nothing knows to look for it.

    The CronJob half is the part with money in it. Two shapes live here and
    only one is a routine: `schedules_routines` is governance work on a
    schedule, mapped to the name the estate uses; `manual_jobs` is a Job
    TEMPLATE, shipped suspended, run by a person with
    `kubectl create job --from=cronjob/<name>`. Calling a manual job a routine
    would put a schedule nobody keeps into the estate's record of what runs
    where, and calling a routine manual would hide a schedule that does run.

    So "manual" is checked against the object rather than accepted as a word:
    the manifest has to actually set `suspend: true`. A CronJob declared manual
    and left unsuspended runs on whatever schedule it carries, on a cluster
    whose operator was told it runs only when they say so, and `costcrew-crew`
    is the one CronJob in this namespace that spends on an account outside the
    cluster.

    **This gate existed and was called by nothing for its whole life**, which is
    why it is numbered here now rather than when it was written. See the note
    under Gates above.
    *(gate: `scripts/manifest-is-true.sh`, now in both callers. Five cases in
    `scripts/gates-have-teeth.sh`: an undeclared workload, a CronJob mapped to a
    routine the estate does not have, the manifests ceasing to declare a kind, a
    manual job that is not suspended, and a manual job with no reason.)*

14. **Every deploy path can set the one key the manifests deliberately ship
    invalid, and sets it where it sticks.** `00-base.yaml` carries
    `TRAILRYX_TRUST_DOMAIN: set-me.invalid` because there is no defensible
    default, and `kubectl apply -k` puts the placeholder back on the next run:
    apply reverts what it MANAGES and leaves what it does not, so the operator's
    hand-patch is exactly the thing that cannot survive. GOTCHAS 90.

    The two cloud wrappers grew `--trust-domain` on 2026-09-01 and this
    repository's own `deploy.sh` did not, so a Hetzner deploy had no way at all
    to set it. That asymmetry was found by a person reading, not by anything
    here.

    **The ordering is the load-bearing half.** A flag parsed and applied BEFORE
    the kustomization is indistinguishable from a correct one by reading the
    flag list, and it is silently useless, because the apply that follows
    reverts it. So the check compares line numbers, not presence.

    What it costs when it is wrong is silence, which is why it is a gate rather
    than a note: the record plane accepts an event only if its agent id begins
    `agent://<domain>/`, so with the placeholder standing every event a caller
    stamps with its own domain is refused as foreign, and a refusal that fires
    on everything reads exactly like a quiet night. (Half the picture, it
    turned out: see "What loud turned out to mean" below.)

    *(gate: `scripts/deploy-flags-agree.sh`. Subjects are FOUND by what makes
    them subjects, a script invoking `k_ "apply -k .../manifests"`, so a fourth
    cloud is covered the day it lands whatever it is called. Two narrower rules
    were tried and both were wrong: by NAME it found itself and
    `deploy-target-current.sh`; by the bare string `apply -k` it found four
    scripts that only PRINT the command as an instruction, plus the tunnel
    overlay, which carries no trust domain. Proved able to fail four ways,
    including the one that matters most: with every deploy script taken away the
    first version exited non-zero and printed NOTHING, because `set -e` killed
    it on grep's empty exit before the check could speak.)*

    **What it does not do.** It reads text. That the patch actually sticks needs
    a live cluster, which invariants 4 and 5 already say this repository cannot
    hold in a gate.

    **What "loud" turned out to mean.** Measured on GCP 2026-09-13 with the
    placeholder left standing on purpose: nothing went red, in two ways at
    once. Writers that derive their agent id from the ConfigMap (the finops
    runner, the console) sealed 9 records under `agent://set-me.invalid/...`
    with `foreign_trust_domain 0` and `trailryx-verify` said VERIFIED: a signed
    history under a domain nobody owns. Writers that carry their own id (the
    gateway stamps whatever a caller sends, the drills are `mockryx.local`)
    are refused as foreign, which is the quiet night the paragraph above
    describes. Neither is red anywhere an operator looks, so `verify.sh` now
    fails on the placeholder: a default that is not loud anywhere is a default
    that ships.

15. **No pod automounts the default ServiceAccount token.** No manifest here
    sets `automountServiceAccountToken`, and this repository ships no RBAC at
    all: no ServiceAccount, Role or RoleBinding of its own. Left at the
    default, every plane pod still gets kubelet's projected token for the
    namespace's `default` ServiceAccount, bound to nothing today. A
    compromised container holds that token anyway, and can use it for
    discovery and SelfSubjectReview against the API server; it also becomes a
    live credential the day any operator binds a Role to `default` for an
    unrelated reason, with no change to the pod that suddenly gains it.

    Confirmed by reading, not assumed: nothing under `manifests/` or `images/`
    references `kubernetes.default`, a ServiceAccount token path, or an
    in-cluster client. Nothing in this stack talks to the Kubernetes API from
    inside a pod, so there is no case where a pod needs this token, and
    `automountServiceAccountToken: false` costs it nothing.

    *(gate: `scripts/no-sa-token-by-default.sh`, which finds every Deployment,
    StatefulSet, CronJob and Job under `manifests/` by kind rather than by a
    hand-kept list, and fails on a missing field or an explicit `true`. Two
    cases in `scripts/gates-have-teeth.sh`: the field removed from a pod spec,
    and a non-pod object, which the gate correctly leaves alone.)*

16. **A tracked file shaped like an operator-only secret is a failure,
    independent of content.** Every gate above answers "is what is here
    correct": it opens a file it already expects, by name, and has nothing to
    say about one it was never told to expect. `cloud/gcp/terraform.tfvars.bak`
    was tracked and published for 76 commits (GOTCHAS 99) because of exactly
    that gap, and GOTCHAS 100 records the second time it showed up, caught
    that time by a person reading `git status` rather than by anything
    automatic.

    Matched by name, not content, folded to lower case so a differently-cased
    extension cannot slip past: terraform variables and state, an issued
    kubeconfig under this repo's own name or an operator's `KUBECONFIG_OUT`
    override, private keys, credential stores, shell history, and a backup an
    editor or a script leaves beside any of those. Not a replacement for the
    gates above; the other half of what none of them do.

    **What it does not cover**, named in the script's own header because it
    stays true regardless of what shapes get added: it reads the index, not
    the commits a push actually carries; a name too generic to denylist by
    itself, like `config`, stays invisible however sensitive its directory
    makes it; and it is a denylist, so a shape nobody has named yet still
    passes clean.
    *(gate: `scripts/no-operator-files-tracked.sh`, called from both
    `.githooks/pre-push` and `.github/workflows/gates.yml`. Cases in
    `scripts/gates-have-teeth.sh`: a tracked file at the repository root (the
    most common real placement, and the one a nested-only harness stopped
    proving), a tracked file at the nested shape of the entry 99 incident, a
    nested EXACT state-file name (fnmatch's `*` spans `/`, so a glob shape can
    still match a whole path by accident; only an exact shape proves it is the
    basename that matched, not the whole path), the same shape left untracked
    staying silent, a stale allow-list entry, an allow-list entry that matches
    no shape at all, and the index taken away entirely.)*

17. **Every installer that generates a Secret generates every key the
    manifests read from it.** Three installers each carry a copy of the block
    that generates `stack-keys`, and copies drift: `10-planes.yaml` and
    `20-console.yaml` started reading `gateway_admin` on 2026-09-07 (GOTCHAS
    97), the root `install.sh` grew the key the same day, and the two cloud
    installers did not. The first fresh cluster after that, GCP on 2026-09-13,
    came up with the gateway and the console both in
    `CreateContainerConfigError` and `deploy-gcp.sh` waited five minutes per
    rollout before its own verify went red. Same asymmetry, same three files,
    as invariant 14. GOTCHAS 101.

    A Secret nobody here generates (an operator's model key, the tunnel's
    token) is out of scope on purpose: the manifest that reads it says so
    beside the reference. The migration branch, "the Secret already exists,
    add only the key that is missing", is a live-cluster property and is
    proved there, not here.
    *(gate: `scripts/secret-keys-agree.sh`, in both callers. Subjects are
    found by what makes them subjects: a tracked script running
    `create secret generic <name>` with a literal name, against every
    `secretKeyRef` in `manifests/` in either YAML spelling, any field order,
    `optional: true` excluded, an unparsable reference red. Six cases in
    `scripts/gates-have-teeth.sh`: an installer dropping a key, a manifest
    reading a key nobody writes in either spelling, a key nobody reads (which
    must pass), every installer taken away, and every reference taken away.)*

18. **Every installer that brings up a k3s server reads the token the cluster
    was created with, before it installs anything, over the helper that can
    read it.** GOTCHAS 59 is the trap (a fresh token is correct exactly once);
    `install.sh` learned it in a0250b8 and `install-gcp.sh` was written with
    it; `install-aws.sh` minted a fresh token on every run. Measured on AWS
    2026-09-13, the second `deploy-aws.sh` over a healthy five-node cluster:
    the k3s install script rewrote `k3s.service.env` on the first server with
    the new token and k3s refused to start, `bootstrap data already found and
    encrypted with different token`; the other two servers kept quorum, so the
    cluster looked alive from anywhere but the kubeconfig, which points at the
    dead one. GOTCHAS 102. Third time a block copied across the three clouds
    drifted: the deploy scripts once (14), the installers twice (17, this).

    The read has to come BEFORE the first server install: a read after it reads
    the file the install just rewrote. It has to be an assignment over the
    same ssh helper as the install: the token file is root 0600, and a read
    over the login helper comes back empty. And it has to tell absent from
    failed: a failed ssh at that moment used to read as "no cluster yet" and
    mint a token.
    *(gate: `scripts/k3s-token-is-reused.sh`, in both callers. Subjects are
    tracked scripts with a non-comment `sh -s - server` line that also set
    `INSTALL_K3S_VERSION`; six cases in `scripts/gates-have-teeth.sh`: the read
    taken away, the read moved below the install, a comment naming the phrase
    (must pass), a wrapped first-server install with the read placed after it,
    the read over the wrong helper, every installer taken away. The fix was
    proved live: cluster 2's second run printed `reusing the token this cluster
    was created with`, `verify.sh` 15 passed / 0 failed / 1 noted.)*

19. **The GCP preflight carries the operator's `terraform.tfvars` through: the
    machine type, disk size, region and node counts already in the file are
    what it checks the quota against and what it writes back, and only the
    environment, set on purpose for one run, overrides them.** The script's
    header has said "written, not clobbered" since the node counts were read
    back on 2026-08-02; the machine type, disk size and region were not, so
    the file's value lost to the script's default every run. Measured
    2026-09-13, R2 of the 1.0 proving run: the file said `c2d-highcpu-8` (the
    family with a 100 vCPU ceiling in europe-west3), the preflight rewrote it
    to `c3d-highcpu-8` (capped at 24, below the 40 the cluster needs) and
    reported the quota against C3D; set back by hand before `terraform apply`.
    Had it not been, the apply would have died halfway on the family ceiling
    with a partial cluster billing, the exact failure the quota step exists to
    catch. GOTCHAS 103. Precedence is environment, then file, then default,
    the same order the counts already had.
    *(gate: `scripts/preflight-keeps-tfvars.sh`, in both callers. It runs the
    real script in a scratch directory with a stub `gcloud`, `terraform` and
    `curl` on PATH, over a seeded tfvars, twice: once with nothing in the
    environment, once with `MACHINE_TYPE` set. Three cases in
    `scripts/gates-have-teeth.sh`: the file's machine type no longer read
    back, a changed default that must pass, the preflight taken away. Red
    first: six problems on the unfixed script, `machine_type: the file said
    c2d-highcpu-8 and the preflight wrote c3d-highcpu-8` among them.)*

20. **The gateway's semantic response cache is off in every install.**
    `@decided 2026-09-24`: the launcher sets `TOKENFUSE_CACHE=off` on every
    tokenfuse gateway container explicitly, because the gateway's own shadow
    default serialises every call behind one lock and serves nothing back for
    it (tokenfuse#319).
    *(gate: `scripts/gateway-cache-is-off.sh`)*

21. **A plane that can move leaves a dead node in seconds, and drains before
    it stops.** Every Deployment here is one replica, and Kubernetes gives
    every pod a 300 s NoExecute toleration for an unreachable or not-ready
    node by default. Measured on k3d on forge, 2026-09-26, stack-k8s v1.1.10:
    `docker kill` of the node running the gateway left it refused for 360 s
    and idryx for 347 s, 47 s to NotReady plus the full 300 s. The same
    cluster's rolling upgrade from v1.1.7 refused 3 gateway probes in 0.8 s,
    the old pod stopping while its endpoint was still in the Service. Same
    shape as invariant 12: nothing broken, a default charged in full.

    So every Deployment AND StatefulSet tolerates both taints for at most 60 s
    (30 s is what ships), and every container that serves a port in a
    Deployment that ROLLS has a `preStop` sleep (5 s ships, the native sleep
    action, no shell needed).

    The first version excluded the Recreate Deployments and the StatefulSet,
    the ReadWriteOnce holders, on the premise that evicting them early cannot
    move their volume. That premise was ours and it was wrong on Longhorn:
    measured on GCP 2026-09-26, policy-db's VM stopped, the policy store stayed
    down until the VM returned, and with invariant 22's Longhorn setting and
    these tolerations it failed over in about 150 s. It is right only on
    storage that cannot move a volume (k3d's local-path), where the early
    eviction costs nothing: the replacement waits Pending for the node, as it
    would have anyway. GOTCHAS 109.

    "Every" means every manifest, not every manifest the kustomization
    includes. Until 2026-10-05 the gate read its subjects from
    `kustomization.yaml`, so the eight opt-in workloads (applied by a flag or
    by `hub/up.sh` on their own) carried no tolerations and were never judged.
    Measured on a GCP hub that day: the node carrying hub-ingress stopped, the
    entry waited the full 300 s, about 4.5 minutes of a 7.3-minute outage at
    the site. GOTCHAS 119.

    **What it does not cover.** One replica still means an outage for as long
    as the new pod takes to start; this shortens the wait, it does not add a
    replica. A network partition, as opposed to a node that is gone, was not
    measured.
    *(gate: `scripts/planes-leave-a-dead-node.sh`, five cases in
    `scripts/gates-have-teeth.sh`; scenarios in
    `features/planes-leave-a-dead-node.feature`)*

22. **Every installer that installs Longhorn tells it to release a dead
    node's volumes.** Longhorn ships `node-down-pod-deletion-policy:
    do-nothing`: an evicted pod sits Terminating on the dead node, and neither
    a StatefulSet nor a Recreate Deployment starts its replacement until the
    old pod is confirmed gone, which a dead node never confirms. Measured on
    GCP 2026-09-26 (N2/G1): policy-db's VM stopped, the policy store down until
    the VM returned; with `delete-both-statefulset-and-deployment-pod` about
    400 s; with that and invariant 21's tolerations about 150 s. The three
    installers set it right after Longhorn is ready and stop if they cannot.
    The shape of the risk: a block copied into three installers, the drift
    behind GOTCHAS 90, 101 and 102.
    *(gate: `scripts/longhorn-releases-a-dead-node.sh`, four cases in
    `scripts/gates-have-teeth.sh`; GOTCHAS 109)*

23. **The hub's one public entry for a remote site routes exactly the eight paths a gateway
    needs, and nothing else.** `manifests/53-hub-entry.yaml` is opt-in, applied by `hub/up.sh`,
    never by the default `apply -k`: unlike every other gate in this list, its whole job is to
    publish something on purpose (`@decided 2026-09-26`: customers will not install a VPN to use
    this stack), so nothing above catches a route that widens, a missing catch-all, or a
    capability added beyond `NET_BIND_SERVICE` - all three would still be valid YAML, still pass
    kubeconform, still keep `automountServiceAccountToken` false. Only reading the Caddyfile's own
    route list, embedded in the manifest's ConfigMap, catches a route that grew.

    @measured 2026-09-26 on GCP (N2/G2): 17 of 17 outcomes locally (Caddy plus the manifest's own
    security context against two stub planes, no cloud) and 12 of 12 from the public internet
    against a live entry (the three polls and decide 200, no key 401, the console and every
    non-routed path 404, plain HTTP 308 to HTTPS). The container's capabilities trap is GOTCHAS
    110; the LoadBalancer existing outside Terraform's own bookkeeping is GOTCHAS 111, and
    `hub/down.sh` deletes the Service first for the reason that entry states.

    The eighth path is `GET /v1/run-spend` on the cloud host, `@decided 2026-10-05`: a site's
    gateway reads it at startup to seed its runs' spend (tokenfuse invariant 75), and the Cloud
    answers it only to a key bound to a site, only about that site's runs, with run id, spend and
    killed. `GET /v1/runs`, which lists the whole org, stays closed. @measured 2026-10-05 on a GCP
    hub (go-to-market-2026-09 evidence `forge-gcp-migration-2026-10-05`): without a seed route a
    restarted site gateway counted only the spend it had seen itself, and a call its run's budget
    should have refused was admitted. A Cloud older than the route answers it 404 and the gateway
    falls back to the old behaviour, so the route is safe to ship ahead of the tokenfuse pin.
    *(gate: `scripts/hub-entry-is-narrow.sh`, eight cases in `scripts/gates-have-teeth.sh`;
    scenarios in `features/a-site-reaches-the-hub-over-one-narrow-door.feature`)*

24. **The delegation plane is off by default, and turning it on needs a trusted
    upstream issuer named in advance.** GOTCHAS.md entry 105 is the gap this
    closes: the gateway's delegation door only verifies a chain when
    `TOKENFUSE_DELEGATION_ISSUER` and `TOKENFUSE_DELEGATION_JWKS` are set, and
    nothing here set them, so `on_behalf_of` travelled as a claim the caller
    wrote and a wardryx policy carrying `deny_if_chain_unproven` or
    `require_root_principal` refused only callers honest enough to say they
    had not proven it.

    `@decided 2026-09-27`: the launchers offer vouchryx as an opt-in
    delegation plane, off by default, so a gateway can verify a proved
    delegation chain instead of trusting a claimed one.

    `manifests/54-delegation.yaml` (vouchryx: a Deployment, a ClusterIP
    Service, three NetworkPolicies and the `vouchryx-state` PersistentVolumeClaim)
    is not in `manifests/kustomization.yaml`'s `resources:`, the same
    treatment as `45-heraldyx.yaml` and `47-scopyx.yaml`. `delegation/up.sh`
    is the only path that applies it, and it refuses before applying anything
    unless the operator has already supplied a trusted upstream issuer,
    audience and JWKS file: there is no defensible default trusted issuer,
    the same reason `00-base.yaml` ships `TRAILRYX_TRUST_DOMAIN` as a
    placeholder rather than a guess (invariant 14). The gateway and the
    console only learn about vouchryx through two `kubectl patch
    --patch-file` bodies (`manifests/54-delegation-gateway-patch.yaml`,
    `manifests/54-delegation-console-patch.yaml`), the same shape
    `55-copilot-cloud.yaml` already uses. `delegation/down.sh` reverses each
    with its own `$patch: delete` counterpart
    (`manifests/54-delegation-gateway-unpatch.yaml`,
    `manifests/54-delegation-console-unpatch.yaml`) rather than by
    re-applying the kustomization the way `55-copilot-cloud.yaml`'s own
    header suggests: **that was tried first and does not work.**
    `kubectl patch --patch-file` never touches the
    `kubectl.kubernetes.io/last-applied-configuration` annotation `apply`'s
    own three-way diff reads, so `kubectl apply -k manifests/` sees no
    difference between what it applied last time and what it wants now, and
    leaves the patch's additions exactly where they are. Measured 2026-09-27
    on forge: every `TOKENFUSE_DELEGATION_*` env var was still on the live
    Deployment after `kubectl apply -k manifests/`, and the same apply also
    reverted `stack-wiring`'s `TRAILRYX_TRUST_DOMAIN` from the operator's own
    value back to the placeholder, invariant 14's own trap, met in the
    process of trying to work around a different one.

    The signing key and the revoke key are minted once, into the
    `vouchryx-keys` Secret, and reused on every later run, the same stance
    `hub/add-site.sh` takes on a site's keys. **The trap that made this
    entry:** vouchryx signs with the RFC 7638 thumbprint of its own signing
    key as `kid`, and a JWKS minted any other way (`vouchryx-demo keygen`
    names its key `vx-lab`) refuses every token `BadToken`. `delegation/up.sh`
    fetches vouchryx's own served JWKS from `/.well-known/jwks.json` after it
    is Ready, through a `kubectl port-forward` rather than through the
    Service (the NetworkPolicy below admits only the gateway and the
    console), and hands that to the gateway, never the operator's own JWKS.
    *(gate: `scripts/delegation-off-by-default.sh`, three cases in
    `scripts/gates-have-teeth.sh`: the manifest joining the default apply
    set, a delegation env var leaking into the default gateway or console
    manifest, and the subject taken away entirely.)*

25. **Felyx, the console's copilot, reaches its model through this stack's own
    gateway, by default.** `@decided 2026-09-27`: the launchers route Felyx
    through the stack's gateway by default, with its agent id in the trust
    domain. `manifests/20-console.yaml` points it at
    `http://tokenfuse-gateway:4100` by Service name, allow-lists that one name
    for its residency check (`GENARYX_COPILOT_LOCAL_HOSTNAMES`, genaryx
    invariant 14: resolved on every connection, cluster addresses only), and
    names it `agent://$(TRAILRYX_TRUST_DOMAIN)/genaryx/felyx`, so its calls are
    priced, budgeted and policy-checked like any agent's. No key ships: the
    `stack-copilot` Secret is optional, and without it Felyx reports itself not
    configured. Nothing in `manifests/` sets `GENARYX_COPILOT_ALLOW_REMOTE`,
    which would skip the residency check and go around the meter (and on a
    cluster enforcing `30-network-policy.yaml` could not reach the internet
    anyway: the gateway is the only pod allowed out). Measured on forge
    2026-09-27 with console v1.1.17: with a dummy key Felyx reported
    `endpoint http://tokenfuse-gateway:4100, local: true` and its question came
    back as the provider's 401 through the gateway; with the allow-list removed
    it refused the endpoint; with no Secret it said the key is not set.
    *(gate: `scripts/felyx-through-the-gateway.sh`; four cases in
    `gates-have-teeth.sh`; `features/felyx-goes-through-the-gateway.feature`)*

26. **The typed-answer data mode is chosen on purpose, and what a mode renders is
    what it says.** `@decided 2026-09-30`: a customer picks one of three data
    modes for typed answers (Jev, where named fields leave for TypeSafe's hosted
    API; their own model on their own hardware; or off), and the launchers ask.
    The default stays off, and `--with-typed` alone keeps the free stub backend
    exactly as before, because choosing Jev is a bill and a data-egress decision
    nobody should get by default.

    `typed/mode.sh` is the one copy of the validation and the rendering; the
    three launchers (`deploy.sh`, `cloud/gcp/deploy-gcp.sh`,
    `cloud/aws/deploy-aws.sh`) only parse `--typed-mode`, `--typed-jev-key-file`,
    `--typed-model-url`, `--typed-model-name`, `--typed-model-key-file` and
    `--typed-model-cidr` and hand them over, the shape GOTCHAS 90, 101 and 102
    record drifting when a block is copied. They run `typed/mode.sh check`
    BEFORE the install, so a missing key file is refused in a second rather than
    after a build. The Jev key is a file the operator names: it becomes a Secret
    built on stdin, is mounted as a file, and `TYPRYX_JEV_KEY_FILE` points at it.
    It is never an environment value, never in a ConfigMap, never an argument,
    never printed, and `typed/mode.sh secrets` refuses a terminal. Each mode
    also renders a NetworkPolicy, `typryx-egress-model`, because
    `30-network-policy.yaml` is default-deny and typryx otherwise cannot reach
    its backend. Modes are rendered whole rather than patched, for invariant
    24's reason: `kubectl patch` leaves the last-applied annotation alone, so a
    later apply of the stub would leave the patched backend in place.

    **The training log is opt-in and adds no disk.** `@decided 2026-09-30`: a
    customer can fine-tune and calibrate a model of their own on their own data,
    and typryx v0.3.0's `TYPRYX_TRAINING_DIR` is what gives them the data;
    `--typed-training` (off by default, any mode but off) sets it, on all three
    launchers through `typed/mode.sh`. Off, every mode renders exactly what it
    did before the flag existed. On, a mode gains that one variable and its
    comment and nothing else: the directory is `/var/lib/typryx/training`, on the
    `typryx-state` claim typryx already had for its ledger, because a
    PersistentVolumeClaim is a billed disk from creation (`00-base.yaml`, GOTCHAS
    81) and so a spending decision the operator makes, never a flag's side
    effect. It is not on `stack-events`, the shared bus other planes read, since
    it holds question text, and it lives as long as the `typryx-state` claim. The
    pin is v0.4.0 everywhere (v0.3.0 first read the variable; v0.4.0 is the first
    release with the `wardryx-proxy` subcommand invariant 29 runs), because an
    older image ignores the variable and writes nothing while the render says
    otherwise.

    **What it does not cover.** No cluster was involved: that the pod starts
    with the mounted Secret, and that the egress rule reaches a real model, need
    a live run, which invariants 4 and 5 already say this repository cannot hold
    in a gate. Switching back to the stub leaves `typryx-egress-model` and the
    key Secrets behind (`apply` does not prune, and keys are not deleted on this
    repository's own initiative); `--typed-mode off` does not remove a typryx an
    earlier run installed.
    *(gate: `scripts/typed-mode-is-honest.sh`, run in both callers after
    kubeconform is installed. Twenty-three cases in `scripts/gates-have-teeth.sh`: a
    missing key file accepted, a blank one accepted, the key as an environment
    value, the committed default leaving the stub, a ConfigMap in a render,
    manifests/51 drifting from the three lines the modes rewrite, a launcher
    losing a flag, a launcher not checking before it installs, a launcher
    applying manifests/51 around the mode, a harmless comment (must pass), and
    the subject taken away; then for the training log: it on without the flag,
    another object riding in with it, a real PersistentVolumeClaim riding in with
    it, a directory under no mount, a directory on the shared bus, the flag
    accepted with no typryx, a launcher losing it, a launcher not forwarding it,
    the pin going back to v0.2.0, a second tag in a document, the pin subject
    gone, and a harmless comment (must pass). The pin check reads every tracked
    file except `GOTCHAS.md`, the dated ledger, which keeps the tag that was
    current when each entry was written, and the two scripts that plant a stale
    tag as text to prove the check fails on it. Scenarios in
    `features/typed-answers-choose-where-your-data-goes.feature`.)*

27. **The gateway's declassify key is minted per cluster, comes from the
    `stack-keys` Secret, and travels on stdin.** `@decided 2026-10-04` (estate
    audit, wave 1): the tokenfuse gateway's `POST /v1/fuse/declassify` lifts a
    run's taint label, the release valve for its agent firewall. It is not
    behind `TOKENFUSE_ADMIN_KEYS`; its own credential, `TOKENFUSE_DECLASSIFY_KEY`
    (presented as `x-fuse-declassify-key`), is optional in the gateway, and with
    it unset anything that can reach port 4100 can clear a run, recorded only as
    `authenticated: false`. No manifest set it. Now the gateway container in
    `10-planes.yaml` reads it from `stack-keys`, key `declassify_key`, never a
    literal and never `optional`, and all three installers (`install.sh`,
    `cloud/gcp/install-gcp.sh`, `cloud/aws/install-aws.sh`) mint it with 24 random
    bytes: on a fresh cluster in the `create secret generic stack-keys` block, on
    a cluster whose Secret already exists by a read-before-write patch, as
    gateway_admin's migration does. Unlike every other key in that Secret, this
    one never rides the ssh command line: the create block is fed by a pipe and
    carries `--from-file=declassify_key=/dev/stdin`, the patch uses `--patch-file
    /dev/stdin`, so neither `--from-literal` nor `patch -p` ever holds it (the
    audit found `--from-literal` values on ssh argv; the other keys still ride
    it, and moving them is not done here). The installers say where the key lives
    and that clearing a run needs it, and print only the command to read it.
    Nothing in this estate calls the endpoint, so minting a key closes it by
    default and breaks nothing. The reader is tokenfuse's `declassify.rs`,
    declared in its `components.json`. An existing cluster applied with
    `kubectl apply -k` and no installer run has no `declassify_key`, so its
    gateway pod sits in `CreateContainerConfigError` until an installer is run
    (same shape as GOTCHAS 97, and deliberate: `optional` would leave the
    endpoint open silently).
    *(gate: `scripts/declassify-is-keyed.sh`, subjects found like invariant 20's
    (gateway containers by image and command) plus the tracked scripts that run
    `create secret generic stack-keys`; that every installer creates the key at
    all is invariant 17's `secret-keys-agree.sh`, which reads this manifest
    reference like any other; teeth in `scripts/gates-have-teeth.sh`; scenarios
    in `features/the-declassify-key-is-minted.feature`. Not covered: a running
    gateway refusing a call with no key, which needs a live cluster, and that
    `kubectl create --from-file=.../dev/stdin` and `patch --patch-file
    /dev/stdin` behave over ssh on a real k3s, which was checked only with a
    local `kubectl --dry-run=client`.)*

28. **Every gateway container sets the operator's ceiling on a run's budget, and
    the figure is one the gateway can start on.** tokenfuse v1.5.0 (its
    invariant 73): a run's budget came from `x-fuse-budget-usd`, the header the
    AGENT sends, and the next call of an open run could widen it, so in a
    deployment with no client keys, no identity map and no unit caps the per-run
    ceiling was whatever the agent said. `TOKENFUSE_MAX_RUN_BUDGET_USD` lowers a
    budget that came from the caller header, a policy default or the built-in
    default to that figure on every call; a caller may always ask for less, and
    a clamped call's answer carries `x-fuse-budget-clamped`. Unset, the gateway
    has no ceiling, which is what a launcher that forgot the variable ships
    with nothing reporting it.

    `10-planes.yaml` sets it to `5.00` as a literal on the gateway container
    (the `focus-export` sidecar and the MCP broker run the same image with a
    subcommand and are not gateways). `@claude 2026-10-04`: default 5.00 equals
    tokenfuse's own DEFAULT_RUN_BUDGET, so an ordinary run is unchanged and only
    a caller-declared larger budget is clamped. It is NOT set on
    `tokenfuse-cloud` and does not lower a budget the Cloud sets (tokenfuse does
    not clamp those), and it bounds each run, not an agent's total spend: an
    agent that opens a new run id gets a new ceiling's worth.

    `--run-budget-ceiling USD` (env `RUN_BUDGET_CEILING`) on all three deploy
    scripts changes it. It is checked by `budget/ceiling.sh`, the one copy of the
    validation (the gateway's own grammar: digits and up to six decimals, above
    zero, no sign or exponent), BEFORE anything is installed, and applied AFTER
    the last `apply -k` with `kubectl set env`, because `apply -k` puts the
    declared `5.00` back over anything set before it or by hand (invariant 14's
    trap, GOTCHAS 90). `set env` changes the pod template, so the gateway rolls
    to the figure by itself, which a ConfigMap patch would not do for a variable
    read at start. The price: a re-run that gives no flag rolls the gateway back
    to 5.00, and one that gives it rolls the gateway twice (apply, then the
    figure). `@claude 2026-10-04`.
    *(gate: `scripts/run-budget-ceiling-is-set.sh` for the manifest and
    `budget/ceiling.sh`, and `scripts/deploy-flags-agree.sh` for the flag, its
    ordering and its check before the install; 13 and 3 cases in
    `scripts/gates-have-teeth.sh`; scenarios in
    `features/the-run-budget-ceiling-is-set.feature`. Not covered: a running
    gateway clamping a call, which is tokenfuse's own test; and nothing was run
    on a cluster.)*

29. **The typed risk signal is off unless asked, and when on it is one stateless
    proxy that only the MCP broker reaches.** `@decided 2026-10-04` (estate
    audit, wave 1, J2): a typed risk signal may turn a call into a hold for a
    person and never into a deny, its first consumer is wardryx (v1.2.0, rule
    `hold_if_signal`), and the signal is recorded so a replay reproduces the
    decision. `--typed-risk-signal` on the three launchers (through
    `typed/mode.sh`, like the other typed flags) renders
    `manifests/56-typryx-wardryx-proxy.yaml`: typryx v0.4.0's `wardryx-proxy`
    subcommand as its own Deployment, which forwards every request to wardryx and,
    for a `POST /v1/decide` carrying a pending tool call, adds typryx's answer to
    the question "what risk class is this call" as a `signals` entry.

    Off by default, and refused when the typed mode is off (nothing to ask).
    Without the flag every render is byte for byte what it was. With it: the proxy
    answers from the SAME backend the mode chose for typryx (the same three lines
    rewritten, the same key Secret mounted, `typryx-egress-model` widened to
    select both pods and no wider) and holds NO state of its own: no claim, no
    journal, no ledger, no training log, not the shared bus (a second writer on
    typryx's hash-chained journal would fork it, and the training log holds
    question text while the proxy asks about tool-call arguments). Only the
    broker's `TOKENFUSE_WARDRYX_URL` points at it, with the viewer key and fail
    closed; the LLM gateway keeps asking wardryx directly, so a typed answer never
    sits on the model path (J2-DESIGN: a model's median latency would miss the
    gateway's 250 ms and, fail-closed, refuse calls). No `hold_if_signal` policy is
    seeded; the README has an example. The broker, which asked wardryx nothing
    before, now asks about EVERY tool call.

    `@claude 2026-10-04`, choices the spec did not decide: the proxy runs with
    `TYPRYX_ALLOW_OPEN_BIND=1` because it must bind the pod address and the broker
    can send only an `Authorization` header, never `X-Typryx-Key`, so its door is
    the one NetworkPolicy that admits the broker alone (four edges: broker ->
    proxy -> wardryx, one peer and one port each); the proxy's ask deadline is 3000
    ms (typryx accepts at most 5000) and the broker's wait 7000 ms, the figures
    stack-single uses (stack-single#88), not the proxy's default 150: Jev's median
    is near 230 ms, and an own model on CPU measured p50 2,130 ms (qwen2.5:7b, 8
    vCPU, typryx-evalset bench, 2026-09-30), so 1000 ms would drop most own-model
    answers and leave every rule with nothing to read. The broker's wait must
    exceed the proxy's LONGEST ask (5000), not only the configured one; the
    broker fails closed.
    *(gate: `scripts/typed-mode-is-honest.sh`, sections 13 to 15, with the stub,
    jev and own-model modes each rendered with the flag, two of them with the
    training log too; 21 cases in `scripts/gates-have-teeth.sh`; scenarios in
    `features/a-typed-risk-signal-reaches-a-hold-only-through-the-broker.feature`.
    Not covered: a pod behind these policies, wardryx holding on a signal, and
    typryx answering through the proxy in a cluster; the proxy was run as a
    container against a stand-in wardryx and nothing else. The first cluster
    run, on 2026-10-05, found the proxy unable to read the key it was given:
    invariant 32, GOTCHAS 117.)*

30. **Every stream file this launcher puts on the events bus, and every idryx
    `--load source:path`, is a pair the readers accept.** heraldyx v0.3.0 and
    idryx v1.1.0 (bus layer 2) refuse an event whose `source` is not allowed for
    the file it came from: `<source>.ndjson` carries `<source>` for the fourteen
    registered sources, `tokenfuse-cloud.ndjson` and `tokenfuse-mcp.ndjson` carry
    `tokenfuse`, and anything else is declared with `HERALDYX_STREAMS` /
    `IDRYX_STREAMS`. A file named otherwise is counted, alerted once as
    `foreign_source` and dropped, so a renamed stream or a new plane with its own
    file silences that plane at the notifier without an error.
    `@claude 2026-10-04`: this launcher needed no rename and sets neither
    variable; its nine streams already match (the table is in the pull request
    that added this). The gate holds it from here.
    *(gate: `scripts/bus-names-match-the-source-rule.sh`, 7 cases in
    `scripts/gates-have-teeth.sh`. Not covered: what a producer stamps in
    `source` (each producer's own code, held across repositories by estate-gates
    C4), and the streams a tool writes by its own default that no manifest names
    (qryx, verdryx, engram, the console). The table is a third copy of the two
    the readers carry and nothing holds the three equal.)*

31. **The on-box chain verifier is in the default install and keeps what it
    remembers on a claim that already exists.** `@decided 2026-10-04` (estate
    audit, wave 1, bus layer 3): every stream on the bus is a hash chain
    (`prev_hash`) and nothing on a box checked one until agent-stack-go v1.1.0's
    `agent-conform watch-dir`, which turns a break into a `chain_broken` event
    (high) in its own stream, `agent-conform.ndjson`, on the bus, where heraldyx
    and the console already read. `40-routines-and-secrets.yaml` runs it as a
    CronJob every 15 minutes, mapped to the routine `agent-conform` in
    `components.json`.

    `@claude 2026-10-04`, the state: a CronJob is a new pod per run, so an
    emptyDir would forget between runs and a persistent break would be announced
    again every run; a claim of its own is a billed disk (a spending decision for
    the operator, GOTCHAS 81). So the state file sits beside the output on
    `stack-events`: no new disk, a second non-stream file on the bus that no
    reader opens, and the verifier holds the bus read-write, so "writes only its
    own output and state" is the tool's guarantee and not the mount's. It runs as
    uid 10002 with `fsGroup: 10001` like the other bus writers. A new break fails
    the Job on purpose (restart `Never`, `backoffLimit: 0`, so a retry cannot
    exit 0 over it) and `verify.sh` counts the failed pod as not Running until it
    ages out. heraldyx v0.3.0 has no catalog sentence for `chain_broken` and
    renders it with its generic wording ("raised an event this build does not have
    a description for"), which is neutral and true.
    *(gate: `scripts/chain-verifier-watches-the-bus.sh`, 13 cases in
    `scripts/gates-have-teeth.sh`; `manifest-is-true.sh` holds the declaration;
    scenarios in `features/the-chain-verifier-watches-the-bus.feature`. Not
    covered: a cluster; that the verifier can read every writer's file on a live
    RWX volume (the writers create 0644 files, read from their source), and what
    `prev_hash` cannot see: a writer compromised in its own uid forging its own
    stream with a valid chain, and truncation from the end. The emptyDir
    measurement is GOTCHAS 115; that heraldyx's mail does not name the broken
    stream is GOTCHAS 116.)*

32. **Every file a pod mounts from a Secret, a ConfigMap or a projected volume is
    readable by the user the pod runs as.** Kubernetes writes those files owned
    by root, with the pod's `fsGroup` as the group when it has one and root's
    otherwise, at `defaultMode` (0644 when nothing sets it). A key at 0440, the
    mode `typed/mode.sh` gives the Jev key and an own model's key, is readable by
    a non-root pod only through `fsGroup`. `typryx-wardryx-proxy` had none, so
    `--typed-mode jev --typed-risk-signal` left it in CrashLoopBackOff on
    `permission denied`, measured on k3d on forge 2026-10-05 and reproduced on
    kind the same day. GOTCHAS 117. The proxy now carries `fsGroup: 65532`, its
    own group (`@claude 2026-10-05`: not the stack group 10001 typryx carries,
    which is for appending to the bus, and the proxy never writes there).

    The rule: every mode a volume sets (its default and each item's) is
    world-readable, or group-readable with a group the pod will have (`fsGroup`,
    or gid 0 as its runAsGroup or a supplemental group), or the pod runs as uid
    0. The owner bit never helps a non-root pod, since the owner is root.
    *(gate: `scripts/mounted-keys-are-readable.sh`, in both callers, over every
    pod template in `manifests/*.yaml` (the kind-less `kubectl patch` bodies
    included, judged on their own securityContext because their target is named
    elsewhere) and every pod `typed/mode.sh` renders across stub, jev and
    own-model with and without a key, each with and without
    `--typed-risk-signal` and `--typed-training`. Red first on `0dd0011`: the
    four proxy renders that mount a key. 10 cases in
    `scripts/gates-have-teeth.sh`; scenarios in
    `features/a-mounted-key-is-readable-by-its-pod.feature`. Not covered: a
    container-level override of runAsUser or runAsGroup (the pod's values are
    judged), an image whose own user differs from what the manifest states, and
    volumes a pod declares but no container mounts (judged anyway).
    @measured `kind create cluster (v0.33); kubectl apply of the proxy
    Deployment as typed/mode.sh renders it at 0dd0011 and on this branch, jev
    and own-model with a key, beside typed/mode.sh secrets` 2026-10-05: at
    `0dd0011` both CrashLoopBackOff, `permission denied`, key `root:root 440`;
    fixed, both 1/1 Ready, key `root:65532 440`. Not run: the whole stack,
    Calico, or a real Jev or model call.)*

33. **Every example of a tokenfuse client key spec here splits the way tokenfuse
    splits it: `secret:key_id`, the key id a bare name.** `TOKENFUSE_MCP_KEYS`
    and `TOKENFUSE_CLIENT_KEYS` are both read by tokenfuse's
    `ClientKeys::from_spec`, which splits each comma-separated entry on its LAST
    colon, because a secret may itself contain colons. README.md and
    `manifests/52-tokenfuse-mcp-broker.yaml` showed the key id as an
    `agent://` URI, which tokenfuse reads as the secret `<secret>:agent` and the
    key id `//<domain>/<name>`: the broker starts, the spec counts as usable,
    and every caller presenting the secret the operator meant is refused 401.
    @measured `ClientKeys::from_spec` on the README's string, as a scratch unit
    test at tokenfuse `a99a6a7` (`cargo test -p tokenfuse-gateway --lib`)
    2026-10-05: one entry, `resolve("pick-a-different-long-secret")` None, key
    id `//acme.example/broker-caller`. Not hit on a cluster as far as any record
    shows, so there is no GOTCHAS entry; the examples were corrected to
    `broker-caller`.
    *(gate: `scripts/client-key-ids-are-bare.sh`, in both callers, over every
    tracked file but `GOTCHAS.md`, `evidence/` and the two scripts that plant
    the shape; it judges literal values in shell (`NAME=value`) and YAML (flow
    and block `name:`/`value:`) form and fails when it finds none. Six cases in
    `scripts/gates-have-teeth.sh`; scenarios in
    `features/a-client-key-example-splits-the-way-tokenfuse-splits-it.feature`.
    Not covered: a value built from a shell variable, which is not judged; a
    URI with no `//` after its last colon looks like a correct entry by text;
    and what an operator types into their own Secret.)*

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
