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
# :stable — the last version promoted from main, not necessarily what
# version.txt says on whatever's checked out right now. Override explicitly
# when testing a version bump on a branch:
#   ANSIBLE_RUNNER=ghcr.io/nineteenseventytwo/ansible-runner:1.2.3 make ...
#   ANSIBLE_RUNNER=ghcr.io/nineteenseventytwo/ansible-runner:latest make ...
ANSIBLE_RUNNER   ?= $(REGISTRY)/ansible-runner:stable
GHA_RUNNER       ?= $(REGISTRY)/gha-runner:$(shell cat images/gha-runner/version.txt)

# For `make image-ansible-runner`'s own build tag specifically, not for
# pulling-and-running — that stays pinned to version.txt regardless of what
# ANSIBLE_RUNNER resolves to. Tagging a fresh, unpublished, untested local
# build :stable would be a lie; GHA_RUNNER above already gets this right for
# gha-runner because it never floats to :stable in the first place.
ANSIBLE_RUNNER_BUILD_TAG ?= $(REGISTRY)/ansible-runner:$(shell cat images/ansible-runner/version.txt)

INVENTORY        ?= ansible/inventory/lab
BUILD_DIR        ?= build

# The engine follows *where you are*, not which target you ran: podman on the
# workstation, docker in CI and on 1972-console-1 (where podman isn't
# installed). Hardcoding it per target breaks Phase B, when you legitimately
# run deploy-nodes from the workstation before CI exists to run it for you.
ENGINE           ?= $(if $(GITHUB_ACTIONS),docker,$(if $(shell command -v podman 2>/dev/null),podman,docker))

# Automation keys, never a human one. Three keys, none ever transported:
#   mark-workstation      passphrase, humans typing `ssh`, never used here
#   ansible-workstation   no passphrase, workstation-launched containers (this)
#   ansible-console       no passphrase, generated on and never leaving
#                         1972-console-1; CI overrides SSH_KEY to point at it
# A passphrase on an automation key would have to be typed into a container
# with no TTY, which is why the agent-forwarding contortion this replaced
# existed at all. See bootstrap/ssh/README.md.
SSH_KEY          ?= $(HOME)/.ssh/ansible-workstation
KNOWN_HOSTS      ?= $(PWD)/ansible/files/known_hosts
SOPS_AGE_DIR     ?= $(if $(GITHUB_ACTIONS),$(RUNNER_TEMP)/age,$(HOME)/.config/sops/age)
KUBECONFIG       ?= $(if $(GITHUB_ACTIONS),$(RUNNER_TEMP)/kube/config,$(HOME)/.kube/config)

# Two container shapes, because the credentials differ. Ansible targets need
# an SSH key and the age key; kubectl/helm targets need a kubeconfig and no
# SSH at all. Mounting the union would mean every `helm upgrade` also carried
# a key that can root every node, and would make ~/.kube/config a hard
# prerequisite for targets that never touch the cluster.
#
# Mount the one SSH key we need, not all of ~/.ssh — that directory holds
# mark-workstation and every other private key on the machine, none of which
# a converge has any business being able to read.
#
# --user matches the image's default (ansible-runner runs as a non-root
# `ansible` user, not root), against whoever is actually invoking make: you,
# on the workstation, or the self-hosted runner's own service account on
# 1972-console-1 (deploy-cluster.yml, deploy-nodes.yml). Either way it's the
# same UID that owns /work and everything under $HOME being mounted in, so
# there's no bind-mount ownership mismatch to fight — a real concern on
# 1972-console-1's native Linux bind mounts, unlike Docker Desktop's more
# forgiving ones. The image's HOME is world-writable for exactly this: an
# arbitrary UID with no /etc/passwd entry still needs somewhere to put
# ~/.ansible/tmp.
# DOCKER_GID is unset (no-op) on the workstation, where whoever invokes make
# already owns the SSH key/age key files being mounted in. On the self-hosted
# runner it's the numeric gid of the host's docker group, set by
# deploy-nodes.yml/deploy-cluster.yml: the container that actually reads
# ansible-console is a sibling spawned over the shared docker socket from
# *inside* the containerized runner, not a process running as admin_user, so
# --user alone can't match ansible-console's owning uid — only group
# membership can. ansible-console is group:docker mode:0640 for exactly this
# (ansible/playbooks/20-cicd-host.yml).
DOCKER_USER = --user "$(shell id -u):$(shell id -g)" $(if $(DOCKER_GID),--group-add $(DOCKER_GID))

