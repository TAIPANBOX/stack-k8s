#!/usr/bin/env bash
# Build every stack image locally and load it into a k3s cluster over ssh.
#
# No registry on purpose: a private registry is another moving part to secure
# and another bill, and for a three-node demo cluster `ctr images import` over
# ssh is both cheaper and easier to explain. Swap in a registry the day the
# cluster outgrows that.
#
#   ./build.sh                      # build only
#   ./build.sh root@1.2.3.4 ...     # build, then import into each node
set -euo pipefail

DEV="${DEV:-$HOME/Development}"
TAG="${TAG:-dev}"
NODES=("$@")

say() { printf '\n== %s\n' "$*"; }

say "go planes"
for svc in wardryx:wardryx idryx:idryx qryx:qryx mockryx:mockryx; do
  name="${svc%%:*}"; repo="${svc##*:}"
  docker build -f images/go-service.Dockerfile \
    --build-arg SERVICE="$name" --build-arg SRC="./$repo" \
    -t "stack/$name:$TAG" "$DEV"
done

say "money plane (one workspace, two binaries)"
docker build -f images/tokenfuse.Dockerfile -t "stack/tokenfuse:$TAG" "$DEV/tokenfuse"

say "console (four languages, because it hosts the tools it spawns)"
docker build -f images/console.Dockerfile -t "stack/genaryx-console:$TAG" "$DEV"

IMAGES=(stack/wardryx stack/idryx stack/qryx stack/mockryx stack/tokenfuse stack/genaryx-console)

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
