#!/usr/bin/env bash
# scripts/versions.sh - effective operator version per component and group
# (components/versions.yaml merged with group-values/<group>/versions.yaml).
# Cluster overrides (clusters/<cluster>/) are not shown.
#   scripts/versions.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

groups=$(yq '.groups | keys | .[]' groups.yaml)
printf '%-11s %-9s %-13s %-10s %s\n' component group channel version approval
for g in $groups; do
  gf=group-values/$g/versions.yaml; [[ -f $gf ]] || gf=/dev/null
  merged=$(yq eval-all '. as $i ireduce ({}; . * $i) | .versions' components/versions.yaml "$gf")
  for c in $(yq ".common[], .groups.\"$g\"[]" groups.yaml); do
    printf '%-11s %-9s %-13s %-10s %s\n' "$c" "$g" \
      "$(yq ".\"$c\".channel // \"-\"" <<<"$merged")" \
      "$(yq ".\"$c\".version // \"MISSING\"" <<<"$merged")" \
      "$(yq ".\"$c\".installPlanApproval // \"Manual\"" <<<"$merged")"
  done
done
