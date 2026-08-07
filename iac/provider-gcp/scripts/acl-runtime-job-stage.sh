#!/usr/bin/env bash
set -euo pipefail

mode="${1:?usage: acl-runtime-job-stage.sh plan|apply}"
case "${mode}" in
  plan | apply) ;;
  *)
    printf 'Unknown ACL runtime-job operation: %s\n' "${mode}" >&2
    exit 2
    ;;
esac

phase="${ACL_RUNTIME_JOB_PHASE:?ACL_RUNTIME_JOB_PHASE is required}"
environment="${ACL_RUNTIME_JOB_ENV:?ACL_RUNTIME_JOB_ENV is required}"
environment_file="${ACL_RUNTIME_JOB_ENV_FILE:?ACL_RUNTIME_JOB_ENV_FILE is required}"
tf_var_file="${ACL_RUNTIME_JOB_TF_VAR_FILE:?ACL_RUNTIME_JOB_TF_VAR_FILE is required}"
plan_path="${ACL_RUNTIME_JOB_PLAN:?ACL_RUNTIME_JOB_PLAN is required}"
manifest_path="${ACL_RUNTIME_JOB_PLAN_MANIFEST:?ACL_RUNTIME_JOB_PLAN_MANIFEST is required}"
completion_evidence="${ACL_RUNTIME_JOB_COMPLETION_EVIDENCE:?ACL_RUNTIME_JOB_COMPLETION_EVIDENCE is required}"
checkpoint="${ACL_RUNTIME_JOB_CHECKPOINT:?ACL_RUNTIME_JOB_CHECKPOINT is required}"
terraform_bin="${ACL_RUNTIME_JOB_TERRAFORM_BIN:?ACL_RUNTIME_JOB_TERRAFORM_BIN is required}"
gcloud_bin="${ACL_RUNTIME_JOB_GCLOUD_BIN:?ACL_RUNTIME_JOB_GCLOUD_BIN is required}"
project_id="${ACL_RUNTIME_JOB_GCP_PROJECT_ID:?ACL_RUNTIME_JOB_GCP_PROJECT_ID is required}"
region="${ACL_RUNTIME_JOB_GCP_REGION:?ACL_RUNTIME_JOB_GCP_REGION is required}"
zone="${ACL_RUNTIME_JOB_GCP_ZONE:?ACL_RUNTIME_JOB_GCP_ZONE is required}"
prefix="${ACL_RUNTIME_JOB_PREFIX:?ACL_RUNTIME_JOB_PREFIX is required}"
state_bucket="${ACL_RUNTIME_JOB_STATE_BUCKET:?ACL_RUNTIME_JOB_STATE_BUCKET is required}"
state_prefix="${ACL_RUNTIME_JOB_STATE_PREFIX:?ACL_RUNTIME_JOB_STATE_PREFIX is required}"
core_image_revision="${ACL_RUNTIME_JOB_CORE_IMAGE_REVISION:?ACL_RUNTIME_JOB_CORE_IMAGE_REVISION is required}"
job_binary_bucket="${ACL_RUNTIME_JOB_BINARY_BUCKET:?ACL_RUNTIME_JOB_BINARY_BUCKET is required}"
topology_policy="${ACL_RUNTIME_JOB_TOPOLOGY_POLICY:?ACL_RUNTIME_JOB_TOPOLOGY_POLICY is required}"
packer_template="${ACL_RUNTIME_JOB_PACKER_TEMPLATE:?ACL_RUNTIME_JOB_PACKER_TEMPLATE is required}"
repo_root="${ACL_RUNTIME_JOB_REPO_ROOT:?ACL_RUNTIME_JOB_REPO_ROOT is required}"
recovery_token="${ACL_RUNTIME_JOB_RECOVERY_TOKEN:-}"
domain_name="${ACL_RUNTIME_JOB_DOMAIN_NAME:-}"
nomad_token_secret_version="${ACL_RUNTIME_JOB_NOMAD_TOKEN_SECRET_VERSION:-}"
curl_bin="${ACL_RUNTIME_JOB_CURL_BIN:-$(command -v curl || true)}"

case "${phase}" in
  pre-server) stage=network; descendant_policy=observe ;;
  post-api) stage=api; descendant_policy=quiesce ;;
  *)
    printf 'ACL_RUNTIME_JOB_PHASE must be pre-server or post-api.\n' >&2
    exit 2
    ;;
esac

