#!/usr/bin/env bash
# scripts/validate.sh - structural checks before anything reaches the hub.
#
#   1. YAML files use the .yaml extension (no .yml)
#   2. every YAML file outside Helm templates/ parses
#   3. catalog consistency: every component on the default chart has
#      components/<name>/values.yaml; every versions entry names a catalog
#      component; a group-values file that sets a version also sets its own
#      dependencies (when the defaults have some); no two components share an
#      operator namespace (OLM resolves a namespace as one unit)
#   4. OpenShift-pinned operators (catalog.yaml versionPolicy: ocp): each
#      ocp/<x.y>/versions.yaml holds only pinned operators, at a version of that
#      release, and a version for every pinned operator; pinned operators appear
#      in no other versions file except cluster overrides
#   5. bootstrap: the charts tag equals catalog.yaml repos.charts.version; every
#      acm.clusterSets entry has a ManagedClusterSetBinding in openshift-gitops
#      and platform-policies
#   6. the hub chart renders with catalog.yaml + groups.yaml (refuses unknown
#      components, groups without filters, unbound clusterSets)
#   7. every component renders for each value layer that applies to it: the
#      defaults, each group-values/<g>, each ocp/<x.y> (pinned operators) and
#      each cluster folder that overrides it
#   (6 and 7 need openshift-gitops-charts: $CHARTS_DIR or ../openshift-gitops-charts)
#
# Needs yq (mikefarah v4) and helm 3. A missing tool is a warning, unless
# REQUIRE_TOOLS=1 (set in CI), where it is an error.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source scripts/charts-dir.sh

fail=0
err()  { echo "validate: $*" >&2; fail=1; }
need() {
  command -v "$1" >/dev/null && return 0
  if [[ ${REQUIRE_TOOLS:-0} == 1 ]]; then err "$1 not found"; else echo "validate: $1 not found - skipping its checks" >&2; fi
  return 1
}

files=$(git ls-files --cached --others --exclude-standard)

# 1. extension
yml=$(grep -E '\.yml$' <<<"$files" || true)
[[ -n $yml ]] && err "rename to .yaml: $(tr '\n' ' ' <<<"$yml")"

have_yq=0; need yq && have_yq=1
have_helm=0; need helm && have_helm=1

# 2. YAML syntax (Helm templates are Go templates, not YAML)
if (( have_yq )); then
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    yq eval-all 'true' "$f" >/dev/null 2>&1 || err "invalid YAML: $f"
  done < <(grep -E '\.yaml$' <<<"$files" | grep -v '/templates/' || true)
fi

catalog_file=catalog.yaml
if (( have_yq )); then
  default_chart=charts/olm-operator
  # 3. component defaults present
  for c in $(yq '.components | keys | .[]' "$catalog_file"); do
    chart=$(yq ".components.\"$c\".chart // \"$default_chart\"" "$catalog_file")
    if [[ $chart == "$default_chart" && ! -f components/$c/values.yaml ]]; then
      err "components/$c/values.yaml missing (component $c uses $default_chart)"
    fi
  done
  # one operator per namespace
  dup=$(yq '.components | to_entries | .[] | (.value.operator.namespace // .value.namespace)' "$catalog_file" | sort | uniq -d)
  [[ -n $dup ]] && err "operator namespace shared by several components: $(tr '\n' ' ' <<<"$dup")"
  # versions entries must name catalog components
  catalog_keys=$(yq '.components | keys | .[]' "$catalog_file")
  for f in components/versions.yaml group-values/*/versions.yaml ocp/*/versions.yaml clusters/*/main-values.yaml; do
    [[ -f $f ]] || continue
    for c in $(yq '.versions // {} | keys | .[]' "$f"); do
      grep -qx "$c" <<<"$catalog_keys" || err "$f: versions.$c is not a component in $catalog_file"
    done
  done
  # a group that changes a version must carry the dependencies generated for it,
  # not inherit the defaults' list (generated for another version)
  for f in group-values/*/versions.yaml; do
    [[ -f $f ]] || continue
    for c in $(yq '.versions // {} | to_entries | .[] | select(.value.version != null and .value.dependencies == null) | .key' "$f"); do
      if [[ $(yq ".versions.\"$c\".dependencies // null" components/versions.yaml) != null ]]; then
        err "$f: versions.$c.version is set but dependencies are inherited from components/versions.yaml - run scripts/olm-dependencies.py $c --group $(basename "$(dirname "$f")") --catalog <image> --write"
      fi
    done
  done
fi

