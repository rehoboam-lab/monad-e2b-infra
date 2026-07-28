#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assertion_script="${script_dir}/assert-workload-plan.sh"
packer_assertion_script="${script_dir}/assert-packer-reserve.sh"
fixture="${script_dir}/testdata/minimal-workload-plan.json"
policy="${script_dir}/../topology/minimal-workload-policy.json"
packer_template="${script_dir}/../nomad-cluster-disk-image/main.pkr.hcl"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

fake_terraform="${test_dir}/terraform"
cp "${script_dir}/testdata/fake-terraform.sh" "${fake_terraform}"
chmod 0700 "${fake_terraform}"

expect_failure() {
  local name="$1"
  local expected_message="$2"
  local plan_path="$3"
  local policy_path="${4:-${policy}}"
  local packer_template_path="${5:-${packer_template}}"
  local output_path="${test_dir}/${name}.output"

  if "${assertion_script}" \
    "${plan_path}" \
    "${fake_terraform}" \
    "${policy_path}" \
    "${packer_template_path}" >"${output_path}" 2>&1; then
    printf 'Expected %s fixture to fail.\n' "${name}" >&2
    exit 1
  fi

  grep -F "${expected_message}" "${output_path}" >/dev/null || {
    printf 'Fixture %s failed for an unexpected reason:\n' "${name}" >&2
    sed -n '1,160p' "${output_path}" >&2
    exit 1
  }
}

expect_success() {
  local name="$1"
  local plan_path="$2"
  local output_path="${test_dir}/${name}.output"

  "${assertion_script}" \
    "${plan_path}" \
    "${fake_terraform}" \
    "${policy}" \
    "${packer_template}" >"${output_path}"

  grep -F '"global_vcpus":30' "${output_path}" >/dev/null
  grep -F '"instances":7' "${output_path}" >/dev/null
  grep -F '"pd_ssd_gb":470' "${output_path}" >/dev/null
  grep -F '"pd_standard_gb":400' "${output_path}" >/dev/null
  grep -F '"local_ssd_gb":750' "${output_path}" >/dev/null
  grep -F '"regional_public_ips":7' "${output_path}" >/dev/null
}

expect_success "minimal" "${fixture}"

jq '
  (
    .resource_changes[]
    | select(
        .type == "google_compute_instance_template"
        and (
          .address
          | contains(".module.build_cluster[")
          or contains(".module.client_cluster[")
        )
      )
    | .change.after.disk[]
    | select(.disk_type == "pd-ssd")
    | .disk_type
  ) = "pd-balanced"
' "${fixture}" >"${test_dir}/balanced-ssd.json"
expect_success "balanced-ssd" "${test_dir}/balanced-ssd.json"

jq '
  (
    .resource_changes[]
    | select(.name == "clickhouse_pool")
    | .change.after.target_size
  ) = 1
' "${fixture}" >"${test_dir}/unexpected-clickhouse.json"
expect_failure \
  "unexpected-clickhouse" \
  "quota_violations must be empty." \
  "${test_dir}/unexpected-clickhouse.json"

jq '
  (
    .resource_changes[]
    | select(
        .address
        == "module.cluster.module.build_cluster[\"default\"].google_compute_region_instance_group_manager.pool"
      )
    | .change.after.update_policy[0].max_surge_fixed
  ) = 1
' "${fixture}" >"${test_dir}/worker-surge.json"
expect_failure \
  "worker-surge" \
  "automated_worker_server_surges must be empty." \
  "${test_dir}/worker-surge.json"

jq '
  (
    .resource_changes[]
    | select(.name == "server_pool")
    | .change.after.update_policy[0].max_surge_fixed
  ) = 1
' "${fixture}" >"${test_dir}/server-surge.json"
expect_failure \
  "server-surge" \
  "automated_worker_server_surges must be empty." \
  "${test_dir}/server-surge.json"

