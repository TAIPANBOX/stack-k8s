#!/usr/bin/env bash
# Checks, for every TAIPANBOX digest the v1.2.0 manifests and keyryx/manifests pin, that cosign v3.1.3 verifies
# its signature against the identity of the repository that publishes it: the repository's own release.yml on a
# version tag (stack-k8s: console-image.yml for the console). Registry reads only; nothing is pushed.
# Output: evidence/verified-images-kind/identity-per-repo-v120.txt. Run from anywhere; needs docker.
set -uo pipefail

check() { # check <image-name> <hex digest> <repository> <workflow file>
  local name=$1 dig="sha256:$2" repo=$3 wf=$4 out rc first
  local id="^https://github\\.com/TAIPANBOX/${repo}/\\.github/workflows/${wf}@refs/tags/v[0-9].*\$"
  out=$(docker run --rm ghcr.io/sigstore/cosign/cosign:v3.1.3 verify --certificate-identity-regexp "$id" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com "ghcr.io/taipanbox/${name}@${dig}" 2>&1)
  rc=$?
  first=$(printf '%s\n' "$out" | grep -m1 -E 'Error|no signatures|Verification for|subject' | cut -c1-120)
  printf '%-24s %-16s %-20s rc=%s %s\n' "$name" "$repo" "$wf" "$rc" "$first"
}

check wardryx 67718da5ef5551767156ef0ea893765f448c484fcbb5dcce5923a0ca83b8c309 wardryx release.yml
check idryx d92eb2e794d15484053b6b0b6dbfdc14314fb9b899c4caf4b2634ce6b6fc0213 idryx release.yml
check tokenfuse 7cbaa794670560468b15a7a6a3c37396767435332e8eca3a30af627de29ad6d9 tokenfuse release.yml
check tokenfuse-control-plane c6160a8eed3d83d9caf42b426e82444cfe48a14027cb90ad4338340587a9d372 tokenfuse release.yml
check genaryx-console 311625121ba911746aa9a52b9fac7ae1a4730a89546636c86d6543214ea5dd07 stack-k8s console-image.yml
check agent-conform 445608e976247b94f4c3877541fdd4ae3f2aa623b18365ee7215a99f75b85e4c agent-stack-go release.yml
check qryx 819ac02d7017c60f9787d80a175d6742ba661067d470e9e508092f0d9bb37ebb qryx release.yml
check mockryx 2c07b4d9723466611a083b9d64ba6b642faac8e669a29066e00103a5de96363c mockryx release.yml
check trailryx-node ab305ac6a65444e08090b56d6f666498b56d560f7351c96a8a84137ece9e6d37 trailryx release.yml
check typryx c9278289b3722d3e89fd90f4834666c295ee0c83b4b014c0df160500f2b57a20 typryx release.yml
check vouchryx 4a2b6b31be44b5391974785bdfca597a88bcc5ddd834d50830bd6b9537e9ab3d vouchryx release.yml
check heraldyx 8b4b60f61d0778e473d3a88df1bd63ea5eeb67428754fa341cf23051766b40b5 heraldyx release.yml
check costcrew 4f7883951aac2a0b723e5b0d7b36cf4005c8b94e4a6335ed051c14370a37b9b7 costcrew release.yml
check keyryx a9f88c44b62545555baffa19e3ace4b9c699c69c3a4aadbae28089aa2b29eb51 keyryx release.yml
check scopyx f39bfa548e43d461667fc371f5738f9f34f6e58bd297702c8f49d4f667c7789d scopyx release.yml
check scopyx b9aa4ba69f57cb079bdebe2add99f14ebca3cdd7499e223a50e7abed88ac4bce scopyx release.yml
