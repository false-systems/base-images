#!/usr/bin/env bash
# Fails when a published builder image is older than STALE_DAYS (default 10).
#
#   ci/staleness.sh [bake target or group]...     # default: every image
#
# The weekly rebuild is how Debian security fixes reach these images: the
# pinned upstream digests rarely move (rust:<version> is frozen once a newer
# Rust ships, and hexpm publishes new dated tags instead of re-pushing old
# ones). GitHub silently disables the schedule of a public repository after
# 60 days without activity, and a disabled schedule cannot report itself, so
# this check is meant to run from OUTSIDE this repository, e.g. a weekly job in
# false-infra. See README.md, "Keeping the weekly rebuild alive".
#
# It reads the image config `created` time of every platform behind each
# moving tag (an anonymous pull; the packages are public), and the oldest one
# counts. A weekly schedule keeps every image under 8 days old; 10 leaves room
# for one slow or retried run.
#
# BUILDX and IMAGE_REGISTRY as in ci/lib.sh.
set -euo pipefail
# shellcheck source=ci/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

max_days=${STALE_DAYS:-10}
[ $# -gt 0 ] || set -- default

refs="$(bake_refs "$@")"
[ -n "$refs" ] || { echo "no bake targets for: $*" >&2; exit 2; }

status=0
while read -r target tag; do
  if ! config="$(buildx imagetools inspect "$tag" --format '{{json .Image}}')"; then
    echo "::error::cannot read ${tag}"
    status=1
    continue
  fi
  # A multi-arch tag gives {"linux/amd64": {config}, ...}, a single image gives
  # the config itself. BuildKit writes nanoseconds, which fromdateiso8601
  # does not take.
  age="$(jq -r '
    (if has("created") then [.] else [.[]] end)
    | map(.created | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)
    | (now - min) / 86400 | floor' <<< "$config")"
  if [ "$age" -gt "$max_days" ]; then
    echo "::error::${tag} was built ${age} days ago (limit ${max_days}); is the weekly schedule of false-systems/base-images disabled?"
    status=1
  else
    echo "ok: ${tag} (${target}) was built ${age} days ago"
  fi
done <<< "$refs"
exit "$status"
