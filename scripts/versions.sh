#!/usr/bin/env bash
# scripts/versions.sh - effective operator version per component and value layer:
#   defaults            components/versions.yaml
#   group-values/<g>    defaults + group-values/<g>/versions.yaml
#   ocp/<x.y>           operators pinned to the OpenShift release, per release
# Cluster overrides (clusters/<cluster>/) are not shown.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

row() { printf '%-22s %-14s %-14s %-24s %s\n' "$@"; }
row layer component channel version approval
show() { # <layer> <merged yaml>
  local merged=$2
  for c in $(yq '.versions // {} | keys | .[]' <<<"$merged"); do
    row "$1" "$c" \
      "$(yq ".versions.\"$c\".channel // \"-\"" <<<"$merged")" \
      "$(yq ".versions.\"$c\".version // .versions.\"$c\".csv // \"MISSING\"" <<<"$merged")" \
      "$(yq ".versions.\"$c\".installPlanApproval // \"Manual\"" <<<"$merged")"
  done
}
merge() { yq ea '. as $i ireduce ({}; . * $i)' "$@"; }

show defaults "$(merge components/versions.yaml)"
for d in group-values/*/; do
  [[ -f $d/versions.yaml ]] || continue
  # only the entries the group changes
  g=$(basename "$d")
  show "group-values/$g" "$(merge components/versions.yaml "$d/versions.yaml" |
    yq ".versions |= with_entries(select(.key as \$k | (load(\"$d/versions.yaml\").versions | has(\$k))))")"
done
for r in $(find ocp -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V); do
  show "ocp/$r" "$(cat "ocp/$r/versions.yaml")"
done
