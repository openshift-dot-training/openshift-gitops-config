#!/usr/bin/env bash
# Render the hub catalog, or one component as Argo CD would, for review.
#   scripts/render.sh                              -> rendered/hub.yaml
#   scripts/render.sh odf group-a [cluster]        -> rendered/odf-group-a[-cluster].yaml
# Needs an openshift-gitops-charts checkout: $CHARTS_DIR or ../openshift-gitops-charts
# (check out the tag in catalog.yaml repos.charts.version to see what clusters get).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source scripts/charts-dir.sh
[[ -n $CHARTS_DIR ]] || { echo "render: set CHARTS_DIR to an openshift-gitops-charts checkout" >&2; exit 1; }
mkdir -p rendered

if [[ $# -eq 0 ]]; then
  helm template platform-catalog "$CHARTS_DIR/charts/platform-catalog" \
    -f catalog.yaml -f groups.yaml > rendered/hub.yaml
  echo "rendered/hub.yaml"
  exit 0
fi

comp=$1 group=${2:-_none} cluster=${3:-}
# same order as the ApplicationSet valueFiles (catalog.yaml / chart defaults)
args=()
for f in components/versions.yaml "components/$comp/values.yaml" \
         "group-values/$group/versions.yaml" "group-values/$group/$comp.yaml" \
         ${cluster:+"clusters/$cluster/main-values.yaml" "clusters/$cluster/values/$comp.yaml"}; do
  [[ -f $f ]] && args+=(-f "$f")
done
chart=$(yq ".components.\"$comp\".chart // \"charts/olm-operator\"" catalog.yaml)
ns=$(yq ".components.\"$comp\".namespace" catalog.yaml)
out="rendered/$comp-$group${cluster:+-$cluster}.yaml"
helm template "$comp" "$CHARTS_DIR/$chart" -n "$ns" "${args[@]}" > "$out"
echo "$out"
