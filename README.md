# OpenShift GitOps config

What runs where, at which exact version. This repository holds:

- the component catalog, `catalog.yaml`;
- the cluster groups, `groups.yaml`;
- the exact operator versions and their OLM dependencies;
- the values per component, per group and per cluster (`clusters/<cluster>/`);
- the one-time hub bootstrap.

The generic Helm charts live in **openshift-gitops-charts** and are pinned by
tag (`catalog.yaml` → `repos.charts.version`). How the charts install and
approve operators is described in that repository's README, in its
"InstallPlan approver" section.

| Repository | Holds | Changes when |
|---|---|---|
| openshift-gitops-charts | how to install an operator (generic charts, approver) | the mechanism changes (tagged releases) |
| openshift-gitops-config (this one) | what runs where, versions, values | every day: upgrades, new clusters, new groups |

## The model: ACM decides where, Git holds what and which version

| Question | Where it is answered |
|---|---|
| **What** can be installed, and how? | `catalog.yaml` → `components`, with the generic charts of openshift-gitops-charts |
| **Which clusters** get which components? | `groups.yaml`: each group is a set of **ACM Placement filters** listing its components |
| **Which version and values** does a cluster get? | value layers keyed by the cluster's labels: defaults, `group-values/`, `ocp/<x.y>/`, `clusters/<cluster>/` |

**Groups are ACM Placement filters.** A group combines any of the following:

- `clusterSets`, the ManagedClusterSets;
- a `labelSelector` on ManagedCluster labels: labels you set, such as
  `platform/group`, or labels ACM sets on every cluster, such as
  `openshiftVersion-major-minor`, `cloud`, `vendor` and `name`;
- a `claimSelector` on ClusterClaims, such as
  `platform.open-cluster-management.io` and
  `region.open-cluster-management.io`.

ACM evaluates the filters. It works the same for clusters ACM deployed and
clusters it imported, and it scales to any number of clusters. A new case
means a new filter, not a new convention.

```yaml
# groups.yaml
common: [logging, loki]                  # placed by every group
groups:
  group-a:                               # a label you set
    labelSelector: { matchLabels: { platform/group: group-a } }
    components: [odf, acs, grafana]
  baremetal:                             # a claim ACM reports
    claimSelector:
      matchExpressions:
        - { key: platform.open-cluster-management.io, operator: In, values: [BareMetal] }
    components: [nmstate]
```

The hub chart (`charts/platform-catalog` in openshift-gitops-charts) renders
three things **per component**:

1. **An ACM Placement.** It has one predicate per group placing the component,
   and the predicates are OR-ed, so a cluster matching several groups gets the
   union of their components.
2. **An ApplicationSet.** It takes its clusters from that Placement's
   decisions (`clusterDecisionResource`), merged with the cluster generator to
   read each cluster's labels.
3. **A health Policy**, bound to an identical Placement. ACM governance and
   Argo CD always see the same clusters.

### Per-cluster exceptions (no new group needed)

```
component.platform/<component>=enabled    # add a component to one cluster
component.platform/<component>=disabled   # remove a component from one cluster
```

Each group predicate excludes clusters carrying the component label, and one
extra predicate selects the `enabled` ones. See
`examples/managed-clusters.yaml`.

### Values precedence (low → high)

Each generated Application is multi-source: the chart from
openshift-gitops-charts, the values from this repository. The layers are
`catalog.yaml` → `valueFiles`. `{label:<key>}` is any label of the cluster,
including the ones ACM sets.

```
olm-operator chart values.yaml                          chart defaults (charts repo)
components/versions.yaml                                default versions
components/<component>/values.yaml                      component defaults
group-values/{label:platform/group}/versions.yaml       versions for clusters with that label
group-values/{label:platform/group}/<component>.yaml    values for clusters with that label
ocp/{label:openshiftVersion-major-minor}/versions.yaml  OpenShift-pinned operators, by release
clusters/<cluster>/main-values.yaml                     cluster-wide values
clusters/<cluster>/values/<component>.yaml              cluster values
```

