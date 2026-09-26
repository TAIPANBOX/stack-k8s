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
./scripts/planes-leave-a-dead-node.sh # invariant 21
./scripts/gates-have-teeth.sh     # invariant 9; needs a clean tree
```

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

    So every Deployment that ROLLS tolerates both taints for at most 60 s
    (30 s is what ships) and every container in it that serves a port has a
    `preStop` sleep (5 s ships, the native sleep action, no shell needed).
    The Recreate ones are excluded on purpose: they are Recreate because they
    hold a ReadWriteOnce claim, and evicting such a pod early does not move
    its volume.

    **What it does not cover.** A node lost with a ReadWriteOnce volume on
    it: on k3d's local-path that volume waits for the node (policy-db came
    back 17 s after the node did), and Longhorn's own detach timing was not
    re-measured here. One replica still means an outage for as long as the
    new pod takes to start; this shortens the wait, it does not add a replica.
    *(gate: `scripts/planes-leave-a-dead-node.sh`, five cases in
    `scripts/gates-have-teeth.sh`; scenarios in
    `features/planes-leave-a-dead-node.feature`)*

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
