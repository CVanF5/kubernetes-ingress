# variables that should not be overridden by the user
VER = $(shell grep IC_VERSION .github/data/version.txt | cut -d '=' -f 2)
GIT_TAG = $(shell git describe --exact-match --tags || echo untagged)
VERSION = $(VER)-SNAPSHOT
NGINX_PLUS_VERSION            ?= R34
NAP_V5_VERSION			      ?= 5.6.0
PLUS_ARGS = --build-arg NGINX_PLUS_VERSION=$(NGINX_PLUS_VERSION) --secret id=nginx-repo.crt,src=nginx-repo.crt --secret id=nginx-repo.key,src=nginx-repo.key

# Variables that can be overridden
REGISTRY                      ?= ## The registry where the image is located.
PREFIX                        ?= nginx/nginx-ingress ## The name of the image. For example, nginx/nginx-ingress
TAG                           ?= $(VERSION:v%=%) ## The tag of the image. For example, 2.0.0
TARGET                        ?= local ## The target of the build. Possible values: local, container and download
PLUS_REPO                     ?= "pkgs.nginx.com" ## The package repo to install nginx-plus from
override DOCKER_BUILD_OPTIONS += --build-arg IC_VERSION=$(VERSION) --build-arg PACKAGE_REPO=$(PLUS_REPO) ## The options for the docker build command. For example, --pull
ARCH                          ?= amd64 ## The architecture of the image or binary. For example: amd64, arm64, ppc64le, s390x. Not all architectures are supported for all targets
GOOS                          ?= linux ## The OS of the binary. For example linux, darwin
NGINX_AGENT                   ?= true
TELEMETRY_ENDPOINT            ?= oss.edge.df.f5.com:443

