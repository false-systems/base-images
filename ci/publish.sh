#!/usr/bin/env bash
# Merges the per-architecture images that the build job pushed by digest into
# one multi-arch index per image, and tags it twice:
#
#   <tag>            moving, e.g. rust-builder:1.97.1; consumers pin its digest
#   <tag>-YYYYMMDD   immutable; a second run on the same day gets .2, .3, ...
#
#   ci/publish.sh <digests dir>
#
# The digests dir holds one file per image and arch, named <target>-<arch>
# and containing the sha256 digest (written by the build job). Tags come from
# docker-bake.hcl. After tagging, the index must hold exactly one linux/amd64
# and one linux/arm64 image plus an attestation manifest (SBOM + provenance)
# for each, or the job fails.
#
# PUBLISH_DAY overrides the date and PUBLISH_TARGETS the targets (tests,
# manual re-runs). BUILDX and IMAGE_REGISTRY as in ci/lib.sh.
set -euo pipefail
# shellcheck source=ci/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dir=${1:?usage: $0 <digests dir>}
day=${PUBLISH_DAY:-$(date -u +%Y%m%d)}
arches=(amd64 arm64)

# PUBLISH_TARGETS narrows the run to some bake targets or groups (a manual
# re-publish of one image, or a local test); CI publishes all of them.
# shellcheck disable=SC2086 # deliberate word splitting of the target list
refs="$(bake_refs ${PUBLISH_TARGETS:-default})"
[ -n "$refs" ] || { echo "no bake targets" >&2; exit 1; }

# Everything must be present before any tag moves.
while read -r target _; do
  for arch in "${arches[@]}"; do
    [ -s "${dir}/${target}-${arch}" ] || {
      echo "::error::no ${arch} digest for ${target} in ${dir}"
      exit 1
    }
  done
done <<< "$refs"

summary "### Published" "" \
  "| Image | Moving tag | Dated tag | Index digest |" \
  "|---|---|---|---|"

while read -r target tag; do
  repo=${tag%:*}
  sources=()
  for arch in "${arches[@]}"; do
    sources+=("${repo}@$(tr -d '[:space:]' < "${dir}/${target}-${arch}")")
  done

  dated="${tag}-${day}"
  n=1
  while buildx imagetools inspect "$dated" >/dev/null 2>&1; do
    n=$((n + 1))
    dated="${tag}-${day}.${n}"
  done

  echo "== ${target}: ${tag} + ${dated} <- ${sources[*]}"
  buildx imagetools create -t "$tag" -t "$dated" "${sources[@]}"

  raw="$(buildx imagetools inspect --raw "$tag")"
  for arch in "${arches[@]}"; do
    jq -e --arg a "$arch" \
      '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a)] | length == 1' \
      <<< "$raw" >/dev/null || {
      echo "::error::${tag} does not hold exactly one linux/${arch} image"
      exit 1
    }
  done
  jq -e --argjson n "${#arches[@]}" \
    '[.manifests[] | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest")] | length == $n' \
    <<< "$raw" >/dev/null || {
    echo "::error::${tag} is missing attestation manifests (SBOM/provenance)"
    exit 1
  }

  digest="$(buildx imagetools inspect "$tag" --format '{{json .Manifest}}' | jq -r .digest)"
  buildx imagetools inspect "$tag"
  summary "| ${target} | \`${tag}\` | \`${dated}\` | \`${digest}\` |"
done <<< "$refs"

summary "" "Consume as \`FROM <moving tag>@<index digest>\`; Dependabot moves the digest."
