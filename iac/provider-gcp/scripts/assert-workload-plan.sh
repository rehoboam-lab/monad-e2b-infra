#!/usr/bin/env bash
set -euo pipefail

plan_path="${1:?usage: assert-workload-plan.sh PLAN_PATH [TERRAFORM_BIN] [POLICY_PATH]}"
terraform_bin="${2:-terraform}"
policy_path="${3:-$(dirname "${BASH_SOURCE[0]}")/../topology/minimal-workload-policy.json}"

command -v jq >/dev/null 2>&1 || {
  printf 'jq is required to inspect the saved workload plan.\n' >&2
  exit 1
}

[[ -f "${plan_path}" ]] || {
  printf 'Saved workload plan does not exist: %s\n' "${plan_path}" >&2
  exit 1
}

[[ -f "${policy_path}" ]] || {
  printf 'Workload topology policy does not exist: %s\n' "${policy_path}" >&2
  exit 1
}

policy_json="$(jq -c . "${policy_path}")"

jq -e '
  (.expected_role_max_instances | keys | sort)
    == ["api", "build", "clickhouse", "client", "loki", "server"]
  and (
    .expected_role_max_instances
    | all(.[]; type == "number" and . >= 0 and floor == .)
  )
  and (.max_worker_surge_per_pool | type == "number" and . >= 0 and floor == .)
  and (.planning_instance_quota | type == "number" and . > 0 and floor == .)
  and (.required_instance_headroom | type == "number" and . >= 0 and floor == .)
  and .required_instance_headroom < .planning_instance_quota
' <<<"${policy_json}" >/dev/null || {
  printf 'Workload topology policy is invalid: %s\n' "${policy_path}" >&2
  exit 1
}

plan_json="$("${terraform_bin}" show -json "${plan_path}")"

jq -e '.errored != true' <<<"${plan_json}" >/dev/null || {
  printf 'Refusing workload plan: Terraform recorded an errored plan.\n' >&2
  exit 1
}