[[ "${environment}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
[[ "${project_id}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "${region}" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]
[[ "${zone}" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]]
[[ "${prefix}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?-$ ]]
[[ ! -L "${completion_evidence}" ]]
for required_file in \
  "${environment_file}" \
  "${tf_var_file}" \
  "${checkpoint}" \
  "${topology_policy}" \
  "${packer_template}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" ]] || {
    printf 'ACL runtime-job input must be a regular non-symlink file: %s\n' \
      "${required_file}" >&2
    exit 1
  }
done

jq -e --arg stage "${stage}" '.stage == $stage' "${checkpoint}" >/dev/null || {
  printf 'ACL runtime-job checkpoint does not match required stage %s.\n' \
    "${stage}" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider_root="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${repo_root}" && pwd -P)"
lease_script="${script_dir}/rollout-mutation-lease.sh"
metadata_script="${script_dir}/workload-plan-metadata.sh"
assertion_script="${script_dir}/assert-acl-runtime-job-plan.sh"
artifacts_script="${script_dir}/assert-workload-artifacts.sh"
checkpoint_script="${script_dir}/assert-network-hardening-checkpoint.sh"
job_gate_script="${script_dir}/nomad-runtime-job-gate.sh"

targets=(
  -target=module.cluster.terraform_data.acl_bootstrap_environment_guard
  -target=module.cluster.terraform_data.network_hardening_rollout_completion_network
  -target=module.cluster.terraform_data.network_hardening_rollout_stage_network
)
if [[ "${phase}" == pre-server ]]; then
  targets+=(
    -target=module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server
  )
else
  targets+=(
    -target='module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]'
    -target='module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]'
    -target='module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]'
    -target='module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]'
    -target='module.cluster.terraform_data.consul_management_handoff_candidate[0]'
    -target='module.cluster.terraform_data.network_hardening_rollout_completion_server_health[0]'
    -target='module.cluster.terraform_data.network_hardening_rollout_stage_server_health[0]'
    -target='module.cluster.terraform_data.network_hardening_rollout_completion_api[0]'
    -target='module.cluster.terraform_data.network_hardening_rollout_stage_api[0]'
    -target=module.nomad
  )
fi

export WORKLOAD_ENV="${environment}"
export WORKLOAD_ENV_FILE="${environment_file}"
export WORKLOAD_TF_VAR_FILE="${tf_var_file}"
export WORKLOAD_GCP_PROJECT_ID="${project_id}"
export WORKLOAD_GCP_REGION="${region}"
export WORKLOAD_GCP_ZONE="${zone}"
export WORKLOAD_PREFIX="${prefix}"
export WORKLOAD_CORE_IMAGE_REVISION="${core_image_revision}"
export WORKLOAD_JOB_BINARY_BUCKET="${job_binary_bucket}"
export WORKLOAD_STATE_BUCKET="${state_bucket}"
export WORKLOAD_STATE_PREFIX="${state_prefix}"
export WORKLOAD_TOPOLOGY_POLICY="${topology_policy}"
export WORKLOAD_PACKER_TEMPLATE="${packer_template}"
export WORKLOAD_CLUSTER_STAGE="${stage}"
export WORKLOAD_CLUSTER_CHECKPOINT="${checkpoint}"
unset CONSUL_HTTP_TOKEN

artifact_snapshot() {
  "${artifacts_script}" \
    "${project_id}" "${region}" "${prefix}" \
    "${core_image_revision}" "${job_binary_bucket}" "${gcloud_bin}"
}

terraform_plan() {
  local output_path="$1"
  shift
  local var_file_args=()
  [[ -f "${tf_var_file}" ]] && var_file_args=(-var-file="${tf_var_file}")
  "${terraform_bin}" -chdir="${provider_root}" plan \
    "${var_file_args[@]}" \
    "${targets[@]}" \
    -out="${output_path}" \
    -input=false \
    -compact-warnings \
    "$@"
}

write_job_projection() {
  local plan="$1"
  local destination="$2"
  local plan_json="$3"
  local include_modify_index="$4"
  local inventory_destination="$5"
  local inventory_source_mode="${6:-auto}"
  local raw_projection="${plan_json}.projection-raw"
  local rows="${plan_json}.projection-rows"
  local jobspec_file="${plan_json}.jobspec"
  local inventory_raw_projection="${plan_json}.inventory-projection-raw"
  local inventory_rows="${plan_json}.inventory-projection-rows"
  local row
  local jobspec_sha256

  [[ "${include_modify_index}" == true \
    || "${include_modify_index}" == false ]]
  [[ "${inventory_source_mode}" == auto \
    || "${inventory_source_mode}" == before \
    || "${inventory_source_mode}" == after ]]

  "${terraform_bin}" show -json "${plan}" >"${plan_json}"
  chmod 0600 "${plan_json}"
  jq -eS --argjson include_modify_index "${include_modify_index}" \
    --arg inventory_source_mode "${inventory_source_mode}" '
    [
      .resource_changes[]?
      | select(
          .mode == "managed"
          and .type == "nomad_job"
          and (.address | startswith("module.nomad."))
        )
      | .change as $change
      | (
          if $inventory_source_mode == "after" or $include_modify_index
          then $change.after.jobspec
          elif $inventory_source_mode == "before"
            and ($change.before | type) == "object"
            and ($change.before.jobspec | type) == "string"
          then $change.before.jobspec
          elif ($change.before | type) == "object"
            and ($change.before.jobspec | type) == "string"
          then $change.before.jobspec
          else $change.after.jobspec
          end
        ) as $jobspec
      | {
          address,
          job_id:($jobspec
            | capture("(?m)^[[:space:]]*job[[:space:]]+\\\"(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)\\\"").id),
          job_type:(
            try ($jobspec
              | capture("(?m)^[[:space:]]*type[[:space:]]*=[[:space:]]*\\\"(?<type>service|system|batch)\\\"").type)
            catch "service"
          ),
          expected_modify_index:(
            if $include_modify_index
            then (
              .change.after.modify_index
              | select(type == "string" and test("^[1-9][0-9]*$"))
              | tonumber
            )
            else null
            end
          ),
          jobspec:$jobspec
        }
      | .normalized_address = (.address | sub("\\[0\\]$"; ""))
      | .inventory_class = (
          if .job_type == "service" or .job_type == "system" then
            "managed-runtime"
          elif (
            [.normalized_address,.job_id] | @tsv
          ) as $pair
          | [
              "module.nomad.module.clickhouse.nomad_job.clickhouse_backup\tclickhouse-backup",
              "module.nomad.module.clickhouse.nomad_job.clickhouse_backup_restore\tclickhouse-backup-restore",
              "module.nomad.module.clickhouse.nomad_job.clickhouse_migrator\tclickhouse-migrator",
              "module.nomad.nomad_job.clean_nfs_cache\tfilestore-cleanup"
            ] | index($pair) != null
          then "token-free-batch"
          else error("unreviewed Nomad batch job in ACL inventory")
          end
        )
      | .child_mode = (
          if .job_type != "batch" then "none"
          elif (.jobspec | test("(?m)^[[:space:]]*periodic[[:space:]]*\\{"))
          then "periodic"
          elif (.jobspec | test("(?m)^[[:space:]]*parameterized[[:space:]]*\\{"))
          then "parameterized"
          else "none"
          end
        )
      | select(
          .inventory_class != "token-free-batch"
          or (
            (.jobspec | test("(?i)(CONSUL_HTTP_TOKEN|X-Consul-Token|consul[_-]token|consul-secret-id)") | not)
            and (.jobspec | contains("monad_acl_handoff_revision") | not)
          )
        )
      | del(.normalized_address)
    ]
    | sort_by(.address)
    | select(length > 0)
    | select(([.[].address] | unique | length) == length)
    | select(([.[].job_id] | unique | length) == length)
    | select(all(.[].expected_modify_index;
        if $include_modify_index
        then (type == "number" and . > 0)
        else . == null
        end
      ))
  ' "${plan_json}" >"${inventory_raw_projection}"
  : >"${inventory_rows}"
  while IFS= read -r row; do
    jq -jr '.jobspec' <<<"${row}" >"${jobspec_file}"
    jobspec_sha256="$(shasum -a 256 "${jobspec_file}" | awk '{print $1}')"
    jq -cS --arg submission_source_sha256 "${jobspec_sha256}" \
      'del(.jobspec) | .submission_source_sha256 = $submission_source_sha256' \
      <<<"${row}" >>"${inventory_rows}"
  done < <(jq -c '.[]' "${inventory_raw_projection}")
  jq -eS --argjson include_modify_index "${include_modify_index}" '
    sort_by(.address)
    | select(length > 0)
    | select(all(.[];
        (.submission_source_sha256 | test("^[0-9a-f]{64}$"))
        and (
          if $include_modify_index
          then (.expected_modify_index | type) == "number"
            and .expected_modify_index > 0
          else .expected_modify_index == null
          end
        )
      ))
  ' --slurp "${inventory_rows}" >"${inventory_destination}"
  chmod 0600 "${inventory_destination}"
  jq -eS --argjson include_modify_index "${include_modify_index}" '
    [
      .resource_changes[]?
      | select(
          .mode == "managed"
          and .type == "nomad_job"
          and (.address | startswith("module.nomad."))
        )
      | {
          address,
          jobspec:.change.after.jobspec,
          expected_modify_index:(
            if $include_modify_index
            then (
              .change.after.modify_index
              | select(type == "string" and test("^[1-9][0-9]*$"))
              | tonumber
            )
            else null
            end
          )
        }
    ]
    | sort_by(.address)
    | select(length > 0)
    | select(all(.[];
        if (.jobspec
          | test("(?m)^[[:space:]]*type[[:space:]]*=[[:space:]]*\"batch\""))
        then (.jobspec | contains("monad_acl_handoff_revision") | not)
        else (.jobspec | contains("monad_acl_handoff_revision = \"1\""))
        end
      ))
    | map(select(
        .jobspec
        | test("(?m)^[[:space:]]*type[[:space:]]*=[[:space:]]*\"batch\"")
        | not
      ))
    | select(length > 0)
    | map(
        .jobspec as $jobspec
        | {
            address,
            jobspec:$jobspec,
            expected_modify_index,
            job_id:($jobspec
              | capture("(?m)^[[:space:]]*job[[:space:]]+\"(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)\"").id),
            job_type:(
              try ($jobspec
                | capture("(?m)^[[:space:]]*type[[:space:]]*=[[:space:]]*\"(?<type>service|system)\"").type)
              catch "service"
            ),
            requires_exclusive_transition:(
              .address == "module.nomad.module.orchestrator[0].nomad_job.orchestrator"
              or .address == "module.nomad.module.template_manager.nomad_job.template_manager"
            )
          }
      )
    | select(all(.[];
        (.job_id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and (.job_type == "service" or .job_type == "system")
        and (.jobspec | type) == "string"
        and (
          if $include_modify_index
          then (.expected_modify_index | type) == "number"
            and .expected_modify_index > 0
          else .expected_modify_index == null
          end
        )
      ))
  ' "${plan_json}" >"${raw_projection}"
  : >"${rows}"
  while IFS= read -r row; do
    jq -jr '.jobspec' <<<"${row}" >"${jobspec_file}"
    jobspec_sha256="$(shasum -a 256 "${jobspec_file}" | awk '{print $1}')"
    jq -cS --arg jobspec_sha256 "${jobspec_sha256}" \
      'del(.jobspec) | .jobspec_sha256 = $jobspec_sha256' \
      <<<"${row}" >>"${rows}"
  done < <(jq -c '.[]' "${raw_projection}")
  jq -eS --argjson include_modify_index "${include_modify_index}" '
    sort_by(.address)
    | select(length > 0)
    | select(all(.[];
        (.jobspec_sha256 | test("^[0-9a-f]{64}$"))
        and (
          if $include_modify_index
          then (.expected_modify_index | type) == "number"
            and .expected_modify_index > 0
          else .expected_modify_index == null
          end
        )
      ))
  ' --slurp "${rows}" >"${destination}"
  chmod 0600 "${destination}"
  rm -f -- "${raw_projection}" "${rows}" "${jobspec_file}" \
    "${inventory_raw_projection}" "${inventory_rows}"
}

write_state_job_inventory() {
  local destination="$1"
  local include_modify_index="$2"
  local raw_projection="${destination}.raw"
  local rows="${destination}.rows"
  local jobspec_file="${destination}.jobspec"
  local row
  local jobspec_sha256

  [[ "${include_modify_index}" == true \
    || "${include_modify_index}" == false ]]
  # Stream state through a strict projection: the full state may contain
  # secrets and is never materialized on disk.
  "${terraform_bin}" -chdir="${provider_root}" show -json \
    | jq -eS --argjson include_modify_index "${include_modify_index}" '
        [
          .values.root_module
          | recurse(.child_modules[]?)
          | .resources[]?
          | select(
              .mode == "managed"
              and .type == "nomad_job"
              and (.address | startswith("module.nomad."))
              and (.values.jobspec | type) == "string"
            )
          | .values.jobspec as $jobspec
          | {
              address,
              job_id:($jobspec
                | capture("(?m)^[[:space:]]*job[[:space:]]+\\\"(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)\\\"").id),
              job_type:(
                try ($jobspec
                  | capture("(?m)^[[:space:]]*type[[:space:]]*=[[:space:]]*\\\"(?<type>service|system|batch)\\\"").type)
                catch "service"
              ),
              expected_modify_index:(
                if $include_modify_index
                then (.values.modify_index | tostring
                  | select(test("^[1-9][0-9]*$")) | tonumber)
                else null
                end
              ),
              jobspec:$jobspec
            }
          | .normalized_address = (.address | sub("\\[0\\]$"; ""))
          | .inventory_class = (
              if .job_type == "service" or .job_type == "system" then
                "managed-runtime"
              elif ([.normalized_address,.job_id] | @tsv) as $pair
                | [
                    "module.nomad.module.clickhouse.nomad_job.clickhouse_backup\tclickhouse-backup",
                    "module.nomad.module.clickhouse.nomad_job.clickhouse_backup_restore\tclickhouse-backup-restore",
                    "module.nomad.module.clickhouse.nomad_job.clickhouse_migrator\tclickhouse-migrator",
                    "module.nomad.nomad_job.clean_nfs_cache\tfilestore-cleanup"
                  ] | index($pair) != null
              then "token-free-batch"
              else error("unreviewed Nomad batch job in Terraform state inventory")
              end
            )
          | .child_mode = (
              if .job_type != "batch" then "none"
              elif (.jobspec | test("(?m)^[[:space:]]*periodic[[:space:]]*\\{"))
              then "periodic"
              elif (.jobspec | test("(?m)^[[:space:]]*parameterized[[:space:]]*\\{"))
              then "parameterized"
              else "none"
              end
            )
          | select(
              .inventory_class != "token-free-batch"
              or (
                (.jobspec | test("(?i)(CONSUL_HTTP_TOKEN|X-Consul-Token|consul[_-]token|consul-secret-id)") | not)
                and (.jobspec | contains("monad_acl_handoff_revision") | not)
              )
            )
          | del(.normalized_address)
        ]
        | sort_by(.address)
        | select(length > 0)
        | select(([.[].address] | unique | length) == length)
        | select(([.[].job_id] | unique | length) == length)
      ' >"${raw_projection}"
  : >"${rows}"
  while IFS= read -r row; do
    jq -jr '.jobspec' <<<"${row}" >"${jobspec_file}"
    jobspec_sha256="$(shasum -a 256 "${jobspec_file}" | awk '{print $1}')"
    jq -cS --arg submission_source_sha256 "${jobspec_sha256}" \
      'del(.jobspec) | .submission_source_sha256 = $submission_source_sha256' \
      <<<"${row}" >>"${rows}"
  done < <(jq -c '.[]' "${raw_projection}")
  jq -eS --argjson include_modify_index "${include_modify_index}" '
    sort_by(.address)
    | select(length > 0)
    | select(all(.[].expected_modify_index;
        if $include_modify_index
        then (type == "number" and . > 0)
        else . == null
        end))
  ' --slurp "${rows}" >"${destination}"
  chmod 0600 "${destination}"
  rm -f -- "${raw_projection}" "${rows}" "${jobspec_file}"
}

source_head="$(git -C "${repo_root}" rev-parse --verify HEAD)"
holder_digest="$({
  printf '%s\n' "${source_head}" "${environment}" "${phase}" "${stage}"
  shasum -a 256 "${checkpoint}"
  printf '%s\n' "$$" "$(date -u +%s)"
} | shasum -a 256 | awk '{print $1}')"

if [[ "${mode}" == plan ]]; then
  temp_dir="$(mktemp -d "${provider_root}/.workload-plan.acl-runtime.${environment}.XXXXXX")"
  temp_plan="${temp_dir}/plan"
  temp_manifest="${temp_dir}/manifest"
  before_artifacts="${temp_dir}/artifacts-before.json"
  after_artifacts="${temp_dir}/artifacts-after.json"
  lease_token="${temp_dir}/lease-token.json"
  lease_acquired=false

  cleanup_plan() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ "${lease_acquired}" == true ]]; then
      if ! "${lease_script}" release "${gcloud_bin}" "${lease_token}"; then
        printf 'Shared rollout lease release failed; inspect before another mutation.\n' >&2
        status=1
      fi
    fi
    rm -rf -- "${temp_dir}"
    exit "${status}"
  }
  trap cleanup_plan EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  umask 077
  "${lease_script}" acquire "${gcloud_bin}" "${state_bucket}" \
    "${project_id}" "${region}" "acl-job-plan:${phase}:${holder_digest}" \
    "${lease_token}"
  lease_acquired=true
  artifact_snapshot >"${before_artifacts}"
  before_fingerprint="$(${metadata_script} fingerprint \
    "${terraform_bin}" "${provider_root}" "${repo_root}" "${before_artifacts}")"
  "${lease_script}" assert-held "${gcloud_bin}" "${state_bucket}" \
    "${project_id}" "${region}" "${lease_token}"
  terraform_plan "${temp_plan}"
  chmod 0600 "${temp_plan}"
  artifact_snapshot >"${after_artifacts}"
  after_fingerprint="$(${metadata_script} fingerprint \
    "${terraform_bin}" "${provider_root}" "${repo_root}" "${after_artifacts}")"
  [[ "${before_fingerprint}" == "${after_fingerprint}" ]] || {
    printf 'ACL runtime-job inputs changed while Terraform was planning.\n' >&2
    exit 1
  }
  "${assertion_script}" "${temp_plan}" "${terraform_bin}" "${phase}" \
    "${project_id}" "${zone}" "${prefix}"
  "${metadata_script}" write "${temp_plan}" "${temp_manifest}" \
    "${terraform_bin}" "${provider_root}" "${repo_root}" \
    "${after_artifacts}" "${after_fingerprint}"
  rm -f -- "${plan_path}" "${manifest_path}" "${manifest_path}.recovery.json"
  mv "${temp_manifest}" "${manifest_path}"
  mv "${temp_plan}" "${plan_path}"
  "${lease_script}" release "${gcloud_bin}" "${lease_token}"
  lease_acquired=false
  rm -rf -- "${temp_dir}"
  trap - EXIT HUP INT TERM
  printf 'Saved ACL %s runtime-job plan: %s\n' "${phase}" "${plan_path}"
  exit 0
