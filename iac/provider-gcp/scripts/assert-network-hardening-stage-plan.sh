#!/usr/bin/env bash
set -euo pipefail

plan_path="${1:?usage: assert-network-hardening-stage-plan.sh PLAN TERRAFORM_BIN STAGE [RECOVERY_STAGE] [REFRESH_STAGE] [PROJECT PREFIX]}"
terraform_bin="${2:-terraform}"
stage="${3:?usage: assert-network-hardening-stage-plan.sh PLAN TERRAFORM_BIN STAGE [RECOVERY_STAGE] [REFRESH_STAGE] [PROJECT PREFIX]}"
recovery_stage="${4:-}"
refresh_stage="${5:-}"
expected_project="${6:-${GCP_PROJECT_ID:-}}"
expected_prefix="${7:-${PREFIX:-}}"

[[ "${expected_project}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || {
  printf 'Expected GCP project is required and must be canonical.\n' >&2
  exit 2
}
[[ "${expected_prefix}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?-$ ]] || {
  printf 'Expected infrastructure prefix is required and must end in a hyphen.\n' >&2
  exit 2
}

case "${stage}" in
  network) previous='disabled' ;;
  server) previous='network' ;;
  api) previous='server' ;;
  worker) previous='api' ;;
  build) previous='worker' ;;
  *)
    printf 'Unknown network-hardening rollout stage: %s\n' "${stage}" >&2
    exit 2
    ;;
esac

if [[ -n "${recovery_stage}" && "${recovery_stage}" != "${stage}" ]]; then
  printf 'Network-hardening recovery context must match the reviewed stage: %s != %s\n' \
    "${recovery_stage}" "${stage}" >&2
  exit 2
fi

if [[ -n "${refresh_stage}" && "${refresh_stage}" != "${stage}" ]]; then
  printf 'Network-hardening refresh context must match the reviewed stage: %s != %s\n' \
    "${refresh_stage}" "${stage}" >&2
  exit 2
fi

if [[ -n "${recovery_stage}" && -n "${refresh_stage}" ]]; then
  printf 'Network-hardening recovery and planned refresh contexts are mutually exclusive.\n' >&2
  exit 2
fi

plan_json="$("${terraform_bin}" show -json "${plan_path}")"
jq -e '.errored != true' <<<"${plan_json}" >/dev/null || {
  printf 'Refusing errored network-hardening plan.\n' >&2
  exit 1
}

guard_address='module.cluster.terraform_data.os_login_operator_access_guard'
case "${stage}" in
  network)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_network'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_network'
    prior_ledger='[]'
    ;;
  server)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_server[0]'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_server[0]'
    prior_ledger='[
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"}
    ]'
    ;;
  api)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_api[0]'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_api[0]'
    prior_ledger='[
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server[0]","input":"server"}
    ]'
    ;;
  worker)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_worker[0]'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_worker[0]'
    prior_ledger='[
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_api[0]","input":"api"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_api[0]","input":"api"}
    ]'
    ;;
  build)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_build[0]'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_build[0]'
    prior_ledger='[
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_api[0]","input":"api"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_api[0]","input":"api"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_worker[0]","input":"worker"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_worker[0]","input":"worker"}
    ]'
    ;;
esac

guard_count="$(jq --arg address "${guard_address}" '[.resource_changes[]? | select(.address == $address)] | length' <<<"${plan_json}")"
[[ "${guard_count}" -eq 1 ]] || {
  printf 'OS Login authorization guard must be present exactly once in the targeted cluster graph.\n' >&2
  exit 1
}
jq -e --arg address "${guard_address}" '
  .resource_changes[]
  | select(.address == $address)
  | .change.after.input == true
    and (
      .change.actions == ["create"]
      or .change.actions == ["no-op"]
      or .change.actions == ["update"]
    )
' <<<"${plan_json}" >/dev/null || {
  printf 'OS Login authorization guard is not explicitly open in the reviewed plan.\n' >&2
  exit 1
}

