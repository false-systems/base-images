#!/usr/bin/env bash
# Trivy scan of locally loaded builder images, before anything is pushed.
#
#   ci/scan.sh rust | elixir | <target>...
#
# For each image: a report of HIGH and CRITICAL findings (fixed or not) in the
# log and the job summary, then the gate: any CRITICAL with a fix available
# fails the job. Unfixed CRITICALs are reported but do not block, since a
# rebuild cannot remove them; the weekly rebuild picks up the fix once Debian
# or the tool ships it.
#
# Trivy runs from its own image, pinned below by digest, with the Docker
# socket mounted so it scans the images `bake --load` just put there. CI and a
# laptop therefore run the same Trivy, and no setup action is needed. To move
# it, resolve the new tag's index digest:
#   docker buildx imagetools inspect ghcr.io/aquasecurity/trivy:<version>
# TRIVY overrides the whole command, e.g. TRIVY=trivy for a local install.
set -euo pipefail
# shellcheck source=ci/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -gt 0 ] || { echo "usage: $0 <bake target or group>..." >&2; exit 2; }

TRIVY_IMAGE=ghcr.io/aquasecurity/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969

trivy() {
  if [ -n "${TRIVY:-}" ]; then
    # shellcheck disable=SC2086 # TRIVY may be a multi-word command.
    ${TRIVY} "$@"
  else
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
      -v base-images-trivy-cache:/root/.cache "$TRIVY_IMAGE" "$@"
  fi
}

refs="$(bake_refs "$@")"
[ -n "$refs" ] || { echo "no bake targets for: $*" >&2; exit 2; }

status=0
first=1
while read -r target ref; do
  echo "== Trivy report (HIGH, CRITICAL): ${ref}"
  db_flags=()
  [ "$first" = 1 ] || db_flags=(--skip-db-update)
  first=0
  # ${a[@]+...}: an empty array under set -u, even in the Mac's bash 3.2.
  report="$(trivy image --quiet ${db_flags[@]+"${db_flags[@]}"} --scanners vuln \
    --severity HIGH,CRITICAL --format table "$ref")"
  printf '%s\n' "$report"
  summary "### Trivy: \`${target}\` (\`${ref}\`)" '```text' \
    "$(printf '%s\n' "$report" | head -n 300)" '```'

  echo "== Trivy gate (fixable CRITICAL): ${ref}"
  if ! trivy image --quiet --skip-db-update --scanners vuln --severity CRITICAL \
      --ignore-unfixed --exit-code 1 --format table "$ref"; then
    echo "::error::${ref} has CRITICAL vulnerabilities with a fix available"
    status=1
  fi
done <<< "$refs"
exit "$status"