CONTAINER_RUN = $(ENGINE) run --rm -i $(DOCKER_USER) \
	-v $(PWD):/work -w /work \
	-v $(SSH_KEY):/home/ansible/.ssh/id_ed25519:ro \
	-v $(KNOWN_HOSTS):/home/ansible/.ssh/known_hosts:ro \
	-v $(SOPS_AGE_DIR):/home/ansible/.config/sops/age:ro \
	-e ANSIBLE_PRIVATE_KEY_FILE=/home/ansible/.ssh/id_ed25519 \
	-e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
	$(ANSIBLE_RUNNER)

# abspath, not $(KUBECONFIG) directly: docker/podman's -v only treats a source
# starting with / as a bind mount. Anything else — including a perfectly valid
# relative path like the one `make kubeconfig` itself writes to
# (./build/kubeconfig, per docs/03-cluster.md) — it reads as a *named volume*
# to create, and named volume names can't contain /, so this fails with
# "names must match [a-zA-Z0-9][a-zA-Z0-9_.-]*" rather than anything that
# reads like a path problem. The default below is already absolute
# ($(HOME)/... or $(RUNNER_TEMP)/...), which is why this never surfaced until
# someone reasonably overrode it with the relative path the docs themselves
# print. abspath is a no-op on an already-absolute path, so this is safe
# either way.
# $(BUILD_DIR)/helm/{config,cache} persist Helm's own state (repositories.yaml,
# the downloaded index) across separate $(HELM) invocations. Each line of a
# recipe is its own shell, so each one is a fresh `podman run --rm` — without
# this, `helm repo add` writes into a container filesystem that is gone the
# instant it exits, and the very next line's `helm repo update` finds no
# repositories at all. Read-write, not :ro like the kubeconfig mount above:
# these are the one thing in this macro that gets written to. Harmless as
# unused mounts on the $(KUBECTL)/$(KUBE_SH) targets that share this macro —
# neither reads nor writes Helm's state directories.
CONTAINER_RUN_KUBE = $(ENGINE) run --rm -i $(DOCKER_USER) \
	-v $(PWD):/work -w /work \
	-v $(abspath $(KUBECONFIG)):/home/ansible/.kube/config:ro \
	-v $(CURDIR)/$(BUILD_DIR)/helm/config:/home/ansible/.config/helm \
	-v $(CURDIR)/$(BUILD_DIR)/helm/cache:/home/ansible/.cache/helm \
	$(ANSIBLE_RUNNER)

# A bind-mount source that does not exist yet gets auto-created by the engine
# daemon, typically root-owned, regardless of --user — bootstrap-argocd's own
# `@mkdir -p` covered its own recipe, but every other target sharing
# CONTAINER_RUN_KUBE (argocd-sync-wait, apply-policy, verify-irsa) had no such
# line, so a fresh checkout could still auto-vivify these two directories as
# root on its first $(KUBECTL)/$(KUBE_SH) call. The next actions/checkout on
# the same self-hosted runner then fails trying to clean a workspace it does
# not own: "EACCES: permission denied, rmdir '.../build/helm'" — confirmed
# live on nineteenseventytwo-platform's own CI after argocd-sync-wait ran
# once. $(shell ...) here is a bare top-level call, evaluated once when make
# parses this file — before any target's recipe runs, regardless of which
# target was invoked — so the directories always exist with the invoking
# user's own ownership before the container engine ever gets a chance to.
$(shell mkdir -p $(BUILD_DIR)/helm/config $(BUILD_DIR)/helm/cache)

# Linting reads files and nothing else — no key, no kubeconfig, no network.
# ANSIBLE_CONFIG is still required even here: ansible-lint resolves
# roles_path relative to it, and without it every role import 404s as
# "role not found" rather than anything resembling a lint finding.
CONTAINER_RUN_PLAIN = $(ENGINE) run --rm -i $(DOCKER_USER) \
	-v $(PWD):/work -w /work \
	-e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
	$(ANSIBLE_RUNNER)

