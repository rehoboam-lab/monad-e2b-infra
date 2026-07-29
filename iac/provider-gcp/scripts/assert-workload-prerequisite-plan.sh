#!/usr/bin/env bash
set -euo pipefail

plan_path="${1:?usage: assert-workload-prerequisite-plan.sh PLAN_PATH TERRAFORM_BIN POLICY_PATH}"
terraform_bin="${2:-terraform}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy_path="${3:-${script_dir}/../topology/minimal-workload-policy.json}"
topology_filter="${script_dir}/workload-plan-topology.jq"
expected_project="${WORKLOAD_GCP_PROJECT_ID:?WORKLOAD_GCP_PROJECT_ID is required}"
expected_region="${WORKLOAD_GCP_REGION:?WORKLOAD_GCP_REGION is required}"
expected_prefix="${WORKLOAD_PREFIX:?WORKLOAD_PREFIX is required}"

[[ -f "${plan_path}" ]] || {
  printf 'Saved workload prerequisite plan does not exist: %s\n' "${plan_path}" >&2
  exit 1
}
[[ -f "${policy_path}" ]] || {
  printf 'Workload topology policy does not exist: %s\n' "${policy_path}" >&2
  exit 1
}
[[ -f "${topology_filter}" ]] || {
  printf 'Workload topology analysis filter does not exist: %s\n' "${topology_filter}" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'jq is required to inspect the saved prerequisite plan.\n' >&2
  exit 1
}

plan_json="$("${terraform_bin}" show -json "${plan_path}")"
policy_json="$(jq -c . "${policy_path}")"

expected_mutations="$(
  jq -cn '[
    {address:"google_artifact_registry_repository.custom_environments_repository",type:"google_artifact_registry_repository",actions:["create"]},
    {address:"google_artifact_registry_repository_iam_member.custom_environments_repository_member",type:"google_artifact_registry_repository_iam_member",actions:["create"]},
    {address:"google_compute_global_address.cloud_sql_private_services",type:"google_compute_global_address",actions:["create"]},
    {address:"google_project_iam_member.cloud_sql_service_agent",type:"google_project_iam_member",actions:["create"]},
    {address:"google_project_iam_member.service_networking_service_agent",type:"google_project_iam_member",actions:["create"]},
    {address:"google_project_service.cloud_sql_admin_api",type:"google_project_service",actions:["create"]},
    {address:"google_project_service.service_networking_api",type:"google_project_service",actions:["create"]},
    {address:"google_project_service_identity.cloud_sql",type:"google_project_service_identity",actions:["create"]},
    {address:"google_project_service_identity.service_networking",type:"google_project_service_identity",actions:["create"]},
    {address:"google_secret_manager_secret.postgres_read_replica_connection_string",type:"google_secret_manager_secret",actions:["create"]},
    {address:"google_secret_manager_secret.sandbox_access_token_hash_seed",type:"google_secret_manager_secret",actions:["create"]},
    {address:"google_secret_manager_secret_version.postgres_connection_string",type:"google_secret_manager_secret_version",actions:["create"]},
    {address:"google_secret_manager_secret_version.postgres_read_replica_connection_string",type:"google_secret_manager_secret_version",actions:["create"]},
    {address:"google_secret_manager_secret_version.sandbox_access_token_hash_seed",type:"google_secret_manager_secret_version",actions:["create"]},
    {address:"google_service_networking_connection.cloud_sql",type:"google_service_networking_connection",actions:["create"]},
    {address:"google_sql_database.operator_canary",type:"google_sql_database",actions:["create"]},
    {address:"google_sql_database_instance.operator_canary",type:"google_sql_database_instance",actions:["create"]},
    {address:"google_sql_user.operator_canary",type:"google_sql_user",actions:["create"]},
    {address:"random_password.cloud_sql_operator_canary",type:"random_password",actions:["create"]},
    {address:"random_password.sandbox_access_token_hash_seed",type:"random_password",actions:["create"]},
    {address:"terraform_data.cloud_sql_connection_budget",type:"terraform_data",actions:["create"]},
    {address:"time_static.volume_token_generation",type:"time_static",actions:["create"]},
    {address:"tls_private_key.volume_token[0]",type:"tls_private_key",actions:["create"]}
  ] | sort_by(.address)'
)"

actual_mutations="$(
  jq -c '
    [
      .resource_changes[]?
      | select(.mode == "managed")
      | select(.change.actions != ["no-op"])
      | {
          address,
          type,
          actions: .change.actions
        }
    ]
    | sort_by(.address)
  ' <<<"${plan_json}"
)"

if ! jq -ne \
  --argjson expected "${expected_mutations}" \
  --argjson actual "${actual_mutations}" \
  '$actual == $expected' >/dev/null; then
  printf 'Refusing workload prerequisite plan: mutation set must be the exact reviewed 23 creates.\n' >&2
  printf 'Expected: %s\n' "$(jq -c . <<<"${expected_mutations}")" >&2
  printf 'Planned:  %s\n' "$(jq -c . <<<"${actual_mutations}")" >&2
  exit 1
fi

unexpected_data_changes="$(
  jq -c '
    [
      .resource_changes[]?
      | select(.mode == "data")
      | {
          address,
          type,
          actions: .change.actions
        }
    ]
  ' <<<"${plan_json}"
)"
if [[ "$(jq 'length' <<<"${unexpected_data_changes}")" -ne 0 ]]; then
  printf 'Refusing workload prerequisite plan: deferred data reads must be empty.\n' >&2
  jq -c '.[]' <<<"${unexpected_data_changes}" >&2
  exit 1
