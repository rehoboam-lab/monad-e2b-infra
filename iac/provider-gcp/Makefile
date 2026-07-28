ENV := $(shell cat ../../.last_used_env || echo "not-set")
ENV_FILE := ../../.env.${ENV}

-include ${ENV_FILE}

TF := $(shell which terraform)
TF_VAR_FILE := ./.terraform.${ENV}.tfvars
TF_VAR_FILE_ARG := $(if $(wildcard $(TF_VAR_FILE)),-var-file=$(TF_VAR_FILE))
TERRAFORM_STATE_BUCKET ?= $(GCP_PROJECT_ID)-terraform-state
TEMPLATE_BUCKET_LOCATION ?= $(GCP_REGION)
BUCKET_PREFIX ?= $(GCP_PROJECT_ID)-

SKIP_FMT ?= false
define tf_fmt
$(if $(filter true,$(SKIP_FMT)),,$(TF) fmt -recursive)
endef

# Set the terraform environment variable only if the environment variable is set
# Strip the passed variable name (it's space sensitive) and check if the variable is set, if yes return TF_VAR_<variable_name>=<value> with the variable name in lower case
define tfvar
$(if $(value $(strip $(1))), TF_VAR_$(shell echo $(strip $(1)) | tr A-Z a-z)=$($(strip $(1))))
endef

tf_vars := \
	TF_VAR_environment=$(TERRAFORM_ENVIRONMENT) \
	$(call tfvar, BUILD_CLUSTERS_CONFIG) \
	$(call tfvar, CLIENT_CLUSTERS_CONFIG) \
	$(call tfvar, API_MACHINE_TYPE) \
	$(call tfvar, API_CLUSTER_SIZE) \
	$(call tfvar, API_USE_NAT) \
	$(call tfvar, API_NAT_IPS) \
	$(call tfvar, SERVER_MACHINE_TYPE) \
	$(call tfvar, SERVER_CLUSTER_SIZE) \
	$(call tfvar, CLICKHOUSE_CLUSTER_SIZE) \
	$(call tfvar, CLICKHOUSE_MACHINE_TYPE) \
	$(call tfvar, LOKI_MACHINE_TYPE) \
	$(call tfvar, LOKI_CLUSTER_SIZE) \
	$(call tfvar, GCP_PROJECT_ID) \
	$(call tfvar, GCP_REGION) \
	$(call tfvar, GCP_ZONE) \
	$(call tfvar, DOMAIN_NAME) \
	$(call tfvar, PREFIX) \
	$(call tfvar, ORCHESTRATOR_ENABLED) \
	$(call tfvar, API_INTERNAL_GRPC_PORT) \
	$(call tfvar, ALLOW_SANDBOX_INTERNAL_CIDRS) \
	$(call tfvar, API_SERVER_COUNT) \
	$(call tfvar, API_RESOURCES_CPU_COUNT) \
	$(call tfvar, API_RESOURCES_MEMORY_MB) \
	$(call tfvar, INGRESS_COUNT) \
	$(call tfvar, CLIENT_PROXY_COUNT) \
	$(call tfvar, CLIENT_PROXY_RESOURCES_CPU_COUNT) \
	$(call tfvar, CLIENT_PROXY_RESOURCES_MEMORY_MB) \
	$(call tfvar, CLICKHOUSE_RESOURCES_CPU_COUNT) \
	$(call tfvar, CLICKHOUSE_RESOURCES_MEMORY_MB) \
	$(call tfvar, CLIENT_PROXY_UPDATE_MAX_PARALLEL) \
	$(call tfvar, LOKI_RESOURCES_CPU_COUNT) \
	$(call tfvar, LOKI_RESOURCES_MEMORY_MB) \
	$(call tfvar, OTEL_COLLECTOR_RESOURCES_CPU_COUNT) \
	$(call tfvar, OTEL_COLLECTOR_RESOURCES_MEMORY_MB) \
	$(call tfvar, ENABLE_OTEL_ROUTER_LOGS) \
	$(call tfvar, OTEL_ROUTER_HTTP_PORT) \
	$(call tfvar, ENABLE_OTEL_ROUTER_METRICS) \
	$(call tfvar, OTEL_ROUTER_GRPC_PORT) \
	$(call tfvar, ENABLE_GCP_TELEMETRY_METRICS) \
	$(call tfvar, ENABLE_GCP_TELEMETRY_EXTERNAL_METRICS) \
	$(call tfvar, TEMPLATE_BUCKET_NAME) \
	$(call tfvar, TEMPLATE_BUCKET_LOCATION) \
	$(call tfvar, ENVD_TIMEOUT) \
	$(call tfvar, REDIS_MANAGED) \
	$(call tfvar, REDIS_SHARD_COUNT) \
	$(call tfvar, GCP_REDIS_NODE_TYPE) \
	$(call tfvar, GCP_REDIS_ENGINE_VERSION) \
	$(call tfvar, GRAFANA_MANAGED) \
	$(call tfvar, FILESTORE_CACHE_ENABLED) \
	$(call tfvar, FILESTORE_CACHE_TIER) \
	$(call tfvar, FILESTORE_CACHE_CAPACITY_GB) \
	$(call tfvar, FILESTORE_MAX_DISK_USAGE_TARGET) \
	$(call tfvar, REMOTE_REPOSITORY_ENABLED) \
	$(call tfvar, API_BOOT_DISK_TYPE) \
	$(call tfvar, SERVER_BOOT_DISK_TYPE) \
	$(call tfvar, SERVER_BOOT_DISK_SIZE_GB) \
	$(call tfvar, CLICKHOUSE_BOOT_DISK_TYPE) \
	$(call tfvar, CLICKHOUSE_STATEFUL_DISK_TYPE) \
	$(call tfvar, CLICKHOUSE_STATEFUL_DISK_SIZE_GB) \
	$(call tfvar, BUCKET_PREFIX) \
	$(call tfvar, LOKI_BOOT_DISK_TYPE) \
	$(call tfvar, LOKI_USE_V13_SCHEMA_FROM) \
	$(call tfvar, DASHBOARD_API_COUNT) \
	$(call tfvar, DEFAULT_PERSISTENT_VOLUME_TYPE) \
	$(call tfvar, PERSISTENT_VOLUME_TYPES) \
	$(call tfvar, DB_MAX_OPEN_CONNECTIONS) \
	$(call tfvar, DB_MIN_IDLE_CONNECTIONS) \
	$(call tfvar, AUTH_DB_MAX_OPEN_CONNECTIONS) \
	$(call tfvar, AUTH_DB_MIN_IDLE_CONNECTIONS) \
	$(call tfvar, CLIENT_PROXY_OIDC_ISSUER_URL) \
	$(call tfvar, ORY_SDK_URL) \
	$(call tfvar, ORY_ISSUER_URL) \
	$(call tfvar, GCS_GRPC_CONNECTION_POOL_SIZE) \
	$(call tfvar, ADDITIONAL_API_PATHS_HANDLED_BY_INGRESS) \
	$(call tfvar, ANYWHERE_CACHE_ENABLED)