completion_count="$(jq --arg address "${completion_address}" '[.resource_changes[]? | select(.address == $address)] | length' <<<"${plan_json}")"
[[ "${completion_count}" -eq 1 ]] || {
  printf 'Network-hardening convergence sentinel must be present exactly once.\n' >&2
  exit 1
}
jq -e \
  --arg address "${completion_address}" \
  --arg stage "${stage}" \
  --arg refresh_stage "${refresh_stage}" '
    .resource_changes[]
    | select(.address == $address)
    | .change.after.input == $stage
    and (
      (
        .change.before == null
        and .change.actions == ["create"]
      )
      or (
        .change.before.input == $stage
        and (
          .change.actions == ["delete", "create"]
          or .change.actions == ["create", "delete"]
        )
      )
      or (
        $stage == "network"
        and .change.before.input == "disabled"
        and (
          .change.actions == ["delete", "create"]
          or .change.actions == ["create", "delete"]
        )
      )
    )
    and (
      $refresh_stage != $stage
      or (
        .change.before.input == $stage
        and (
          .change.actions == ["delete", "create"]
          or .change.actions == ["create", "delete"]
        )
      )
    )
  ' <<<"${plan_json}" >/dev/null || {
  printf 'Network-hardening convergence sentinel is not a valid initial or retry transition for %s -> %s.\n' \
    "${previous}" "${stage}" >&2
  exit 1
}

marker_count="$(jq --arg address "${marker_address}" '[.resource_changes[]? | select(.address == $address)] | length' <<<"${plan_json}")"
[[ "${marker_count}" -eq 1 ]] || {
  printf 'Network-hardening state marker must be present exactly once.\n' >&2
  exit 1
}
jq -e \
  --arg address "${marker_address}" \
  --arg stage "${stage}" \
  --arg recovery_stage "${recovery_stage}" \
  --arg refresh_stage "${refresh_stage}" '
    .resource_changes[]
    | select(.address == $address)
    | .change.after.input == $stage
    and (
      if $refresh_stage == $stage then
        .change.before.input == $stage
        and .change.actions == ["no-op"]
      else
        (
          $stage == "network"
          and (.change.before == null or .change.before.input == "disabled")
          and (.change.actions == ["create"] or .change.actions == ["update"])
        )
        or (
          $stage != "network"
          and .change.before == null
          and .change.actions == ["create"]
        )
        or (
          $recovery_stage == $stage
          and .change.before.input == $stage
          and .change.actions == ["no-op"]
        )
      end
    )
  ' <<<"${plan_json}" >/dev/null || {
  printf 'Network-hardening stage must advance exactly %s -> %s, use a validated recovery context, or use an explicit planned same-stage refresh.\n' \
    "${previous}" "${stage}" >&2
  exit 1
}

jq -e --argjson expected "${prior_ledger}" '
  [
    $expected[] as $want
    | [.resource_changes[]? | select(.address == $want.address)] as $matches
    | ($matches | length) == 1
      and $matches[0].change.actions == ["no-op"]
      and $matches[0].change.before.input == $want.input
      and $matches[0].change.after.input == $want.input
  ]
  | all
' <<<"${plan_json}" >/dev/null || {
  printf 'Network-hardening %s stage is missing a clean cumulative prior-stage ledger.\n' \
    "${stage}" >&2
  exit 1
}

case "${stage}" in
  network)
    expected_mutations='[
      "module.cluster.module.network.google_compute_firewall.iap_remote_connection_firewall_ingress[0]",
      "module.cluster.module.network.google_compute_firewall.internal_remote_connection_firewall_ingress",
      "module.cluster.module.network.google_compute_firewall.remote_connection_firewall_ingress"
    ]'
    ;;
  server)
    expected_mutations='[
      "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/fetch-gcp-secret.sh\"]",
      "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-consul.sh\"]",
      "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-nomad.sh\"]",
      "module.cluster.google_compute_health_check.server_nomad_check",
      "module.cluster.google_compute_instance_template.server",
      "module.cluster.google_compute_region_instance_group_manager.server_pool"
    ]'
    ;;
  api)
    expected_mutations='[
      "module.cluster.google_compute_instance_group_manager.api_pool",
      "module.cluster.google_compute_instance_template.api"
    ]'
    ;;
  worker)
    expected_mutations='[
      "module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template",
      "module.cluster.module.client_cluster[\"default\"].google_compute_region_instance_group_manager.pool"
    ]'
    ;;
  build)
    expected_mutations='[
      "module.cluster.google_compute_instance_group_manager.clickhouse_pool",
      "module.cluster.google_compute_instance_group_manager.loki_pool",
      "module.cluster.google_compute_instance_template.clickhouse",
      "module.cluster.google_compute_instance_template.loki",
      "module.cluster.module.build_cluster[\"default\"].google_compute_instance_template.template",
      "module.cluster.module.build_cluster[\"default\"].google_compute_region_instance_group_manager.pool"
    ]'
    ;;
