# Per-cluster values

One folder per cluster, named after its ManagedCluster (= Argo CD cluster)
name. Every file is optional; only add what this cluster changes.

```
clusters/<cluster>/
  main-values.yaml          values for every component on this cluster,
                            including versions: overrides (e.g. a canary)
  values/<component>.yaml   values for one component (highest precedence)
  manifests/<component>/    raw manifests, for components with clusterManifests: true
```

A version override must carry its own dependency list - generate it with
`scripts/olm-dependencies.py <component> --versions-file clusters/<cluster>/main-values.yaml --catalog <index> --write`
or take it from olm-upgrade-analyzer's `gitops-versions.yaml`.
