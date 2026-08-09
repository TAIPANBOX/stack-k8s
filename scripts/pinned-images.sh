#!/usr/bin/env bash
# Every image the manifests apply is pinned, or explicitly built by this repo.
#
# The failure this refuses is quiet by construction: a pod that comes back
# different after a restart nobody ran. `:latest` and `:main` move under the
# operator, so "which build is running" stops having an answer, and a rollback
# stops being possible: there is no earlier tag to go back to.
#
# Three shapes are allowed, and nothing else:
#
#   ghcr.io/<owner>/<name>:vX.Y.Z   published by us, immutable version
#   <anything>@sha256:...           pinned by digest
#   stack/<name>:dev                built by this repo on the node, from a
#                                   checkout whose commit the deploy prints
#
# Plus a short allowlist below for upstream images, each with its reason.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
note() { printf '  \033[33mnote\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

# Upstream images that are not pinned to a digest, each here on purpose.
#
# postgres:16-alpine is the policy store. The tag moves within the 16 series,
# which is the point: it picks up patch releases of a database holding what the
# fleet is permitted to do. Pinning it by digest would freeze those out until
# somebody remembered to bump it. Recorded rather than silently allowed.
ALLOWED_UPSTREAM="postgres:16-alpine"

count=0
while IFS= read -r line; do
  img="${line#*image: }"
  img="$(printf '%s' "$img" | tr -d ' "')"
  [ -n "$img" ] || continue
  count=$((count+1))
  case "$img" in
    *@sha256:*)               ;;
    ghcr.io/*:v[0-9]*)        ;;
    stack/*:dev)              ;;
    *:latest|*:main|*:master) bad "$img moves: a pod can come back different without a rollout" ;;
    *)
      hit=0
      for a in $ALLOWED_UPSTREAM; do [ "$img" = "$a" ] && hit=1; done
      if [ "$hit" = 1 ]; then
        note "$img is an upstream tag, allowed by name (see this script's header)"
      else
        bad "$img is neither pinned, nor built here, nor an allowed upstream tag"
      fi ;;
  esac
done < <(grep -rh "image: " manifests/*.yaml)

# A count of zero is not a clean bill of health, it is a check that found
# nothing to check. Until 2026-08-09 this printed "OK: 0 image references, all
# pinned" and exited 0 on a tree where `manifests/*.yaml` matched no file, which
# happens the moment somebody normalises the extension to .yml or moves the
# manifests into a subdirectory. Neither is a strange thing to do, and nothing
# else here would have said the images had stopped being checked.
if [ "$count" = 0 ]; then
  echo "FAIL: no image references found under manifests/*.yaml, so this check"
  echo "      measured nothing. It cannot tell whether every image is pinned if"
  echo "      it cannot find an image. If the manifests moved or were renamed,"
  echo "      this check has to move with them; silence here is not health."
  exit 1
fi

if [ "$fail" = 0 ]; then
  echo "OK: $count image references, all pinned, built here, or allowed by name."
else
  echo "$fail image reference(s) can change under the operator."
fi
exit "$fail"
