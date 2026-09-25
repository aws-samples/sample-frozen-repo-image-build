# Frozen Package Repository, deployment Makefile. Deploy `make all` (bootstrap->distribution->workload->images->full-sync->seed) or run phase targets one at a time.
# Run `make plan` first to review. Cross-account: set a profile per account, e.g. make all DIST_PROFILE=frozenrepo-distribution WORK_PROFILE=frozenrepo-workload (Distribution=write, Workload=air-gapped read).

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENV_DIR       := environments
DIST_DIR      := $(ENV_DIR)/Distribution
WORK_DIR      := $(ENV_DIR)/Workload
TG            := terragrunt
TG_NONINT     := --non-interactive

# Set these to the AWS profiles that can assume the deploy role in each account.
DIST_PROFILE  ?=
WORK_PROFILE  ?=
DIST_AWS      := $(if $(DIST_PROFILE),AWS_PROFILE=$(DIST_PROFILE),)
WORK_AWS      := $(if $(WORK_PROFILE),AWS_PROFILE=$(WORK_PROFILE),)

# Container image tags (must match the image_tag inputs in _env/sync-engine.hcl and _env/mirror.hcl).
IMAGE_TAG         ?= v1.0.0

# Explicit acknowledgement required before the operator-authorized initial full sync.
BASELINE_APPROVED ?= false

# Container engine. Defaults to Finch (Docker-free). Override with CONTAINER=docker.
CONTAINER     ?= finch

.PHONY: help all plan plan-distribution plan-workload \
        bootstrap lambda-deps images image-sync image-mirror full-sync \
        distribution workload seed check-config test \
        unit destroy-workload destroy-distribution

CONFIG_FILE := $(ENV_DIR)/config.hcl

## help
help:
	@echo "Frozen Package Repository deployment"
	@echo ""
	@echo "ALL-IN (one command, auto-approve, correct ordering):"
	@echo "  make all            bootstrap -> distribution -> workload -> images -> full-sync -> seed"
	@echo ""
	@echo "REVIEW FIRST (no changes applied):"
	@echo "  make plan           run-all plan for both accounts"
	@echo ""
	@echo "STEP-BY-STEP (run in order, review as you go):"
	@echo "  make bootstrap      state bucket + lock table per account + cross-account state policy"
	@echo "  make distribution   run-all apply the Distribution account"
	@echo "  make workload       run-all apply the Workload account"
	@echo "  make images         build + push the sync and mirror images (amd64)"
	@echo "  make full-sync BASELINE_APPROVED=true"
	@echo "                       one-time operator-authorized initial mirror (hours)"
	@echo "  make seed           invoke the detector once to baseline the manifest"
	@echo ""
	@echo "SINGLE UNIT (finest granularity):"
	@echo "  make unit DIR=environments/Distribution/us-west-2/frozen-store"
	@echo ""
	@echo "Set DIST_PROFILE and WORK_PROFILE for cross-account credentials."

## all-in
# `run --all apply` auto-approves, so run `make plan` first to review.
# Order matters: sync-engine and mirror units CREATE the ECR repos, so image builds/pushes must run after the account applies. full-sync populates the repo (hours); seed then baselines the detector.
all: bootstrap distribution workload images full-sync seed
	@echo "== Full deployment complete =="

## preflight: fail fast if config.hcl still holds template placeholders
# Scans active config.hcl lines for shipped sentinel account/network ids, mock
# ARNs, the placeholder parent AMI, example domains/email/certificate, and the
# non-unique demonstration bucket name. Any match blocks plan/apply.
check-config:
	@test -f "$(CONFIG_FILE)" || { echo "ERROR: $(CONFIG_FILE) not found."; exit 1; }
	@if grep -vE '^\s*#' "$(CONFIG_FILE)" | grep -Eq '111111111111|222222222222|vpc-1111|vpc-2222|subnet-1111|subnet-2222|sg-1111|sg-2222|:key/mock|Z0000000000000000MOCK|ami-00000000000000000|example\.com|amzn-s3-demo-frozen-os-repos|mock-cert'; then \
	  echo ""; \
	  echo "=============================================================="; \
	  echo " ERROR: $(CONFIG_FILE) still contains template placeholders."; \
	  echo " Fill in your real account ids, VPC/subnet/SG ids, and ARNs"; \
	  echo " before running plan/apply. Offending lines:"; \
	  echo "=============================================================="; \
	  grep -nvE '^\s*#' "$(CONFIG_FILE)" | grep -E '111111111111|222222222222|vpc-1111|vpc-2222|subnet-1111|subnet-2222|sg-1111|sg-2222|:key/mock|Z0000000000000000MOCK|ami-00000000000000000|example\.com|amzn-s3-demo-frozen-os-repos|mock-cert'; \
	  exit 1; \
	fi
	@echo "== config.hcl preflight OK (no template placeholders detected) =="