fi

temp_dir="$(mktemp -d "${provider_root}/.workload-apply.acl-runtime.${environment}.XXXXXX")"
apply_plan="${temp_dir}/reviewed.plan"
apply_manifest="${temp_dir}/reviewed.plan.manifest"
artifacts="${temp_dir}/artifacts.json"
post_plan="${temp_dir}/post-apply.plan"
post_plan_json="${temp_dir}/post-apply.json"
job_projection="${temp_dir}/jobs.json"
job_inventory_projection="${temp_dir}/job-inventory.json"
desired_job_inventory_projection="${temp_dir}/desired-job-inventory.json"
transition_job_inventory_projection="${temp_dir}/transition-job-inventory.json"
reviewed_plan_json="${temp_dir}/reviewed-plan.json"
post_job_projection="${temp_dir}/post-jobs.json"
post_job_inventory_projection="${temp_dir}/post-job-inventory.json"
transition_evidence="${temp_dir}/exclusive-transition.json"
live_convergence_evidence="${temp_dir}/live-nomad-convergence.json"
evidence_tmp="${temp_dir}/completion-evidence.json"
lease_token="${temp_dir}/lease-token.json"
lease_acquired=false
lease_borrowed=false
mutation_started=false
convergence_proven=false
convergence_only=false
reviewed_plan_current=false
recovery_source_dir=""
resume_recovery_apply=false
recovery_review_path="${manifest_path}.recovery.json"

