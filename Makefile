# Minimal Makefile for the org image build.
#
# The provider image is built by the Harness CI pipeline directly from
# Dockerfile.org (Kaniko), so this Makefile only holds dev helpers that do not
# depend on the removed Crossplane build submodule.

PROJECT_NAME := provider-harness
PROJECT_REPO := github.com/jeremywyx/$(PROJECT_NAME)

# Regenerate the committed flattened package manifest (package.yaml) from
# package/. Downloads the pinned Crossplane CLI if missing.
xpkg-yaml:
	@./hack/generate-package-yaml.sh

# Scaffold a new Harness resource type + controller (see hack/helpers/addtype.sh).
# Arguments:
#   provider:  Camel case name, e.g. Harness
#   group:     API group for the new type, e.g. connector
#   kind:      Kind of the new type, e.g. GitConnector
#   apiversion:(optional, defaults to v1alpha1)
provider.addtype: $(GOMPLATE)
	@[ "${provider}" ] || ( echo "argument \"provider\" is not set"; exit 1 )
	@[ "${group}" ] || ( echo "argument \"group\" is not set"; exit 1 )
	@[ "${kind}" ] || ( echo "argument \"kind\" is not set"; exit 1 )
	@PROVIDER=$(provider) GROUP=$(group) KIND=$(kind) APIVERSION=$(apiversion) PROJECT_REPO=$(PROJECT_REPO) GOMPLATE=$(GOMPLATE) ./hack/helpers/addtype.sh

.PHONY: xpkg-yaml provider.addtype

# --- local tools (downloaded, not from the build submodule) ---
TOOLS_DIR ?= .work/tools
GOMPLATE_VERSION ?= 3.10.0

UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),x86_64)
  GOMPLATE_ARCH := amd64
else ifeq ($(UNAME_M),aarch64)
  GOMPLATE_ARCH := arm64
else
  GOMPLATE_ARCH := $(UNAME_M)
endif
GOMPLATE_PLATFORM := $(shell uname -s | tr A-Z a-z)_$(GOMPLATE_ARCH)
GOMPLATE := $(TOOLS_DIR)/gomplate-$(GOMPLATE_VERSION)

$(GOMPLATE):
	@mkdir -p $(TOOLS_DIR)
	@curl -fsSLo $(GOMPLATE) https://github.com/hairyhenderson/gomplate/releases/download/v$(GOMPLATE_VERSION)/gomplate_$(GOMPLATE_PLATFORM)
	@chmod +x $(GOMPLATE)