All of these files are optional (`ignoreMissingValueFiles: true`). Groups
decide *where*; the layers decide *what values*. A layer can follow any label,
so add one in `valueFiles` when a new dimension needs its own values (region,
cloud, environment…). For example, `group-values/group-a/odf.yaml` defines a
2Ti StorageCluster for clusters labelled `platform/group=group-a`, and the
example cluster overrides only `storageCluster.storageSize: 4Ti`.

### Versions: default → group → cluster

Every operator is installed at an **exact version** with
`installPlanApproval: Manual`. Versions are values. They live in one
`versions:` block per level, so a group's versions can be read in one file:

```yaml
# components/versions.yaml              defaults for every cluster
approver:
  image: registry.redhat.io/openshift4/ose-cli-rhel9:v4.18
versions:
  logging:  { channel: stable-6.2, version: 6.2.3 }
  portworx: { channel: stable, version: 25.2.1, pxVersion: 3.3.1 }

# group-values/group-b/versions.yaml    only what differs for the group
versions:
  logging: { channel: stable-6.1, version: 6.1.4 }

# ocp/4.19/versions.yaml               operators pinned to the OpenShift release
versions:
  odf: { channel: stable-4.19, version: 4.19.1, dependencies: [...] }

# clusters/<cluster>/main-values.yaml    one cluster (e.g. a canary)
versions:
  logging: { channel: stable-6.2, version: 6.2.13 }
```

| Field | Meaning |
|---|---|
| `channel` | OLM channel. Change it together with `version`. |
| `version` | Exact operator version `x.y.z`. **Required**: a Manual component without it fails to render, so CI and the pre-commit hook block it. |
| `csv` | Full CSV name. Only needed when `subscription.csvFormat` cannot build it. |
| `installPlanApproval` | `Manual` (default). `Automatic` removes the approver for that component. |
| `dependencies` | Exact CSVs that OLM installs with this version. The approver accepts only these. Generated: see *OLM dependencies of each version*. |
| anything else | Operand versions tied to the operator, e.g. `pxVersion` for the Portworx `StorageCluster` image (`group-values/group-b/portworx.yaml`). |

The CSV name is built from the version with `subscription.csvFormat` in
`components/<name>/values.yaml`. The default is `<package>.v<version>`, and ODF
uses `odf-operator.v%s-rhodf`. The most specific level wins, so a cluster's
folder `clusters/<cluster>/` can always override its group.

Versions are deliberately **not** in `groups.yaml`. Anything coming from the
hub catalog reaches the Application as inline Helm `values`, which in Argo CD
override every value file, so a cluster could no longer override it.

Which versions are compatible is decided outside this repo by
olm-upgrade-analyzer: the OpenShift ±1 support rule, z-stream requirements,
and certified combinations such as Portworx (OpenShift x.y.z + operator + PX
Enterprise). This repo installs exactly what those files say.

- `scripts/versions.sh` prints the effective version of every component per group.
- `scripts/validate.sh` fails on a missing `version`, or on a `versions:` entry
  for an unknown component.

### OLM dependencies of each version

The approver accepts only the exact dependency CSVs listed in `versions.<component>.dependencies`.
There are two ways to produce that list.

**OLM dependencies from the upgrade plan.** olm-upgrade-analyzer writes
`gitops-versions.yaml` next to its oc-mirror configuration. It holds the
exact `channel`, `version`, `csv` and `dependencies` of every operator for the
target OpenShift release, in this repo's `versions:` format. Run it with
`--gitops-repo <this checkout>` to get this repo's component names, including
`acm.mceVersion` / `acm.mceChannel` for MCE. Then merge the block into
`components/versions.yaml`, `group-values/<group>/versions.yaml` or a cluster's
`clusters/<cluster>/main-values.yaml`.

**OLM dependencies: `scripts/olm-dependencies.py`.** Each bundle in the
catalog declares its dependencies (`olm.package.required`,
`olm.gvk.required`, `olm.constraint`). The script does the following:

1. Pulls the package from the catalog image the same way olm-upgrade-analyzer
   does (`oc image extract … --path /configs/<package>/`).
2. Finds the bundle for the exact version in the versions files.
3. Resolves its dependencies transitively, including the package that
   provides a required GVK.
4. Writes the exact dependency CSVs to `versions.<component>.dependencies`,
   in the file that defines that version.

The approver then accepts only those exact CSVs:

```bash
# after choosing a new version (default, group or cluster file):
scripts/olm-dependencies.py odf --group group-a \
    --catalog registry.example.com/CHANGE-ME/redhat-operator-index:v4.18 --check   # + added / - removed, exit 1 on drift
scripts/olm-dependencies.py odf --group group-a \
    --catalog registry.example.com/CHANGE-ME/redhat-operator-index:v4.18 --write   # update group-values/group-a/versions.yaml
scripts/olm-dependencies.py odf --versions-file clusters/<cluster>/main-values.yaml \
    --catalog ... --write                                                           # a cluster override
```

Other things the script and the checks cover:

- **Catalog image.** Use the mirrored index for airgapped clusters. Pass
  `--authfile` for registry credentials, or `--configs <dir>` for an already
  extracted `/configs` tree. Add `--full` when a required GVK is provided by a
  package that is not pulled yet.
- **CSV name check.** The script warns when `subscription.csvFormat` does not
  produce the real CSV name.
- **Drift check.** `scripts/validate.sh` fails when a group changes a
  `version` but would inherit the default file's dependency list, which was
  generated for another version.
- **Fallback.** Without a generated list, the approver falls back to the CSV
  name prefixes in `subscription.dependencies`.

## Variants

Every operator is installed the same way: an exact version, Manual approval,
and an approver that accepts only that version. What changes between operators
is how their versions move, what OLM installs with them, and how their CSVs are
named. Each variant has an example component.

### How the version moves

| Variant | Examples | How it is expressed | What checks it |
|---|---|---|---|
| **Independent of the OpenShift release** | `logging`, `loki`, `acs`, `grafana`, `mongodb`, `dynatrace` | `channel` + exact `version`. It changes when you decide, inside OpenShift's support window (usually ±1 minor, `olm.maxOpenShiftVersion`). | olm-upgrade-analyzer plans it. `olm-dependencies.py` warns when the version is not in its channel. |
| **Pinned to the OpenShift release** | `odf`, `nmstate` (also kubevirt, nfd, local-storage) | `versionPolicy: ocp` in `catalog.yaml`. Versions live in `ocp/<x.y>/versions.yaml`, picked by the release ACM reports for each cluster. | `validate.sh`: each release folder holds only pinned operators, all of them, at versions of that release. |
| **Certified combination** | `portworx` | The operator version and the operand version (`pxVersion`, used by the StorageCluster) sit in the same `versions` entry and always change together. The certified OpenShift x.y.z + operator + operand matrix is checked outside this repo. | olm-upgrade-analyzer vendor constraints. |

**Versions follow the cluster's real OpenShift release.** Pinned operators
appear only in `ocp/<x.y>/versions.yaml`. Each cluster reads the folder of
the release ACM reports for it (label `openshiftVersion-major-minor`). A
cluster upgraded from 4.18 to 4.19 therefore switches to `ocp/4.19/` by
itself, even in the middle of a fleet upgrade, with nothing to edit per
cluster or per group.

`validate.sh` enforces these rules for every release folder:

- the folder holds only pinned operators;
- each one at a version of that release;
- every pinned operator has a version, so a cluster on that release can
  always install it.

It also refuses pinned operators in any other versions file. Only an explicit
cluster override is allowed.

**Upgrading OpenShift.**

1. olm-upgrade-analyzer plans the path. An EUS jump such as 4.18 → 4.20 needs
   the 4.19 catalog for pinned operators.