cleanup_apply() {
  local status=$?
  local preserve=false
  trap - EXIT HUP INT TERM
  if [[ "${lease_acquired}" == true ]]; then
    if [[ "${mutation_started}" == true && "${convergence_proven}" == false ]]; then
      if [[ "${lease_borrowed}" == true ]]; then
        printf 'ACL recovery remains unconverged; preserving the held lease and original recovery authority at %s.\n' \
          "${recovery_source_dir}" >&2
      else
        printf 'ACL job mutation started without proven convergence; preserving lease and recovery data at %s.\n' \
          "${temp_dir}" >&2
        preserve=true
      fi
      status=1
    elif [[ "${lease_borrowed}" == true && "${mutation_started}" == false ]]; then
      printf 'Borrowed recovery lease remains held; the original generation-bound token remains the recovery authority.\n' >&2
    elif ! "${lease_script}" release "${gcloud_bin}" "${lease_token}"; then
      printf 'Shared rollout lease release failed; preserving recovery data at %s.\n' \
        "${temp_dir}" >&2
      preserve=true
      status=1
    fi
  fi
  [[ "${preserve}" == true ]] || rm -rf -- "${temp_dir}"
  exit "${status}"
}

write_state_identity() {
  local destination="$1"
  local identity_tmp="${destination}.tmp"

  # Never materialize the full Terraform state. It contains credentials and
  # other sensitive values that must not survive a crash in recovery data.
  "${terraform_bin}" -chdir="${provider_root}" state pull \
    | jq -eS '
        {
          lineage:(.lineage | select(type == "string" and length > 0)),
          serial:(.serial | select(type == "number" and . >= 0))
        }
      ' >"${identity_tmp}"
  chmod 0600 "${identity_tmp}"
  mv -f -- "${identity_tmp}" "${destination}"
  chmod 0600 "${destination}"
}

