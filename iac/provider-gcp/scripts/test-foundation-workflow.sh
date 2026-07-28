#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider_root="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${provider_root}/../.." && pwd)"
workspace="$(mktemp -d)"
trap 'rm -rf "${workspace}"' EXIT

expect_pass() {
  local description="$1"
  shift
  if ! "$@" >"${workspace}/stdout" 2>"${workspace}/stderr"; then
    printf 'expected pass: %s\n' "${description}" >&2
    cat "${workspace}/stderr" >&2
    exit 1
  fi
}

expect_fail() {
  local description="$1"
  shift
  if "$@" >"${workspace}/stdout" 2>"${workspace}/stderr"; then
    printf 'expected failure: %s\n' "${description}" >&2
    exit 1
  fi
}

backend_dir="${workspace}/backend"
mkdir -p "${backend_dir}"
cat >"${backend_dir}/terraform.tfstate" <<'JSON'
{
  "version": 3,
  "backend": {
    "type": "gcs",
    "config": {
      "bucket": "monad-state",
      "prefix": "terraform/orchestration/dev/state"
    }
  }
}
JSON

expect_pass \
  "matching environment backend" \
  "${script_dir}/assert-foundation-backend.sh" \
  monad-state \
  terraform/orchestration/dev/state \
  "${backend_dir}"
expect_fail \
  "wrong backend bucket" \
  "${script_dir}/assert-foundation-backend.sh" \
  other-state \
  terraform/orchestration/dev/state \
  "${backend_dir}"
expect_fail \
  "wrong backend environment prefix" \
  "${script_dir}/assert-foundation-backend.sh" \
  monad-state \
  terraform/orchestration/prod/state \
  "${backend_dir}"
expect_fail \
  "missing backend metadata" \
  "${script_dir}/assert-foundation-backend.sh" \
  monad-state \
  terraform/orchestration/dev/state \
  "${workspace}/missing-backend"

fake_terraform="${workspace}/terraform"
fake_terraform_version="${workspace}/terraform-version"
printf '1.7.5\n' >"${fake_terraform_version}"
cat >"${fake_terraform}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  version)
    printf '{"terraform_version":"%s"}\n' "$(cat "${FAKE_TERRAFORM_VERSION_FILE}")"
    ;;
  *)
    printf 'unexpected fake Terraform command: %s\n' "${1:-<none>}" >&2
    exit 2
    ;;
esac
EOF
chmod 0755 "${fake_terraform}"

metadata_config="${workspace}/metadata-config"
mkdir -p "${metadata_config}/scripts"
cat >"${metadata_config}/main.tf" <<'EOF'
terraform {
  required_version = "=1.7.5"
}
EOF
printf 'fixture\n' >"${metadata_config}/Makefile"
printf '#!/usr/bin/env bash\n' >"${metadata_config}/scripts/guard.sh"
metadata_env="${workspace}/.env.dev"
printf 'GCP_PROJECT_ID=monad-code\n' >"${metadata_env}"
metadata_plan="${workspace}/foundation.plan"
metadata_manifest="${workspace}/foundation.plan.manifest"
printf 'reviewed plan bytes\n' >"${metadata_plan}"
chmod 0600 "${metadata_plan}"

export FAKE_TERRAFORM_VERSION_FILE="${fake_terraform_version}"
export FOUNDATION_ENV="dev"
export FOUNDATION_ENV_FILE="${metadata_env}"
export FOUNDATION_TF_VAR_FILE="${workspace}/absent.tfvars"
export FOUNDATION_GCP_PROJECT_ID="monad-code"
export FOUNDATION_GCP_REGION="us-east4"
export FOUNDATION_STATE_BUCKET="monad-state"
export FOUNDATION_STATE_PREFIX="terraform/orchestration/dev/state"
metadata_fingerprint="$(
  "${script_dir}/foundation-plan-metadata.sh" \
    fingerprint \
    "${fake_terraform}" \
    "${metadata_config}" \
    "${repo_root}"
)"

expect_fail \
  "changed configuration fingerprint cannot be recorded" \
  "${script_dir}/foundation-plan-metadata.sh" \
  write \
  "${metadata_plan}" \
  "${metadata_manifest}" \
  "${fake_terraform}" \
  "${metadata_config}" \
  "${repo_root}" \
  deadbeef