2. **Before** the first cluster reaches a release, add `ocp/<x.y>/versions.yaml`
   for it, with the pinned versions and their dependencies (analyzer export
   or `scripts/olm-dependencies.py --versions-file ocp/<x.y>/versions.yaml`).
3. Upgrade the clusters. ACM updates their label, and Argo CD applies that
   release's versions.
4. Independent operators only move when their supported OpenShift range
   requires it.

### What OLM installs with the operator

| Variant | Example | How it is expressed |
|---|---|---|
| Nothing else (one CSV) | most operators | `dependencies: []` |
| OLM dependency, same InstallPlan | `web-terminal` → `devworkspace-operator` | exact CSVs in `versions.<name>.dependencies` |
| Subscription created at runtime, same namespace | `odf` → `odf-dependencies` → 8 sub-operators | `approver.extra` with `csvFromMain` + `dependenciesKey` (`components/odf/values.yaml`) |
| Subscription created at runtime, other namespace | `acm` → `multicluster-engine` | `approver.extra` with `versionKey` / `channelKey` / `csvFormat` (`components/acm/values.yaml`) |

The dependency lists are generated from the catalog, never written by hand.
See *OLM dependencies of each version*.

### How the CSV is named

| Variant | Example | How it is expressed |
|---|---|---|
| `<package>.v<version>` | `cluster-logging.v6.2.3` | nothing: the default `csvFormat` |
| vendor suffix | `odf-operator.v4.18.3-rhodf` | `subscription.csvFormat: odf-operator.v%s-rhodf` |
| other prefix | `portworx-operator.v25.2.1` (package `portworx-certified`) | `subscription.csvFormat: portworx-operator.v%s` |
| no `v`, build number | `kubernetes-nmstate-operator.4.18.0-202506020833` | exact `csv:` in the `versions` entry |

olm-upgrade-analyzer always writes the exact `csv:`, so its exports work for
every variant.

### Install mode and approval

| Variant | Example | How it is expressed |
|---|---|---|
| own namespace | `odf`, `nmstate` | `operatorGroup.targetNamespaces: [<namespace>]` |
| all namespaces | `logging`, `loki`, `web-terminal` | `operatorGroup.targetNamespaces: []`, still in a namespace of its own |
| Manual, exact version (default) | every component | `version` (or `csv`) required |
| Automatic | none | `installPlanApproval: Automatic`: no approver, no version required |

One operator per namespace is enforced. OLM resolves all Subscriptions in a
namespace together, so a shared namespace could mix operators in one
InstallPlan.

## Layout

```
catalog.yaml                    components (what can be installed), repos, charts tag
groups.yaml                     groups (ACM Placement filters) -> components
ocp/<x.y>/versions.yaml         OpenShift-pinned operator versions per release
components/versions.yaml        default exact versions (+ dependencies) and approver image
components/<name>/values.yaml   per-component defaults for the chart
group-values/<group>/           versions.yaml and <component>.yaml per group
clusters/<cluster>/             main-values.yaml, values/<component>.yaml, manifests/<component>/
bootstrap/                      one-time hub setup (oc apply -k)
examples/managed-clusters.yaml  how clusters join groups (labels)
scripts/validate.sh             checks + renders (hooks + CI)
scripts/render.sh               local render for review
scripts/versions.sh             effective versions per group
scripts/olm-dependencies.py     OLM dependencies of a pinned version, from the catalog
scripts/check-sensitive.sh      blocks credentials, internal hostnames and IPs
githooks/                       pre-commit, commit-msg, pre-push; allowed-domains
```

## Bootstrap (once per hub)

Prereqs: ACM and OpenShift GitOps installed on the hub.

1. Replace the `CHANGE-ME` placeholders with your values in your copy of the
   two repositories. They are the repository URLs in `catalog.yaml`
   (`repos.*`), `bootstrap/root-application.yaml` and
   `bootstrap/appprojects.yaml`, and the approver image. Keep
   `catalog.yaml` `repos.charts.version` and the charts `targetRevision` in
   `bootstrap/root-application.yaml` on the same tag; `scripts/validate.sh`
   checks this.
