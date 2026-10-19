# secret_doc NAME KEY=VALUE [KEY=@FILE ...]
#
# Prints a Secret manifest on stdout, every value base64 encoded, for
# `kubectl create -f -` or `apply -f -` at the far end of a pipe:
#
#   secret_doc stack-keys cloud_admin="$CLOUD_SECRET" | k_ "-n agent-stack create -f -"
#
# Why this shape (CLAUDE.md invariant 60): the values are arguments to a shell
# function, which runs no process, and the base64 step reads its value from a
# builtin's stdin, so no value is on any command line. What reaches ssh is the
# document, on stdin. It also takes a multi-line value (a PEM certificate) that
# a `--from-literal` argument cannot carry without a newline in argv.
#
# KEY=@FILE reads the file's bytes exactly, so a PEM keeps its final newline
# (a `$(cat ...)` would strip it). A value that really begins with @ cannot be
# passed this way; none of ours does.
#
# The namespace is not in the document: pass it to kubectl with -n, so the
# document cannot disagree with the command about where it goes.
#
# Sourced by the installers, deploy scripts and up.sh scripts. Pure shell, no
# network, no file.

secret_doc() {
  local name="$1" kv
  shift
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\ntype: Opaque\ndata:\n' "$name"
  for kv in "$@"; do
    case "$kv" in
      *=*) ;;
      *) echo "secret_doc: '$kv' is not KEY=VALUE for Secret $name" >&2; return 1 ;;
    esac
    v="${kv#*=}"
    case "$v" in
      @*) # KEY=@FILE: the file's bytes exactly, a trailing newline included (a PEM needs it)
        printf '  %s: %s\n' "${kv%%=*}" "$(base64 < "${v#@}" | tr -d '\n')" ;;
      *)
        printf '  %s: %s\n' "${kv%%=*}" "$(printf '%s' "$v" | base64 | tr -d '\n')" ;;
    esac
  done
}