expect_pass \
  "write plan provenance" \
  "${script_dir}/foundation-plan-metadata.sh" \
  write \
  "${metadata_plan}" \
  "${metadata_manifest}" \
  "${fake_terraform}" \
  "${metadata_config}" \
  "${repo_root}" \
  "${metadata_fingerprint}"
expect_pass \
  "verify unchanged plan provenance" \
  "${script_dir}/foundation-plan-metadata.sh" \
  verify \
  "${metadata_plan}" \
  "${metadata_manifest}" \
  "${fake_terraform}" \
  "${metadata_config}" \
  "${repo_root}"

FOUNDATION_GCP_PROJECT_ID="other-project" \
  expect_fail \
    "changed project invalidates plan" \
    "${script_dir}/foundation-plan-metadata.sh" \
    verify \
    "${metadata_plan}" \
    "${metadata_manifest}" \
    "${fake_terraform}" \
    "${metadata_config}" \
    "${repo_root}"

printf '\n# drift\n' >>"${metadata_config}/main.tf"
expect_fail \
  "changed Terraform source invalidates plan" \
  "${script_dir}/foundation-plan-metadata.sh" \
  verify \
  "${metadata_plan}" \
  "${metadata_manifest}" \
  "${fake_terraform}" \
  "${metadata_config}" \
  "${repo_root}"
cat >"${metadata_config}/main.tf" <<'EOF'
terraform {
  required_version = "=1.7.5"
}
EOF

printf 'tampered\n' >>"${metadata_plan}"
expect_fail \
  "changed plan bytes invalidate provenance" \
  "${script_dir}/foundation-plan-metadata.sh" \
  verify \
  "${metadata_plan}" \
  "${metadata_manifest}" \
  "${fake_terraform}" \
  "${metadata_config}" \
  "${repo_root}"

printf 'reviewed plan bytes\n' >"${metadata_plan}"
chmod 0644 "${metadata_plan}"
expect_fail \
  "world-readable plan is rejected" \
  "${script_dir}/foundation-plan-metadata.sh" \
  verify \
  "${metadata_plan}" \
  "${metadata_manifest}" \
  "${fake_terraform}" \
  "${metadata_config}" \
  "${repo_root}"

fake_gcloud="${workspace}/gcloud"
bucket_mode_file="${workspace}/bucket-mode"
bucket_created_file="${workspace}/bucket-created"
bucket_updated_file="${workspace}/bucket-updated"
bucket_log_file="${workspace}/bucket-log"
cat >"${fake_gcloud}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_BUCKET_LOG_FILE}"
mode="$(cat "${FAKE_BUCKET_MODE_FILE}")"

if [[ "${1:-}" == "projects" && "${2:-}" == "describe" ]]; then
  printf '123456\n'
  exit 0
fi

if [[ "${1:-}" == "storage" && "${2:-}" == "buckets" && "${3:-}" == "create" ]]; then
  if [[ "${mode}" == "create-fails" ]]; then
    printf 'simulated create failure\n' >&2
    exit 1
  fi
  touch "${FAKE_BUCKET_CREATED_FILE}"
  exit 0
fi

if [[ "${1:-}" == "storage" && "${2:-}" == "buckets" && "${3:-}" == "update" ]]; then
  touch "${FAKE_BUCKET_UPDATED_FILE}"
  exit 0
fi

if [[ "${1:-}" != "storage" || "${2:-}" != "buckets" || "${3:-}" != "describe" ]]; then
  printf 'unexpected fake gcloud command\n' >&2
  exit 2
fi

if [[ "${mode}" == "missing" || "${mode}" == "create-fails" ]]; then
  if [[ ! -f "${FAKE_BUCKET_CREATED_FILE}" ]]; then
    printf 'simulated missing bucket\n' >&2
    exit 1
  fi
fi

project_number="123456"
location="US-EAST4"
if [[ "${mode}" == "wrong-project" ]]; then
  project_number="654321"
fi
if [[ "${mode}" == "wrong-location" ]]; then
  location="US-WEST1"
fi

secure=false
if [[ -f "${FAKE_BUCKET_UPDATED_FILE}" && "${mode}" != "insecure-after-update" ]]; then
  secure=true
fi

