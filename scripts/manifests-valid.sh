#!/usr/bin/env bash
# Every manifest in this repository validates against the Kubernetes schema.
#
# WHY THIS DID NOT EXIST UNTIL NOW, AND WHY THAT WAS A HOLE
#
# The other gates here check POLICY: that the cluster comes up closed, that
# images are pinned, that every cloud claim is dated. None of them checks that
# the YAML is a thing Kubernetes would accept. A misspelled field is not
# rejected by the API server, it is IGNORED: `readOnlyRootFileSystem` with a
# capital S is silently dropped, the pod starts, and a container an operator
# believes is read-only is writable. That is the worst available failure shape
# for this repository, because the manifest reads correctly to a human.
#
# `--strict` is what turns that from a warning into a failure: without it,
# kubeconform accepts unknown fields exactly as the API server does.
#
# WHY kubeconform AND NOT `kubectl --dry-run`
#
# `kubectl apply --dry-run=client` fetches the OpenAPI schema FROM A CLUSTER. On
# a machine with no cluster it fails with a connection error, which is not the
# same as a manifest being wrong and is why a check built on it would be skipped
# in CI and would then be a check that never runs.
#
# INSTALL
#
#   go install github.com/yannh/kubeconform/cmd/kubeconform@latest
#
# Missing, this script FAILS rather than passing quietly. A validation that
# could not run is not a validation that passed, and this whole repository is
# about the difference.
set -euo pipefail
cd "$(dirname "$0")/.."

kc="$(command -v kubeconform || true)"
if [ -z "$kc" ] && [ -x "$(go env GOPATH 2>/dev/null)/bin/kubeconform" ]; then
	kc="$(go env GOPATH)/bin/kubeconform"
fi
if [ -z "$kc" ]; then
	echo "FAIL: kubeconform is not on PATH, so nothing here was validated."
	echo "      A schema check that cannot run is not a schema check that passed."
	echo "      Install it with: go install github.com/yannh/kubeconform/cmd/kubeconform@latest"
	exit 1
fi

# PATCH FRAGMENTS, EXCLUDED BY NAME, EACH WITH ITS OWN CHECKED REASON
#
# Two files here are patch BODIES rather than manifests: they carry a partial
# `spec:` that kustomize or `kubectl patch` merges into an object defined
# elsewhere. A schema validator is right to reject a partial object and wrong to
# be asked about one.
#
# They are NOT the same kind of fragment, and one uniform rule got that wrong
# when this script was written. A kustomize patch DOES carry `apiVersion` and
# `kind`: that is how it names the object it merges into. A `kubectl patch
# --patch-file` body carries neither. So each exclusion is justified by a fact
# that is true of THAT file and is checked on every run, rather than by a
# property they were assumed to share.
#
# Excluded by name and not by a pattern, the way `pinned-images.sh` allows
# `postgres:16-alpine`. A pattern like `*-patch.yaml` would be shorter and would
# silently exclude any future file somebody named that way.

# tunnel/console-patch.yaml: a kustomize strategic-merge patch. The checkable
# fact is that a kustomization LISTS it as one. If it stops being listed, it is
# either dead or a manifest, and either way this gate must stop skipping it.
if ! grep -q 'path: console-patch.yaml' tunnel/kustomization.yaml 2>/dev/null; then
	echo "FAIL: tunnel/console-patch.yaml is skipped as a kustomize patch, but"
	echo "      tunnel/kustomization.yaml no longer lists it under patches:."
	echo "      It is now either dead or a manifest, and neither may be skipped."
	exit 1
fi

# manifests/55-copilot-cloud.yaml: a `kubectl patch --patch-file` body. The
# checkable fact is that it carries no apiVersion, which is what makes it
# unloadable as an object and unvalidatable as a schema.
if grep -qE '^apiVersion:' manifests/55-copilot-cloud.yaml 2>/dev/null; then
	echo "FAIL: manifests/55-copilot-cloud.yaml is skipped as a patch body but now"
	echo "      carries apiVersion, which makes it a manifest this gate must check."
	echo "      Take it off the FRAGMENTS list in this script."
	exit 1
fi

FRAGMENTS=(
	"tunnel/console-patch.yaml"
	"manifests/55-copilot-cloud.yaml"
)

for f in "${FRAGMENTS[@]}"; do
	if [ ! -f "$f" ]; then
		echo "FAIL: $f is excluded from validation and does not exist."
		echo "      Remove the entry, or restore the file. An exclusion list that"
		echo "      outlives its files is a list nobody re-reads."
		exit 1
	fi
done

# Files, gathered explicitly and counted, so an empty glob is a failure rather
# than a clean run over nothing. Zero files validated would otherwise print the
# same OK as forty.
files=()
while IFS= read -r f; do
	skip=""
	for frag in "${FRAGMENTS[@]}"; do
		[ "$f" = "$frag" ] && skip=1
	done
	[ -z "$skip" ] && files+=("$f")
done < <(
	find manifests tunnel cloud -name '*.yaml' -not -name 'kustomization.yaml' 2>/dev/null | sort
)

if [ "${#files[@]}" -eq 0 ]; then
	echo "FAIL: no manifests were found, so this check measured nothing."
	exit 1
fi

echo "validating ${#files[@]} manifest file(s), skipping ${#FRAGMENTS[@]} patch fragment(s)"

# `-ignore-missing-schemas` is deliberately NOT passed. A CRD this repository
# does not ship would then be skipped silently, and a typo inside one would
# look identical to a clean file. If a CRD ever arrives here, add its schema
# location with `-schema-location` rather than turning the check off.
#
# The example files carry placeholders, not values, and are excluded by name
# rather than by a pattern: `secrets.example.yaml` and `site.example.yaml` are
# templates an operator copies, and one of them is deliberately incomplete.
"$kc" -strict -summary \
	-skip Secret \
	-ignore-filename-pattern '.*\.example\.yaml' \
	"${files[@]}"

echo "OK: every manifest is a document Kubernetes would accept, unknown fields included."