if (( have_yq )); then
  # 4. operators pinned to the OpenShift release
  pinned=$(yq '.components | to_entries | .[] | select(.value.versionPolicy == "ocp") | .key' "$catalog_file")
  releases=$(find ocp -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V || true)
  [[ -n $pinned && -z $releases ]] && err "pinned components ($(tr '\n' ' ' <<<"$pinned")) but no ocp/<x.y>/versions.yaml"
  for r in $releases; do
    f=ocp/$r/versions.yaml
    [[ $r =~ ^[0-9]+\.[0-9]+$ ]] || err "ocp/$r: the folder name must be an OpenShift release x.y"
    [[ -f $f ]] || { err "ocp/$r: versions.yaml missing"; continue; }
    for c in $(yq '.versions // {} | keys | .[]' "$f"); do
      grep -qx "$c" <<<"$pinned" || err "$f: $c is not versionPolicy: ocp in $catalog_file - independent versions go to components/ or group-values/"
      v=$(yq ".versions.\"$c\".version // \"\"" "$f")
      [[ $v == "$r".* ]] || err "$f: $c ${v:-<no version>} is not an OpenShift $r version"
    done
    for c in $pinned; do
      [[ -n $(yq ".versions.\"$c\".version // \"\"" "$f") ]] || err "$f: no version for $c - clusters on OpenShift $r could not install it"
    done
  done
  for f in components/versions.yaml group-values/*/versions.yaml; do
    [[ -f $f ]] || continue
    for c in $pinned; do
      [[ $(yq ".versions.\"$c\" // \"\"" "$f") == "" ]] || err "$f: $c is pinned to the OpenShift release - its versions belong in ocp/<x.y>/versions.yaml"
    done
  done

  # 5. bootstrap
  for set in $(yq '.acm.clusterSets[]' "$catalog_file"); do
    for ns in openshift-gitops platform-policies; do
      n=$(yq ea "[select(.kind == \"ManagedClusterSetBinding\" and .metadata.namespace == \"$ns\" and .spec.clusterSet == \"$set\")] | length" bootstrap/managedclustersetbindings.yaml)
      [[ $n -ge 1 ]] || err "bootstrap/managedclustersetbindings.yaml: no binding of clusterSet $set in $ns"
    done
  done
  # bootstrap renders the hub chart at the same tag the clusters use
  want=$(yq '.repos.charts.version' "$catalog_file")
  got=$(yq '.spec.sources[] | select(.path == "charts/platform-catalog") | .targetRevision' bootstrap/root-application.yaml)
  [[ $want == "$got" ]] || err "bootstrap/root-application.yaml uses charts $got, catalog.yaml repos.charts.version is $want"
fi

if [[ -z $CHARTS_DIR ]]; then
  if [[ ${REQUIRE_TOOLS:-0} == 1 ]]; then err "no openshift-gitops-charts checkout (CHARTS_DIR)"
  else echo "validate: no openshift-gitops-charts checkout (CHARTS_DIR) - skipping renders" >&2; fi
  have_helm=0
fi

if (( have_helm && have_yq )); then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  # 6. hub chart
  helm template platform-catalog "$CHARTS_DIR/charts/platform-catalog" -f "$catalog_file" -f groups.yaml \
    >"$tmp/hub.yaml" 2>"$tmp/err" || err "hub chart: $(cat "$tmp/err")"

  # 7. each component for each value layer that applies to it (charts in openshift-gitops-charts)
  render() { # <component> <label> <values files...>
    local c=$1 label=$2; shift 2
    local args=()
    for f in "$@"; do [[ -f $f ]] && args+=(-f "$f"); done
    helm template "$c" "$CHARTS_DIR/$chart" -n "$ns" "${args[@]}" >/dev/null 2>"$tmp/err" \
      || err "$c ($label): $(cat "$tmp/err")"
  }
  for c in $(yq '.components | keys | .[]' "$catalog_file"); do
    chart=$(yq ".components.\"$c\".chart // \"$default_chart\"" "$catalog_file")
    [[ -d $CHARTS_DIR/$chart && -z $(yq ".components.\"$c\".repoURL // \"\"" "$catalog_file") ]] || continue
    ns=$(yq ".components.\"$c\".namespace" "$catalog_file")
    base=(components/versions.yaml "components/$c/values.yaml")
    if grep -qx "$c" <<<"$pinned"; then
      layers=(); for r in $releases; do layers+=("ocp/$r"); done
    else
      layers=(defaults); for d in group-values/*/; do [[ -d $d ]] && layers+=("${d%/}"); done
    fi
    for l in "${layers[@]}"; do
      case $l in
        ocp/*) render "$c" "$l" "${base[@]}" "$l/versions.yaml" ;;
        group-values/*) render "$c" "$l" "${base[@]}" "$l/versions.yaml" "$l/$c.yaml" ;;
        *) render "$c" "$l" "${base[@]}" ;;
      esac
    done
    # cluster folders overriding this component (pinned ones on the newest release folder)
    newest=$(tail -1 <<<"$releases")
    for d in clusters/*/; do
      d=${d%/}
      [[ -f $d/values/$c.yaml || $(yq ".versions.\"$c\" // \"\"" "$d/main-values.yaml" 2>/dev/null) != "" ]] || continue
      extra=(); grep -qx "$c" <<<"$pinned" && extra=("ocp/$newest/versions.yaml")
      render "$c" "$d" "${base[@]}" "${extra[@]}" "$d/main-values.yaml" "$d/values/$c.yaml"
    done
  done
fi

(( fail == 0 )) && echo "validate: OK"
exit $fail