if [[ "${secure}" == true ]]; then
  cat <<JSON
{
  "name": "monad-state",
  "projectNumber": "${project_number}",
  "location": "${location}",
  "storageClass": "STANDARD",
  "iamConfiguration": {
    "uniformBucketLevelAccess": {"enabled": true},
    "publicAccessPrevention": "enforced"
  },
  "versioning": {"enabled": true},
  "softDeletePolicy": {"retentionDurationSeconds": "2592000"}
}
JSON
else
  cat <<JSON
{
  "name": "monad-state",
  "projectNumber": "${project_number}",
  "location": "${location}",
  "storageClass": "NEARLINE",
  "iamConfiguration": {
    "uniformBucketLevelAccess": {"enabled": false},
    "publicAccessPrevention": "inherited"
  },
  "versioning": {"enabled": false},
  "softDeletePolicy": {"retentionDurationSeconds": "604800"}
}
JSON
fi
EOF
chmod 0755 "${fake_gcloud}"

export FAKE_BUCKET_MODE_FILE="${bucket_mode_file}"
export FAKE_BUCKET_CREATED_FILE="${bucket_created_file}"
export FAKE_BUCKET_UPDATED_FILE="${bucket_updated_file}"
export FAKE_BUCKET_LOG_FILE="${bucket_log_file}"

reset_bucket_fixture() {
  rm -f \
    "${bucket_created_file}" \
    "${bucket_updated_file}" \
    "${bucket_log_file}"
}

reset_bucket_fixture
printf 'missing\n' >"${bucket_mode_file}"
expect_pass \
  "missing bucket is created and hardened" \
  "${script_dir}/ensure-foundation-state-bucket.sh" \
  monad-state \
  monad-code \
  us-east4 \
  "${fake_gcloud}"
test -f "${bucket_created_file}"
test -f "${bucket_updated_file}"
grep -q -- '--public-access-prevention' "${bucket_log_file}"
grep -q -- '--uniform-bucket-level-access' "${bucket_log_file}"
grep -q -- '--soft-delete-duration=30d' "${bucket_log_file}"

reset_bucket_fixture
printf 'wrong-project\n' >"${bucket_mode_file}"
expect_fail \
  "accessible bucket in another project is rejected before update" \
  "${script_dir}/ensure-foundation-state-bucket.sh" \
  monad-state \
  monad-code \
  us-east4 \
  "${fake_gcloud}"
test ! -f "${bucket_updated_file}"

reset_bucket_fixture
printf 'wrong-location\n' >"${bucket_mode_file}"
expect_fail \
  "bucket in the wrong immutable location is rejected" \
  "${script_dir}/ensure-foundation-state-bucket.sh" \
  monad-state \
  monad-code \
  us-east4 \
  "${fake_gcloud}"
test ! -f "${bucket_updated_file}"

reset_bucket_fixture
printf 'insecure-after-update\n' >"${bucket_mode_file}"
expect_fail \
  "failed bucket hardening is detected after update" \
  "${script_dir}/ensure-foundation-state-bucket.sh" \
  monad-state \
  monad-code \
  us-east4 \
  "${fake_gcloud}"

reset_bucket_fixture
printf 'create-fails\n' >"${bucket_mode_file}"
expect_fail \
  "bucket creation errors are not swallowed" \
  "${script_dir}/ensure-foundation-state-bucket.sh" \
  monad-state \
  monad-code \
  us-east4 \
  "${fake_gcloud}"

override_terraform="${workspace}/terraform-override"
cat >"${override_terraform}" <<'EOF'
#!/usr/bin/env bash
printf '{"terraform_version":"9.9.9"}\n'
EOF
chmod 0755 "${override_terraform}"
expect_fail \
  "Make command line cannot override pinned Terraform version" \
  make -C "${provider_root}" foundation-toolchain-guard \
  TF="${override_terraform}" \
  EXPECTED_TERRAFORM_VERSION=9.9.9

