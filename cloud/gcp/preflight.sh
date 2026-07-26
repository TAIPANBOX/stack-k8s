#!/usr/bin/env bash
# Run this first, on the machine that will drive the deployment.
#
#   ./preflight.sh --project <project-id>
#
# It checks everything the run needs, generates the ssh key if there is none,
# and writes terraform.tfvars so no long command line has to be retyped. It
# creates NOTHING billable and spends NOTHING. Safe to run as often as you like.
#
# Two things here have no counterpart in the AWS preflight, and both are GCP
# facts worth the extra lines:
#
#   - APIs are off until switched on. A brand new project cannot create a VM
#     because the Compute Engine API is not enabled, and the error names the
#     API rather than the thing you asked for. Enabling is free.
#   - Quotas are per machine FAMILY as well as per region. C3 (Intel) had a
#     separate 24 vCPU ceiling on the project this was written against, against
#     the 40 this cluster needs, while C3D (AMD) drew on the general 200. A
#     cluster that cannot be created is better found here than at apply.
#
# The deliberate design point, unchanged from AWS: this machine stays light. The
# container images are built ON A CLUSTER NODE by deploy-gcp.sh, not here, so
# there is no need for Docker, no need for the seven source repositories, and no
# 20 GB checkout.
set -euo pipefail

KEY="${KEY:-$HOME/.ssh/stack-k8s-gcp}"
REGION="${REGION:-europe-west3}"
ZONE="${ZONE:-${REGION}-a}"
MACHINE_TYPE="${MACHINE_TYPE:-c3d-highcpu-8}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2604-lts-amd64}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
PROJECT="${GCP_PROJECT:-${CLOUDSDK_CORE_PROJECT:-}}"
SERVERS_WANTED="${SERVERS_WANTED:-3}"
AGENTS_WANTED="${AGENTS_WANTED:-2}"
DISK_GB="${DISK_GB:-100}"
TFVARS="terraform.tfvars"
ENABLE_APIS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)     PROJECT="$2"; shift 2 ;;
    --region)      REGION="$2"; ZONE="${REGION}-a"; shift 2 ;;
    --zone)        ZONE="$2"; shift 2 ;;
    --enable-apis) ENABLE_APIS=1; shift ;;
    -h|--help)     sed -n '2,30p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '   \033[31mmiss\033[0m  %s\n' "$*"; MISSING=$((MISSING + 1)); }
warn() { printf '   \033[33mwarn\033[0m  %s\n' "$*"; }
note() { printf '         %s\n' "$*"; }
MISSING=0

case "$(uname -s)" in
  Darwin) INSTALL_HINT="brew install" ;;
  Linux)  INSTALL_HINT="sudo apt install" ;;
  *)      INSTALL_HINT="install" ;;
esac

# ---- 1. tools --------------------------------------------------------------
say "tools on this machine"
need() {
  if command -v "$1" >/dev/null 2>&1; then
    ok "$(printf '%-10s %s' "$1" "$($2 2>&1 | head -1)")"
  else
    bad "$(printf '%-10s %s' "$1" "$3")"
  fi
}
need ssh       "ssh -V"            "every system has this; if it is missing, something is very wrong"
need curl      "curl --version"    "$INSTALL_HINT curl"
need terraform "terraform version" "$INSTALL_HINT terraform  (or: brew tap hashicorp/tap && brew install hashicorp/tap/terraform)"
need gcloud    "gcloud version"    "https://cloud.google.com/sdk/docs/install"
need jq        "jq --version"      "$INSTALL_HINT jq"

if command -v kubectl >/dev/null 2>&1; then
  ok "$(printf '%-10s %s' kubectl "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion 2>/dev/null || echo present)")"
else
  printf '   \033[33mopt\033[0m   %-10s %s\n' kubectl "optional: the scripts drive k3s kubectl over ssh. $INSTALL_HINT kubectl"
fi
command -v docker >/dev/null 2>&1 || \
  printf '   \033[33mopt\033[0m   %-10s %s\n' docker "not needed: images are built on a cluster node, not here"

# ---- 2. the ssh key --------------------------------------------------------
# Generated HERE, on the machine that will use it. A private key that arrives
# over chat, mail or a shared drive is not a private key any more.
say "ssh key"
if [ -f "$KEY" ]; then
  ok "$KEY exists"
  note "fingerprint: $(ssh-keygen -lf "$KEY.pub" 2>/dev/null | awk '{print $2}')"
else
  echo "   no key at $KEY, generating one now"
  ssh-keygen -t ed25519 -N "" -C "stack-k8s gcp $(date -u +%Y-%m-%d)" -f "$KEY" >/dev/null
  chmod 600 "$KEY"
  ok "created $KEY"
  note "the private half stays on this machine. Terraform uploads only $KEY.pub"
