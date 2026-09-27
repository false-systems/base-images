# shellcheck shell=bash
# Shared by the ci/ scripts. Source it; do not run it.
#
# BUILDX overrides how buildx is invoked, e.g. on a Mac where the plugin is not
# registered with the docker CLI:
#   BUILDX=/opt/homebrew/lib/docker/cli-plugins/docker-buildx ci/smoke.sh rust
# IMAGE_REGISTRY (docker-bake.hcl) changes the image names the same way it
# does for `docker buildx bake`.

buildx() {
  # shellcheck disable=SC2086 # BUILDX may be "docker buildx" (two words).
  ${BUILDX:-docker buildx} "$@"
}

# Prints "<target> <first tag>" for each bake target in the given targets or
# groups, straight from docker-bake.hcl, so no script repeats a tag.
bake_refs() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  (cd "$root" && buildx bake --print "$@" 2>/dev/null) |
    jq -r '.target | to_entries[] | "\(.key) \(.value.tags[0])"'
}

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}
