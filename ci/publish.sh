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
# docker-bake.hcl.
#
# Verify first, tag second. For every target, `imagetools create --dry-run`
# computes the index that would be pushed, and it must hold exactly one
# linux/amd64 and one linux/arm64 image plus an attestation manifest (SBOM +
# provenance) for each. Only when every target passes does any tag move, so a
# bad index is never published, and a failed check of rust-ebpf also keeps
# rust-builder's tag where it was. After tagging, the pushed index is
# inspected and checked again.
#
# PUBLISH_DAY overrides the date and PUBLISH_TARGETS the targets or groups (CI
# publishes one group per job; tests and manual re-runs narrow it further).
# BUILDX and IMAGE_REGISTRY as in ci/lib.sh.
set -euo pipefail
# shellcheck source=ci/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dir=${1:?usage: $0 <digests dir>}
day=${PUBLISH_DAY:-$(date -u +%Y%m%d)}
arches=(amd64 arm64)

# shellcheck disable=SC2086 # deliberate word splitting of the target list
refs="$(bake_refs ${PUBLISH_TARGETS:-default})"
[ -n "$refs" ] || { echo "no bake targets" >&2; exit 1; }

# Sets `sources` to <repo>@<digest> for each arch of one target.
load_sources() {
  local target=$1 repo=${2%:*} arch
  sources=()
  for arch in "${arches[@]}"; do
    [ -s "${dir}/${target}-${arch}" ] || {
      echo "::error::no ${arch} digest for ${target} in ${dir}"
      return 1
    }
    sources+=("${repo}@$(tr -d '[:space:]' < "${dir}/${target}-${arch}")")
  done
}

# Checks a raw image index (JSON): exactly one linux/<arch> image per arch,
# and one attestation manifest per image.
check_index() {
  local what=$1 raw=$2 arch
  for arch in "${arches[@]}"; do
    jq -e --arg a "$arch" \
      '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a)] | length == 1' \
      <<< "$raw" >/dev/null || {
      echo "::error::${what} does not hold exactly one linux/${arch} image"
      return 1
    }
  done
  jq -e --argjson n "${#arches[@]}" \
    '[.manifests[] | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest")] | length == $n' \
    <<< "$raw" >/dev/null || {
    echo "::error::${what} is missing attestation manifests (SBOM/provenance)"
    return 1
  }
}

# Pass 1: every target's index is computed and checked; nothing is written.
while read -r target tag; do
  load_sources "$target" "$tag"
  echo "== check ${target}: ${sources[*]}"
  raw="$(buildx imagetools create --dry-run -t "$tag" "${sources[@]}")"
  check_index "the index for ${tag}" "$raw"
done <<< "$refs"

# Pass 2: tag, then check what the registry now serves.
summary "### Published" "" \
  "| Image | Moving tag | Dated tag | Index digest |" \
  "|---|---|---|---|"

while read -r target tag; do
  load_sources "$target" "$tag"

  dated="${tag}-${day}"
  n=1
  while buildx imagetools inspect "$dated" >/dev/null 2>&1; do
    n=$((n + 1))
    dated="${tag}-${day}.${n}"
  done

  echo "== ${target}: ${tag} + ${dated} <- ${sources[*]}"
  buildx imagetools create -t "$tag" -t "$dated" "${sources[@]}"
  check_index "$tag" "$(buildx imagetools inspect --raw "$tag")"

  digest="$(buildx imagetools inspect "$tag" --format '{{json .Manifest}}' | jq -r .digest)"
  buildx imagetools inspect "$tag"
  summary "| ${target} | \`${tag}\` | \`${dated}\` | \`${digest}\` |"
done <<< "$refs"

summary "" "Consume as \`FROM <moving tag>@<index digest>\`; Dependabot moves the digest."
