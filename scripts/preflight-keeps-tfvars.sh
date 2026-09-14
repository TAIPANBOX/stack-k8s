#!/usr/bin/env bash
# `cloud/gcp/preflight.sh` carries an operator's own `terraform.tfvars` through:
# the machine type, disk size and region already in the file are what it checks
# the quota against and what it writes back, unless the environment overrides
# them on purpose.
#
# WHY THIS EXISTS
#
# The GCP preflight writes terraform.tfvars so no long command line has to be
# retyped, and its header says the file is "written, not clobbered". It read
# the node counts back from an existing file (2026-08-02, after telling an
# operator building three nodes that five would not fit) and nothing else: the
# machine type came from the environment or the script's default,
# `c3d-highcpu-8`, whatever the file said. On 2026-09-13, running R2 of the 1.0
# proving run, the file said `c2d-highcpu-8` (the family with a 100 vCPU
# ceiling in europe-west3; C3D is capped at 24, below the 40 this cluster
# needs). The preflight rewrote it to C3D, reported the quota against C3D,
# and the operator set the file back by hand before `terraform apply`. Had
# they not, the apply would have died halfway on the family ceiling with a
# partial cluster billing, the exact failure the quota step exists to catch.
# GOTCHAS 103.
#
# WHAT IT CHECKS
#
# The real script, run twice in a scratch directory with a stub `gcloud`,
# `terraform` and `curl` on PATH (enough for it to reach step 10 and write the
# file; it creates nothing and calls nothing real), over a tfvars an operator
# might have left: a machine type, a disk size and a region that are not the
# script's defaults, plus a line of their own.
#
#   1. With nothing in the environment: all three values and the operator's
#      own line survive the rewrite.
#   2. With MACHINE_TYPE set in the environment: the environment wins, because
#      that is the documented way to choose a type on purpose.
#
# WHAT IT REFUSES TO PASS ON
#
# The preflight script missing, or a run that never reached the writing step
# (no tfvars afterwards): "measured nothing", exit 1, rather than a pass on a
# file nobody wrote.
#
# WHAT IT DOES NOT CHECK
#
# The AWS preflight, which has no tfvars of its own to clobber. That the quota
# numbers are right: only that they are measured against the operator's type.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

PRE="cloud/gcp/preflight.sh"
if [ ! -f "$PRE" ]; then
	printf 'FAIL: %s is not there, so this check measured nothing.\n' "$PRE"
	exit 1
fi
PRE_ABS="$PWD/$PRE"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/run"

# The stubs. Every gcloud call in the preflight tolerates an empty answer
# (`|| true`, `|| echo`); these give the few answers that decide whether step
# 10 is reached at all: a signed-in account, a readable project, the two APIs
# enabled, a machine type that exists, and one regional CPUS quota so the
# quota line names the type it was measured against.
cat >"$tmp/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
case "$*" in
	*"config get-value account"*) echo "operator@example.test" ;;
	*"config get-value project"*) echo "stub-project" ;;
	*"projects describe"*) exit 0 ;;
	*"services list"*) printf 'compute.googleapis.com\niam.googleapis.com\n' ;;
	*"machine-types describe"*"guestCpus"*) echo 8 ;;
	*"machine-types describe"*"memoryMb"*) echo 16384 ;;
	*"regions describe"*) echo '{"quotas":[{"metric":"CPUS","limit":200,"usage":0}]}' ;;
	*"--format=json"*) echo '{}' ;;
	*"version"*) echo "Google Cloud SDK stub" ;;
	*) : ;;
esac
STUB
cat >"$tmp/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo "Terraform stub"
STUB
cat >"$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
	*checkip*) echo "203.0.113.7" ;;
	*) echo '{}' ;;
esac
STUB
chmod +x "$tmp/bin/"*

seed() {
	cat >"$tmp/run/terraform.tfvars" <<'TFV'
# left by an operator who chose the family with quota
project_id          = "stub-project"
operator_cidr       = "198.51.100.1/32"
ssh_public_key_path = "/nowhere/key.pub"
region              = "europe-west1"
machine_type        = "c2d-highcpu-8"
disk_gb             = 50
server_count        = 3
agent_count         = 2

# Yours, carried through untouched.
operator_note = "keep me"
TFV
}

run_preflight() {
	# The environment the operator did NOT set is emptied on purpose, so this
	# host's shell cannot supply a value the file should have supplied.
	(cd "$tmp/run" && env -i HOME="$tmp" PATH="$tmp/bin:/usr/bin:/bin" \
		KEY="$tmp/key" "$@" bash "$PRE_ABS" --project stub-project >"$tmp/out.log" 2>&1)
	return 0
}

value_of() {
	sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"[:space:]]+)\"?.*/\1/p" "$tmp/run/terraform.tfvars" | tail -1
}

fails=0
problem() {
	printf 'FAIL: %s\n' "$1"
	fails=$((fails + 1))
}

# --- 1. nothing in the environment: the file's own values survive ----------
seed
run_preflight
if [ ! -f "$tmp/run/terraform.tfvars" ]; then
	printf 'FAIL: the preflight wrote no terraform.tfvars at all, so this check measured nothing.\n'
	sed -n '1,40p' "$tmp/out.log"
	exit 1
fi
[ "$(value_of machine_type)" = "c2d-highcpu-8" ] ||
	problem "machine_type: the file said c2d-highcpu-8 and the preflight wrote $(value_of machine_type)"
[ "$(value_of disk_gb)" = "50" ] ||
	problem "disk_gb: the file said 50 and the preflight wrote $(value_of disk_gb)"
[ "$(value_of region)" = "europe-west1" ] ||
	problem "region: the file said europe-west1 and the preflight wrote $(value_of region)"
[ "$(value_of server_count)" = "3" ] && [ "$(value_of agent_count)" = "2" ] ||
	problem "node counts: the file said 3+2 and the preflight wrote $(value_of server_count)+$(value_of agent_count)"
grep -q '^operator_note = "keep me"' "$tmp/run/terraform.tfvars" ||
	problem "the operator's own line was not carried through"
grep -q "quota in europe-west1" "$tmp/out.log" ||
	problem "the quota was not checked in the file's region (europe-west1)"
grep -q "5 x c2d-highcpu-8" "$tmp/out.log" ||
	problem "the quota was not measured against the file's machine type (5 x c2d-highcpu-8)"

# --- 2. the environment set on purpose still wins ---------------------------
seed
run_preflight MACHINE_TYPE=n2-standard-8
[ "$(value_of machine_type)" = "n2-standard-8" ] ||
	problem "MACHINE_TYPE in the environment must override the file, and the preflight wrote $(value_of machine_type)"
[ "$(value_of disk_gb)" = "50" ] ||
	problem "an environment override of one value must not reset the others: disk_gb became $(value_of disk_gb)"

if [ "$fails" -gt 0 ]; then
	printf '\n%d problem(s): the preflight rewrites what the operator wrote. A tfvars that\n' "$fails"
	printf 'changes under the operator between preflight and apply is a cluster they did not choose.\n'
	exit 1
fi
printf 'OK: preflight.sh carries the machine type, disk size, region, node counts and the operator'"'"'s own lines through terraform.tfvars, and the environment still overrides them.\n'