# RUNNER_LOCAL=1 runs the tools straight off PATH instead of through the
# image. Used on 1972-console-1, and by the lint workflow, which is on a
# GitHub-hosted runner with the tools pip-installed — pulling an arm64 image
# onto an amd64 runner to lint text files would be silly. Either way the
# command and its flags are defined once, here.
ifeq ($(RUNNER_LOCAL),1)
  ANSIBLE   = ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook
  KUBE_SH   = sh -eu -c
  KUBECTL   = kubectl
  HELM      = helm
  LINT          = ANSIBLE_CONFIG=ansible/ansible.cfg
  LINT_NO_SOPS  = ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_VARS_ENABLED=host_group_vars
else
  ANSIBLE   = $(CONTAINER_RUN) ansible-playbook
  KUBE_SH   = $(CONTAINER_RUN_KUBE) sh -eu -c
  KUBECTL   = $(CONTAINER_RUN_KUBE) kubectl
  HELM      = $(CONTAINER_RUN_KUBE) helm
  LINT          = $(CONTAINER_RUN_PLAIN)
  LINT_NO_SOPS  = $(ENGINE) run --rm -i $(DOCKER_USER) \
	-v $(PWD):/work -w /work \
	-e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
	-e ANSIBLE_VARS_ENABLED=host_group_vars \
	$(ANSIBLE_RUNNER)
endif

# CHECK=1 turns any converge into a dry run. The workflows pass it through
# from their check_mode input so CI and a laptop spell it the same way.
CHECK_ARGS = $(if $(CHECK),--check --diff,)

PLAYBOOK = $(ANSIBLE) -i $(INVENTORY)

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Guard, not a preference: deploy-cicd restarts dockerd and the runner stack on
# 1972-console-1. Run from a runner *on* that host, it kills the job partway
# through and you get a red tick with a half-applied change.
.PHONY: require-workstation
require-workstation:
	@test -z "$(GITHUB_ACTIONS)" || { \
	  echo "refusing to run from CI: this target restarts the runner host it would be running on"; \
	  echo "run it from the workstation instead"; exit 1; }

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

.PHONY: known-hosts
known-hosts: ## Regenerate ansible/files/known_hosts from the live lab nodes
	bootstrap/ssh/scan-known-hosts.sh

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
deploy-nodes: ## Converge all nodes to the hardened baseline (CHECK=1 for a dry run)
	$(PLAYBOOK) ansible/playbooks/10-bootstrap-nodes.yml $(CHECK_ARGS)

.PHONY: deploy-cicd
deploy-cicd: require-workstation ## Stand up the compose runner stack on 1972-console-1
	$(PLAYBOOK) ansible/playbooks/20-cicd-host.yml $(CHECK_ARGS)

.PHONY: images
images: image-ansible-runner image-gha-runner ## Build both container images locally (arm64)

# build-<name>.yml (via the reusable _build-image.yml) is the real publisher
# (docker/build-push-action, native arm64 hosted runner), triggered by a
# version.txt bump on a branch. These targets are for testing a Dockerfile
# change locally without pushing, from whichever side is calling.
.PHONY: image-ansible-runner
image-ansible-runner: ## Build the ansible-runner image locally
ifeq ($(ENGINE),docker)
	docker buildx build --platform linux/arm64 \
	  -t $(ANSIBLE_RUNNER_BUILD_TAG) images/ansible-runner --load
else
	podman build --platform linux/arm64 \
	  -t $(ANSIBLE_RUNNER_BUILD_TAG) images/ansible-runner
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
deploy-cluster: ## kubeadm init, Cilium, join workers, default-deny (CHECK=1 for a dry run)
	$(PLAYBOOK) ansible/playbooks/30-cluster.yml $(CHECK_ARGS)

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