## review
plan: plan-distribution plan-workload

plan-distribution: check-config lambda-deps
	cd $(DIST_DIR) && $(DIST_AWS) $(TG) run --all plan

plan-workload: check-config
	cd $(WORK_DIR) && $(WORK_AWS) $(TG) run --all plan

## step-by-step phases
# One-time state backend: remote-state bucket (Distribution) with a least-privilege cross-account policy for the Workload deploy principal, plus a DynamoDB lock table in EACH account. Idempotent.
# Deploy roles (when deploy_role_name is set) remain a landing-zone concern.
bootstrap: check-config
	@test -n "$(DIST_PROFILE)" && test -n "$(WORK_PROFILE)" || \
	  { echo "usage: make bootstrap DIST_PROFILE=<profile> WORK_PROFILE=<profile>"; exit 1; }
	scripts/bootstrap.sh "$(DIST_PROFILE)" "$(WORK_PROFILE)"

images: image-sync image-mirror

# --platform=linux/amd64 is required: ECS tasks run on Fargate LINUX/X86_64, so a native arm64 (Apple Silicon) image fails at task start with a manifest-platform mismatch.
# ECR repos use immutable tags, so a wrong-platform push blocks the tag.
image-sync: check-config
	@echo "== build + push sync image ($(IMAGE_TAG)) to the Distribution account ECR =="
	@acct=$$(sed -n 's/^ *distribution_account_id *= *"\([0-9]*\)".*/\1/p' $(CONFIG_FILE)); \
	ecr="$$acct.dkr.ecr.us-east-1.amazonaws.com"; \
	set -e; \
	cd containers/sync && $(CONTAINER) build --platform=linux/amd64 -t $$ecr/frozenrepo/frozen-repo-sync:$(IMAGE_TAG) . ; \
	$(DIST_AWS) aws ecr get-login-password --region us-east-1 | $(CONTAINER) login --username AWS --password-stdin $$ecr; \
	$(CONTAINER) push $$ecr/frozenrepo/frozen-repo-sync:$(IMAGE_TAG)

image-mirror: check-config
	@echo "== build + push mirror image ($(IMAGE_TAG)) to the Workload account ECR =="
	@acct=$$(sed -n 's/^ *workload_account_id *= *"\([0-9]*\)".*/\1/p' $(CONFIG_FILE)); \
	ecr="$$acct.dkr.ecr.us-west-2.amazonaws.com"; \
	set -e; \
	cd containers/mirror && $(CONTAINER) build --platform=linux/amd64 -t $$ecr/frozenrepo/frozen-repo-mirror:$(IMAGE_TAG) . ; \
	$(WORK_AWS) aws ecr get-login-password --region us-west-2 | $(CONTAINER) login --username AWS --password-stdin $$ecr; \
	$(CONTAINER) push $$ecr/frozenrepo/frozen-repo-mirror:$(IMAGE_TAG)

