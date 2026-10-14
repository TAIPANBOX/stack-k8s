#!/usr/bin/env bash
# Invariant 44. A cost report never under-reports. A running instance type with
# no rate in cloud/aws/cost-live.sh or cloud/gcp/cost-live.sh makes that script
# exit non-zero and name the type, and never prints a total that counts it as 0.
#
# Each script runs with a stub aws or gcloud on PATH. The stub answers the one
# instance query with the machine type under test and every other query with
# nothing, so no account is needed and nothing is billed. The rates the stubs
# check are the ones the scripts print, so a rate that goes missing fails here.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
bad() { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in *InstanceType*) echo "$FAKE_TYPE" ;; esac
exit 0
STUB
cat > "$tmp/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
case "$*" in *machineType*) echo "$FAKE_TYPE" ;; esac
exit 0
STUB
chmod +x "$tmp/bin/aws" "$tmp/bin/gcloud"

# run SCRIPT TYPE: sets OUT (stdout and stderr) and RC.
run() {
	RC=0
	OUT="$(FAKE_TYPE="$2" GCP_PROJECT=stub-project PATH="$tmp/bin:$PATH" bash "$1" 2>&1)" || RC=$?
}

# expect_total SCRIPT TYPE WANT: exit 0 and a TOTAL line carrying WANT.
expect_total() {
	run "$1" "$2"
	if [ "$RC" -ne 0 ]; then
		bad "$1 with $2 exited $RC; a known type must price and exit 0"
	elif ! printf '%s\n' "$OUT" | grep -qE "^ +TOTAL +$3 USD/hour\$"; then
		bad "$1 with $2 did not print TOTAL $3 USD/hour"
	fi
}

# expect_refusal SCRIPT TYPE: non-zero exit, names the type, prints no TOTAL.
expect_refusal() {
	run "$1" "$2"
	if [ "$RC" -eq 0 ]; then
		bad "$1 with unknown type $2 exited 0: a total is printed that counts it as zero"
	elif ! printf '%s\n' "$OUT" | grep -qF "unknown rate for $2"; then
		bad "$1 with unknown type $2 does not say: unknown rate for $2"
	elif printf '%s\n' "$OUT" | grep -qE '^ +TOTAL'; then
		bad "$1 with unknown type $2 still prints a TOTAL"
	fi
}

expect_refusal cloud/aws/cost-live.sh x9.unknown-test
expect_total cloud/aws/cost-live.sh m7i.xlarge 0.2415
expect_total cloud/aws/cost-live.sh c7i.2xlarge 0.4074
expect_refusal cloud/gcp/cost-live.sh x9-unknown-test
expect_total cloud/gcp/cost-live.sh c2d-highcpu-8 0.3863

if [ "$fail" -gt 0 ]; then
	printf '%d check(s) failed: a cost script can under-report a running machine.\n' "$fail"
	exit 1
fi
echo "OK: unknown machine types are refused by both cost scripts; known types price to their table rate."
