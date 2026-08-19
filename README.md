# provider-harness

## Local XPKG Workflow

Build and install the provider package into the existing `provider-harness-dev`
kind cluster using a local OCI registry (plain HTTP):

```bash
make build-xpkg
make install-local
kubectl get providers
make local-clean
```

`make install-local` starts a local `registry:3` container (`kind-registry`) on
the kind Docker network, pushes the built package to it, and applies the
Provider. Crossplane fetches the package from the registry over plain HTTP,
because the package reference uses the registry's RFC1918 private IP (for example
`172.18.0.3:5000/provider-harness:local`), which the package fetcher treats as an
insecure registry. The runtime image is also loaded onto the cluster nodes so the
provider pod can start.

The workflow uses these defaults, which can be overridden per command or in the
environment:

- `KIND_CLUSTER_NAME`: kind cluster to install into (`provider-harness-dev`)
- `PACKAGE_NAME` / `PACKAGE_TAG`: package repository name and tag
  (`provider-harness:local`)
- `REGISTRY_CONTAINER`: local registry container name (`kind-registry`)
- `REGISTRY_PORT` / `REGISTRY_HOST_PORT`: in-cluster and host registry ports
  (`5000` / `5001`)
- `PUSH_REF`: host-side registry reference used to push
  (`127.0.0.1:5001/provider-harness:local`)
- `PACKAGE_REF`: in-cluster package reference resolved at install time to
  `<registry-private-ip>:5000/provider-harness:local`
- `CROSSPLANE_CLI_VERSION`: Crossplane CLI version (`v2.3.4`)
- `LOCAL_STATE_DIR`: dedicated directory for the CLI, manifest, and isolated
  Helm state (`_output/local-xpkg`)

Cleanup is explicit. Only `make local-clean` removes the generated local
package, the local images, the `kind-registry` container, and the local state; it
does not delete the kind cluster, the Crossplane Helm release, or global Helm
state.