# Vendor each Lambda's pip deps (requirements.txt) into its source dir so the archive_file zip contains them; without this the functions fail at import with Runtime.ImportModuleError.
# Idempotent; vendored packages are gitignored. Requires python3 + pip.
lambda-deps:
	@echo "== vendor Lambda pip dependencies into the source dirs =="
	@for d in lambdas/*/; do \
	  if [ -f "$$d/requirements.txt" ]; then \
	    echo "-- $$d"; \
	    python3 -m pip install --quiet --upgrade --target "$$d" -r "$$d/requirements.txt"; \
	  fi; \
	done

distribution: check-config lambda-deps
	@echo "== apply Distribution account (run-all, dependency-ordered) =="
	cd $(DIST_DIR) && $(DIST_AWS) $(TG) run --all apply $(TG_NONINT)

workload: check-config
	@echo "== apply Workload account (run-all, dependency-ordered) =="
	cd $(WORK_DIR) && $(WORK_AWS) $(TG) run --all apply $(TG_NONINT)

# One-time initial population: run the sync task in FULL_SYNC mode to mirror every os_matrix repo (download, GPG-verify, upload). Runs for HOURS and egresses tens of GB via the Distribution NAT.
# Network values come from config.hcl and the sync-engine outputs (nothing hardcoded). Idempotent: re-running re-mirrors.
full-sync: check-config
	@test "$(BASELINE_APPROVED)" = "true" || { \
	  echo "ERROR: initial full sync establishes the operator-authorized baseline."; \
	  echo "Review the configured repositories, then rerun with BASELINE_APPROVED=true."; \
	  exit 1; \
	}
	@echo "== initial operator-authorized full sync: mirror every os_matrix repo into the frozen bucket =="
	@set -e; \
	subnets=$$(sed -n 's/^ *distribution_subnet_ids *= *\[\(.*\)\].*/\1/p' $(CONFIG_FILE) | tr -d ' "'); \
	sg=$$(cd $(DIST_DIR)/us-east-1/sync-engine && $(DIST_AWS) $(TG) output -raw security_group_id 2>/dev/null); \
	cluster=$$(cd $(DIST_DIR)/us-east-1/sync-engine && $(DIST_AWS) $(TG) output -raw cluster_name 2>/dev/null); \
	family=$$(cd $(DIST_DIR)/us-east-1/sync-engine && $(DIST_AWS) $(TG) output -raw task_family 2>/dev/null); \
	test -n "$$subnets" && test -n "$$sg" && test -n "$$cluster" && test -n "$$family" || { echo "ERROR: could not resolve subnets/SG/cluster/task family (is the Distribution account applied?)"; exit 1; }; \
	echo "   cluster=$$cluster subnets=$$subnets sg=$$sg"; \
	task_arn=$$($(DIST_AWS) aws ecs run-task \
	  --cluster "$$cluster" --task-definition "$$family" --launch-type FARGATE \
	  --network-configuration "awsvpcConfiguration={subnets=[$$subnets],securityGroups=[$$sg],assignPublicIp=DISABLED}" \
	  --overrides '{"containerOverrides":[{"name":"sync","environment":[{"name":"FULL_SYNC","value":"true"},{"name":"BASELINE_APPROVED","value":"true"}]}]}' \
	  --region us-east-1 --query 'tasks[0].taskArn' --output text); \
	case "$$task_arn" in ""|None) echo "ERROR: ECS did not start the full-sync task"; exit 1;; esac; \
	echo "   task=$$task_arn"; \
	echo "   waiting for the full-sync task to stop (this can take hours)..."; \
	$(DIST_AWS) aws ecs wait tasks-stopped --cluster "$$cluster" --tasks "$$task_arn" --region us-east-1; \
	exit_code=$$($(DIST_AWS) aws ecs describe-tasks --cluster "$$cluster" --tasks "$$task_arn" --region us-east-1 --query 'tasks[0].containers[?name==`sync`].exitCode | [0]' --output text); \
	stopped_reason=$$($(DIST_AWS) aws ecs describe-tasks --cluster "$$cluster" --tasks "$$task_arn" --region us-east-1 --query 'tasks[0].stoppedReason' --output text); \
	if [ "$$exit_code" != "0" ]; then \
	  echo "ERROR: full-sync task failed (exit=$$exit_code, reason=$$stopped_reason, task=$$task_arn)"; \
	  exit 1; \
	fi; \
	echo "== full sync completed successfully (task=$$task_arn) =="

seed:
	@echo "== seed the frozen repo (invoke the detector once; can run several minutes) =="
	@set -e; \
	function_name=$$(cd $(DIST_DIR)/us-east-1/detector-lambda && $(DIST_AWS) $(TG) output -raw function_name 2>/dev/null); \
	test -n "$$function_name" || { echo "ERROR: could not resolve detector function name (is the Distribution account applied?)"; exit 1; }; \
	response_file=$$(mktemp); \
	trap 'rm -f "$$response_file"' EXIT; \
	function_error=$$($(DIST_AWS) aws lambda invoke --function-name "$$function_name" \
	  --cli-read-timeout 900 --region us-east-1 --query 'FunctionError' --output text "$$response_file"); \
	cat "$$response_file"; \
	if [ "$$function_error" != "None" ]; then \
	  echo "ERROR: detector Lambda failed (FunctionError=$$function_error)"; \
	  exit 1; \
	fi

## single unit (finest granularity, review + apply one component)
unit:
	@test -n "$(DIR)" || { echo "usage: make unit DIR=environments/<Account>/<region>/<component>"; exit 1; }
	cd $(DIR) && $(TG) plan && $(TG) apply

## tests
# Static and behavioral guards for security-critical sync invariants.
test:
	python3 -m unittest discover -s tests -p 'test_*.py'
	bash -n containers/sync/sync.sh containers/mirror/entrypoint.sh scripts/bootstrap.sh

## teardown (reverse order: workload before distribution)
destroy-workload:
	cd $(WORK_DIR) && $(WORK_AWS) $(TG) run --all destroy $(TG_NONINT)

destroy-distribution:
	cd $(DIST_DIR) && $(DIST_AWS) $(TG) run --all destroy $(TG_NONINT)
