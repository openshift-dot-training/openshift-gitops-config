# Group values

A value layer keyed by the cluster label `platform/group` (see `catalog.yaml`
→ `valueFiles`): `group-values/<value>/` applies to every cluster labelled
`platform/group=<value>`.

- `<value>/versions.yaml` - versions for those clusters (`versions:` block, same
  format as `components/versions.yaml`). List only what differs from the
  defaults. Operators pinned to the OpenShift release are not allowed here:
  they live in `ocp/<x.y>/versions.yaml`.
- `<value>/<component>.yaml` - any other value for one component.

This layer is independent of where components are placed (`groups.yaml`), and
optional. Add other label-keyed layers in `catalog.yaml` the same way when a
new dimension needs its own values. A single cluster can still override
anything in `clusters/<cluster>/`. Files are optional - a missing file is
ignored.
