# Single entrypoint for the platform. Both the workstation (by hand) and CI
# (via `make` in a workflow step) call these same targets.
#
# The container engine is chosen by who's calling, not hardcoded: podman on
# the workstation (no docker install there by design), docker in CI. Detected
# from GITHUB_ACTIONS, which every GitHub-hosted and self-hosted runner sets —
# override with ENGINE=docker|podman to force one. Everything still runs the
# same ansible-runner image either way, pulled from GHCR; only the local
# engine invoking it differs. Set RUNNER_LOCAL=1 to skip containers entirely
# and use a locally installed ansible-playbook instead (useful on
# 1972-console-1 itself, where it's already on PATH).

SHELL := /bin/bash
.DEFAULT_GOAL := help

ORG              ?= nineteenseventytwo
REGISTRY         ?= ghcr.io/$(ORG)
ANSIBLE_RUNNER   ?= $(REGISTRY)/ansible-runner:$(shell cat images/ansible-runner/version.txt)
GHA_RUNNER       ?= $(REGISTRY)/gha-runner:$(shell cat images/gha-runner/version.txt)

INVENTORY        ?= ansible/inventory/lab
KUBECONFIG       ?= $(HOME)/.kube/config
BUILD_DIR        ?= build

ENGINE           ?= $(if $(GITHUB_ACTIONS),docker,podman)

# Mounts: repo at /work, ssh agent socket, kubeconfig for the cluster targets.
CONTAINER_RUN = $(ENGINE) run --rm -i \
	-v $(PWD):/work -w /work \
	-v $(HOME)/.ssh:/root/.ssh:ro \
	-v $(HOME)/.config/sops/age:/root/.config/sops/age:ro \
	-e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
	$(ANSIBLE_RUNNER)

ifeq ($(RUNNER_LOCAL),1)
  ANSIBLE = ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook
  KUBECTL = kubectl
  HELM    = helm
else
  ANSIBLE = $(CONTAINER_RUN) ansible-playbook
  KUBECTL = $(CONTAINER_RUN) kubectl
  HELM    = $(CONTAINER_RUN) helm
endif

PLAYBOOK = $(ANSIBLE) -i $(INVENTORY)

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------

.PHONY: deps
deps: ## Verify local tooling is present
	@missing=0; \
	for t in $(ENGINE) sops age-keygen; do \
	  command -v $$t >/dev/null 2>&1 || { echo "missing: $$t"; missing=1; }; \
	done; \
	if [ "$(RUNNER_LOCAL)" = "1" ]; then \
	  for t in ansible-playbook kubectl helm; do \
	    command -v $$t >/dev/null 2>&1 || { echo "missing: $$t"; missing=1; }; \
	  done; \
	fi; \
	[ $$missing -eq 0 ] && echo "all prerequisites present"

# --------------------------------------------------------------------------
# Phase A — imaging and network
# --------------------------------------------------------------------------

.PHONY: bootstrap-render
bootstrap-render: ## Render cloud-init for one host. Usage: make bootstrap-render HOST=1972-master-1
	@test -n "$(HOST)" || { echo "HOST is required, e.g. HOST=1972-master-1"; exit 1; }
	bootstrap/cloud-init/render.sh "$(HOST)" "$(BUILD_DIR)/$(HOST)"

.PHONY: bootstrap-render-all
bootstrap-render-all: ## Render cloud-init for every host in the inventory
	@for h in 1972-console-1 1972-master-1 1972-worker-1 1972-worker-2; do \
	  bootstrap/cloud-init/render.sh "$$h" "$(BUILD_DIR)/$$h"; \
	done

.PHONY: test-network
test-network: ## Run the VLAN 20 validation matrix (docs/01-network-validation.md)
	tests/network-check.sh

.PHONY: test-nodes
test-nodes: ## Assert every node matches the hardened baseline
	$(PLAYBOOK) ansible/playbooks/site.yml --check --diff