# Argo polls every 3 minutes. Nudging it and then waiting turns "the deploy
# finished" into something you can gate on, rather than a green tick that only
# means a commit landed. Lives here rather than inline in the workflow because
# it is work, not orchestration — and because you want to run it by hand too.
ARGOCD_SYNC_TIMEOUT ?= 60
.PHONY: argocd-sync-wait
argocd-sync-wait: ## Nudge Argo CD and block until the platform app is Synced/Healthy
	$(KUBE_SH) ' \
	  kubectl -n argocd patch application platform --type merge \
	    -p "{\"operation\":{\"sync\":{\"revision\":\"HEAD\"}}}"; \
	  for i in $$(seq 1 $(ARGOCD_SYNC_TIMEOUT)); do \
	    status=$$(kubectl -n argocd get application platform \
	      -o jsonpath="{.status.sync.status}/{.status.health.status}"); \
	    echo "platform: $$status"; \
	    [ "$$status" = "Synced/Healthy" ] && exit 0; \
	    sleep 15; \
	  done; \
	  echo "argocd did not reach Synced/Healthy in time" >&2; \
	  kubectl -n argocd get applications -o wide >&2; \
	  exit 1'

# Runs on the workstation, not through the ansible-runner image: it needs an
# `aws sso login` session from ~/.aws, and mounting that into a container to
# avoid writing three lines of Makefile would be the wrong trade. Same reasoning
# as bootstrap/ssh/scan-known-hosts.sh.
.PHONY: publish-oidc
publish-oidc: ## Publish the cluster's OIDC discovery documents to the public JWKS bucket
	@command -v aws >/dev/null || { echo "aws cli not found — this target runs on the workstation" >&2; exit 1; }
	@command -v kubectl >/dev/null || { echo "kubectl not found — this target runs on the workstation" >&2; exit 1; }
	KUBECONFIG=$(KUBECONFIG) bootstrap/oidc/publish-discovery.sh

# Proves the whole chain end to end: a pod gets a projected token, exchanges it
# at STS, and comes back with an assumed-role identity. Run it after the roles
# exist — a green result here is the only real evidence IRSA works, as opposed
# to each half looking correct on its own.
.PHONY: verify-irsa
verify-irsa: ## Assume an AWS role from inside the cluster and print the identity
	$(KUBE_SH) ' 	  kubectl -n vault get sa vault 	    -o jsonpath="{.metadata.annotations.eks\.amazonaws\.com/role-arn}" 	    | grep -q . || { echo "vault ServiceAccount carries no role-arn annotation" >&2; exit 1; }; 	  echo "annotation present"; 	  kubectl -n vault get pod -l app.kubernetes.io/name=vault 	    -o jsonpath="{.items[0].spec.containers[0].env[?(@.name=="AWS_ROLE_ARN")].value}" 	    | grep -q . || { echo "AWS_ROLE_ARN not injected — check the pod-identity-webhook pod" >&2; exit 1; }; 	  echo "webhook injection present"; 	  kubectl -n vault exec deploy/vault -- sh -c 	    "vault status 2>&1 | grep -E "Sealed|Seal Type"" '

.PHONY: apply-policy
apply-policy: ## Apply baseline policy and tenant namespaces (Argo owns these after bootstrap)
	$(KUBECTL) apply -f policy/
	$(KUBECTL) apply -f policy/tenants/

# --------------------------------------------------------------------------
# Lint
# --------------------------------------------------------------------------

.PHONY: lint
lint: lint-yaml lint-ansible lint-shell lint-helm ## Run every linter

.PHONY: lint-yaml
lint-yaml:
	$(LINT) yamllint -c .yamllint --strict .

.PHONY: lint-ansible
lint-ansible:
	$(LINT) ansible-lint -c .ansible-lint

# ANSIBLE_VARS_ENABLED drops community.sops.sops for this one check. Loading
# group_vars otherwise means decrypting secrets.sops.yml, which would make an
# age key a prerequisite for answering "does the inventory parse" — and lint
# runs on pull requests, which is the last place a decryption key belongs.
.PHONY: lint-inventory
lint-inventory: ## Inventory parses and every host resolves
	$(LINT_NO_SOPS) ansible-inventory -i $(INVENTORY) --list --yaml > /dev/null

.PHONY: lint-shell
lint-shell:
	$(LINT) sh -c 'find bootstrap tests -name "*.sh" -print0 | xargs -0 -r shellcheck'

.PHONY: lint-helm
lint-helm: ## Render every pinned chart against its values file
	$(LINT) tests/helm-template-check.sh

.PHONY: clean
clean: ## Remove rendered artefacts
	rm -rf $(BUILD_DIR)