assert_recovery_recreates_transition() {
  local plan="$1"
  local transition="$2"
  local plan_json="${temp_dir}/recovery-recreation-plan.json"
  local expected_jobs="${temp_dir}/recovery-recreation-expected.json"
  local created_jobs="${temp_dir}/recovery-recreation-created.json"

  "${terraform_bin}" show -json "${plan}" >"${plan_json}"
  chmod 0600 "${plan_json}"
  jq -eS '[
      .descendant_quiescence.descendant_capable_parent_ids[]?,
      (.actions[]?
        | select(.action == "purged_before_first_locking_rollout")
        | .job_id)
    ] | unique | select(length > 0)' \
    "${transition}" >"${expected_jobs}"
  jq -eS '[
      .resource_changes[]?
      | select(
          .mode == "managed"
          and .type == "nomad_job"
          and (.address | startswith("module.nomad."))
          and (.change.actions | index("create") != null)
        )
      | .change.after.jobspec
      | capture("(?m)^[[:space:]]*job[[:space:]]+\\\"(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)\\\"").id
    ] | unique' "${plan_json}" >"${created_jobs}"
  jq -e --slurpfile created "${created_jobs}" '
    all(.[]; . as $job_id | $created[0] | index($job_id) != null)
  ' "${expected_jobs}" >/dev/null || {
    printf 'Fresh recovery plan does not recreate every quiesced or purged Nomad parent.\n' >&2
    return 1
  }
}

run_nomad_gate() {
  local gate_mode="$1"
  local gate_projection="$2"
  local gate_inventory_projection="$3"
  local gate_evidence="$4"
  local gate_transition="${5:-}"
  local gate_transition_inventory="${6:-}"
  local nomad_token_fd=9
  local status

  # Secret Manager writes into an anonymous pipe. The management token is
  # consumed into gate memory and is never placed in a recovery directory,
  # filesystem artifact, command argument, or environment variable.
  exec 9< <(
    env \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
      -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
      "${gcloud_bin}" secrets versions access "${nomad_token_version}" \
        --secret="${nomad_secret}" --project="${project_id}"
  )
  set +e
  NOMAD_JOB_GATE_PROJECTION="${gate_projection}" \
    NOMAD_JOB_GATE_INVENTORY_PROJECTION="${gate_inventory_projection}" \
    NOMAD_JOB_GATE_TOKEN_FD="${nomad_token_fd}" \
    NOMAD_JOB_GATE_BASE_URL="https://nomad.${domain_name}" \
    NOMAD_JOB_GATE_EVIDENCE="${gate_evidence}" \
    NOMAD_JOB_GATE_TRANSITION_EVIDENCE="${gate_transition}" \
    NOMAD_JOB_GATE_TRANSITION_INVENTORY_PROJECTION="${gate_transition_inventory}" \
    NOMAD_JOB_GATE_DESCENDANT_POLICY="${descendant_policy}" \
    NOMAD_JOB_GATE_CURL_BIN="${curl_bin}" \
    "${job_gate_script}" "${gate_mode}"
  status=$?
  set -e
  exec 9<&-
  return "${status}"
}

load_recovery_transition_inventory() {
  local recovery_inventory="${recovery_source_dir}/job-inventory.json"
  local expected_sha
  local actual_sha

  [[ -f "${recovery_inventory}" && ! -L "${recovery_inventory}" ]] || {
    printf 'Recovery is missing the original pre-apply Nomad inventory projection.\n' >&2
    return 1
  }
  expected_sha="$(jq -er '
    .inventory_projection_sha256
    | select(type == "string" and test("^[0-9a-f]{64}$"))
  ' "${recovery_transition}")"
  actual_sha="$(shasum -a 256 "${recovery_inventory}" | awk '{print $1}')"
  [[ "${actual_sha}" == "${expected_sha}" ]] || {
    printf 'Recovery pre-apply Nomad inventory no longer matches the original transition.\n' >&2
    return 1
  }
  cp "${recovery_inventory}" "${transition_job_inventory_projection}"
  chmod 0600 "${transition_job_inventory_projection}"
}

create_current_recovery_probe() {
  local before_artifacts="${temp_dir}/recovery-artifacts-before.json"
  local after_artifacts="${temp_dir}/recovery-artifacts-after.json"

  recovery_probe_plan="${temp_dir}/recovery-probe.plan"
  recovery_probe_manifest="${temp_dir}/recovery-probe.plan.manifest"
  recovery_probe_state="${temp_dir}/recovery-probe.state.json"
  artifact_snapshot >"${before_artifacts}"
  recovery_before_fingerprint="$(${metadata_script} fingerprint \
    "${terraform_bin}" "${provider_root}" "${repo_root}" \
    "${before_artifacts}")"
  "${lease_script}" assert-held "${gcloud_bin}" "${state_bucket}" \
    "${project_id}" "${region}" "${lease_token}"
  set +e
  terraform_plan "${recovery_probe_plan}" -detailed-exitcode >/dev/null
  recovery_plan_status=$?
  set -e
  [[ "${recovery_plan_status}" -eq 0 \
    || "${recovery_plan_status}" -eq 2 ]] || {
    printf 'Could not create a fresh ACL runtime-job recovery plan (Terraform exit %s).\n' \
      "${recovery_plan_status}" >&2
    return 1
  }
  chmod 0600 "${recovery_probe_plan}"
  artifact_snapshot >"${after_artifacts}"
  recovery_after_fingerprint="$(${metadata_script} fingerprint \
    "${terraform_bin}" "${provider_root}" "${repo_root}" \
    "${after_artifacts}")"
  [[ "${recovery_before_fingerprint}" == "${recovery_after_fingerprint}" ]] || {
    printf 'ACL runtime-job recovery inputs changed while Terraform was planning.\n' >&2
    return 1
  }
  "${assertion_script}" "${recovery_probe_plan}" "${terraform_bin}" \
    "${phase}" "${project_id}" "${zone}" "${prefix}"
  "${metadata_script}" write "${recovery_probe_plan}" \
    "${recovery_probe_manifest}" "${terraform_bin}" "${provider_root}" \
    "${repo_root}" "${after_artifacts}" "${recovery_after_fingerprint}"
  write_state_identity "${recovery_probe_state}"
}

