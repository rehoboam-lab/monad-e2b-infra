#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assertion_script="${script_dir}/assert-network-hardening-normal-plan.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

fake_terraform="${test_dir}/terraform"
cp "${script_dir}/testdata/fake-terraform.sh" "${fake_terraform}"
chmod 0700 "${fake_terraform}"

make_plan() {
  local stage="$1"
  local output="$2"

  jq -n --arg stage "${stage}" '
    {network: 1, server: 2, api: 3, worker: 4, build: 5} as $rank
    | [
        {address:"module.cluster.google_compute_instance_template.server", role_rank:2},
        {address:"module.cluster.google_compute_instance_template.api", role_rank:3},
        {address:"module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template", role_rank:4},
        {address:"module.cluster.module.build_cluster[\"default\"].google_compute_instance_template.template", role_rank:5},
        {address:"module.cluster.google_compute_instance_template.loki", role_rank:5},
        {address:"module.cluster.google_compute_instance_template.clickhouse", role_rank:5}
      ] as $templates
    | {
      format_version: "1.2",
      errored: false,
      resource_changes: (
        [
          {
            address: "module.cluster.terraform_data.network_hardening_rollout_completion",
            mode: "managed",
            type: "terraform_data",
            change: {
              actions: ["no-op"],
              before: {input: $stage},
              after: {input: $stage}
            }
          },
          {
            address: "module.cluster.terraform_data.network_hardening_rollout_stage",
            mode: "managed",
            type: "terraform_data",
            change: {
              actions: ["no-op"],
              before: {input: $stage},
              after: {input: $stage}
            }
          }
        ]
        + [
            $templates[]
            | {
                address: .address,
                mode: "managed",
                type: "google_compute_instance_template",
                change: {
                  actions: ["no-op"],
                  before: {metadata: (if $rank[$stage] >= .role_rank then {"enable-oslogin":"TRUE"} else {} end)},
                  after: {metadata: (if $rank[$stage] >= .role_rank then {"enable-oslogin":"TRUE"} else {} end)}
                }
              }
          ]
      )
    }
  ' >"${output}"
}

expect_failure() {
  local name="$1"
  local expected="$2"
  local plan="$3"
  local output="${test_dir}/${name}.output"

  if "${assertion_script}" "${plan}" "${fake_terraform}" >"${output}" 2>&1; then
    printf 'Expected %s to fail.\n' "${name}" >&2
    exit 1
  fi
  grep -F "${expected}" "${output}" >/dev/null || {
    printf '%s failed for an unexpected reason:\n' "${name}" >&2
    sed -n '1,120p' "${output}" >&2
    exit 1
  }
}

make_plan build "${test_dir}/valid.json"
"${assertion_script}" \
  "${test_dir}/valid.json" "${fake_terraform}" >"${test_dir}/valid.output"
grep -F 'preserves completed network-hardening stage: build' \
  "${test_dir}/valid.output" >/dev/null

make_plan disabled "${test_dir}/disabled.json"
expect_failure \
  disabled \
  'may not initialize, advance, regress, or remain disabled' \
  "${test_dir}/disabled.json"

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage")
    | .change.actions) = ["update"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage")
    | .change.after.input) = "disabled"
' "${test_dir}/valid.json" >"${test_dir}/reverse.json"
expect_failure \
  reverse \
  'may not initialize, advance, regress, or remain disabled' \
  "${test_dir}/reverse.json"

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion")
    | .change.actions) = ["delete", "create"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion")
    | .change.after.input) = "server"
' "${test_dir}/valid.json" >"${test_dir}/skip.json"
expect_failure \
  skip \
  'may not initialize, advance, regress, or remain disabled' \
  "${test_dir}/skip.json"

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion")
    | .change.before.input) = "worker"
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion")
    | .change.after.input) = "worker"
' "${test_dir}/valid.json" >"${test_dir}/mismatch.json"
expect_failure \
  mismatch \
  'Network-hardening convergence sentinel and state marker disagree' \
  "${test_dir}/mismatch.json"

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template")
    | .change.after.metadata) = {}
' "${test_dir}/valid.json" >"${test_dir}/template-regression.json"
expect_failure \
  template-regression \
  'OS Login template intent inconsistent with completed stage build' \
  "${test_dir}/template-regression.json"

jq '
  .resource_changes |= map(
    select(.address != "module.cluster.terraform_data.network_hardening_rollout_stage")
  )
' "${test_dir}/valid.json" >"${test_dir}/missing.json"
expect_failure \
  missing \
  'Network-hardening state marker must be present exactly once' \
  "${test_dir}/missing.json"

printf 'Ordinary workload network-hardening stage tests passed.\n'
