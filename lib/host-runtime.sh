# host-runtime.sh: two host settings every k3s node needs on the Ubuntu 26.04
# kernel 7.0 images (CLAUDE.md invariant 98, GOTCHAS 169 and 170). Sourced by
# install.sh, cloud/aws/install-aws.sh and cloud/gcp/install-gcp.sh; each pipes
# host_runtime_script into a root shell on every node before its k3s install.
#
#   cri_apparmor_profile [fixed|upstream] [name]   prints the container profile
#   nfs_client_modprobe                            prints the nfsv4 module option
#   host_runtime_script                            prints the sh script a node runs
#
# 1. AppArmor (GOTCHAS 169). Ubuntu sets kernel.apparmor_restrict_unprivileged_unconfined=1,
#    and runc, unconfined and without CAP_MAC_OVERRIDE, has its change to the container
#    profile converted to a stack: the container's processes carry
#    cri-containerd.apparmor.d//&unconfined. containerd's default profile allows
#    signal and ptrace only to the literal name, so a container's own processes cannot
#    signal each other (Postgres cannot stop its own server or ask for a checkpoint, and
#    every Go binary's SIGURG preemption is denied). containerd#14485, fixed by
#    containerd#14487 (merged 2026-11-16; release/2.3 #14590, release/2.4 #14591),
#    which adds the stacked peer to exactly those two rules. No containerd tag and no
#    k3s release carries it as of 2026-11-27.
#
#    containerd loads its default profile only when no profile of that name is loaded
#    (contrib/apparmor/apparmor.go, LoadDefaultProfile: `if isLoaded(name) { return nil }`),
#    so a host copy loaded first is the one every container gets. The copy below is
#    containerd's own template as k3s v1.36.2+k3s1 ships it (k3s-io/containerd
#    v2.3.2-k3s2, contrib/apparmor/template.go), rendered as containerd renders it on
#    these hosts (abi/3.0, tunables/global and abstractions/base present, the daemon
#    unconfined, no rootlesskit), with the two rules of #14487 added and nothing else.
#    It lives in /etc/apparmor.d, so apparmor.service loads it on every boot, before
#    k3s. Once a k3s release ships a containerd with #14487 the copy is the same
#    profile containerd would load, and can go.
#
# 2. NFS (GOTCHAS 170). Linux 6.19+ clients ask for a directory delegation
#    (GET_DIR_DELEGATION, op 46) in the GETATTR they send when revalidating a
#    directory. The nfs-ganesha in Longhorn v1.7.2's share-manager answers OP_ILLEGAL,
#    which the client cannot decode, and the call fails with EREMOTEIO (fixed in
#    nfs-ganesha 9.11, nfs-ganesha#1385; Longhorn ships a fixed ganesha from v1.11.3,
#    longhorn#13268). The kernel's own switch, the nfsv4 module parameter
#    directory_delegations (fs/nfs/delegation.c, default on, 0644), turns the request
#    off; delegations are a cache, so off is the behaviour of every kernel before 6.19.

HR_PROFILE_NAME=cri-containerd.apparmor.d
HR_PROFILE_FILE=/etc/apparmor.d/stack-cri-containerd
HR_MODPROBE_FILE=/etc/modprobe.d/99-stack-nfs-no-dir-delegations.conf

cri_apparmor_profile() { # [fixed|upstream] [name]
  local kind="${1:-fixed}" name="${2:-$HR_PROFILE_NAME}"
  case "$kind" in fixed | upstream) ;; *) echo "cri_apparmor_profile: fixed or upstream, not $kind" >&2; return 1 ;; esac
  cat <<EOF
abi <abi/3.0>,
#include <tunables/global>

profile ${name} flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Manager may send signals to container processes.
  signal (receive) peer=unconfined,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=${name},
EOF
  if [ "$kind" = fixed ]; then
    cat <<EOF
  # containerd#14487: with kernel.apparmor_restrict_unprivileged_unconfined=1 the change to
  # this profile is converted to a stack, and the container's processes carry this label.
  signal (send,receive) peer=${name}//&unconfined,