# NAP V5 Policy Compilation Variables
NAP_V5_COMPILER_IMAGE         ?= private-registry.nginx.com/nap/waf-compiler:$(NAP_V5_VERSION) ## NGINX App Protect V5 container image for policy compilation
POLICY_DIR                    ?= $(strip build/policies)## Directory where policy files are stored
COMPILED_POLICY_DIR           ?= $(strip build/compiled-policies)## Directory for compiled policy files
POLICY_COMPILE_CONTAINER      ?= nap-v5-compiler ## Name for the temporary policy compilation container
POLICY_MOUNT_PATH             ?= /etc/app_protect/conf/policies ## Path inside container where compiled policies will be mounted
COMPILE_POLICIES              ?= false ## Set to true to compile and include policies in the image build
INCLUDE_POLICIES              ?= false ## Set to true to include pre-compiled policies in the image build
POLICY_MOUNT_DIR              ?= /etc/nginx/app_protect/policies ## Directory in container where policies will be mounted
POLICY_FILES                  := $(wildcard $(POLICY_DIR)/*.json) ## JSON policy files to compile

# Additional flags added here can be accessed in main.go.
# e.g. `main.version` maps to `var version` in main.go
GO_LINKER_FLAGS_VARS = -X main.version=${VERSION} -X main.telemetryEndpoint=${TELEMETRY_ENDPOINT}
GO_LINKER_FLAGS_OPTIONS = -s -w
GO_LINKER_FLAGS = $(GO_LINKER_FLAGS_OPTIONS) $(GO_LINKER_FLAGS_VARS)
DEBUG_GO_LINKER_FLAGS = $(GO_LINKER_FLAGS_VARS)
DEBUG_GO_GC_FLAGS = all=-N -l

ifeq (${REGISTRY},)
BUILD_IMAGE             := $(strip $(PREFIX)):$(strip $(TAG))
else
BUILD_IMAGE             := $(strip $(REGISTRY))/$(strip $(PREFIX)):$(strip $(TAG))
endif

# final docker build command
DOCKER_CMD = docker build --platform linux/$(strip $(ARCH)) $(strip $(DOCKER_BUILD_OPTIONS)) --target $(strip $(TARGET)) -f build/Dockerfile -t $(BUILD_IMAGE) .

export DOCKER_BUILDKIT = 1

.DEFAULT_GOAL:=help

.PHONY: help
help: Makefile ## Display this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "; printf "Usage:\n\n    make \033[36m<target>\033[0m [VARIABLE=value...]\n\nTargets:\n\n"}; {printf "    \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@grep -E '^(override )?[a-zA-Z0-9_-]+ \??\+?= .*? ## .*$$' $< | sort | awk 'BEGIN {FS = " \\??\\+?= .*? ## "; printf "\nVariables:\n\n"}; {gsub(/override /, "", $$1); printf "    \033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: all
all: test lint verify-codegen update-crds debian-image

.PHONY: lint
lint: ## Run linter
	@git fetch
	docker run --pull always --rm -v $(shell pwd):/kubernetes-ingress -w /kubernetes-ingress -v $(shell go env GOCACHE):/cache/go -e GOCACHE=/cache/go -e GOLANGCI_LINT_CACHE=/cache/go -v $(shell go env GOPATH)/pkg:/go/pkg golangci/golangci-lint:latest git diff -p origin/main > /tmp/diff.patch && golangci-lint --color always run -v --new-from-patch=/tmp/diff.patch

.PHONY: lint-python
lint-python: ## Run linter for python tests
	@isort -V || (code=$$?; printf "\033[0;31mError\033[0m: there was a problem with isort, use 'brew install isort' to install it\n"; exit $$code)
	@black --version || (code=$$?; printf "\033[0;31mError\033[0m: there was a problem with black, use 'brew install black' to install it\n"; exit $$code)
	@isort .
	@black .

.PHONY: format
format: ## Run goimports & gofmt
	@go install golang.org/x/tools/cmd/goimports
	@go install mvdan.cc/gofumpt@latest
	@goimports -l -w .
	@gofumpt -l -w .

.PHONY: staticcheck
staticcheck: ## Run staticcheck linter
	@staticcheck -version >/dev/null 2>&1 || go install honnef.co/go/tools/cmd/staticcheck@2022.1.3;
	staticcheck ./...

.PHONY: test
test: ## Run GoLang tests
	go test -tags=aws,helmunit -shuffle=on ./...

.PHONY: test-update-snaps
test-update-snaps:
	UPDATE_SNAPS=true go test -tags=aws,helmunit -shuffle=on ./...

cover: ## Generate coverage report
	go test -tags=aws,helmunit -shuffle=on -race -coverprofile=coverage.txt -covermode=atomic ./...

cover-html: test ## Generate and show coverage report in HTML format
	go tool cover -html coverage.txt

.PHONY: verify-codegen
verify-codegen: ## Verify code generation
	./hack/verify-codegen.sh

.PHONY: update-codegen
update-codegen: ## Generate code
	./hack/update-codegen.sh

.PHONY: update-crds
update-crds: ## Update CRDs
	go run sigs.k8s.io/controller-tools/cmd/controller-gen crd paths=./pkg/apis/... output:crd:artifacts:config=config/crd/bases
	@kustomize version || (code=$$?; printf "\033[0;31mError\033[0m: there was a problem with kustomize, use 'brew install kustomize' to install it\n"; exit $$code)
	kustomize build config/crd >deploy/crds.yaml
	kustomize build config/crd/app-protect-dos --load-restrictor='LoadRestrictionsNone' >deploy/crds-nap-dos.yaml
	kustomize build config/crd/app-protect-waf --load-restrictor='LoadRestrictionsNone' >deploy/crds-nap-waf.yaml

.PHONY: telemetry-schema
telemetry-schema: ## Generate the telemetry Schema
	go generate internal/telemetry/exporter.go
	gofumpt -w internal/telemetry/*_generated.go

# NAP V5 Policy Compilation Targets

.PHONY: setup-policy-dirs
setup-policy-dirs: ## Create policy directories if they don't exist
	@mkdir -p $(POLICY_DIR) $(COMPILED_POLICY_DIR)

.PHONY: validate-policy-files
validate-policy-files: setup-policy-dirs ## Validate that policy files exist
	@POLICY_FILES="$(wildcard $(POLICY_DIR)/*.json)"; \
	if [ -z "$$POLICY_FILES" ]; then \
		printf "\033[0;33mWarning\033[0m: No JSON policy files found in $(POLICY_DIR)/\n"; \
		printf "Create policy files with .json extension in the $(POLICY_DIR)/ directory\n"; \
		exit 1; \
	else \
		printf "Found policy files:\n"; \
		for file in $$POLICY_FILES; do \
			printf "  - %s\n" "$$(basename $$file)"; \
		done; \
	fi

.PHONY: pull-nap-v5-image
pull-nap-v5-image: ## Pull NGINX App Protect V5 container image
	@printf "Pulling NAP V5 image: $(NAP_V5_COMPILER_IMAGE)\n"
	docker pull --platform linux/$(strip $(ARCH)) $(NAP_V5_COMPILER_IMAGE)

.PHONY: compile-policies-for-build
compile-policies-for-build: validate-policy-files pull-nap-v5-image
	@printf "Compiling policies for container build...\n"
	@if [ "${COMPILE_POLICIES}" = "true" ]; then \
		mkdir -p $(COMPILED_POLICY_DIR) && \
		for policy in $(POLICY_FILES); do \
			POLICY_NAME=$$(basename $$policy .json); \
			printf "Compiling: $$policy -> $(COMPILED_POLICY_DIR)/$$POLICY_NAME.tgz\n"; \
			docker run --platform linux/$(strip $(ARCH)) --rm \
				-v "$$(pwd):$$(pwd)" \
				--workdir "$$(pwd)" \
				$(NAP_V5_COMPILER_IMAGE) \
				-p "$$(pwd)/$$policy" \
				-o "$$(pwd)/$(COMPILED_POLICY_DIR)/$$POLICY_NAME.tgz" || { \
					echo "✗ Failed to compile $$policy"; exit 1; }; \
			printf "✓ Compiled: $$policy\n"; \
		done; \
	fi
	@printf "\033[0;32mSuccess\033[0m: All policies compiled for container build\n"

.PHONY: debian-image-nap-v5-plus
debian-image-nap-v5-plus: build ## Create Debian NAP V5 image
ifeq ($(strip $(COMPILE_POLICIES)),true)
	@$(MAKE) compile-policies-for-build
endif
	$(DOCKER_CMD) $(PLUS_ARGS) \
	--build-arg BUILD_OS=debian-plus-nap-v5 \
	--build-arg NAP_MODULES=waf \
	--build-arg NGINX_AGENT=$(NGINX_AGENT) \
	--build-arg WAF_VERSION=v5 \
	$(if $(strip $(COMPILE_POLICIES)), \
	--build-arg INCLUDE_POLICIES=true \
	--build-arg POLICY_MOUNT_DIR=/etc/nginx/app_protect/policies \
	--build-context policies=$(COMPILED_POLICY_DIR))

.PHONY: debian-image-nap-v5-plus-with-policies
debian-image-nap-v5-plus-with-policies: ## Create Debian NAP V5 image with pre-compiled policies
	@$(MAKE) COMPILE_POLICIES=true compile-policies-for-build
	@$(MAKE) debian-image-nap-v5-plus BUILD_ARGS="--build-arg COMPILE_POLICIES=true --build-arg INCLUDE_POLICIES=true --build-arg POLICY_MOUNT_DIR=/etc/nginx/app_protect/policies"

.PHONY: compile-policy
compile-policy: validate-policy-files pull-nap-v5-image ## Compile a single JSON policy file (requires POLICY_FILE variable)
ifndef POLICY_FILE
	$(error POLICY_FILE is required. Usage: make compile-policy POLICY_FILE=path/to/policy.json)
endif
	@if [ ! -f "$(POLICY_FILE)" ]; then \
		printf "\033[0;31mError\033[0m: Policy file $(POLICY_FILE) not found\n"; \
		exit 1; \
	fi
	@printf "Compiling policy: $(POLICY_FILE)\n"
	@POLICY_NAME=$(basename "$(POLICY_FILE)" .json); \
	docker run --platform linux/$(strip $(ARCH))  --rm \
		-v "$(shell pwd)/$(POLICY_DIR):/policies:ro" \
		-v "$(shell pwd)/$(COMPILED_POLICY_DIR):/compiled:rw" \
		--name $(POLICY_COMPILE_CONTAINER)-single \
		$(NAP_V5_COMPILER_IMAGE) \
		sh -c "cd /opt/app_protect/bin && \
			./bd_agent --compile-policy /policies/$(basename $(POLICY_FILE)) \
			--output /compiled/$${POLICY_NAME}.tgz && \
			printf 'Successfully compiled policy: $(POLICY_FILE) -> $(COMPILED_POLICY_DIR)/${POLICY_NAME}.tgz\n'"

.PHONY: compile-policies
compile-policies: validate-policy-files pull-nap-v5-image ## Compile all JSON policy files in the policy directory
	@printf "Compiling all policies in $(POLICY_DIR)/\n"
	@POLICY_FILES=$(wildcard $(POLICY_DIR)/*.json); \
	for policy in $$POLICY_FILES; do \
		printf "Compiling: $$policy\n"; \
		POLICY_NAME=$$(basename "$$policy" .json); \
		docker run --platform linux/$(strip $(ARCH)) --rm  \
			-v "$(shell pwd):$(shell pwd)" $(NAP_V5_COMPILER_IMAGE) \
			-p "$(shell pwd)/$(POLICY_DIR)/$$POLICY_NAME".json \
			-o "$(shell pwd)/$(COMPILED_POLICY_DIR)/$$POLICY_NAME.tgz" || { \
				printf "\033[0;31mError\033[0m: Failed to compile $$policy\n"; \
				exit 1; \
			}; \
		printf "✓ Compiled: $${policy} -> $(COMPILED_POLICY_DIR)/$$POLICY_NAME.tgz\n"; \
	done
	@printf "\033[0;32mSuccess\033[0m: All policies compiled successfully\n"

.PHONY: validate-policies
validate-policies: validate-policy-files pull-nap-v5-image ## Validate all JSON policy files without compiling
	@echo "Looking for policies in '$(POLICY_DIR)'"
	@POLICY_FILES="$(wildcard $(POLICY_DIR)/*.json)"; \
	if [ -z "$$POLICY_FILES" ]; then \
		echo "No policies found"; exit 1; \
	fi
	@for policy in $(POLICY_FILES); do \
		printf "Validating: $policy\n"; \
		docker run --rm \
			-v "$(shell pwd)/$(POLICY_DIR):/policies:ro" \
			--name $(POLICY_COMPILE_CONTAINER)-validate-$(basename $policy .json) \
			$(NAP_V5_COMPILER_IMAGE) \
			sh -c "cd /opt/app_protect/bin && \
				./bd_agent --validate-policy /policies/$(basename $policy)" || { \
				printf "\033[0;31mError\033[0m: Failed to validate $policy\n"; \
				exit 1; \
			}; \
		printf "✓ Valid: $policy\n"; \
	done
	@printf "\033[0;32mSuccess\033[0m: All policies are valid\n"

.PHONY: clean-policies
clean-policies: ## Remove all compiled policy files
	@printf "Cleaning compiled policies in $(COMPILED_POLICY_DIR)/\n"
	@rm -rf $(COMPILED_POLICY_DIR)/*.tgz
	@printf "Compiled policies cleaned\n"

.PHONY: policy-info
policy-info: ## Display information about NAP V5 policy compilation setup
	@printf "\n\033[1mNGINX App Protect V5 Policy Compilation Configuration:\033[0m\n"
	@printf "  NAP V5 Image:           $(NAP_V5_COMPILER_IMAGE)\n"
	@printf "  Policy Directory:       $(POLICY_DIR)/\n"
	@printf "  Compiled Policy Dir:    $(COMPILED_POLICY_DIR)/\n"
	@printf "  Container Name Prefix:  $(POLICY_COMPILE_CONTAINER)\n"
	@printf "  Policy Mount Path:      $(POLICY_MOUNT_PATH)\n"
	@printf "  Compile Policies:       $(COMPILE_POLICIES)\n"
	@printf "\n\033[1mAvailable Policy Targets:\033[0m\n"
	@printf "  make list-policies           - List JSON policy files\n"
	@printf "  make validate-policies       - Validate all policies\n"
	@printf "  make compile-policy POLICY_FILE=path/to/policy.json\n"
	@printf "  make compile-policies        - Compile all policies\n"
	@printf "  make list-compiled-policies  - List compiled policies\n"
	@printf "  make clean-policies          - Remove compiled policies\n"
	@printf "\n\033[1mContainer Build with Policies:\033[0m\n"
	@printf "  make debian-image-nap-v5-plus-with-policies  - Build with pre-compiled policies\n"
	@printf "  make COMPILE_POLICIES=true debian-image-nap-v5-plus  - Alternative syntax\n"

.PHONY: build
build: ## Build Ingress Controller binary
	@docker -v || (code=$$?; printf "\033[0;31mError\033[0m: there was a problem with Docker\n"; exit $$code)
ifeq ($(strip $(TARGET)),local)
	@go version || (code=$$?; printf "\033[0;31mError\033[0m: unable to build locally, try using the parameter TARGET=container or TARGET=download\n"; exit $$code)
	CGO_ENABLED=0 GOOS=$(strip $(GOOS)) GOARCH=$(strip $(ARCH)) go build -trimpath -ldflags "$(GO_LINKER_FLAGS)" -o nginx-ingress github.com/nginx/kubernetes-ingress/cmd/nginx-ingress
else ifeq ($(strip $(TARGET)),download)
	@$(MAKE) download-binary-docker
else ifeq ($(strip $(TARGET)),debug)
	@go version || (code=$$?; printf "\033[0;31mError\033[0m: unable to build locally, try using the parameter TARGET=container or TARGET=download\n"; exit $$code)
	CGO_ENABLED=0 GOOS=$(strip $(GOOS)) GOARCH=$(strip $(ARCH)) go build -ldflags "$(DEBUG_GO_LINKER_FLAGS)" -gcflags "$(DEBUG_GO_GC_FLAGS)" -o nginx-ingress github.com/nginx/kubernetes-ingress/cmd/nginx-ingress
endif

.PHONY: download-binary-docker
download-binary-docker: ## Download Docker image from which to extract Ingress Controller binary, TARGET=download is required
ifeq ($(strip $(TARGET)),download)
DOWNLOAD_TAG := $(shell ./hack/docker.sh $(GIT_TAG))
ifeq ($(DOWNLOAD_TAG),fail)
$(error unable to build with TARGET=download, this function is only available when building from a git tag or from the latest commit matching the edge image)
endif
override DOCKER_BUILD_OPTIONS += --build-arg DOWNLOAD_TAG=$(DOWNLOAD_TAG)
endif

.PHONY: build-goreleaser
build-goreleaser: ## Build Ingress Controller binary using GoReleaser
	@goreleaser -v || (code=$$?; printf "\033[0;31mError\033[0m: there was a problem with GoReleaser. Follow the docs to install it https://goreleaser.com/install\n"; exit $$code)
	GOOS=linux GOPATH=$(shell go env GOPATH) GOARCH=$(strip $(ARCH)) goreleaser build --clean --debug --snapshot --id kubernetes-ingress --single-target

.PHONY: debian-image
debian-image: build ## Create Docker image for Ingress Controller (Debian)
	$(DOCKER_CMD) --build-arg BUILD_OS=debian --build-arg POLICY_MOUNT_DIR=$(POLICY_MOUNT_DIR) --build-arg COMPILE_POLICIES=$(COMPILE_POLICIES) --build-arg INCLUDE_POLICIES=$(INCLUDE_POLICIES)



.PHONY: alpine-image
alpine-image: build ## Create Docker image for Ingress Controller (Alpine)
	$(DOCKER_CMD) --build-arg BUILD_OS=alpine

.PHONY: alpine-image-plus
alpine-image-plus: build ## Create Docker image for Ingress Controller (Alpine with NGINX Plus)
	$(DOCKER_CMD) $(PLUS_ARGS) --build-arg BUILD_OS=alpine-plus

.PHONY: alpine-image-plus-fips
alpine-image-plus-fips: build ## Create Docker image for Ingress Controller (Alpine with NGINX Plus and FIPS)
	$(DOCKER_CMD) $(PLUS_ARGS) --build-arg BUILD_OS=alpine-plus-fips

.PHONY: alpine-image-nap-plus-fips
alpine-image-nap-plus-fips: build ## Create Docker image for Ingress Controller (Alpine with NGINX Plus, NGINX App Protect WAF and FIPS)
	$(DOCKER_CMD) $(PLUS_ARGS) --build-arg BUILD_OS=alpine-plus-nap-fips --build-arg NGINX_AGENT=$(NGINX_AGENT)

.PHONY: alpine-image-nap-v5-plus-fips
alpine-image-nap-v5-plus-fips: build ## Create Docker image for Ingress Controller (Alpine with NGINX Plus, NGINX App Protect WAFv5 and FIPS)
	$(DOCKER_CMD) $(PLUS_ARGS) \
	--build-arg BUILD_OS=alpine-plus-nap-v5-fips \
	--build-arg NGINX_AGENT=$(NGINX_AGENT) \
	--build-arg WAF_VERSION=v5

.PHONY: debian-image-plus
debian-image-plus: build ## Create Docker image for Ingress Controller (Debian with NGINX Plus)
	$(DOCKER_CMD) $(PLUS_ARGS) --build-arg BUILD_OS=debian-plus

.PHONY: debian-image-nap-plus
debian-image-nap-plus: build ## Create Docker image for Ingress Controller (Debian with NGINX Plus and NGINX App Protect WAF)
	$(DOCKER_CMD) $(PLUS_ARGS) --build-arg BUILD_OS=debian-plus-nap --build-arg NAP_MODULES=waf --build-arg NGINX_AGENT=$(NGINX_AGENT)

.PHONY: debian-image-dos-plus
debian-image-dos-plus: build ## Create Docker image for Ingress Controller (Debian with NGINX Plus and NGINX App Protect DoS)
	$(DOCKER_CMD) $(PLUS_ARGS) --build-arg BUILD_OS=debian-plus-nap --build-arg NAP_MODULES=dos

.PHONY: debian-image-nap-dos-plus
debian-image-nap-dos-plus: build ## Create Docker image for Ingress Controller (Debian with NGINX Plus, NGINX App Protect WAF and DoS)
	$(DOCKER_CMD) $(PLUS_ARGS) --build-arg BUILD_OS=debian-plus-nap --build-arg NAP_MODULES=waf,dos  --build-arg NGINX_AGENT=$(NGINX_AGENT)

.PHONY: ubi-image
ubi-image: build ## Create Docker image for Ingress Controller (UBI)
	$(DOCKER_CMD) --build-arg BUILD_OS=ubi

.PHONY: ubi-image-plus
ubi-image-plus: build ## Create Docker image for Ingress Controller (UBI with NGINX Plus)
	$(DOCKER_CMD) $(PLUS_ARGS) --build-arg BUILD_OS=ubi-9-plus

.PHONY: ubi-image-nap-plus
ubi-image-nap-plus: build ## Create Docker image for Ingress Controller (UBI with NGINX Plus and NGINX App Protect WAF)
	$(DOCKER_CMD) $(PLUS_ARGS) --secret id=rhel_license,src=rhel_license --build-arg BUILD_OS=ubi-9-plus-nap --build-arg NAP_MODULES=waf --build-arg NGINX_AGENT=$(NGINX_AGENT)

.PHONY: ubi-image-nap-v5-plus
ubi-image-nap-v5-plus: build ## Create Docker image for Ingress Controller (UBI with NGINX Plus and NGINX App Protect WAFv5)
	$(DOCKER_CMD) $(PLUS_ARGS) --secret id=rhel_license,src=rhel_license \
	--build-arg BUILD_OS=ubi-9-plus-nap-v5 \
	--build-arg NAP_MODULES=waf \
	--build-arg NGINX_AGENT=$(NGINX_AGENT) \
	--build-arg WAF_VERSION=v5

.PHONY: ubi-image-dos-plus
ubi-image-dos-plus: build ## Create Docker image for Ingress Controller (UBI with NGINX Plus and NGINX App Protect DoS)
	$(DOCKER_CMD) $(PLUS_ARGS) --secret id=rhel_license,src=rhel_license --build-arg BUILD_OS=ubi-9-plus-nap --build-arg NAP_MODULES=dos

.PHONY: ubi-image-nap-dos-plus
ubi-image-nap-dos-plus: build ## Create Docker image for Ingress Controller (UBI with NGINX Plus, NGINX App Protect WAF and DoS)
	$(DOCKER_CMD) $(PLUS_ARGS) --secret id=rhel_license,src=rhel_license --build-arg BUILD_OS=ubi-9-plus-nap --build-arg NAP_MODULES=waf,dos  --build-arg NGINX_AGENT=$(NGINX_AGENT)

.PHONY: all-images ## Create all the Docker images for Ingress Controller
all-images: alpine-image alpine-image-plus alpine-image-plus-fips alpine-image-nap-plus-fips debian-image debian-image-plus debian-image-nap-plus debian-image-dos-plus debian-image-nap-dos-plus ubi-image ubi-image-plus ubi-image-nap-plus ubi-image-dos-plus ubi-image-nap-dos-plus

.PHONY: patch-os
patch-os: ## Patch supplied image
	$(DOCKER_CMD) --build-arg IMAGE_NAME=$(IMAGE)

.PHONY: push
push: ## Docker push to PREFIX and TAG
	docker push $(strip $(PREFIX)):$(strip $(TAG))

.PHONY: clean
clean:  ## Remove nginx-ingress binary
	-rm -f nginx-ingress
	-rm -rf dist

.PHONY: deps
deps: ## Add missing and remove unused modules, verify deps and download them to local cache
	@go mod tidy && go mod verify && go mod download

.PHONY: clean-cache
clean-cache: ## Clean go cache
	@go clean -modcache

.PHONY: rebuild-test-img ## Rebuild the python e2e test image
rebuild-test-img:
	cd tests && \
	make build

debug-policy-dir:
	@echo "Raw: '$(POLICY_DIR)'"