fi
PERM="$(stat -f '%Lp' "$KEY" 2>/dev/null || stat -c '%a' "$KEY" 2>/dev/null || echo '?')"
[ "$PERM" = "600" ] || { bad "$KEY has mode $PERM, ssh will refuse it"; note "fix: chmod 600 $KEY"; }

# ---- 3. credentials --------------------------------------------------------
# Two of them, and the difference matters. gcloud uses your user credentials;
# Terraform uses Application Default Credentials, which are a SEPARATE login.
# Having one and not the other is the most common way a first GCP run fails,
# and it fails inside the provider with a message about a missing token rather
# than about a missing login.
say "credentials"
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
if [ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "(unset)" ]; then
  ok "gcloud: $ACCOUNT"
else
  bad "gcloud is not signed in"
  note "fix: gcloud auth login"
fi
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  ok "application default credentials present (this is what terraform uses)"
else
  bad "no application default credentials"
  note "fix: gcloud auth application-default login"
fi

# ---- 4. the project --------------------------------------------------------
say "project"
if [ -z "$PROJECT" ]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  [ "$PROJECT" = "(unset)" ] && PROJECT=""
fi
if [ -z "$PROJECT" ]; then
  bad "no project given"
  note "pass --project <project-id>, and note that the ID is not the display name:"
  note "    gcloud projects list"
else
  if gcloud projects describe "$PROJECT" >/dev/null 2>&1; then
    ok "$PROJECT"
    ROLES="$(gcloud projects get-iam-policy "$PROJECT" --flatten='bindings[].members' \
      --filter="bindings.members:$ACCOUNT" --format='value(bindings.role)' 2>/dev/null | tr '\n' ' ' || true)"
    [ -n "$ROLES" ] && note "your roles here: $ROLES"
  else
    bad "cannot read project '$PROJECT'"
    note "either the ID is wrong (it is not the display name) or your account has no access to it"
    PROJECT=""
  fi
fi

if [ -n "$PROJECT" ]; then
  BILL="$(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)' 2>/dev/null || echo "")"
  case "$BILL" in
    True|true) ok "billing is linked and enabled" ;;
    False|false) bad "the project exists but has NO billing account linked; nothing can be created" ;;
    *) warn "cannot read the billing link (that needs a role on the billing account, not on the project)"
       note "the run works without this; it only means this script cannot confirm it" ;;
  esac
fi

# ---- 5. the APIs -----------------------------------------------------------
# Free to enable, and nothing works before they are. Enabling one is not a
# billable act: it is the switch that ALLOWS billable acts, which is why this
# script will do it for you but says so first.
if [ -n "$PROJECT" ]; then
  say "apis"
  NEED_APIS="compute.googleapis.com iam.googleapis.com"
  ENABLED="$(gcloud services list --enabled --project="$PROJECT" --format='value(config.name)' 2>/dev/null || true)"
  TO_ENABLE=""
  for a in $NEED_APIS; do
    if printf '%s\n' "$ENABLED" | grep -qx "$a"; then ok "$a"; else
      if [ "$ENABLE_APIS" = 1 ]; then TO_ENABLE="$TO_ENABLE $a"; else
        bad "$a is not enabled"
        note "free to turn on. Re-run with --enable-apis, or: gcloud services enable $a --project=$PROJECT"
      fi
    fi
  done
  if [ -n "$TO_ENABLE" ]; then
    echo "   enabling:$TO_ENABLE (free, creates nothing)"
    # shellcheck disable=SC2086
    gcloud services enable $TO_ENABLE --project="$PROJECT" >/dev/null && ok "enabled$TO_ENABLE"
  fi
fi