esac

server_member="serviceAccount:${expected_prefix}nomad-server@${expected_project}.iam.gserviceaccount.com"
worker_member="serviceAccount:${expected_prefix}infra-instances@${expected_project}.iam.gserviceaccount.com"
data_member="serviceAccount:${expected_prefix}data-node@${expected_project}.iam.gserviceaccount.com"
api_member="serviceAccount:${expected_prefix}api-controller@${expected_project}.iam.gserviceaccount.com"
secret_base="projects/${expected_project}/secrets/${expected_prefix}"

server_iam_expected="$(jq -cn \
  --arg base "${secret_base}" \
  --arg member "${server_member}" '
    ["consul-secret-id", "nomad-secret-id", "consul-gossip-key"]
    | map(
        ($base + .) as $secret
        | {
            address:("module.cluster.google_secret_manager_secret_iam_member.bootstrap_server[" + ($secret | @json) + "]"),
            project:($base | split("/")[1]),
            secret_id:$secret,
            member:$member
          }
      )
  ')"
worker_iam_expected="$(jq -cn \
  --arg base "${secret_base}" \
  --arg member "${worker_member}" '
    ["nomad-secret-id"]
    | map(
        ($base + .) as $secret
        | {
            address:("module.cluster.google_secret_manager_secret_iam_member.bootstrap_worker[" + ($secret | @json) + "]"),
            project:($base | split("/")[1]),
            secret_id:$secret,
            member:$member
          }
      )
  ')"
data_iam_expected="$(jq -cn \
  --arg base "${secret_base}" \
  --arg member "${data_member}" '
    ["consul-secret-id", "consul-gossip-key", "consul-dns-request-token"]
    | map(
        ($base + .) as $secret
        | {
            address:("module.cluster.google_secret_manager_secret_iam_member.bootstrap_data[" + ($secret | @json) + "]"),
            project:($base | split("/")[1]),
            secret_id:$secret,
            member:$member
          }
      )
  ')"
api_iam_expected="$(jq -cn \
  --arg base "${secret_base}" \
  --arg member "${api_member}" '
    ["consul-secret-id", "consul-gossip-key", "consul-dns-request-token"]
    | map(
        ($base + .) as $secret
        | {
            address:("module.cluster.google_secret_manager_secret_iam_member.bootstrap_api[" + ($secret | @json) + "]"),
            project:($base | split("/")[1]),
            secret_id:$secret,
            member:$member
          }
      )
  ')"

case "${stage}" in
  network)
    bootstrap_iam_expected='[]'
    ;;
  server)
    bootstrap_iam_expected="$(jq -c 'map(. + {shape:"create-or-no-op"})' <<<"${server_iam_expected}")"
    ;;
  api)
    bootstrap_iam_expected="$(jq -cn \
      --argjson server "${server_iam_expected}" \
      --argjson api "${api_iam_expected}" \
      '($server | map(. + {shape:"no-op"})) + ($api | map(. + {shape:"create-or-no-op"}))')"
    ;;
  worker)
    bootstrap_iam_expected="$(jq -cn \
      --argjson server "${server_iam_expected}" \
      --argjson api "${api_iam_expected}" \
      --argjson worker "${worker_iam_expected}" \
      '($server + $api | map(. + {shape:"no-op"})) + ($worker | map(. + {shape:"create-or-no-op"}))')"
    ;;
  build)
    bootstrap_iam_expected="$(jq -cn \
      --argjson server "${server_iam_expected}" \
      --argjson api "${api_iam_expected}" \
      --argjson worker "${worker_iam_expected}" \
      --argjson data "${data_iam_expected}" \
      '($server + $api + $worker | map(. + {shape:"no-op"})) + ($data | map(. + {shape:"create-or-no-op"}))')"
    ;;
esac

bootstrap_iam_changes="$(jq -cS '
  [
    .resource_changes[]?
    | select(.mode == "managed")
    | select(.address | startswith("module.cluster.google_secret_manager_secret_iam_member.bootstrap_"))
  ]
' <<<"${plan_json}")"