fi

unexpected_nomad_resources="$(
  jq -c '
    [
      .resource_changes[]?
      | select(
          (.type | startswith("nomad_"))
          or (.address | startswith("module.nomad."))
        )
      | {
          address,
          type,
          actions: .change.actions
        }
    ]
  ' <<<"${plan_json}"
)"
if [[ "$(jq 'length' <<<"${unexpected_nomad_resources}")" -ne 0 ]]; then
  printf 'Refusing workload prerequisite plan: Nomad resources must be absent.\n' >&2
  jq -c '.[]' <<<"${unexpected_nomad_resources}" >&2
  exit 1
fi

topology="$(
  jq -c \
    --argjson expected "${policy_json}" \
    -f "${topology_filter}" \
    <<<"${plan_json}"
)"
for field in \
  destructive_cloud_sql_resources \
  unknown_cloud_sql_resources \
  missing_or_duplicate_cloud_sql_resources \
  invalid_cloud_sql_resources; do
  if [[ "$(jq ".${field} | length" <<<"${topology}")" -ne 0 ]]; then
    printf 'Refusing workload prerequisite plan: %s must be empty.\n' "${field}" >&2
    jq -c ".${field}[]" <<<"${topology}" >&2
    exit 1
  fi
done

if ! jq -e \
  --arg expected_project "${expected_project}" \
  --arg expected_region "${expected_region}" \
  --arg expected_prefix "${expected_prefix}" '
  def row($address):
    [
      .resource_changes[]?
      | select(.address == $address)
    ][0];

  row("google_artifact_registry_repository.custom_environments_repository") as $repo
  | row("google_artifact_registry_repository_iam_member.custom_environments_repository_member") as $repo_iam
  | row("google_secret_manager_secret.postgres_read_replica_connection_string") as $read_secret
  | row("google_secret_manager_secret_version.postgres_read_replica_connection_string") as $read_version
  | row("random_password.sandbox_access_token_hash_seed") as $seed_password
  | row("google_secret_manager_secret.sandbox_access_token_hash_seed") as $seed_secret
  | row("google_secret_manager_secret_version.sandbox_access_token_hash_seed") as $seed_version
  | row("tls_private_key.volume_token[0]") as $volume_key
  | row("time_static.volume_token_generation") as $volume_time
  | row("google_sql_database_instance.operator_canary") as $sql_instance
  | (
      [
        .configuration.root_module.resources[]?
        | select(
            .address
            == "google_artifact_registry_repository.custom_environments_repository"
          )
      ][0]
    ) as $repo_config
  | (
      .configuration.provider_config[
        ($repo_config.provider_config_key // "")
      ] // {}
    ) as $provider_config
  | $repo.change.after.format == "DOCKER"
    and $repo.change.after.project == $expected_project
    and $repo.change.after.repository_id
      == ($expected_prefix + "custom-environments")
    and $repo.change.after_unknown.repository_id != true
    and $repo_config.mode == "managed"
    and $repo_config.type == "google_artifact_registry_repository"
    and $provider_config.full_name
      == "registry.terraform.io/hashicorp/google"
    and ($provider_config.alias // null) == null
    and $provider_config.expressions.project.references
      == ["var.gcp_project_id"]
    and $provider_config.expressions.region.references
      == ["var.gcp_region"]
    and $repo_iam.change.after.role == "roles/artifactregistry.repoAdmin"
    and ($repo_iam.change.after.member | type) == "string"
    and ($repo_iam.change.after.member | startswith("serviceAccount:"))
    and $repo_iam.change.after_unknown.role != true
    and $repo_iam.change.after_unknown.member != true
    and $read_secret.change.after.secret_id
      == ($expected_prefix + "postgres-read-replica-connection-string")
    and ($read_secret.change.after.replication | length) == 1
    and ($read_secret.change.after.replication[0].auto | length) == 1
    and $read_secret.change.after.replication[0].auto[0].customer_managed_encryption == []
    and $read_secret.change.after.replication[0].user_managed == []
    and $read_version.change.after.secret_data == " "
    and $read_version.change.after_sensitive.secret_data == true
    and $seed_password.change.after.length == 32
    and $seed_password.change.after.special == false
    and $seed_secret.change.after.secret_id
      == ($expected_prefix + "sandbox-access-token-hash-seed")
    and ($seed_secret.change.after.replication | length) == 1
    and ($seed_secret.change.after.replication[0].auto | length) == 1
    and $seed_secret.change.after.replication[0].auto[0].customer_managed_encryption == []
    and $seed_secret.change.after.replication[0].user_managed == []
    and $seed_version.change.after_sensitive.secret_data == true
    and $seed_version.change.after_unknown.secret_data == true
    and $volume_key.change.after.algorithm == "ED25519"
    and $volume_key.change.after_sensitive.private_key_openssh == true
    and $volume_key.change.after_sensitive.private_key_pem == true
    and $volume_key.change.after_unknown.private_key_openssh == true
    and $volume_key.change.after_unknown.private_key_pem == true
    and $volume_time.change.after.rfc3339 == null
    and $volume_time.change.after_unknown.rfc3339 == true
    and $sql_instance.change.after.project == $expected_project
    and $sql_instance.change.after.region == $expected_region
' <<<"${plan_json}" >/dev/null; then
  printf 'Refusing workload prerequisite plan: non-Cloud-SQL prerequisite identity or sensitive-value handling drifted.\n' >&2
  exit 1
fi

printf 'Workload prerequisite plan passed: exactly 23 reviewed creates, zero data reads, and zero Nomad resources.\n'