# ---- 6. quota, which is where a GCP run dies before it starts ---------------
# Read from the region rather than assumed. The numbers this cluster needs are
# derived from the same variables Terraform uses, so they cannot drift apart.
if [ -n "$PROJECT" ] && printf '%s\n' "$ENABLED" | grep -qx compute.googleapis.com; then
  say "quota in $REGION"
  NODES=$((SERVERS_WANTED + AGENTS_WANTED))
  VCPU_EACH="$(gcloud compute machine-types describe "$MACHINE_TYPE" --zone="$ZONE" --project="$PROJECT" \
    --format='value(guestCpus)' 2>/dev/null || echo "")"
  if [ -z "$VCPU_EACH" ]; then
    bad "$MACHINE_TYPE does not exist in $ZONE"
    note "list what does: gcloud compute machine-types list --zones=$ZONE --project=$PROJECT"
  else
    ok "$MACHINE_TYPE is available in $ZONE ($VCPU_EACH vCPU, $(gcloud compute machine-types describe "$MACHINE_TYPE" --zone="$ZONE" --project="$PROJECT" --format='value(memoryMb)' 2>/dev/null) MB)"
  fi
  NEED_CPU=$((NODES * ${VCPU_EACH:-8}))
  NEED_SSD=$((NODES * DISK_GB))

  QJSON="$(gcloud compute regions describe "$REGION" --project="$PROJECT" --format=json 2>/dev/null || echo '{}')"
  # The family quota, if this machine type has one. C3 does, C3D does not, and
  # which is which is not guessable: it is read here.
  FAMILY="$(printf '%s' "$MACHINE_TYPE" | cut -d- -f1 | tr '[:lower:]' '[:upper:]')_CPUS"
  check_quota() {
    local metric="$1" need="$2" label="$3"
    local line limit usage
    line="$(printf '%s' "$QJSON" | jq -r --arg m "$metric" '.quotas[]? | select(.metric==$m) | "\(.limit) \(.usage)"' 2>/dev/null || true)"
    [ -z "$line" ] && { note "no $metric quota in this region (it draws on the general pool)"; return; }
    limit="${line%% *}"; usage="${line##* }"
    if awk -v l="$limit" -v u="$usage" -v n="$need" 'BEGIN{exit !(l-u >= n)}'; then
      ok "$(printf '%-18s limit %-8s used %-6s need %s   %s' "$metric" "$limit" "$usage" "$need" "$label")"
      # `awk && note` is the whole story of GOTCHAS.md item 26 in one line: as
      # the last command of a function under `set -e`, a false test is an exit,
      # and the script stops here looking like it finished. Measured on the
      # first run of this file, 2026-07-26.
      awk -v l="$limit" -v u="$usage" -v n="$need" 'BEGIN{exit !(l-u == n)}' \
        && note "exactly at the limit: this fits, with no headroom for one more" \
        || true
    else
      bad "$(printf '%-18s limit %-8s used %-6s need %s' "$metric" "$limit" "$usage" "$need")"
      note "request an increase: IAM & Admin > Quotas & System Limits, filter on $metric in $REGION"
    fi
  }
  check_quota CPUS "$NEED_CPU" "$NODES x $MACHINE_TYPE"
  check_quota "$FAMILY" "$NEED_CPU" "legacy per-family ceiling, if this family has one"

  # The quota that actually stops a modern machine type, and the reason this
  # block exists at all. `compute.regions.describe` does NOT list it: it lists
  # CPUS, C2_CPUS, N2_CPUS and friends, all of which passed, while the apply
  # died on a ceiling none of them mentions:
  #
  #   Quota 'CPUS_PER_VM_FAMILY' exceeded. Limit: 24.0 in region europe-west3
  #   dimensions = map[region:europe-west3 vm_family:C3D]
  #
  # Measured 2026-07-26: three of five instances created, two refused, and the
  # partial cluster billed while it was sorted out. It is readable ahead of
  # time, just not from the same API, so this asks Service Usage directly.
  #
  # Worth knowing before choosing a machine type on a fresh project: in
  # europe-west3 the NEWEST families (C3D, C4, C4A) were capped at 24 vCPU and
  # an increase request was auto-denied in three seconds, while C2D sat at 100
  # and N4/N4A at 200. The previous generation is open and the current one is
  # not, which is the opposite of what anyone plans for.
  FAM_CODE="$(printf '%s' "$MACHINE_TYPE" | cut -d- -f1 | tr '[:lower:]' '[:upper:]')"
  PF_URL="https://serviceusage.googleapis.com/v1beta1/projects/$PROJECT/services/compute.googleapis.com"
  PF_URL="$PF_URL/consumerQuotaMetrics/compute.googleapis.com%2Fcpus_per_vm_family/limits/%2Fproject%2Fregion%2Fvm_family"
  PF_LIMIT="$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" "$PF_URL" 2>/dev/null \
    | jq -r --arg r "$REGION" --arg f "$FAM_CODE" \
      '.quotaBuckets[]? | select(.dimensions.region==$r and .dimensions.vm_family==$f) | .effectiveLimit' 2>/dev/null | head -1)"
  if [ -z "$PF_LIMIT" ] || [ "$PF_LIMIT" = "null" ]; then
    note "CPUS_PER_VM_FAMILY: no separate ceiling for $FAM_CODE in $REGION"
  elif [ "$PF_LIMIT" -ge "$NEED_CPU" ] 2>/dev/null; then
    ok "$(printf '%-18s limit %-8s need %-6s   the ceiling that regions.describe does not show' "CPUS_PER_VM_FAMILY" "$PF_LIMIT" "$NEED_CPU")"
  else
    bad "$(printf '%-18s limit %-8s need %s   for family %s' "CPUS_PER_VM_FAMILY" "$PF_LIMIT" "$NEED_CPU" "$FAM_CODE")"
    note "This is the one that fails the apply HALFWAY, leaving instances billing."
    note "Either request an increase (a fresh project's request may be auto-denied),"
    note "or pick a family with room. To see them all:"
    note "    curl -s -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \\"
    note "      '$PF_URL' | jq -r '.quotaBuckets[]|select(.dimensions.region==\"$REGION\")|\"\\(.dimensions.vm_family) \\(.effectiveLimit)\"'"
  fi
  check_quota SSD_TOTAL_GB "$NEED_SSD" "pd-balanced counts as SSD"
  check_quota IN_USE_ADDRESSES "$NODES" "one public address per node"
  check_quota INSTANCES "$NODES" ""
