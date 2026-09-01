#!/usr/bin/env bash
# Run this first, on the machine that will drive the deployment.
#
#   ./preflight.sh
#
# It checks everything the run needs, generates the ssh key if there is none,
# and writes terraform.tfvars so no long command line has to be retyped. It
# creates NOTHING in the cloud and spends NOTHING. Safe to run as often as you
# like.
#
# The deliberate design point: this machine stays light. The container images
# are built ON A CLUSTER NODE by deploy-aws.sh, not here, so there is no need
# for Docker, no need for the seven source repositories, and no 20 GB checkout.
# What is needed is four command line tools and a set of AWS credentials.
set -euo pipefail

KEY="${KEY:-$HOME/.ssh/stack-k8s-aws}"
REGION="${REGION:-eu-central-1}"
PROFILE="${AWS_PROFILE:-stack-k8s}"
TFVARS="terraform.tfvars"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '   \033[31mmiss\033[0m  %s\n' "$*"; MISSING=$((MISSING + 1)); }
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
need ssh       "ssh -V"                     "every system has this; if it is missing, something is very wrong"
need curl      "curl --version"             "$INSTALL_HINT curl"
need terraform "terraform version"          "$INSTALL_HINT terraform  (or: brew tap hashicorp/tap && brew install hashicorp/tap/terraform)"
need aws       "aws --version"              "$INSTALL_HINT awscli"
need jq        "jq --version"               "$INSTALL_HINT jq"

if command -v kubectl >/dev/null 2>&1; then
  ok "$(printf '%-10s %s' kubectl "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion 2>/dev/null || echo present)")"
else
  printf '   \033[33mopt\033[0m   %-10s %s\n' kubectl "optional: the scripts drive k3s kubectl over ssh. $INSTALL_HINT kubectl"
fi

if ! command -v docker >/dev/null 2>&1; then
  printf '   \033[33mopt\033[0m   %-10s %s\n' docker "not needed: images are built on a cluster node, not here"
fi

# ---- 2. the ssh key --------------------------------------------------------
# Generated HERE, on the machine that will use it. A private key that arrives
# over chat, mail or a shared drive is not a private key any more, so this
# script makes one rather than expecting one to be handed over.
say "ssh key"
if [ -f "$KEY" ]; then
  ok "$KEY exists"
  note "fingerprint: $(ssh-keygen -lf "$KEY.pub" 2>/dev/null | awk '{print $2}')"
else
  echo "   no key at $KEY, generating one now"
  ssh-keygen -t ed25519 -N "" -C "stack-k8s aws $(date -u +%Y-%m-%d)" -f "$KEY" >/dev/null
  chmod 600 "$KEY"
  ok "created $KEY"
  note "the private half stays on this machine. Terraform uploads only $KEY.pub"
fi
PERM="$(stat -f '%Lp' "$KEY" 2>/dev/null || stat -c '%a' "$KEY" 2>/dev/null || echo '?')"
[ "$PERM" = "600" ] || { bad "$KEY has mode $PERM, ssh will refuse it"; note "fix: chmod 600 $KEY"; }

# ---- 3. AWS credentials ----------------------------------------------------
# Never entered by a script, never stored in this repo, never passed on a
# command line where it would land in shell history.
say "aws credentials (profile: $PROFILE)"
if ! command -v aws >/dev/null 2>&1; then
  bad "aws cli missing, cannot check"
elif IDENT="$(AWS_PROFILE="$PROFILE" aws sts get-caller-identity --output json 2>/dev/null)"; then
  ok "account $(echo "$IDENT" | jq -r .Account)"
  note "$(echo "$IDENT" | jq -r .Arn)"
  # A run driven by an account root user is a run where one leaked key is the
  # whole account. Worth one line of warning, not a refusal.
  echo "$IDENT" | jq -r .Arn | grep -q ':root$' && \
    note "WARNING: this is the account ROOT user. Prefer the IAM user from README step 2."
else
  bad "profile '$PROFILE' has no working credentials"
  note "create the IAM user described in README.md step 2, then run:"
  note "    aws configure --profile $PROFILE"
  note "and type the secret yourself. Do not paste it into a file or a chat."
fi

# ---- 4. the address the firewall will trust --------------------------------
say "your public address"
MYIP="$(curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$MYIP" ]; then
  ok "$MYIP"
  note "ssh and the Kubernetes API will be open to $MYIP/32 and to nothing else"
  note "if you are on a VPN or a phone hotspot, this changes when the connection does"
else
  bad "could not determine your public address"
fi

# ---- 5. access to the closed piece ----------------------------------------
# The open stack needs no credentials at all. The Genaryx console is the one
# closed component, and without it the cluster is a real deployment with no
# control room, which also means no browser freeze test.
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
  note "with it:    export CONSOLE_TOKEN=<a github token that can read TAIPANBOX/genaryx>"
fi

# ---- 6. write terraform.tfvars --------------------------------------------
# Only the operator's OWN address, key and region are written here, and any
# other setting already in the file is carried through untouched.
#
# It used to `cat >` the whole file. An operator who had set `instance_type`,
# `server_count` or `disk_gb` lost them silently on the next run, and the loss
# showed up as a cluster of the wrong size or shape with no message anywhere
# saying why. Measured 2026-08-02: a five-node c7i.2xlarge setting was reduced
# to three lines by one preflight run.
#
# A preflight that creates nothing must also destroy nothing.
say "terraform.tfvars"
if [ -n "$MYIP" ]; then
  MANAGED='^[[:space:]]*(operator_cidr|ssh_public_key_path|region)[[:space:]]*='
  KEPT=""
  if [ -f "$TFVARS" ]; then
    KEPT="$(grep -vE "$MANAGED" "$TFVARS" | grep -vE '^[[:space:]]*#' | grep -E '=' || true)"
  fi
  {
    printf '# Written by preflight.sh. Safe to commit? No: it records where you were.\n'
    printf '# .gitignore already excludes it.\n'
    printf '#\n'
    printf '# Only the three lines below are managed here. Anything else you set is\n'
    printf '# kept as it was, every run.\n'
    printf 'operator_cidr       = "%s/32"\n' "$MYIP"
    printf 'ssh_public_key_path = "%s.pub"\n' "$KEY"
    printf 'region              = "%s"\n' "$REGION"
    if [ -n "$KEPT" ]; then
      printf '\n# Yours, carried through untouched.\n%s\n' "$KEPT"
    fi
  } > "$TFVARS.new" && mv "$TFVARS.new" "$TFVARS"
  ok "wrote $TFVARS"
  note "operator_cidr = $MYIP/32"
  if [ -n "$KEPT" ]; then
    note "kept $(printf '%s\n' "$KEPT" | grep -c '=') setting(s) you had already chosen"
  fi
else
  bad "no address, so no tfvars. Pass -var operator_cidr=... by hand."
fi

# ---- verdict ---------------------------------------------------------------
say "verdict"
if [ "$MISSING" -eq 0 ]; then
  cat <<EOF
   Everything needed is here, and nothing has been created or spent.

   Next, in order:

     1. Read ../COSTS.md for what each line of the bill is. What THIS cluster
        costs is computed from the counts above by step 2, which prints it as
        hourly_usd and creates nothing. Not one cent is spent before step 3.

     2. terraform init && terraform plan
        Free. Creates nothing. Shows exactly what step 3 would make.

     3. terraform apply
        THIS is where billing starts. Note the time.

     4. ./deploy-aws.sh --servers ... --agents ...
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