.PHONY: init
init:
	@ printf "Refusing legacy init in the Monad fork. Use 'make foundation-init' then review 'make foundation-plan'.\n"
	@ exit 1

FOUNDATION_PLAN := .tfplan.foundation.$(ENV)
FOUNDATION_DESTROY_PLAN := .tfplan.foundation-destroy.$(ENV)
override FOUNDATION_CONFIRMATION := APPLY KEYLESS FOUNDATION

.PHONY: runtime-blocked
runtime-blocked:
	@ printf "Refusing workload Terraform in the F1.0 foundation branch. Only foundation-init, foundation-plan, and confirmed foundation-apply are supported.\n"
	@ exit 1

.PHONY: foundation-config-guard
foundation-config-guard:
	@ test "$(ENV)" != "not-set" || (printf "No environment selected. Run 'make set-env ENV=dev' from the repository root.\n"; exit 1)
	@ test -f "$(ENV_FILE)" || (printf "Missing environment file $(ENV_FILE).\n"; exit 1)
	@ test -n "$(GCP_PROJECT_ID)" || (printf "GCP_PROJECT_ID is required.\n"; exit 1)
	@ test -n "$(GCP_REGION)" || (printf "GCP_REGION is required.\n"; exit 1)
	@ test -n "$(TERRAFORM_STATE_BUCKET)" && test "$(TERRAFORM_STATE_BUCKET)" != "-terraform-state" || (printf "A valid TERRAFORM_STATE_BUCKET is required.\n"; exit 1)