jq -e \
  --argjson expected "${bootstrap_iam_expected}" '
    def exact($value; $want):
      $value != null
      and $value.project == $want.project
      and $value.secret_id == $want.secret_id
      and $value.role == "roles/secretmanager.secretAccessor"
      and $value.member == $want.member;
    . as $actual
    | ($actual | length) == ($expected | length)
    and all($expected[];
      . as $want
      | [$actual[] | select(.address == $want.address)] as $matches
      | ($matches | length) == 1
        and $matches[0].type == "google_secret_manager_secret_iam_member"
        and exact($matches[0].change.after; $want)
        and (
          if $want.shape == "no-op" then
            $matches[0].change.actions == ["no-op"]
            and exact($matches[0].change.before; $want)
          else
            (
              $matches[0].change.actions == ["create"]
              and $matches[0].change.before == null
            )
            or (
              $matches[0].change.actions == ["no-op"]
              and exact($matches[0].change.before; $want)
            )
          end
        )
    )
  ' <<<"${bootstrap_iam_changes}" >/dev/null || {
  printf 'Refusing %s stage: bootstrap IAM is not the exact project, identity, secret set, count, and safe stage shape.\n' \
    "${stage}" >&2
  exit 1
}

# A create-before-destroy content-addressed object can remain deposed if a
# prior apply is interrupted after publishing the new object. ABANDON makes
# Terraform's pending delete state-only. Admit that cleanup in the next exact
# stage only when the current object is a byte-for-byte no-op in the same
# bucket and both object names/sources remain bound to the reviewed script.
jq -e '
  def object_contract($address):
    if $address == "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/fetch-gcp-secret.sh\"]" then
      {name:"fetch-gcp-secret", source:"nomad-cluster/scripts/fetch-gcp-secret.sh"}
    elif $address == "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-consul.sh\"]" then
      {name:"run-consul", source:"nomad-cluster/scripts/run-consul.sh"}
    elif $address == "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-nomad.sh\"]" then
      {name:"run-nomad", source:"nomad-cluster/scripts/run-nomad.sh"}
    else null end;
  def current_for($plan; $address):
    [
      $plan.resource_changes[]?
      | select(.address == $address and .deposed == null)
    ];
  . as $plan
  | [
      $plan.resource_changes[]?
      | select(.mode == "managed")
      | select(.deposed != null)
      | select(.address | startswith("module.cluster.google_storage_bucket_object.setup_config_objects["))
    ] as $deposed
  | ($deposed | length) <= 3
  and ([$deposed[].address] | unique | length) == ($deposed | length)
  and all($deposed[];
    . as $old
    | object_contract($old.address) as $contract
    | current_for($plan; $old.address) as $current
    | $contract != null
      and ($old.deposed | test("^[0-9a-f]{8}$"))
      and $old.type == "google_storage_bucket_object"
      and $old.change.actions == ["delete"]
      and $old.change.after == null
      and $old.change.before.deletion_policy == "ABANDON"
      and ($old.change.before.name | test("^" + $contract.name + "-[0-9a-f]{5}\\.sh$"))
      and ($old.change.before.source | endswith($contract.source))
      and ($current | length) == 1
      and $current[0].type == "google_storage_bucket_object"
      and $current[0].change.actions == ["no-op"]
      and $current[0].change.before == $current[0].change.after
      and $current[0].change.after.deletion_policy == "ABANDON"
      and $current[0].change.after.bucket == $old.change.before.bucket
      and ($current[0].change.after.name | test("^" + $contract.name + "-[0-9a-f]{5}\\.sh$"))
      and ($current[0].change.after.source | endswith($contract.source))
  )
' <<<"${plan_json}" >/dev/null || {
  printf 'Refusing %s stage: deposed setup object is not an exact ABANDON state-only cleanup beside one current no-op.\n' \
    "${stage}" >&2
  exit 1
}

actual_mutations="$(jq -cS \
  --arg guard "${guard_address}" \
  --arg completion "${completion_address}" \
  --arg marker "${marker_address}" '
    [
      .resource_changes[]?
      | select(.mode == "managed")
      | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | select(.address != $guard and .address != $completion and .address != $marker)
      | select(.address | startswith("module.cluster.google_secret_manager_secret_iam_member.bootstrap_") | not)
      | select(
          (
            .deposed != null
            and (.address | startswith("module.cluster.google_storage_bucket_object.setup_config_objects["))
          )
          | not
        )
      | .address
    ]
    | sort
  ' <<<"${plan_json}")"
