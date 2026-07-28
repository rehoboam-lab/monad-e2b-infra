#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assertion_script="${script_dir}/assert-workload-plan.sh"
fixture="${script_dir}/testdata/minimal-workload-plan.json"
policy="${script_dir}/../topology/minimal-workload-policy.json"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

fake_terraform="${test_dir}/terraform"
cp "${script_dir}/testdata/fake-terraform.sh" "${fake_terraform}"
chmod 0700 "${fake_terraform}"

expect_failure() {
  local name="$1"
  local expected_message="$2"
  local plan_path="$3"
  local output_path="${test_dir}/${name}.output"

  if "${assertion_script}" "${plan_path}" "${fake_terraform}" "${policy}" >"${output_path}" 2>&1; then
    printf 'Expected %s fixture to fail.\n' "${name}" >&2
    exit 1
  fi

  grep -F "${expected_message}" "${output_path}" >/dev/null || {
    printf 'Fixture %s failed for an unexpected reason:\n' "${name}" >&2
    sed -n '1,120p' "${output_path}" >&2
    exit 1
  }
}

"${assertion_script}" "${fixture}" "${fake_terraform}" "${policy}" >/dev/null

jq '
  (
    .resource_changes[]
    | select(.name == "clickhouse_pool")
    | .change.after.target_size
  ) = 0
' "${fixture}" >"${test_dir}/missing-clickhouse.json"
expect_failure \
  "missing-clickhouse" \
  "ClickHouse maximum instance count is 0; expected 1." \
  "${test_dir}/missing-clickhouse.json"

jq '
  (
    .resource_changes[]
    | select(
        .address
        == "module.cluster.module.build_cluster[\"default\"].google_compute_region_instance_group_manager.pool"
      )
    | .change.after.update_policy[0].max_surge_fixed
  ) = 10
' "${fixture}" >"${test_dir}/worker-surge.json"
expect_failure \
  "worker-surge" \
  "worker_surge_violations must be empty." \
  "${test_dir}/worker-surge.json"

jq '
  (
    .resource_changes[]
    | select(.name == "api_pool")
    | .change.after.update_policy[0].max_surge_fixed
  ) = 7
' "${fixture}" >"${test_dir}/rollout-capacity.json"
expect_failure \
  "rollout-capacity" \
  "peak rollout capacity is 24; policy permits at most 18" \
  "${test_dir}/rollout-capacity.json"

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

printf 'Workload plan assertion fixtures passed.\n'