.PHONY: foundation-init
foundation-init: foundation-config-guard
	@ printf "Initializing keyless foundation state for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ gcloud storage buckets create gs://$(TERRAFORM_STATE_BUCKET) --location $(GCP_REGION) --project $(GCP_PROJECT_ID) --default-storage-class STANDARD --uniform-bucket-level-access > /dev/null 2>&1 || true
	@ gcloud storage buckets update gs://$(TERRAFORM_STATE_BUCKET) --versioning --soft-delete-duration=30d
	@ $(TF) init -input=false -reconfigure -backend-config=bucket=$(TERRAFORM_STATE_BUCKET)
	@ ./scripts/assert-foundation-state.sh "$(TF)"

.PHONY: foundation-plan
foundation-plan: foundation-config-guard
	@ printf "Planning keyless foundation only for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ ./scripts/assert-foundation-state.sh "$(TF)"
	@ $(call tf_fmt)
	@ umask 077; $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) \
		-var=anywhere_cache_enabled=false \
		-target=module.init \
		-out=$(FOUNDATION_PLAN) \
		-input=false \
		-compact-warnings
	@ chmod 0600 $(FOUNDATION_PLAN)
	@ ./scripts/assert-foundation-plan.sh "$(FOUNDATION_PLAN)" "$(TF)" apply

.PHONY: foundation-apply
foundation-apply: foundation-config-guard
	@ if [ "$(CONFIRM)" != "$(FOUNDATION_CONFIRMATION)" ]; then \
		printf "Refusing foundation apply. Re-run with CONFIRM='$(FOUNDATION_CONFIRMATION)'.\n"; \
		exit 1; \
	fi
	@ test -f $(FOUNDATION_PLAN) || (printf "Missing reviewed plan $(FOUNDATION_PLAN). Run 'make foundation-plan' first.\n"; exit 1)
	@ ./scripts/assert-foundation-state.sh "$(TF)"
	@ ./scripts/assert-foundation-plan.sh "$(FOUNDATION_PLAN)" "$(TF)" apply
	@ $(TF) apply -input=false $(FOUNDATION_PLAN)
	@ rm $(FOUNDATION_PLAN)

.PHONY: foundation-destroy-plan
foundation-destroy-plan: foundation-config-guard
	@ printf "Planning review-only foundation destroy for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ ./scripts/assert-foundation-state.sh "$(TF)"
	@ umask 077; $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) \
		-var=anywhere_cache_enabled=false \
		-target=module.init \
		-destroy \
		-out=$(FOUNDATION_DESTROY_PLAN) \
		-input=false \
		-compact-warnings
	@ chmod 0600 $(FOUNDATION_DESTROY_PLAN)
	@ ./scripts/assert-foundation-plan.sh "$(FOUNDATION_DESTROY_PLAN)" "$(TF)" destroy
	@ printf "Destroy plan is review-only; this branch intentionally provides no apply target.\n"

.PHONY: state-migrate
state-migrate: runtime-blocked
	@ printf "Running Terraform state migrations for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) state mv 'random_password.api_admin_secret' 'module.init.random_password.api_admin_secret' || true
	@ $(tf_vars) $(TF) state mv 'google_secret_manager_secret.api_admin_token' 'module.init.google_secret_manager_secret.api_admin_token' || true
	@ $(tf_vars) $(TF) state mv 'google_secret_manager_secret_version.api_admin_token_value' 'module.init.google_secret_manager_secret_version.api_admin_token_value' || true
	@ $(tf_vars) $(TF) state mv 'random_password.dashboard_api_admin_secret' 'module.init.random_password.dashboard_api_admin_secret' || true
	@ $(tf_vars) $(TF) state mv 'google_secret_manager_secret.dashboard_api_admin_token' 'module.init.google_secret_manager_secret.dashboard_api_admin_token' || true
	@ $(tf_vars) $(TF) state mv 'google_secret_manager_secret_version.dashboard_api_admin_token_value' 'module.init.google_secret_manager_secret_version.dashboard_api_admin_token_value' || true
	@ $(tf_vars) $(TF) state mv 'module.nomad.random_password.clickhouse_password' 'random_password.clickhouse_password' || true
	@ $(tf_vars) $(TF) state mv 'module.nomad.random_password.clickhouse_server_secret' 'random_password.clickhouse_server_secret' || true

.PHONY: apply-init
apply-init: runtime-blocked
	@ $(tf_vars) $(TF) apply $(TF_VAR_FILE_ARG) -target=module.init -auto-approve -input=false -compact-warnings