workflow_repo="${workspace}/workflow-repo"
workflow_provider="${workflow_repo}/iac/provider-gcp"
mkdir -p "${workflow_provider}"
cp "${provider_root}/Makefile" "${workflow_provider}/Makefile"
cp -R "${provider_root}/scripts" "${workflow_provider}/scripts"
cp "${repo_root}/.tool-versions" "${workflow_repo}/.tool-versions"
cat >"${workflow_repo}/.env.dev" <<'EOF'
GCP_PROJECT_ID=monad-code
GCP_REGION=us-east4
GCP_ZONE=us-east4-a
DOMAIN_NAME=example.invalid
TERRAFORM_ENVIRONMENT=dev
PREFIX=e2b-
EOF
printf 'dev\n' >"${workflow_repo}/.last_used_env"
cat >"${workflow_provider}/main.tf" <<'EOF'
terraform {
  required_version = "=1.7.5"
}
EOF
mkdir -p "${workflow_provider}/.terraform"
cat >"${workflow_provider}/.terraform/terraform.tfstate" <<'JSON'
{
  "version": 3,
  "backend": {
    "type": "gcs",
    "config": {
      "bucket": "monad-code-terraform-state",
      "prefix": "terraform/orchestration/dev/state"
    }
  }
}
JSON

workflow_terraform="${workspace}/workflow-terraform"
workflow_plan_mode="${workspace}/workflow-plan-mode"
workflow_apply_marker="${workspace}/workflow-apply-marker"
cat >"${workflow_terraform}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  version)
    printf '{"terraform_version":"1.7.5"}\n'
    ;;
  state)
    printf 'No state file was found!\n' >&2
    exit 1
    ;;
  fmt)
    ;;
  plan)
    if [[ "$(cat "${WORKFLOW_PLAN_MODE_FILE}")" == "fail" ]]; then
      printf 'simulated plan failure\n' >&2
      exit 1
    fi
    for argument in "$@"; do
      case "${argument}" in
        -out=*)
          printf 'fresh reviewed plan\n' >"${argument#-out=}"
          ;;
      esac
    done
    ;;
  show)
    cat <<'JSON'
{"resource_changes":[{"address":"module.init.google_project_service.compute_engine_api","mode":"managed","type":"google_project_service","change":{"actions":["create"]}}]}
JSON
    ;;
  apply)
    touch "${WORKFLOW_APPLY_MARKER}"
    ;;
  *)
    printf 'unexpected fake Terraform command: %s\n' "${1:-<none>}" >&2
    exit 2
    ;;
esac
EOF
chmod 0755 "${workflow_terraform}"
export WORKFLOW_PLAN_MODE_FILE="${workflow_plan_mode}"
export WORKFLOW_APPLY_MARKER="${workflow_apply_marker}"

git -C "${workflow_repo}" init -q
git -C "${workflow_repo}" config user.name "Foundation Guard Test"
git -C "${workflow_repo}" config user.email "foundation-guard@example.invalid"
git -C "${workflow_repo}" add -A
git -C "${workflow_repo}" commit -qm "fixture"

stale_plan="${workflow_provider}/.tfplan.foundation.dev"
stale_manifest="${stale_plan}.manifest"
printf 'stale plan\n' >"${stale_plan}"
printf '{}\n' >"${stale_manifest}"
chmod 0600 "${stale_plan}" "${stale_manifest}"
printf 'fail\n' >"${workflow_plan_mode}"
expect_fail \
  "failed replan removes stale plan and provenance" \
  make -C "${workflow_provider}" foundation-plan \
  TF="${workflow_terraform}"
test ! -e "${stale_plan}"
test ! -e "${stale_manifest}"

printf 'success\n' >"${workflow_plan_mode}"
expect_pass \
  "successful plan atomically publishes plan and provenance" \
  make -C "${workflow_provider}" foundation-plan \
  TF="${workflow_terraform}"
test -f "${stale_plan}"
test -f "${stale_manifest}"

printf '\n# changed after review\n' >>"${workflow_provider}/main.tf"
expect_fail \
  "apply rejects source drift before Terraform apply" \
  make -C "${workflow_provider}" foundation-apply \
  TF="${workflow_terraform}" \
  CONFIRM='APPLY KEYLESS FOUNDATION'
test ! -e "${workflow_apply_marker}"

cat >"${workflow_provider}/main.tf" <<'EOF'
terraform {
  required_version = "=1.7.5"
}
EOF
expect_pass \
  "unchanged reviewed plan reaches Terraform apply" \
  make -C "${workflow_provider}" foundation-apply \
  TF="${workflow_terraform}" \
  CONFIRM='APPLY KEYLESS FOUNDATION'
test -f "${workflow_apply_marker}"
test ! -e "${stale_plan}"
test ! -e "${stale_manifest}"

printf 'Foundation workflow fixtures passed.\n'
