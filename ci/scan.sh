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
# TRIVY overrides the command, e.g. to run it from a container locally:
#   TRIVY="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
#          -v trivy-cache:/root/.cache aquasec/trivy:0.74.0" ci/scan.sh elixir
set -euo pipefail
# shellcheck source=ci/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -gt 0 ] || { echo "usage: $0 <bake target or group>..." >&2; exit 2; }

trivy() {
  # shellcheck disable=SC2086 # TRIVY may be a multi-word command.
  ${TRIVY:-command trivy} "$@"
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
