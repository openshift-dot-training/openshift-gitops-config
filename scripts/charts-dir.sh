# scripts/charts-dir.sh - sourced by render.sh and validate.sh.
# Sets CHARTS_DIR to an openshift-gitops-charts checkout: $CHARTS_DIR if set,
# else a sibling ../openshift-gitops-charts. Empty when none is found.
root="$(git rev-parse --show-toplevel)"
if [[ -z ${CHARTS_DIR:-} && -d "$root/../openshift-gitops-charts/charts" ]]; then
  CHARTS_DIR="$(cd "$root/../openshift-gitops-charts" && pwd)"
fi
if [[ -n ${CHARTS_DIR:-} && ! -d "$CHARTS_DIR/charts/olm-operator" ]]; then
  echo "CHARTS_DIR=$CHARTS_DIR is not an openshift-gitops-charts checkout" >&2
  CHARTS_DIR=""
fi
CHARTS_DIR=${CHARTS_DIR:-}
