# Group values

Files here apply to every cluster labelled `platform/group=<group>`:

- `<group>/versions.yaml` - operator versions for the group (`versions:` block,
  same format as `components/versions.yaml`). List only what differs from the
  defaults.
- `<group>/<component>.yaml` - any other value for one component.

Both sit between the defaults in `components/` and the per-cluster values in
`clusters/<cluster>/`, so a single cluster can still override a group version
(e.g. a canary) with a `versions:` block in its `main-values.yaml`.
Files are optional - a missing file is ignored.