2. `oc apply -k bootstrap/`. This creates:
   - the `platform-policies` namespace
   - ManagedClusterSetBindings
   - a `GitOpsCluster`, which registers managed clusters in Argo CD
   - RBAC that lets Argo CD manage ACM policies and placements
   - the AppProjects
   - the root Application `platform-catalog`. It is multi-source: the hub chart
     comes from the charts repository at the tag, `catalog.yaml` and
     `groups.yaml` come from this one.
   - the `acm-placement` ConfigMap, and read access to PlacementDecisions for
     the ApplicationSet controller.
3. Put the clusters in the ClusterSets of `acm.clusterSets`, and label them
   for the groups that use your own labels (`platform/group`). ACM's own
   labels and claims need no action. Optionally pin a cluster to other
   revisions with `chartsRevision` / `configRevision` (see
   `examples/managed-clusters.yaml`).

## Day-2 operations

| Task | Change |
|---|---|
| Add a cluster to a group | make it match the group's filters, e.g. `oc label managedcluster <c> platform/group=group-a` (ClusterSet, ACM labels and claims need nothing) |
| Move a cluster between groups | change what it matches (components only in the old group are left running, see *Removal* below) |
| Add a component to a group | add it to the group's list in `groups.yaml` |
| Add a new component | add an entry under `components:`, add `components/<name>/values.yaml` and its default version in `components/versions.yaml`, then reference it in `groups.yaml` |
| Create a new group | add a group with its filters and components in `groups.yaml` |
| Tune a component for a group | `group-values/<group>/<component>.yaml` |
| Tune a component for one cluster | `clusters/<cluster>/values/<component>.yaml` |
| Upgrade a component everywhere | `version` (+ `channel`) in `components/versions.yaml` after mirroring it, then `scripts/olm-dependencies.py <component> --write` |
| Upgrade a component for one group | `group-values/<group>/versions.yaml` |
| Prepare an OpenShift release | add `ocp/<x.y>/versions.yaml` with every pinned operator before the first cluster reaches it (see *Variants*) |
| Canary a version on one cluster | `versions:` in that cluster's `clusters/<cluster>/main-values.yaml` |
| Pin a cluster to a charts tag / config branch | labels `chartsRevision` / `configRevision` |

A component name that `groups.yaml` lists but the catalog does not define makes
the render fail on purpose:
`groups.yaml: component "x" (group "y") is not defined in the catalog (components)`.
So does a group without any filter (it would select every cluster) and a group
using a ClusterSet that is not bound (`acm.clusterSets`).

A component does not have to use `charts/olm-operator`. Set `chart:` (and
`repoURL:` if the chart lives in another repository) to any Helm chart path.
Use `helmValues` for values computed from cluster labels, and
`clusterManifests: true` to also sync `clusters/<cluster>/manifests/<component>/`
as raw manifests. Add the chart repository to `bootstrap/appprojects.yaml`.

### Removal

`preserveResourcesOnDeletion: true` is the default. If a cluster leaves a group
or a component is removed, Argo CD deletes the Application but **leaves the
workload running**. This protects stateful components such as ODF and Portworx.
Decommission them deliberately.

## Local review

Both need an openshift-gitops-charts checkout, either in `$CHARTS_DIR` or
next to this repository. Check out the tag in `catalog.yaml` to see what the
clusters get.

```bash
scripts/render.sh                       # -> rendered/hub.yaml (what the hub will apply)
scripts/render.sh odf group-a cluster-a1         # -> rendered/odf-group-a-cluster-a1.yaml
```

## Placeholders and git hooks

This repository is published, so it holds **no real environment data**:
repository URLs, hostnames, cluster names and credentials are placeholders
(`example.com`, `CHANGE-ME-...`). Real values belong in your own copy of the
repositories.

Enable the hooks once per clone:

```bash
git config core.hooksPath githooks
```

| Hook | Checks |
|---|---|
| `pre-commit` | `scripts/check-sensitive.sh --staged`, then `scripts/validate.sh` |
| `commit-msg` | the commit message, for the same sensitive data |
| `pre-push` | refuses force-pushes to and deletion of `main`, and re-scans every pushed commit (diffs and messages) |

`scripts/check-sensitive.sh` blocks the following:

- private keys
- pull secrets
- GitHub, GitLab and AWS tokens
- JWT / service-account tokens
- `password:`, `token:` or `secret:` keys with a real value
- hostnames on a domain not listed in `githooks/allowed-domains`
- IPv4 addresses outside loopback and the RFC 5737 documentation ranges

To allow a public value, add its domain to `githooks/allowed-domains`. For a
one-off, add `# sensitive-scan: allow (<reason>)` on the same line.

`scripts/validate.sh` checks the following:

- YAML files use the `.yaml` extension (not `.yml`), and every YAML file parses
- catalog consistency: component defaults exist, versions name catalog
  components, one operator per namespace
- the OpenShift-pinned rules for `ocp/<x.y>/`
- every `acm.clusterSets` entry is bound in both namespaces, and the bootstrap
  charts tag equals `catalog.yaml`
- the hub chart renders (refuses unknown components, groups without filters,
  unbound ClusterSets)
- every component renders for each value layer that applies to it

The GitHub Actions workflow runs both scripts on every PR, so a commit made
with `--no-verify` is still caught.

## Assumptions to verify on your hub

- **ACM sets `openshiftVersion-major-minor` on every ManagedCluster.** The
  `ocp/<x.y>/` layer is keyed on it. Check with `oc get managedcluster --show-labels`.
  If your ACM version names it differently, change the `{label:...}` in
  `catalog.yaml` → `valueFiles`.
- **ManagedCluster labels reach the Argo CD cluster secrets.** Placements
  select the clusters, but the `{label:<key>}` value layers read the labels
  that GitOpsCluster copies to the cluster secrets. Check with:
  `oc get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true --show-labels`
- **The ApplicationSet controller can read PlacementDecisions.** It needs the
  `acm-placement` ConfigMap and the Role from `bootstrap/acm-placement.yaml`.
  The controller's ServiceAccount is `openshift-gitops-applicationset-controller`
  in OpenShift GitOps; adjust it if your instance differs.
- **OperatorPolicy** (used by the health policies) needs ACM 2.11 or later. On
  older hubs, set `acm.healthPolicies: false`, or supply
  `extraPolicyTemplates` with ConfigurationPolicies.
- **The versions in `components/versions.yaml` and `ocp/` are examples.** Replace them
  with the exact versions you mirror. Verify the following against your
  catalog (`oc get packagemanifest <package> -n openshift-marketplace -o yaml`):
  - package names (MongoDB, Dynatrace, Portworx)
  - CSV name formats (`csvFormat`, e.g. Portworx)
  - the ODF `dependencies` list (compare with a real ODF InstallPlan)
- **ACM's MCE subscription annotation**
  (`installer.open-cluster-management.io/mce-subscription-spec`) and
  pre-creating the `multicluster-engine` namespace: verify both against the
  ACM documentation for your version.
- **Approver image.** `registry.redhat.io/openshift4/ose-cli-rhel9:<tag>` must
  be mirrored and reachable from the clusters. It also needs `/bin/sh` and
  `date`, which the ose-cli image includes.
- **`helmValues` overrides every value file.** In Argo CD, inline `values` take
  precedence over `valueFiles`. Use it only for computed values (such as the
  catalog source chosen from a cluster label), not for defaults that clusters should be able
  to override.
- **No ordering between components.** For example, Logging may sync before
  Loki. The retry/backoff in `defaults.syncPolicy` makes this converge. Use
  ApplicationSet progressive syncs if you need strict ordering.

## License

Apache License 2.0. See `LICENSE`.