write_recovery_review() {
  local reviewed_plan="$1"
  local reviewed_manifest="$2"
  local state_identity="$3"
  local transition="$4"
  local authority_token="$5"
  local journal_tmp="${temp_dir}/recovery-review.json"

  [[ -f "${transition}" && ! -L "${transition}" ]]
  [[ -f "${authority_token}" && ! -L "${authority_token}" ]]
  jq -nS \
    --arg source_sha "${source_head}" \
    --arg environment "${environment}" \
    --arg phase "${phase}" \
    --arg stage "${stage}" \
    --arg plan_sha256 "$(shasum -a 256 "${reviewed_plan}" | awk '{print $1}')" \
    --arg manifest_sha256 "$(shasum -a 256 "${reviewed_manifest}" | awk '{print $1}')" \
    --arg transition_sha256 "$(shasum -a 256 "${transition}" | awk '{print $1}')" \
    --arg recovery_token_sha256 "$(shasum -a 256 "${authority_token}" | awk '{print $1}')" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile state "${state_identity}" '
      {
        schema_version:1,
        source_sha:$source_sha,
        environment:$environment,
        phase:$phase,
        stage:$stage,
        plan_sha256:$plan_sha256,
        manifest_sha256:$manifest_sha256,
        transition_sha256:$transition_sha256,
        recovery_token_sha256:$recovery_token_sha256,
        state:$state[0],
        created_at:$created_at
      }
    ' >"${journal_tmp}"
  chmod 0600 "${journal_tmp}"
  rm -f -- "${plan_path}" "${manifest_path}" "${recovery_review_path}"
  mv "${reviewed_manifest}" "${manifest_path}"
  mv "${reviewed_plan}" "${plan_path}"
  mv "${journal_tmp}" "${recovery_review_path}"
  chmod 0600 "${plan_path}" "${manifest_path}" "${recovery_review_path}"
}

recovery_review_matches_current_state() {
  local transition="$1"
  local authority_token="$2"
  local current_state="$3"
  local recorded_state="${temp_dir}/recorded-recovery-state.json"
  local fresh_json="${temp_dir}/fresh-recovery-plan.json"
  local reviewed_json="${temp_dir}/reviewed-recovery-plan.json"
  local fresh_changes="${temp_dir}/fresh-recovery-changes.json"
  local reviewed_changes="${temp_dir}/reviewed-recovery-changes.json"

  [[ -f "${plan_path}" && ! -L "${plan_path}" \
    && -f "${manifest_path}" && ! -L "${manifest_path}" \
    && -f "${recovery_review_path}" && ! -L "${recovery_review_path}" ]] \
    || return 1
  [[ "$(stat -c '%a' "${recovery_review_path}" 2>/dev/null \
    || stat -f '%Lp' "${recovery_review_path}")" == 600 ]] || return 1
  jq -e \
    --arg source_sha "${source_head}" \
    --arg environment "${environment}" \
    --arg phase "${phase}" \
    --arg stage "${stage}" \
    --arg plan_sha256 "$(shasum -a 256 "${plan_path}" | awk '{print $1}')" \
    --arg manifest_sha256 "$(shasum -a 256 "${manifest_path}" | awk '{print $1}')" \
    --arg transition_sha256 "$(shasum -a 256 "${transition}" | awk '{print $1}')" \
    --arg recovery_token_sha256 "$(shasum -a 256 "${authority_token}" | awk '{print $1}')" '
      .schema_version == 1
      and .source_sha == $source_sha
      and .environment == $environment
      and .phase == $phase
      and .stage == $stage
      and .plan_sha256 == $plan_sha256
      and .manifest_sha256 == $manifest_sha256
      and .transition_sha256 == $transition_sha256
      and .recovery_token_sha256 == $recovery_token_sha256
      and (.state.lineage | type) == "string"
      and (.state.serial | type) == "number"
    ' "${recovery_review_path}" >/dev/null || return 1
  jq -eS '.state' "${recovery_review_path}" >"${recorded_state}" || return 1
  cmp -s "${recorded_state}" "${current_state}" || return 1
  "${metadata_script}" verify "${plan_path}" "${manifest_path}" \
    "${terraform_bin}" "${provider_root}" "${repo_root}" "${artifacts}" \
    >/dev/null 2>&1 || return 1
  "${terraform_bin}" show -json "${recovery_probe_plan}" >"${fresh_json}" \
    || return 1
  "${terraform_bin}" show -json "${plan_path}" >"${reviewed_json}" \
    || return 1
  jq -eS '[.resource_changes[]? | {address,mode,type,name,index,provider_name,change}]
    | sort_by(.address)' "${fresh_json}" >"${fresh_changes}" || return 1
  jq -eS '[.resource_changes[]? | {address,mode,type,name,index,provider_name,change}]
    | sort_by(.address)' "${reviewed_json}" >"${reviewed_changes}" || return 1
  cmp -s "${fresh_changes}" "${reviewed_changes}"
}

trap cleanup_apply EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077

if [[ -z "${recovery_token}" ]]; then
  [[ -f "${plan_path}" && ! -L "${plan_path}" ]] || {
  printf 'Missing reviewed ACL runtime-job plan: %s\n' "${plan_path}" >&2
  exit 1
  }
  [[ -f "${manifest_path}" && ! -L "${manifest_path}" ]] || {
  printf 'Missing reviewed ACL runtime-job manifest: %s\n' "${manifest_path}" >&2
  exit 1
  }
fi

if [[ -n "${recovery_token}" ]]; then
  "${script_dir}/assert-acl-runtime-job-recovery-token.sh" \
    "${recovery_token}" "${state_bucket}" "${project_id}" "${region}" \
    "${phase}" "${stage}" "${environment}" "${state_prefix}" \
    "${repo_root}" >/dev/null
  cp "${recovery_token}" "${lease_token}"
  lease_borrowed=true
  recovery_source_dir="$(cd "$(dirname "${recovery_token}")" && pwd -P)"
else
  "${lease_script}" acquire "${gcloud_bin}" "${state_bucket}" \
    "${project_id}" "${region}" \
    "acl-job-apply:${phase}:${stage}:${environment}:${state_prefix}:${source_head}:${holder_digest}" \
    "${lease_token}"
fi
lease_acquired=true
artifact_snapshot >"${artifacts}"
if [[ "${lease_borrowed}" == true ]]; then
  recovery_transition="${recovery_source_dir}/exclusive-transition.json"
  [[ -f "${recovery_transition}" && ! -L "${recovery_transition}" ]] || {
    printf 'Recovery requires the original private exclusive-transition evidence beside the generation-bound lease token.\n' >&2
    exit 1
  }
  create_current_recovery_probe
  if [[ "${recovery_plan_status}" -eq 0 ]]; then
    cp "${recovery_probe_plan}" "${apply_plan}"
    cp "${recovery_probe_manifest}" "${apply_manifest}"
    chmod 0600 "${apply_plan}" "${apply_manifest}"
    convergence_only=true
  else
    assert_recovery_recreates_transition \
      "${recovery_probe_plan}" "${recovery_transition}"
    if recovery_review_matches_current_state \
      "${recovery_transition}" "${recovery_token}" "${recovery_probe_state}"; then
      cp "${plan_path}" "${apply_plan}"
      cp "${manifest_path}" "${apply_manifest}"
      chmod 0600 "${apply_plan}" "${apply_manifest}"
      resume_recovery_apply=true
    else
      write_recovery_review "${recovery_probe_plan}" \
        "${recovery_probe_manifest}" "${recovery_probe_state}" \
        "${recovery_transition}" "${recovery_token}"
      printf 'Saved a fresh state-serial-bound recovery plan under the held lease. Review %s, then rerun the same apply with ACL_RUNTIME_JOB_RECOVERY_TOKEN=%s.\n' \
        "${plan_path}" "${recovery_token}" >&2
      exit 1
    fi
  fi