jq '
  (
    .resource_changes[]
    | select(.name == "server_pool")
    | .change.after.update_policy[0].max_unavailable_fixed
  ) = 2
' "${fixture}" >"${test_dir}/server-unavailable.json"
expect_failure \
  "server-unavailable" \
  "role maximum unavailable counts differ from policy." \
  "${test_dir}/server-unavailable.json"

jq '
  (
    .resource_changes[]
    | select(.name == "api_pool")
    | .change.after.update_policy[0].max_surge_fixed
  ) = 2
' "${fixture}" >"${test_dir}/quota-overflow.json"
expect_failure \
  "quota-overflow" \
  "quota_violations must be empty." \
  "${test_dir}/quota-overflow.json"

jq '
  (
    .resource_changes[]
    | select(.name == "server_pool")
    | .change.actions
  ) = ["delete", "create"]
' "${fixture}" >"${test_dir}/destructive-mig.json"
expect_failure \
  "destructive-mig" \
  "destructive_migs must be empty." \
  "${test_dir}/destructive-mig.json"

jq '
  (
    .resource_changes[]
    | select(
        .address
        == "module.cluster.module.build_cluster[\"default\"].google_compute_region_instance_group_manager.pool"
      )
    | .change.actions
  ) = ["update"]
  |
  (
    .resource_changes[]
    | select(
        .address
        == "module.cluster.module.build_cluster[\"default\"].google_compute_region_instance_group_manager.pool"
      )
    | .change.before
  ) = {
    "target_size": 2,
    "update_policy": [{"max_surge_fixed": 0, "max_surge_percent": null}]
  }
' "${fixture}" >"${test_dir}/capacity-reduction.json"
expect_failure \
  "capacity-reduction" \
  "capacity_reductions must be empty." \
  "${test_dir}/capacity-reduction.json"

jq '
  (
    .resource_changes[]
    | select(.name == "api_pool")
    | .change.actions
  ) = ["update"]
' "${fixture}" >"${test_dir}/unknown-previous-capacity.json"
expect_failure \
  "unknown-previous-capacity" \
  "unresolved_previous_capacities must be empty." \
  "${test_dir}/unknown-previous-capacity.json"

jq '
  (
    .resource_changes[]
    | select(.name == "server_pool")
    | .change.after.update_policy[0].max_surge_fixed
  ) = null
  |
  (
    .resource_changes[]
    | select(.name == "server_pool")
    | .change.after_unknown.update_policy
  ) = true
' "${fixture}" >"${test_dir}/unknown-surge.json"
expect_failure \
  "unknown-surge" \
  "unresolved_surges must be empty." \
  "${test_dir}/unknown-surge.json"

jq '
  (
    .resource_changes[]
    | select(
        .address
        == "module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template"
      )
    | .change.after.machine_type
  ) = "n1-standard-4"
' "${fixture}" >"${test_dir}/machine-type-drift.json"
expect_failure \
  "machine-type-drift" \
  "role machine and disk resources differ from policy." \
  "${test_dir}/machine-type-drift.json"

jq '
  (
    .resource_changes[]
    | select(
        .address
        == "module.cluster.module.build_cluster[\"default\"].google_compute_instance_template.template"
      )
    | .change.after.disk[]
    | select(.disk_type == "pd-ssd")
    | .disk_size_gb
  ) = 210
' "${fixture}" >"${test_dir}/ssd-capacity-drift.json"
expect_failure \
  "ssd-capacity-drift" \
  "role machine and disk resources differ from policy." \
  "${test_dir}/ssd-capacity-drift.json"

jq '
  (
    .resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.api")
    | .change.after.disk[0].disk_size_gb
  ) = 201
' "${fixture}" >"${test_dir}/standard-pd-drift.json"
expect_failure \
  "standard-pd-drift" \
  "role machine and disk resources differ from policy." \
  "${test_dir}/standard-pd-drift.json"