# --------------------------------------------------------------------------
# Phase B — nodes and CI/CD
# --------------------------------------------------------------------------

.PHONY: ping
ping: ## Connectivity check against every inventory host
	$(CONTAINER_RUN) ansible -i $(INVENTORY) all -m ping

.PHONY: deploy-nodes
deploy-nodes: ## Converge all nodes to the hardened baseline
	$(PLAYBOOK) ansible/playbooks/10-bootstrap-nodes.yml

.PHONY: deploy-cicd
deploy-cicd: ## Stand up the compose runner stack on 1972-console-1
	$(PLAYBOOK) ansible/playbooks/20-cicd-host.yml

.PHONY: images
images: image-ansible-runner image-gha-runner ## Build both container images locally (arm64)

# build-images.yml is the real publisher (docker/build-push-action, native
# arm64 hosted runner). These targets are for testing a Dockerfile change
# without pushing, from whichever side is calling.
.PHONY: image-ansible-runner
image-ansible-runner: ## Build the ansible-runner image locally
ifeq ($(ENGINE),docker)
	docker buildx build --platform linux/arm64 \
	  -t $(ANSIBLE_RUNNER) images/ansible-runner --load
else
	podman build --platform linux/arm64 \
	  -t $(ANSIBLE_RUNNER) images/ansible-runner
endif

.PHONY: image-gha-runner
image-gha-runner: ## Build the gha-runner image locally
ifeq ($(ENGINE),docker)
	docker buildx build --platform linux/arm64 \
	  -t $(GHA_RUNNER) images/gha-runner --load
else
	podman build --platform linux/arm64 \
	  -t $(GHA_RUNNER) images/gha-runner
endif

# --------------------------------------------------------------------------
# Phase C — cluster
# --------------------------------------------------------------------------

.PHONY: deploy-cluster
deploy-cluster: ## kubeadm init, Cilium, join workers, default-deny
	$(PLAYBOOK) ansible/playbooks/30-cluster.yml

.PHONY: kubeconfig
kubeconfig: ## Fetch the admin kubeconfig from the control plane to ./build/kubeconfig
	@mkdir -p $(BUILD_DIR)
	$(PLAYBOOK) ansible/playbooks/30-cluster.yml --tags kubeconfig

.PHONY: bootstrap-argocd
bootstrap-argocd: ## Install Argo CD and hand it cluster/ via the app-of-apps
	$(HELM) repo add argo https://argoproj.github.io/argo-helm
	$(HELM) repo update argo
	$(HELM) upgrade --install argocd argo/argo-cd \
	  --namespace argocd --create-namespace \
	  --version $$(grep '^# chart:' cluster/argocd/values.yaml | awk '{print $$3}') \
	  --values cluster/argocd/values.yaml --wait
	$(KUBECTL) apply -f cluster/argocd/bootstrap/

.PHONY: argocd-sync
argocd-sync: ## Force Argo CD to reconcile now instead of waiting for the poll
	$(KUBECTL) -n argocd patch application platform \
	  --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'

.PHONY: apply-policy
apply-policy: ## Apply baseline policy and tenant namespaces (Argo owns these after bootstrap)
	$(KUBECTL) apply -f policy/
	$(KUBECTL) apply -f policy/tenants/

# --------------------------------------------------------------------------
# Lint
# --------------------------------------------------------------------------

.PHONY: lint
lint: lint-yaml lint-ansible lint-shell ## Run every linter

.PHONY: lint-yaml
lint-yaml:
	$(CONTAINER_RUN) yamllint -c .yamllint .

.PHONY: lint-ansible
lint-ansible:
	$(CONTAINER_RUN) ansible-lint -c .ansible-lint

.PHONY: lint-shell
lint-shell:
	@find bootstrap tests -name '*.sh' -print0 | xargs -0 -r shellcheck

.PHONY: clean
clean: ## Remove rendered artefacts
	rm -rf $(BUILD_DIR)