else
  if [[ -f "${plan_path}" && ! -L "${plan_path}" \
    && -f "${manifest_path}" && ! -L "${manifest_path}" ]] \
    && "${metadata_script}" verify "${plan_path}" "${manifest_path}" \
      "${terraform_bin}" "${provider_root}" "${repo_root}" "${artifacts}" \
      >/dev/null 2>&1; then
    reviewed_plan_current=true
  fi
  [[ "${reviewed_plan_current}" == true ]] || {
    printf 'Reviewed ACL runtime-job plan provenance is stale or invalid.\n' >&2
    exit 1
  }
  cp "${plan_path}" "${apply_plan}"
  cp "${manifest_path}" "${apply_manifest}"
  chmod 0600 "${apply_plan}" "${apply_manifest}"
  "${metadata_script}" verify "${apply_plan}" "${apply_manifest}" \
    "${terraform_bin}" "${provider_root}" "${repo_root}" "${artifacts}"
fi
"${assertion_script}" "${apply_plan}" "${terraform_bin}" "${phase}" \
  "${project_id}" "${zone}" "${prefix}"
"${checkpoint_script}" "${stage}" "${checkpoint}" "${project_id}" \
  "${region}" "${zone}" "${prefix}" "${repo_root}"
"${lease_script}" assert-held "${gcloud_bin}" "${state_bucket}" \
  "${project_id}" "${region}" "${lease_token}"
[[ "${domain_name}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || {
  printf 'ACL_RUNTIME_JOB_DOMAIN_NAME must be the exact deployed domain.\n' >&2
  exit 1
}
[[ -x "${curl_bin}" ]] || {
  printf 'ACL runtime-job gate requires an executable curl binary.\n' >&2
  exit 1
}
nomad_secret="${prefix}nomad-secret-id"
nomad_secret_version_prefix="projects/${project_id}/secrets/${nomad_secret}/versions/"
[[ "${nomad_token_secret_version}" == "${nomad_secret_version_prefix}"* ]] || {
  printf 'Nomad gate token reference must target the exact project and secret.\n' >&2
  exit 1
}
nomad_token_version="${nomad_token_secret_version#"${nomad_secret_version_prefix}"}"
[[ "${nomad_token_version}" =~ ^[1-9][0-9]*$ ]] || {
  printf 'Nomad gate token reference must use an immutable numeric version.\n' >&2
  exit 1
}
if [[ "${convergence_only}" == true ]]; then
  [[ -f "${recovery_source_dir}/exclusive-transition.json" \
    && ! -L "${recovery_source_dir}/exclusive-transition.json" ]] || {
    printf 'Clean-state recovery is missing the original exclusive-transition evidence; preserve the lease for operator audit.\n' >&2
    exit 1
  }
  cp "${recovery_source_dir}/exclusive-transition.json" "${transition_evidence}"
  load_recovery_transition_inventory
  cp "${apply_plan}" "${post_plan}"
  chmod 0600 "${transition_evidence}" \
    "${transition_job_inventory_projection}" "${post_plan}"
  mutation_started=true
else
  write_job_projection \
    "${apply_plan}" "${job_projection}" "${reviewed_plan_json}" false \
    "${job_inventory_projection}"
  write_job_projection \
    "${apply_plan}" "${temp_dir}/desired-jobs.json" \
    "${temp_dir}/desired-plan.json" false \
    "${desired_job_inventory_projection}" after
  cmp -s "${job_projection}" "${temp_dir}/desired-jobs.json" || {
    printf 'Desired runtime projection changed while deriving after-source inventory.\n' >&2
    exit 1
  }
  if [[ "${phase}" == pre-server ]]; then
    write_state_job_inventory "${job_inventory_projection}" false
  fi
  if [[ "${lease_borrowed}" == true ]]; then
    load_recovery_transition_inventory
  else
    cp "${job_inventory_projection}" "${transition_job_inventory_projection}"
    chmod 0600 "${transition_job_inventory_projection}"
  fi
  mutation_started=true
  if [[ "${resume_recovery_apply}" == true ]]; then
    cp "${recovery_transition}" "${transition_evidence}"
    chmod 0600 "${transition_evidence}"
  else
    run_nomad_gate prepare "${job_projection}" \
      "${job_inventory_projection}" "${transition_evidence}"
    destructive_transition_count="$(jq '
      (.descendant_quiescence.actions | length)
      + ([.actions[] | select(
          .action == "purged_before_first_locking_rollout"
        )] | length)
    ' "${transition_evidence}")"
    if [[ "${destructive_transition_count}" -gt 0 ]]; then
      create_current_recovery_probe
      [[ "${recovery_plan_status}" -eq 2 ]] || {
        printf 'Nomad prepare mutated live jobs but Terraform did not produce the required recovery plan.\n' >&2
        exit 1
      }
      assert_recovery_recreates_transition \
        "${recovery_probe_plan}" "${transition_evidence}"
      write_recovery_review "${recovery_probe_plan}" \
        "${recovery_probe_manifest}" "${recovery_probe_state}" \
        "${transition_evidence}" "${lease_token}"
      printf 'Nomad jobs were quiesced under the held lease. Review the fresh recreation plan %s, then rerun with ACL_RUNTIME_JOB_RECOVERY_TOKEN=%s.\n' \
        "${plan_path}" "${lease_token}" >&2
      exit 1
    fi
  fi
  "${terraform_bin}" -chdir="${provider_root}" apply -input=false "${apply_plan}"

  set +e
  terraform_plan "${post_plan}" -detailed-exitcode >/dev/null
  post_status=$?
  set -e
  if [[ "${post_status}" -ne 0 ]]; then
    printf 'ACL runtime-job state is not clean after apply (Terraform exit %s).\n' \
      "${post_status}" >&2
    exit 1
  fi
fi
"${assertion_script}" "${post_plan}" "${terraform_bin}" "${phase}" \
  "${project_id}" "${zone}" "${prefix}"

if [[ "${convergence_only}" == false ]]; then
  cmp -s "${plan_path}" "${apply_plan}" \
    && cmp -s "${manifest_path}" "${apply_manifest}" || {
      printf 'Published ACL plan changed while reviewed bytes were applying.\n' >&2
      exit 1
    }
fi

write_job_projection \
  "${post_plan}" "${post_job_projection}" "${post_plan_json}" true \
  "${post_job_inventory_projection}"
if [[ "${phase}" == pre-server ]]; then
  write_state_job_inventory "${post_job_inventory_projection}" true
fi
if [[ "${convergence_only}" == true ]]; then
  jq -S 'map(.expected_modify_index = null)' \
    "${post_job_projection}" >"${job_projection}"
  jq -S 'map(.expected_modify_index = null)' \
    "${post_job_inventory_projection}" >"${job_inventory_projection}"
  cp "${job_inventory_projection}" "${desired_job_inventory_projection}"
  chmod 0600 "${job_projection}" "${job_inventory_projection}" \
    "${desired_job_inventory_projection}"
fi
jq -S 'map(.expected_modify_index = null)' \
  "${post_job_projection}" >"${temp_dir}/post-static-jobs.json"
cmp -s "${job_projection}" "${temp_dir}/post-static-jobs.json" || {
  printf 'Nomad job projection changed between reviewed and converged plans.\n' >&2
  exit 1
}
jq -S 'map(.expected_modify_index = null)' \
  "${post_job_inventory_projection}" \
  >"${temp_dir}/post-static-job-inventory.json"
jq -eS \
  --slurpfile before "${transition_job_inventory_projection}" \
  --slurpfile desired "${desired_job_inventory_projection}" '
    . as $post
    | ($before[0]
        | map({address,job_id,job_type,inventory_class,child_mode}))
      == ($post
        | map({address,job_id,job_type,inventory_class,child_mode}))
    and all($desired[0][];
      . as $wanted
      | any($post[]; . == $wanted))
    and all($before[0][];
      . as $original
      | if any($desired[0][]; .address == $original.address)
        then true
        else any($post[]; . == $original)
        end)
  ' "${temp_dir}/post-static-job-inventory.json" >/dev/null || {
  printf 'Nomad inventory identity, desired source, or unrelated-job source changed between review and convergence.\n' >&2
  exit 1
}
run_nomad_gate wait "${post_job_projection}" \
  "${post_job_inventory_projection}" "${live_convergence_evidence}" \
  "${transition_evidence}" "${transition_job_inventory_projection}"