fi

# ---- 7. the image ----------------------------------------------------------
if [ -n "$PROJECT" ]; then
  say "image"
  IMG="$(gcloud compute images describe-from-family "$IMAGE_FAMILY" --project="$IMAGE_PROJECT" \
    --format='value(name,creationTimestamp)' 2>/dev/null | tr '\t' ' ' || true)"
  if [ -n "$IMG" ]; then ok "$IMAGE_PROJECT/$IMAGE_FAMILY resolves to $IMG"
  else bad "cannot resolve $IMAGE_PROJECT/$IMAGE_FAMILY"; fi
fi

# ---- 8. the address the firewall will trust --------------------------------
say "your public address"
MYIP="$(curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$MYIP" ]; then
  ok "$MYIP"
  note "ssh and the Kubernetes API will be open to $MYIP/32 and to nothing else"
  note "if you are on a VPN or a phone hotspot, this changes when the connection does"
else
  bad "could not determine your public address"
fi

# ---- 9. access to the closed piece ----------------------------------------
say "github access for the Genaryx console (optional)"
if [ -n "${CONSOLE_TOKEN:-}" ]; then
  if curl -sf -o /dev/null -H "Authorization: Bearer $CONSOLE_TOKEN" \
       "https://api.github.com/repos/TAIPANBOX/genaryx" 2>/dev/null; then
    ok "CONSOLE_TOKEN can read TAIPANBOX/genaryx"
  else
    bad "CONSOLE_TOKEN is set but cannot read TAIPANBOX/genaryx"
    note "the open stack still deploys; the console and the freeze test do not"
  fi
else
  printf '   \033[33mopt\033[0m   %s\n' "CONSOLE_TOKEN not set"
  note "without it: wardryx, idryx, qryx, mockryx, tokenfuse deploy and enforce,"
  note "but there is no console, so the browser freeze proof cannot be reproduced."
fi

# ---- 10. write terraform.tfvars -------------------------------------------
say "terraform.tfvars"
if [ -n "$MYIP" ] && [ -n "$PROJECT" ]; then
  cat > "$TFVARS" <<EOF
# Written by preflight.sh. Not committed: .gitignore excludes *.tfvars, and this
# file records where you were.
project_id          = "$PROJECT"
operator_cidr       = "$MYIP/32"
ssh_public_key_path = "$KEY.pub"
region              = "$REGION"
machine_type        = "$MACHINE_TYPE"
disk_gb             = $DISK_GB
EOF
  ok "wrote $TFVARS"
  note "project $PROJECT, operator $MYIP/32, $MACHINE_TYPE, ${DISK_GB} GB disks"
else
  bad "missing the project or your address, so no tfvars was written"
fi

# ---- verdict ---------------------------------------------------------------
say "verdict"
if [ "$MISSING" -eq 0 ]; then
  cat <<EOF
   Everything needed is here, and nothing has been created or spent.

   Next, in order:

     1. Read ../COSTS.md. The cluster costs about USD 1.88/hour once step 3
        runs, and not one cent before it.

     2. terraform init && terraform plan
        Free. Creates nothing. Shows exactly what step 3 would make.

     3. terraform apply
        THIS is where billing starts. Note the time.

     4. ./deploy-gcp.sh --servers ... --agents ...
        One command: cluster, images, workload, and both test suites.
        (The exact line is printed by terraform apply.)

     5. ./teardown.sh
        When finished. It checks afterwards that nothing is still billing.
EOF
else
  printf '   \033[31m%s thing(s) still needed.\033[0m Fix the "miss" lines above and re-run.\n' "$MISSING"
  echo "   Nothing was created and nothing was spent."
  exit 1
fi