EOF
  fi
  cat <<'EOF'

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9/],[^1-9/][^0-9/],[^1-9s/][^0-9y/][^0-9s/],[^1-9/][^0-9/][^0-9/][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # allow processes within the container to trace each other,
  # provided all other LSM and yama setting allow it.
EOF
  printf '  ptrace (trace,tracedby,read,readby) peer=%s,\n' "$name"
  [ "$kind" = fixed ] && printf '  # Same stacked-label peer as the signal rule above.\n  ptrace (trace,tracedby,read,readby) peer=%s//&unconfined,\n' "$name"
  printf '}\n'
}

nfs_client_modprobe() {
  printf '%s\n' 'options nfsv4 directory_delegations=N'
}

# The script a node runs as root. It shows the denial with containerd's profile as it
# ships (loaded under a probe name, so a live cluster's containers are never touched),
# installs and loads the fixed profile, and stops the install if a process in it still
# cannot signal its own child. Then the NFS option, now and for every later boot.
host_runtime_script() {
  local probe=stack-probe-cri-upstream
  cat <<EOF
set -eu
host=\$(hostname)
probe() { # profile -> allowed | denied | unprobed
  if ! grep -q "^\$1 " /sys/kernel/security/apparmor/profiles 2>/dev/null; then echo unprobed; return 0; fi
  # An unprivileged process changes to the profile on exec, the way runc does, and
  # signals its own child. This is the case Ubuntu converts to a stack.
  setpriv --reuid 65534 --regid 65534 --clear-groups sh -c '
    f=/proc/self/attr/apparmor/exec; [ -w "\$f" ] || f=/proc/self/attr/exec
    echo "exec '"\$1"'" > "\$f" 2>/dev/null || exit 3
    exec sh -c "sleep 2 & kill -URG \\\$! 2>/dev/null; r=\\\$?; wait; exit \\\$r"' >/dev/null 2>&1 && rc=0 || rc=\$?
  case \$rc in 0) echo allowed ;; 3) echo unprobed ;; *) echo denied ;; esac
}
if [ -d /sys/kernel/security/apparmor ] && command -v apparmor_parser >/dev/null 2>&1; then
  t=\$(mktemp)
  cat > "\$t" <<'PROFILE'
$(cri_apparmor_profile upstream "$probe")
PROFILE
  apparmor_parser -r -K "\$t"
  before=\$(probe $probe)
  apparmor_parser -R -K "\$t" >/dev/null 2>&1 || true
  rm -f "\$t"
  cat > $HR_PROFILE_FILE <<'PROFILE'
$(cri_apparmor_profile fixed)
PROFILE
  chmod 644 $HR_PROFILE_FILE
  apparmor_parser -r $HR_PROFILE_FILE
  after=\$(probe $HR_PROFILE_NAME)
  echo "   \$host apparmor: containerd's profile as shipped: \$before; with the stacked peer: \$after (restrict_unprivileged_unconfined=\$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_unconfined 2>/dev/null || echo absent))"
  if [ "\$after" = denied ]; then
    echo "   \$host: a process in $HR_PROFILE_NAME is still denied a signal to its own child" >&2
    exit 1
  fi
else
  echo "   \$host apparmor: not enabled on this host, no profile needed"
fi
mkdir -p /etc/modprobe.d
printf '%s\n' '$(nfs_client_modprobe)' > $HR_MODPROBE_FILE
modprobe nfsv4 2>/dev/null || true
p=/sys/module/nfsv4/parameters/directory_delegations
if [ -e "\$p" ]; then
  echo N > "\$p"
  v=\$(cat "\$p")
  echo "   \$host nfs: directory_delegations=\$v"
  if [ "\$v" != N ]; then
    echo "   \$host: the nfsv4 client still asks for directory delegations" >&2
    exit 1
  fi
else
  echo "   \$host nfs: this kernel asks for no directory delegations"
fi
EOF
}
