#!/usr/bin/env bash
# scripts/validate.sh - structural checks before anything reaches the hub.
#
#   1. YAML files use the .yaml extension (no .yml)
#   2. every YAML file outside Helm templates/ parses
#   3. every catalog component on the default chart has components/<name>/values.yaml,
#      every versions.yaml entry names a catalog component, a group that sets a
#      version also sets its own dependencies (when the defaults have some), and no two
#      components share an operator namespace (OLM resolves a namespace as one
#      unit, so one InstallPlan could mix operators)
#   4. the hub chart renders with catalog.yaml + groups.yaml (fails on unknown
#      components); bootstrap/root-application.yaml uses the same charts tag as
#      catalog.yaml
#   5. every component renders through its chart for each group it belongs to,
#      and for every cluster folder that overrides it
#   (4 and 5 need openshift-gitops-charts: $CHARTS_DIR or ../openshift-gitops-charts)
#   6. versionPolicy: ocp components have a version of the level's ocp release
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
  for f in components/versions.yaml group-values/*/versions.yaml; do
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
  # versionPolicy: ocp - the operator version follows the OpenShift release:
  # its x.y must equal the effective ocp of the level (defaults, each group,
  # each cluster folder for the components it overrides)
  pinned=$(yq '.components | to_entries | .[] | select(.value.versionPolicy == "ocp") | .key' "$catalog_file")
  check_pinned() { # <label> <merged yaml> <component>...
    local label=$1 merged=$2; shift 2
    local ocp ver
    ocp=$(yq '.ocp // ""' <<<"$merged")
    for c in "$@"; do
      ver=$(yq ".versions.\"$c\".version // \"\"" <<<"$merged")
      [[ -z $ver ]] && continue
      [[ -n $ocp ]] || { err "$label: $c is pinned to the OpenShift release but no ocp: is set"; continue; }
      [[ $ver == "$ocp".* ]] || err "$label: $c $ver does not match ocp $ocp (versionPolicy: ocp in $catalog_file)"
    done
  }
  merge() { yq ea '. as $i ireduce ({}; . * $i)' "$@"; }
  check_pinned components/versions.yaml "$(merge components/versions.yaml)" $pinned
  for g in $(yq '.groups | keys | .[]' groups.yaml); do
    gf=group-values/$g/versions.yaml; [[ -f $gf ]] || gf=/dev/null
    members=$(yq ".common[], .groups.\"$g\"[]" groups.yaml)
    check_pinned "group $g" "$(merge components/versions.yaml "$gf")" $(comm -12 <(sort <<<"$pinned") <(sort <<<"$members"))
  done
  for d in clusters/*/; do
    f=${d%/}/main-values.yaml; [[ -f $f ]] || continue
    own=$(yq '.versions // {} | keys | .[]' "$f")
    check_pinned "$f" "$(merge components/versions.yaml "$f")" $(comm -12 <(sort <<<"$pinned") <(sort <<<"$own"))
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
  # 4. hub chart
  helm template platform-catalog "$CHARTS_DIR/charts/platform-catalog" -f "$catalog_file" -f groups.yaml \
    >"$tmp/hub.yaml" 2>"$tmp/err" || err "hub chart: $(cat "$tmp/err")"

  # 5. each component x each of its groups (only charts in this repo)
  for c in $(yq '.components | keys | .[]' "$catalog_file"); do
    chart=$(yq ".components.\"$c\".chart // \"$default_chart\"" "$catalog_file")
    [[ -d $CHARTS_DIR/$chart && -z $(yq ".components.\"$c\".repoURL // \"\"" "$catalog_file") ]] || continue
    ns=$(yq ".components.\"$c\".namespace" "$catalog_file")
    groups=$(yq ".groups | to_entries | .[] | select(.value[] == \"$c\") | .key" groups.yaml)
    for g in _none $groups; do
      args=(-f components/versions.yaml)
      [[ -f components/$c/values.yaml ]] && args+=(-f "components/$c/values.yaml")
      [[ -f group-values/$g/versions.yaml ]] && args+=(-f "group-values/$g/versions.yaml")
      [[ -f group-values/$g/$c.yaml ]] && args+=(-f "group-values/$g/$c.yaml")
      helm template "$c" "$CHARTS_DIR/$chart" -n "$ns" "${args[@]}" >/dev/null 2>"$tmp/err" \
        || err "$c (group $g): $(cat "$tmp/err")"
    done
    # every cluster folder that overrides this component (main-values versions or values/<c>.yaml)
    for d in clusters/*/; do
      cl=$(basename "$d")
      [[ -f $d/values/$c.yaml || $(yq ".versions.\"$c\" // \"\"" "$d/main-values.yaml" 2>/dev/null) != "" ]] || continue
      args=(-f components/versions.yaml)
      [[ -f components/$c/values.yaml ]] && args+=(-f "components/$c/values.yaml")
      [[ -f $d/main-values.yaml ]] && args+=(-f "$d/main-values.yaml")
      [[ -f $d/values/$c.yaml ]] && args+=(-f "$d/values/$c.yaml")
      helm template "$c" "$CHARTS_DIR/$chart" -n "$ns" "${args[@]}" >/dev/null 2>"$tmp/err" \
        || err "$c (cluster $cl): $(cat "$tmp/err")"
    done
  done
fi

(( fail == 0 )) && echo "validate: OK"
exit $fail