checkpoint_sha256="$(shasum -a 256 "${checkpoint}" | awk '{print $1}')"
plan_sha256="$(shasum -a 256 "${apply_plan}" | awk '{print $1}')"
manifest_sha256="$(shasum -a 256 "${apply_manifest}" | awk '{print $1}')"
post_plan_sha256="$(shasum -a 256 "${post_plan}" | awk '{print $1}')"
job_projection_sha256="$(shasum -a 256 "${job_projection}" | awk '{print $1}')"
live_job_projection_sha256="$(shasum -a 256 "${post_job_projection}" | awk '{print $1}')"
job_inventory_projection_sha256="$(shasum -a 256 \
  "${transition_job_inventory_projection}" | awk '{print $1}')"
live_job_inventory_projection_sha256="$(shasum -a 256 \
  "${post_job_inventory_projection}" | awk '{print $1}')"
transition_evidence_sha256="$(shasum -a 256 "${transition_evidence}" | awk '{print $1}')"
live_convergence_evidence_sha256="$(shasum -a 256 "${live_convergence_evidence}" | awk '{print $1}')"
job_addresses="$(jq -c '[.[].address]' "${job_projection}")"
for digest in \
  "${checkpoint_sha256}" "${plan_sha256}" "${manifest_sha256}" \
  "${post_plan_sha256}" "${job_projection_sha256}" \
  "${live_job_projection_sha256}" "${job_inventory_projection_sha256}" \
  "${live_job_inventory_projection_sha256}" \
  "${transition_evidence_sha256}" "${live_convergence_evidence_sha256}"; do
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]]
done

jq -nS \
  --arg source_sha "${source_head}" \
  --arg environment "${environment}" \
  --arg project_id "${project_id}" \
  --arg region "${region}" \
  --arg zone "${zone}" \
  --arg prefix "${prefix}" \
  --arg phase "${phase}" \
  --arg stage "${stage}" \
  --arg checkpoint_sha256 "${checkpoint_sha256}" \
  --arg plan_sha256 "${plan_sha256}" \
  --arg manifest_sha256 "${manifest_sha256}" \
  --arg post_plan_sha256 "${post_plan_sha256}" \
  --arg job_projection_sha256 "${job_projection_sha256}" \
  --arg live_job_projection_sha256 "${live_job_projection_sha256}" \
  --arg job_inventory_projection_sha256 "${job_inventory_projection_sha256}" \
  --arg live_job_inventory_projection_sha256 "${live_job_inventory_projection_sha256}" \
  --arg transition_evidence_sha256 "${transition_evidence_sha256}" \
  --arg live_convergence_evidence_sha256 "${live_convergence_evidence_sha256}" \
  --argjson job_addresses "${job_addresses}" \
  --slurpfile exclusive_transition "${transition_evidence}" \
  --slurpfile live_job_projection "${post_job_projection}" \
  --slurpfile job_inventory_projection "${transition_job_inventory_projection}" \
  --slurpfile live_job_inventory_projection "${post_job_inventory_projection}" \
  --slurpfile live_nomad_convergence "${live_convergence_evidence}" \
  --arg applied_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {
      schema_version:1,
      source_sha:$source_sha,
      environment:$environment,
      project_id:$project_id,
      region:$region,
      zone:$zone,
      prefix:$prefix,
      phase:$phase,
      stage:$stage,
      checkpoint_sha256:$checkpoint_sha256,
      reviewed_plan_sha256:$plan_sha256,
      reviewed_manifest_sha256:$manifest_sha256,
      converged_plan_sha256:$post_plan_sha256,
      job_projection_sha256:$job_projection_sha256,
      live_job_projection_sha256:$live_job_projection_sha256,
      job_inventory_projection_sha256:$job_inventory_projection_sha256,
      live_job_inventory_projection_sha256:$live_job_inventory_projection_sha256,
      exclusive_transition_sha256:$transition_evidence_sha256,
      live_nomad_convergence_sha256:$live_convergence_evidence_sha256,
      job_addresses:$job_addresses,
      exclusive_transition:$exclusive_transition[0],
      live_job_projection:$live_job_projection[0],
      job_inventory_projection:$job_inventory_projection[0],
      live_job_inventory_projection:$live_job_inventory_projection[0],
      live_nomad_convergence:$live_nomad_convergence[0],
      applied_at:$applied_at
    }
  ' >"${evidence_tmp}"
chmod 0600 "${evidence_tmp}"
evidence_dir="$(dirname "${completion_evidence}")"
[[ -d "${evidence_dir}" && ! -L "${evidence_dir}" ]]
mv -f -- "${evidence_tmp}" "${completion_evidence}"
chmod 0600 "${completion_evidence}"
[[ ! -L "${completion_evidence}" ]]
convergence_proven=true

rm -f -- "${plan_path}" "${manifest_path}" "${recovery_review_path}"
"${lease_script}" release "${gcloud_bin}" "${lease_token}"
if [[ "${lease_borrowed}" == true ]]; then
  rm -f -- "${recovery_token}"
fi
lease_acquired=false
rm -rf -- "${temp_dir}"
trap - EXIT HUP INT TERM
printf 'Applied and reconverged ACL %s runtime-job plan. Evidence: %s\n' \
  "${phase}" "${completion_evidence}"
