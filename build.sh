#!/usr/bin/env bash
# Build the stack images that are NOT published, and load them into a k3s
# cluster over ssh.
#
# This file used to say "no registry on purpose". That was true while nothing
# was published: a private registry is a moving part to secure and a bill, and
# `ctr images import` over ssh was cheaper for a demo cluster. It said to swap
# in a registry the day the cluster outgrew that, and 2026-08-03 was the day.
# The five Go planes are on ghcr.io now, pinned by version in the manifests,
# and the kubelet pulls them: no build, no tarball over ssh, no Go toolchain on
# anybody's node.
#
# What is left here is what is not published: tokenfuse (Rust) and the console.
#
#   ./build.sh                      # build only
#   ./build.sh root@1.2.3.4 ...     # build, then import into each node
#   BUILD_PLANES=1 ./build.sh ...   # also build the five Go planes locally
#
# BUILD_PLANES is for the two cases the registry does not serve: testing a
# change that is not released yet, and a cluster whose nodes cannot reach
# ghcr.io. It builds them at :$TAG, which the manifests do not reference, so
# using them also means editing the image line or patching the deployment.
set -euo pipefail

DEV="${DEV:-$HOME/Development}"
TAG="${TAG:-dev}"
BUILD_PLANES="${BUILD_PLANES:-0}"
NODES=("$@")

say() { printf '\n== %s\n' "$*"; }

PLANES=()
if [ "$BUILD_PLANES" = 1 ]; then
  say "go planes (BUILD_PLANES=1; normally pulled from ghcr.io)"
  for svc in wardryx:wardryx idryx:idryx qryx:qryx mockryx:mockryx heraldyx:heraldyx; do
    name="${svc%%:*}"; repo="${svc##*:}"
    docker build -f images/go-service.Dockerfile \
      --build-arg SERVICE="$name" --build-arg SRC="./$repo" \
      -t "stack/$name:$TAG" "$DEV"
    PLANES+=("stack/$name")
  done
else
  say "go planes: pulled from ghcr.io by the kubelet, nothing to build"
fi

say "money plane (one workspace, two binaries)"
docker build -f images/tokenfuse.Dockerfile -t "stack/tokenfuse:$TAG" "$DEV/tokenfuse"

say "console (four languages, because it hosts the tools it spawns)"
docker build -f images/console.Dockerfile -t "stack/genaryx-console:$TAG" "$DEV"

# `${PLANES[@]+...}` rather than a bare expansion: under `set -u`, bash 3.2
# (which is what /bin/bash still is on macOS) treats an empty array's `[@]` as
# an unbound variable and exits. Caught here before it reached anybody.
IMAGES=(${PLANES[@]+"${PLANES[@]}"} stack/tokenfuse stack/genaryx-console)

if [ ${#NODES[@]} -eq 0 ]; then
  say "built: ${IMAGES[*]} (no nodes given, nothing imported)"
  exit 0
fi

# k3s reads from containerd, not the docker daemon, so every node needs the
# image imported explicitly. Streamed rather than staged in a temp file, so a
# node with a small disk does not need room for the tarball twice.
for node in "${NODES[@]}"; do
  for img in "${IMAGES[@]}"; do
    say "importing $img:$TAG into $node"
    docker save "$img:$TAG" | ssh "$node" 'k3s ctr images import -'
  done
done

say "done. apply with: kubectl apply -k manifests/"