expected_mutations="$(jq -cS 'sort' <<<"${expected_mutations}")"
unexpected_mutations="$(jq -cn \
  --argjson actual "${actual_mutations}" \
  --argjson allowed "${expected_mutations}" \
  '$actual - $allowed')"
if [[ "$(jq 'length' <<<"${unexpected_mutations}")" -ne 0 ]]; then
  printf 'Refusing %s stage: mutation set escapes its exact reviewed pool boundary.\n' \
    "${stage}" >&2
  printf 'Allowed: %s\nActual:  %s\n' "${expected_mutations}" "${actual_mutations}" >&2
  exit 1
fi

if [[ "${stage}" == "server" ]]; then
  jq -e '
    [
      .resource_changes[]?
      | select(
          .address
          == "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-nomad.sh\"]"
        )
      | select(.deposed == null)
    ] as $matches
    | ($matches | length) == 1
      and $matches[0].mode == "managed"
      and $matches[0].type == "google_storage_bucket_object"
      and (
        $matches[0].change.actions == ["no-op"]
        or (
          (
            $matches[0].change.actions == ["create"]
            or
            $matches[0].change.actions == ["create", "delete"]
            or $matches[0].change.actions == ["delete", "create"]
          )
          and (
            (
              $matches[0].change.actions == ["create"]
              and $matches[0].change.before == null
            )
            or ($matches[0].change.before.name | test("^run-nomad-[0-9a-f]{5}\\.sh$"))
          )
          and ($matches[0].change.after.name | test("^run-nomad-[0-9a-f]{5}\\.sh$"))
          and ($matches[0].change.after.source | endswith("nomad-cluster/scripts/run-nomad.sh"))
        )
      )
  ' <<<"${plan_json}" >/dev/null || {
    printf 'Refusing server stage: the exact restart-safe Nomad bootstrap object is missing or unsafe.\n' >&2
    exit 1
  }

  jq -e '
    def one($address):
      [.resource_changes[]? | select(.address == $address)]
      | if length == 1 then .[0] else null end;
    def field_unknown($resource; $field):
      any(
        ($resource.change.after_unknown // {} | .. | objects);
        has($field) and .[$field] == true
      );
    def container_unknown($resource; $container):
      any(
        ($resource.change.after_unknown[$container] // false | ..);
        . == true
      );
    def normalize_compute_resource_id:
      if type == "string" then
        sub("^https://www.googleapis.com/compute/(v1|beta)/"; "")
        | sub("^https://compute.googleapis.com/compute/(v1|beta)/"; "")
        | sub("^//compute.googleapis.com/"; "")
      else
        .
      end;
    one("module.cluster.google_compute_health_check.server_nomad_check") as $health
    | one("module.cluster.google_compute_region_instance_group_manager.server_pool") as $server
    | $health != null
      and $health.type == "google_compute_health_check"
      and ($health.change.actions | index("delete") | not)
      and (field_unknown($health; "id") | not)
      and ($health.change.after.id | type) == "string"
      and (
        $health.change.after.id
        | normalize_compute_resource_id
        | test("^projects/[^/]+/global/healthChecks/[^/]+$")
      )
      and (field_unknown($health; "check_interval_sec") | not)
      and (field_unknown($health; "timeout_sec") | not)
      and (field_unknown($health; "healthy_threshold") | not)
      and (field_unknown($health; "unhealthy_threshold") | not)
      and (container_unknown($health; "http_health_check") | not)
      and $health.change.after.check_interval_sec == 5
      and $health.change.after.timeout_sec == 5
      and $health.change.after.healthy_threshold == 2
      and $health.change.after.unhealthy_threshold == 10
      and ($health.change.after.http_health_check | length) == 1
      and $health.change.after.http_health_check[0].port == 50001
      and $health.change.after.http_health_check[0].request_path == "/healthz"
      and $server != null
      and ($server.change.actions | index("delete") | not)
      and ($server.change.after.distribution_policy_zones | type) == "array"
      and (field_unknown($server; "distribution_policy_zones") | not)
      and ($server.change.after.distribution_policy_zones | length) >= 1
      and ($server.change.after.update_policy | length) == 1
      and (container_unknown($server; "update_policy") | not)
      and $server.change.after.update_policy[0].replacement_method == "SUBSTITUTE"
      and $server.change.after.update_policy[0].max_unavailable_fixed == 0
      and ($server.change.after.update_policy[0].max_unavailable_percent // 0) == 0
      and $server.change.after.update_policy[0].max_surge_fixed
        >= ($server.change.after.distribution_policy_zones | length)
      and ($server.change.after.auto_healing_policies | length) == 1
      and (container_unknown($server; "auto_healing_policies") | not)
      and ($server.change.after.auto_healing_policies[0].health_check | type) == "string"
      and (
        $server.change.after.auto_healing_policies[0].health_check
        | normalize_compute_resource_id
      ) == ($health.change.after.id | normalize_compute_resource_id)
      and $server.change.after.auto_healing_policies[0].initial_delay_sec == 120
      and ($server.change.after.instance_lifecycle_policy | length) == 1
      and (container_unknown($server; "instance_lifecycle_policy") | not)
      and $server.change.after.instance_lifecycle_policy[0].default_action_on_failure == "REPAIR"
      and $server.change.after.instance_lifecycle_policy[0].force_update_on_repair == "NO"
      and $server.change.after.instance_lifecycle_policy[0].on_failed_health_check == "DO_NOTHING"
  ' <<<"${plan_json}" >/dev/null || {
    printf 'Refusing server stage: local-voter health, substitute rollout, or zone-surge invariants are unsafe.\n' >&2
    exit 1
  }
  for setup_object in \
    'fetch-gcp-secret|scripts/fetch-gcp-secret.sh' \
    'run-consul|scripts/run-consul.sh'; do
    object_name="${setup_object%%|*}"
    object_source="${setup_object#*|}"
    object_address="module.cluster.google_storage_bucket_object.setup_config_objects[\"${object_source}\"]"
    jq -e \
      --arg address "${object_address}" \
      --arg object_name "${object_name}" \
      --arg source "nomad-cluster/${object_source}" '
        [.resource_changes[]? | select(.address == $address and .deposed == null)] as $matches
        | ($matches | length) == 1
          and $matches[0].mode == "managed"
          and $matches[0].type == "google_storage_bucket_object"
          and (
            $matches[0].change.actions == ["no-op"]
            or (
              (
                $matches[0].change.actions == ["create"]
                or $matches[0].change.actions == ["create", "delete"]
                or $matches[0].change.actions == ["delete", "create"]
              )
              and (
                ($matches[0].change.actions == ["create"] and $matches[0].change.before == null)
                or ($matches[0].change.before.name | test("^" + $object_name + "-[0-9a-f]{5}\\.sh$"))
              )
              and ($matches[0].change.after.name | test("^" + $object_name + "-[0-9a-f]{5}\\.sh$"))
              and ($matches[0].change.after.source | endswith($source))
            )
          )
      ' <<<"${plan_json}" >/dev/null || {
      printf 'Refusing server stage: bootstrap object %s is missing or unsafe.\n' \
        "${object_name}" >&2
      exit 1
    }
  done
fi

if [[ "${stage}" == "network" ]]; then
  jq -e '
    def ports($rule):
      [$rule[]? | select(.protocol == "tcp") | .ports[]?] | sort;
    def logged:
      (.log_config | length) == 1
      and .log_config[0].metadata == "EXCLUDE_ALL_METADATA";
    def after($address):
      [.resource_changes[]? | select(.address == $address)]
      | if length == 1 then .[0].change.after else null end;
    after("module.cluster.module.network.google_compute_firewall.iap_remote_connection_firewall_ingress[0]") as $iap
    | after("module.cluster.module.network.google_compute_firewall.remote_connection_firewall_ingress") as $deny
    | after("module.cluster.module.network.google_compute_firewall.internal_remote_connection_firewall_ingress") as $legacy
    | $iap != null
      and $iap.direction == "INGRESS"
      and $iap.priority == 700
      and ($iap.source_ranges | sort) == ["35.235.240.0/20"]
      and ($iap.target_tags | sort) == ["orch"]
      and ports($iap.allow) == ["22", "3389"]
      and (($iap.deny // []) | length) == 0
      and ($iap | logged)
      and $deny != null
      and $deny.direction == "INGRESS"
      and $deny.priority == 800
      and ($deny.source_ranges | sort) == ["0.0.0.0/0"]
      and ($deny.target_tags | sort) == ["orch"]
      and ports($deny.deny) == ["22", "3389"]
      and (($deny.allow // []) | length) == 0
      and ($deny | logged)
      and $legacy != null
      and $legacy.direction == "INGRESS"
      and $legacy.priority == 900
      and ($legacy.source_ranges | sort) == ["0.0.0.0/0", "35.235.240.0/20"]
      and ($legacy.target_tags | sort) == ["orch"]
      and ports($legacy.allow) == ["22", "3389"]
      and (($legacy.deny // []) | length) == 0
      and ($legacy | logged)
  ' <<<"${plan_json}" >/dev/null || {
    printf 'Refusing network stage: firewall precedence or exact rule semantics are unsafe.\n' >&2
    exit 1
  }
fi

# A failed apply can already have committed a template or MIG update while the
# downstream convergence sentinel and stage marker remain at the previous
# stage. Accept any mutation subset inside this stage's boundary so that the
# same reviewed stage can be retried, while still rejecting rollback, skips,
# later-pool changes, and generic-autoscaler ownership changes.

# The cumulative dependency chain pulls every completed template into the
# exact-stage plan while keeping future pools out. Re-prove OS Login intent for
# all prior/current templates and reject any mutation outside the current pool.
template_expectations="$(jq -cn \
  --arg stage "${stage}" \
  --arg project "${expected_project}" \
  --arg prefix "${expected_prefix}" '
  if $stage == "network" then []
  elif $stage == "server" then [
    {address:"module.cluster.google_compute_instance_template.server",identity:($prefix + "nomad-server@" + $project + ".iam.gserviceaccount.com"),server:true}
  ]
  elif $stage == "api" then [
    {address:"module.cluster.google_compute_instance_template.server",identity:($prefix + "nomad-server@" + $project + ".iam.gserviceaccount.com"),server:true},
    {address:"module.cluster.google_compute_instance_template.api",identity:($prefix + "api-controller@" + $project + ".iam.gserviceaccount.com")}
  ]
  elif $stage == "worker" then [
    {address:"module.cluster.google_compute_instance_template.server",identity:($prefix + "nomad-server@" + $project + ".iam.gserviceaccount.com"),server:true},
    {address:"module.cluster.google_compute_instance_template.api",identity:($prefix + "api-controller@" + $project + ".iam.gserviceaccount.com")},
    {address:"module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template",identity:($prefix + "infra-instances@" + $project + ".iam.gserviceaccount.com")}
  ]
  else [
    {address:"module.cluster.google_compute_instance_template.server",identity:($prefix + "nomad-server@" + $project + ".iam.gserviceaccount.com"),server:true},
    {address:"module.cluster.google_compute_instance_template.api",identity:($prefix + "api-controller@" + $project + ".iam.gserviceaccount.com")},
    {address:"module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template",identity:($prefix + "infra-instances@" + $project + ".iam.gserviceaccount.com")},
    {address:"module.cluster.module.build_cluster[\"default\"].google_compute_instance_template.template",identity:($prefix + "infra-instances@" + $project + ".iam.gserviceaccount.com")},
    {address:"module.cluster.google_compute_instance_template.loki",identity:($prefix + "data-node@" + $project + ".iam.gserviceaccount.com")},
    {address:"module.cluster.google_compute_instance_template.clickhouse",identity:($prefix + "data-node@" + $project + ".iam.gserviceaccount.com")}
  ]
  end
')"
jq -e \
  --argjson expected "${template_expectations}" \
  --arg server_tag "${expected_prefix}nomad-server" '
  [
    $expected[] as $want
    | [ .resource_changes[]? | select(.address == $want.address) ] as $matches
    | ($matches | length) == 1
      and $matches[0].change.after.metadata["enable-oslogin"] == "TRUE"
      and ($matches[0].change.after.service_account | length) == 1
      and $matches[0].change.after.service_account[0].email == $want.identity
      and (
        ($want.server // false) == false
        or ($matches[0].change.after.tags | index($server_tag)) != null
      )
  ]
  | all
' <<<"${plan_json}" >/dev/null || {
  printf 'Refusing %s stage: cumulative template identity, server discovery tag, or OS Login intent is incomplete.\n' \
    "${stage}" >&2
  exit 1
}

printf 'Network-hardening stage plan passed: %s (%s -> %s).\n' \
  "${stage}" "${previous}" "${stage}"
