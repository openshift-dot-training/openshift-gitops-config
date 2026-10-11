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

## The problem this solves

The original `trident` ApplicationSet joins two things: a generic chart (from
the platform repo) and per-cluster values (from `environments/<cluster>.git`).
That works for one component. It does not answer this question: *which
clusters get which set of components?*

For example, group A gets ODF, ACS and Grafana. Group B gets MongoDB, Dynatrace
and Portworx. Both groups get Logging and Loki.

The two-repository split stays the same. Generic charts are in
openshift-gitops-charts, which plays the role of the original chart
repository. Values are here, with a folder per cluster under `clusters/`
instead of one repository per cluster. This repository adds the groups and
the exact versions.

## The model: three layers, each defined in one place

| Question | Where it is answered | Who edits it |
|---|---|---|
| **What** can be installed, and how? | `catalog.yaml` → `components:` | platform team |
| **Which components** does each group get? | `groups.yaml` | platform team |
| **Which group** is a cluster in? | ManagedCluster label `platform/group=<group>` | cluster provisioning |

```yaml
# groups.yaml
common: [logging, loki]          # every cluster that has any platform/group label
groups:
  group-a: [odf, acs, grafana]
  group-b: [mongodb, dynatrace, portworx]
```

A hub Helm chart (`charts/platform-catalog` (openshift-gitops-charts)) inverts this map. For **each
component** it generates:

1. An `ApplicationSet` whose cluster generator selects
   `platform/group In (groups that list the component)`. A component under
   `common` uses `Exists` instead.
2. An ACM `Placement` with **exactly the same selector**, plus a `Policy`
   (`<component>-health`, an OperatorPolicy in inform mode) and a
   `PlacementBinding`.

Argo CD and ACM build their selectors from the same helper
(`platform.selection`), so they cannot drift apart. The ACM Governance console
shows a non-compliant cluster whenever Argo CD failed to deliver a component it
should have delivered.

### Per-cluster exceptions (no new group needed)

```
component.platform/<component>=enabled    # add a component to one cluster
component.platform/<component>=disabled   # remove a component from one cluster
```

Each ApplicationSet has two generators: by-group (which excludes clusters that
carry the component label) and opt-in. They never match the same cluster, so a
cluster never produces two Applications with the same name. See
`examples/managed-clusters/labels.yaml`.

### Values precedence (low → high)

Each generated Application is multi-source, like the original trident one:

```
olm-operator chart values.yaml                      chart defaults      (charts repo)
components/versions.yaml                            default versions
components/<component>/values.yaml                  component defaults
group-values/<group>/versions.yaml                  group versions
group-values/<group>/<component>.yaml               group values
clusters/<cluster>/main-values.yaml                 cluster-wide values
clusters/<cluster>/values/<component>.yaml          cluster values
```

All of these files are optional (`ignoreMissingValueFiles: true`). For example,
`group-values/group-a/odf.yaml` defines a 2Ti StorageCluster for all of group A,
and the example cluster overrides only `storageCluster.storageSize: 4Ti`.

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

# clusters/<cluster>/main-values.yaml    one cluster (e.g. a canary)
versions:
  odf: { channel: stable-4.19, version: 4.19.1 }
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

## Layout

```
catalog.yaml                    components (what can be installed), repos, charts tag
groups.yaml                     group -> components   (edit this most often)
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
   two repositories. They are the repository URLs in `catalog.yaml` (`repos.*`,
   `components.trident`), `bootstrap/root-application.yaml` and
   `bootstrap/appprojects.yaml`, and the trident catalog source name. Keep
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
3. Label the clusters with `platform/group`, and optionally `chartsRevision`
   / `configRevision` (see `examples/managed-clusters.yaml`).

## Day-2 operations

| Task | Change |
|---|---|
| Add a cluster to a group | `oc label managedcluster <c> platform/group=group-a` |
| Move a cluster between groups | change the label (components only in the old group are left running, see *Removal* below) |
| Add a component to a group | add it to the group's list in `groups.yaml` |
| Add a new component | add an entry under `components:`, add `components/<name>/values.yaml` and its default version in `components/versions.yaml`, then reference it in `groups.yaml` |
| Create a new group | add a key under `groups:` in `groups.yaml` |
| Tune a component for a group | `group-values/<group>/<component>.yaml` |
| Tune a component for one cluster | `clusters/<cluster>/values/<component>.yaml` |
| Upgrade a component everywhere | `version` (+ `channel`) in `components/versions.yaml` after mirroring it, then `scripts/olm-dependencies.py <component> --write` |
| Upgrade a component for one group | `group-values/<group>/versions.yaml` |
| Canary a version on one cluster | `versions:` in that cluster's `clusters/<cluster>/main-values.yaml` |
| Pin a cluster to a charts tag / config branch | labels `chartsRevision` / `configRevision` |

A component name that `groups.yaml` lists but the catalog does not define makes
the render fail on purpose:
`groups.yaml: component "x" (group "y") is not defined in values.components`.

A component does not have to use `charts/olm-operator`. Set `chart:` (and
`repoURL:` if the chart lives elsewhere) to any Helm chart path. The migrated
`trident` entry does this: it points at `charts/trident` in your existing chart repo,
keeps the `catalogSource` logic for local-cluster in `helmValues`, and syncs
`config/trident` as raw manifests (`clusterManifests: true`).

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

- YAML files use the `.yaml` extension (not `.yml`)
- every YAML file parses
- every component on the default chart has `components/<name>/values.yaml`
- the hub chart renders with `groups.yaml`
- every component renders for each of its groups

The GitHub Actions workflow runs both scripts on every PR, so a commit made
with `--no-verify` is still caught.

## Assumptions to verify on your hub

- **ManagedCluster labels reach the Argo CD cluster secrets.** The cluster
  generator matches labels on those secrets. The original trident
  ApplicationSet already depends on this (it selected on cluster-secret
  labels), so it should already be true. Check with:
  `oc get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true --show-labels`
- **OperatorPolicy** (used by the health policies) needs ACM 2.11 or later. On
  older hubs, set `acm.healthPolicies: false`, or supply
  `extraPolicyTemplates` with ConfigurationPolicies.
- **The versions in `components/versions.yaml` are examples.** Replace them
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
  trident catalogSource switch), not for defaults that clusters should be able
  to override.
- **No ordering between components.** For example, Logging may sync before
  Loki. The retry/backoff in `defaults.syncPolicy` makes this converge. Use
  ApplicationSet progressive syncs if you need strict ordering.

## License

Apache License 2.0. See `LICENSE`.