.PHONY: switch
switch:
	@ printf "Switching Terraform backend for different env ${ENV}\n"
	@ $(TF) init -input=false -upgrade -reconfigure -backend-config=bucket=$(TERRAFORM_STATE_BUCKET)

.PHONY: destroy
destroy: runtime-blocked
	@ printf "Destroying Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) destroy $(TF_VAR_FILE_ARG)

.PHONY: plan
plan: runtime-blocked
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(call tf_fmt)
	@ $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -compact-warnings

.PHONY: terraform
terraform: runtime-blocked
	@ printf "Terraform command for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(call tf_fmt)
	@ $(tf_vars) $(TF) $(ARGS)

# Deploy all jobs in Nomad
# When job name is specified, all '-' are replaced with '_' in the job name
# Clickhouse jobs are scoped in Clickhouse submodule so we need special handling for them
plan_only_jobs_moved_targets = -target="random_password.clickhouse_password" -target="random_password.clickhouse_server_secret" -target="module.nomad.random_password.clickhouse_password" -target="module.nomad.random_password.clickhouse_server_secret"

.PHONY: plan-only-jobs plan-only-jobs/clickhouse plan-only-jobs/clickhouse_migrator plan-only-jobs/clickhouse_backup plan-only-jobs/clickhouse_backup_restore
plan-only-jobs/clickhouse: runtime-blocked
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(call tf_fmt)
	$(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -compact-warnings -target="module.nomad.module.clickhouse.nomad_job.clickhouse" $(plan_only_jobs_moved_targets)
plan-only-jobs/clickhouse_migrator: runtime-blocked
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(call tf_fmt)
	$(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -compact-warnings -target="module.nomad.module.clickhouse.nomad_job.clickhouse_migrator" $(plan_only_jobs_moved_targets)
plan-only-jobs/clickhouse_backup: runtime-blocked
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(call tf_fmt)
	$(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -compact-warnings -target="module.nomad.module.clickhouse.nomad_job.clickhouse_backup" $(plan_only_jobs_moved_targets)
plan-only-jobs/clickhouse_backup_restore: runtime-blocked
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(call tf_fmt)
	$(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -compact-warnings -target="module.nomad.module.clickhouse.nomad_job.clickhouse_backup_restore" $(plan_only_jobs_moved_targets)
plan-only-jobs/%: runtime-blocked
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(call tf_fmt)
	@ $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -compact-warnings -target=module.nomad.nomad_job.$(subst -,_,$(notdir $@)) -target=module.nomad.module.$(subst -,_,$(notdir $@)) $(plan_only_jobs_moved_targets)
plan-only-jobs: runtime-blocked
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(call tf_fmt)
	@ $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -compact-warnings -target=module.nomad $(plan_only_jobs_moved_targets)

.PHONY: plan-without-jobs
plan-without-jobs: runtime-blocked
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(eval TARGET := $(shell cat main.tf | grep "^module" | awk '{print $$2}' | tr ' ' '\n' | grep -v -e "nomad" | awk '{print "-target=module." $$0 ""}' | xargs))
	@ $(tf_vars) \
	$(TF) plan \
	$(TF_VAR_FILE_ARG) \
	-out=.tfplan.$(ENV) \
	-input=false \
	-compact-warnings \
	-parallelism=20 \
	$(TARGET)

.PHONY: apply
apply: runtime-blocked
	@ printf "Applying Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(TF) apply \
	-auto-approve \
	-input=false \
	-compact-warnings \
	-parallelism=20 \
	.tfplan.$(ENV)
	@ rm .tfplan.$(ENV)

# Shortcut to importing resources into Terraform state (e.g. after creating resources manually or switching between different branches for the same environment)
.PHONY: import
import: runtime-blocked
	@ printf "Importing resources for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) import $(TF_VAR_FILE_ARG) "$(TARGET)" "$(ID)" -no-color

.PHONY: move
move: runtime-blocked
	@ printf "Moving resource for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) state mv "$(SOURCE)" "$(TARGET)" -no-color

# Login for Packer and Docker (uses gcloud user creds)
# Login for Terraform (uses application default creds)
.PHONY: provider-login
provider-login:
	gcloud --quiet auth login --update-adc
	gcloud config set project "$(GCP_PROJECT_ID)"
	gcloud --quiet auth configure-docker "$(GCP_REGION)-docker.pkg.dev"