jq '
  (
    .resource_changes[]
    | select(
        .address
        == "module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template"
      )
    | .change.after.disk[]
    | select(.disk_type == "local-ssd")
    | .disk_size_gb
  ) = 750
' "${fixture}" >"${test_dir}/local-ssd-drift.json"
expect_failure \
  "local-ssd-drift" \
  "role machine and disk resources differ from policy." \
  "${test_dir}/local-ssd-drift.json"

jq '
  (
    .resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.api")
    | .change.after.network_interface[0].access_config
  ) = []
' "${fixture}" >"${test_dir}/public-ip-drift.json"
expect_failure \
  "public-ip-drift" \
  "role machine and disk resources differ from policy." \
  "${test_dir}/public-ip-drift.json"

jq '
  (
    .resource_changes[]
    | select(
        .address
        == "module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template"
      )
    | .change.after.disk[0].disk_type
  ) = "hyperdisk-balanced"
' "${fixture}" >"${test_dir}/unknown-disk-type.json"
expect_failure \
  "unknown-disk-type" \
  "invalid_template_disks must be empty." \
  "${test_dir}/unknown-disk-type.json"

jq '
  (
    .resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.server")
    | .change.after_unknown.disk
  ) = true
' "${fixture}" >"${test_dir}/unknown-disk.json"
expect_failure \
  "unknown-disk" \
  "unresolved_templates must be empty." \
  "${test_dir}/unknown-disk.json"

jq '
  .resource_changes += [
    {
      "address": "module.cluster.google_compute_instance_template.unreviewed",
      "mode": "managed",
      "type": "google_compute_instance_template",
      "name": "unreviewed",
      "change": {
        "actions": ["create"],
        "after": {
          "machine_type": "e2-standard-2",
          "disk": [{
            "disk_size_gb": 20,
            "disk_type": "pd-ssd",
            "type": "PERSISTENT"
          }],
          "network_interface": [{"access_config": [{}]}]
        }
      }
    }
  ]
' "${fixture}" >"${test_dir}/unknown-template.json"
expect_failure \
  "unknown-template" \
  "unknown_templates must be empty." \
  "${test_dir}/unknown-template.json"

jq '
  .resource_changes += [
    {
      "address": "module.cluster.google_compute_disk.unreviewed",
      "mode": "managed",
      "type": "google_compute_disk",
      "name": "unreviewed",
      "change": {
        "actions": ["create"],
        "after": {
          "size": 10,
          "type": "pd-ssd"
        }
      }
    }
  ]
' "${fixture}" >"${test_dir}/unknown-resource.json"
expect_failure \
  "unknown-resource" \
  "unexpected_quota_resources must be empty." \
  "${test_dir}/unknown-resource.json"

jq '.quota_limits.global_vcpus = 64' \
  "${policy}" >"${test_dir}/quota-policy-drift.json"
expect_failure \
  "quota-policy-drift" \
  "Workload topology policy is invalid or differs from reviewed quota limits" \
  "${fixture}" \
  "${test_dir}/quota-policy-drift.json"

jq '.transient_reserve.vcpus = 8' \
  "${policy}" >"${test_dir}/packer-policy-drift.json"
expect_failure \
  "packer-policy-drift" \
  "Workload topology policy is invalid or differs from reviewed quota limits" \
  "${fixture}" \
  "${test_dir}/packer-policy-drift.json"

sed \
  's/machine_type = local.quota_reserve.machine_type/machine_type = "n1-standard-8"/' \
  "${packer_template}" >"${test_dir}/packer-drift.pkr.hcl"
expect_failure \
  "packer-template-drift" \
  "Packer template must contain exactly one machine-type reserve assignment" \
  "${fixture}" \
  "${policy}" \
  "${test_dir}/packer-drift.pkr.hcl"

"${packer_assertion_script}" "${policy}" "${packer_template}" >/dev/null

printf 'Workload plan assertion fixtures passed.\n'
