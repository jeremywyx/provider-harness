# Minimal Makefile for the org image build.
#
# The provider image is built by the Harness CI pipeline directly from
# Dockerfile.org (Kaniko), so this Makefile only holds dev helpers that do not
# depend on the removed Crossplane build submodule.

# Regenerate the committed flattened package manifest (package.yaml) from
# package/. Downloads the pinned Crossplane CLI if missing.
xpkg-yaml:
	@./hack/generate-package-yaml.sh

.PHONY: xpkg-yaml