topology="$(
  jq -c --argjson expected "${policy_json}" '
    def managed_changes:
      [
        .resource_changes[]?
        | select(.mode == "managed")
      ];

    def is_mig:
      .type == "google_compute_instance_group_manager"
      or .type == "google_compute_region_instance_group_manager";

    def role:
      if .type == "google_compute_region_instance_group_manager" and .name == "server_pool" then
        "server"
      elif .type == "google_compute_instance_group_manager" and .name == "api_pool" then
        "api"
      elif .type == "google_compute_instance_group_manager" and .name == "clickhouse_pool" then
        "clickhouse"
      elif .type == "google_compute_instance_group_manager" and .name == "loki_pool" then
        "loki"
      elif .type == "google_compute_region_instance_group_manager"
        and .name == "pool"
        and (.address | contains(".module.build_cluster[")) then
        "build"
      elif .type == "google_compute_region_instance_group_manager"
        and .name == "pool"
        and (.address | contains(".module.client_cluster[")) then
        "client"
      else
        null
      end;

    def autoscaler_address($address):
      $address
      | sub(
          "\\.google_compute_region_instance_group_manager\\.pool$";
          ".google_compute_region_autoscaler.autoscaler[0]"
        );

    def unknown_field($resource; $field):
      any(
        ($resource.change.after_unknown // {} | .. | objects);
        has($field) and .[$field] == true
      );

    def capacity($resource; $changes):
      if unknown_field($resource; "target_size") then
        null
      elif ($resource.change.after.target_size | type) == "number" then
        $resource.change.after.target_size
      else
        autoscaler_address($resource.address) as $autoscaler_address
        | (
            [
              $changes[]
              | select(.address == $autoscaler_address)
              | select((.change.after_unknown.autoscaling_policy // false) != true)
              | select(unknown_field(.; "max_replicas") | not)
              | .change.after.autoscaling_policy[0].max_replicas
            ][0] // null
          )
      end;

    managed_changes as $changes
    | (
        [
          $changes[]
          | select(is_mig)
        ]
      ) as $migs
    | (
        [
          $migs[] as $resource
          | ($resource | role) as $role
          | select($role != null)
          | capacity($resource; $changes) as $capacity
          | {
              address: $resource.address,
              role: $role,
              capacity: $capacity,
              surge: (
                if $capacity == 0 then
                  0
                else
                  ($resource.change.after.update_policy[0].max_surge_fixed // 0)
                end
              ),
              surge_percent: (
                if $capacity == 0 then
                  0
                else
                  ($resource.change.after.update_policy[0].max_surge_percent // 0)
                end
              ),
              surge_unknown: (
                ($resource.change.after_unknown.update_policy // false) == true
                or
                unknown_field($resource; "max_surge_fixed")
                or unknown_field($resource; "max_surge_percent")
              )
            }
        ]
      ) as $rows
    | (
        reduce ($expected.expected_role_max_instances | keys[]) as $role
          ({};
            .[$role] = (
              [
                $rows[]
                | select(.role == $role)
                | .capacity
                | select(type == "number")
              ]
              | add // 0
            )
          )
      ) as $role_max_instances
    | {
        role_max_instances: $role_max_instances,
        base_max_instances: ([$rows[].capacity | select(type == "number")] | add // 0),
        rollout_surge_instances: ([$rows[].surge | select(type == "number")] | add // 0),
        peak_rollout_instances: (
          ([$rows[].capacity | select(type == "number")] | add // 0)
          + ([$rows[].surge | select(type == "number")] | add // 0)
        ),
        destructive_migs: [
          $migs[]
          | select(.change.actions | index("delete"))
          | .address
        ],
        unknown_migs: [
          $migs[]
          | select(role == null)
          | .address
        ],
        unresolved_capacities: [
          $rows[]
          | select((.capacity | type) != "number")
          | .address
        ],
        unresolved_surges: [
          $rows[]
          | select(.capacity != 0 and .surge_unknown)
          | .address
        ],
        invalid_surges: [
          $rows[]
          | select(
              (.surge | type) != "number"
              or .surge < 0
              or (.surge | floor) != .surge
            )
          | {
              address: .address,
              surge: .surge
            }
        ],
        percentage_surges: [
          $rows[]
          | select(.surge_percent != 0)
          | .address
        ],
        worker_surge_violations: [
          $rows[]
          | select(.role == "build" or .role == "client")
          | select(
              (.surge | type) != "number"
              or .surge > $expected.max_worker_surge_per_pool
            )
          | {
              address: .address,
              surge: .surge
            }
        ]
      }
  ' <<<"${plan_json}"
)"

for field in destructive_migs unknown_migs unresolved_capacities unresolved_surges invalid_surges percentage_surges worker_surge_violations; do
  if [[ "$(jq ".${field} | length" <<<"${topology}")" -ne 0 ]]; then
    printf 'Refusing workload plan: %s must be empty.\n' "${field}" >&2
    jq -r ".${field}[]" <<<"${topology}" >&2
    exit 1
  fi
done

expected_clickhouse="$(jq -r '.expected_role_max_instances.clickhouse' <<<"${policy_json}")"
actual_clickhouse="$(jq -r '.role_max_instances.clickhouse' <<<"${topology}")"
if [[ "${actual_clickhouse}" -ne "${expected_clickhouse}" ]]; then
  printf 'Refusing workload plan: ClickHouse maximum instance count is %s; expected %s.\n' \
    "${actual_clickhouse}" "${expected_clickhouse}" >&2
  exit 1
fi

if ! jq -e \
  --argjson expected "$(jq -c '.expected_role_max_instances' <<<"${policy_json}")" \
  '.role_max_instances == $expected' <<<"${topology}" >/dev/null; then
  printf 'Refusing workload plan: role maximum instance counts differ from policy.\n' >&2
  printf 'Expected: %s\n' \
    "$(jq -c '.expected_role_max_instances' <<<"${policy_json}")" >&2
  printf 'Planned:  %s\n' \
    "$(jq -c '.role_max_instances' <<<"${topology}")" >&2
  exit 1
fi

planning_quota="$(jq -r '.planning_instance_quota' <<<"${policy_json}")"
required_headroom="$(jq -r '.required_instance_headroom' <<<"${policy_json}")"
peak_instances="$(jq -r '.peak_rollout_instances' <<<"${topology}")"
maximum_allowed_peak="$((planning_quota - required_headroom))"

if [[ "${peak_instances}" -gt "${maximum_allowed_peak}" ]]; then
  printf 'Refusing workload plan: peak rollout capacity is %s; policy permits at most %s to reserve %s instances of headroom.\n' \
    "${peak_instances}" "${maximum_allowed_peak}" "${required_headroom}" >&2
  exit 1
fi

printf 'Workload plan topology passed: roles=%s base=%s surge=%s peak=%s planning-quota=%s reserved-headroom=%s.\n' \
  "$(jq -c '.role_max_instances' <<<"${topology}")" \
  "$(jq -r '.base_max_instances' <<<"${topology}")" \
  "$(jq -r '.rollout_surge_instances' <<<"${topology}")" \
  "${peak_instances}" \
  "${planning_quota}" \
  "${required_headroom}"
printf 'The quota value is a planning assumption; verify the live regional quota before apply.\n'
