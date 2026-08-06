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
  server-safety) previous='network' ;;
  server) previous='server-safety' ;;
  server-health) previous='server' ;;
  api) previous='server-health' ;;
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

environment_guard_address='module.cluster.terraform_data.acl_bootstrap_environment_guard'
guard_address='module.cluster.terraform_data.os_login_operator_access_guard'
handoff_address='module.cluster.terraform_data.consul_management_handoff_candidate[0]'
case "${stage}" in
  network)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_network'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_network'
    prior_ledger='[]'
    ;;
  server-safety)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]'
    prior_ledger='[
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"}
    ]'
    ;;
  server)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]'
    prior_ledger='[
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]","input":"server-safety"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]","input":"server-safety"}
    ]'
    ;;
  server-health)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_server_health[0]'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_server_health[0]'
    prior_ledger='[
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]","input":"server-safety"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]","input":"server-safety"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]","input":"server"}
    ]'
    ;;
  api)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_api[0]'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_api[0]'
    prior_ledger='[
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]","input":"server-safety"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]","input":"server-safety"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_health[0]","input":"server-health"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_health[0]","input":"server-health"}
    ]'
    ;;
  worker)
    completion_address='module.cluster.terraform_data.network_hardening_rollout_completion_worker[0]'
    marker_address='module.cluster.terraform_data.network_hardening_rollout_stage_worker[0]'
    prior_ledger='[
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]","input":"server-safety"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]","input":"server-safety"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_health[0]","input":"server-health"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_health[0]","input":"server-health"},
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
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]","input":"server-safety"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]","input":"server-safety"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]","input":"server"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_health[0]","input":"server-health"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_health[0]","input":"server-health"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_api[0]","input":"api"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_api[0]","input":"api"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_worker[0]","input":"worker"},
      {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_worker[0]","input":"worker"}
    ]'
    ;;
esac

environment_guard_count="$(jq --arg address "${environment_guard_address}" '[.resource_changes[]? | select(.address == $address)] | length' <<<"${plan_json}")"
[[ "${environment_guard_count}" -eq 1 ]] || {
  printf 'ACL bootstrap environment guard must be present exactly once in the targeted cluster graph.\n' >&2
  exit 1
}
jq -e --arg address "${environment_guard_address}" '
  .resource_changes[]
  | select(.address == $address)
  | .change.after.input == "dev"
    and (
      .change.actions == ["create"]
      or .change.actions == ["no-op"]
      or .change.actions == ["update"]
    )
' <<<"${plan_json}" >/dev/null || {
  printf 'ACL bootstrap environment guard is not explicitly restricted to dev in the reviewed plan.\n' >&2
  exit 1
}

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
      or (
        $stage == "server-safety"
        and .change.before.input == "server"
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
          $stage == "server-safety"
          and .change.before.input == "server"
          and .change.actions == ["update"]
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

if [[ "${stage}" == "network" || "${stage}" == "server-safety" ]]; then
  if jq -e --arg address "${handoff_address}" \
    'any(.resource_changes[]?; .address == $address)' <<<"${plan_json}" >/dev/null; then
    printf 'Pre-template server stage must not claim the Consul management handoff marker.\n' >&2
    exit 1
  fi
else
  jq -e \
    --arg address "${handoff_address}" \
    --arg candidate_ref_prefix "projects/${expected_project}/secrets/${expected_prefix}consul-management-candidate-token/versions/" \
    --arg stage "${stage}" '
      [.resource_changes[]? | select(.address == $address)] as $handoff
      | ($handoff | length) == 1
        and $handoff[0].type == "terraform_data"
        and $handoff[0].change.after.input.phase == "candidate"
        and $handoff[0].change.after.input.server_stage == "server"
        and ($handoff[0].change.after.input.candidate_ref | startswith($candidate_ref_prefix))
        and ($handoff[0].change.after.input.candidate_ref | test("/versions/[1-9][0-9]*$"))
        and (
          if $stage == "server" then
            $handoff[0].change.actions == ["create"]
            and $handoff[0].change.before == null
          else
            $handoff[0].change.actions == ["no-op"]
            and $handoff[0].change.before == $handoff[0].change.after
          end
        )
    ' <<<"${plan_json}" >/dev/null || {
    printf 'Consul management candidate handoff must be a state-backed server transition and immutable thereafter.\n' >&2
    exit 1
  }
fi

case "${stage}" in
  network)
    expected_mutations='[
      "module.cluster.module.network.google_compute_firewall.iap_remote_connection_firewall_ingress[0]",
      "module.cluster.module.network.google_compute_firewall.internal_remote_connection_firewall_ingress",
      "module.cluster.module.network.google_compute_firewall.remote_connection_firewall_ingress"
    ]'
    ;;
  server-safety)
    expected_mutations='[
      "module.cluster.google_compute_health_check.server_voter_check",
      "module.cluster.terraform_data.server_mig_safety_policy[0]"
    ]'
    ;;
  server)
    expected_mutations='[
      "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/fetch-gcp-secret.sh\"]",
      "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-consul.sh\"]",
      "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-nomad.sh\"]",
      "module.cluster.google_compute_instance_template.server",
      "module.cluster.google_compute_region_instance_group_manager.server_pool"
    ]'
    ;;
  server-health)
    expected_mutations='[
      "module.cluster.google_compute_region_instance_group_manager.server_pool"
    ]'
    ;;
  api)
    expected_mutations='[
      "module.cluster.google_compute_health_check.server_nomad_check_legacy[0]",
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
    [
      {key:"consul_management_candidate",secret:"consul-management-candidate-token"},
      {key:"nomad_management",secret:"nomad-secret-id"},
      {key:"consul_gossip",secret:"consul-gossip-key"},
      {key:"consul_catalog_read",secret:"consul-catalog-read-token"},
      {key:"consul_nomad_client_sync",secret:"consul-nomad-client-sync-token"},
      {key:"consul_worker_autoscaler",secret:"consul-worker-autoscaler-token"}
    ]
    | map(
        . as $entry
        | ($base + $entry.secret) as $secret
        | {
            address:("module.cluster.google_secret_manager_secret_iam_member.bootstrap_server[" + ($entry.key | @json) + "]"),
            project:($base | split("/")[1]),
            secret_id:$secret,
            member:$member
          }
      )
  ')"
worker_iam_expected="$(jq -cn \
  --arg base "${secret_base}" \
  --arg member "${worker_member}" '
    []
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
    [
      {key:"consul_gossip",secret:"consul-gossip-key"},
      {key:"consul_catalog_read",secret:"consul-catalog-read-token"},
      {key:"consul_nomad_client_sync",secret:"consul-nomad-client-sync-token"}
    ]
    | map(
        . as $entry
        | ($base + $entry.secret) as $secret
        | {
            address:("module.cluster.google_secret_manager_secret_iam_member.bootstrap_data[" + ($entry.key | @json) + "]"),
            project:($base | split("/")[1]),
            secret_id:$secret,
            member:$member
          }
      )
  ')"
api_iam_expected="$(jq -cn \
  --arg base "${secret_base}" \
  --arg member "${api_member}" '
    [
      {key:"consul_gossip",secret:"consul-gossip-key"},
      {key:"consul_catalog_read",secret:"consul-catalog-read-token"},
      {key:"consul_nomad_client_sync",secret:"consul-nomad-client-sync-token"}
    ]
    | map(
        . as $entry
        | ($base + $entry.secret) as $secret
        | {
            address:("module.cluster.google_secret_manager_secret_iam_member.bootstrap_api[" + ($entry.key | @json) + "]"),
            project:($base | split("/")[1]),
            secret_id:$secret,
            member:$member
          }
      )
  ')"

case "${stage}" in
  network | server-safety)
    bootstrap_iam_expected='[]'
    ;;
  server)
    bootstrap_iam_expected="$(jq -c 'map(. + {shape:"create-or-no-op"})' <<<"${server_iam_expected}")"
    ;;
  server-health)
    bootstrap_iam_expected="$(jq -c 'map(. + {shape:"no-op"})' <<<"${server_iam_expected}")"
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
      and ($old.change.before.name | test("^" + $contract.name + "-[0-9a-f]{5}([0-9a-f]{59})?\\.sh$"))
      and ($old.change.before.source | endswith($contract.source))
      and ($current | length) == 1
      and $current[0].type == "google_storage_bucket_object"
      and $current[0].change.actions == ["no-op"]
      and $current[0].change.before == $current[0].change.after
      and $current[0].change.after.deletion_policy == "ABANDON"
      and $current[0].change.after.bucket == $old.change.before.bucket
      and ($current[0].change.after.name | test("^" + $contract.name + "-[0-9a-f]{64}\\.sh$"))
      and ($current[0].change.after.source | endswith($contract.source))
  )
' <<<"${plan_json}" >/dev/null || {
  printf 'Refusing %s stage: deposed setup object is not an exact ABANDON state-only cleanup beside one current no-op.\n' \
    "${stage}" >&2
  exit 1
}

actual_mutations="$(jq -cS \
  --arg guard "${guard_address}" \
  --arg environment_guard "${environment_guard_address}" \
  --arg handoff "${handoff_address}" \
  --arg completion "${completion_address}" \
  --arg marker "${marker_address}" '
    [
      .resource_changes[]?
      | select(.mode == "managed")
      | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | select(.address != $guard and .address != $environment_guard and .address != $handoff and .address != $completion and .address != $marker)
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
            or ($matches[0].change.before.name | test("^run-nomad-[0-9a-f]{5}([0-9a-f]{59})?\\.sh$"))
          )
          and ($matches[0].change.after.name | test("^run-nomad-[0-9a-f]{64}\\.sh$"))
          and ($matches[0].change.after.source | endswith("nomad-cluster/scripts/run-nomad.sh"))
        )
      )
  ' <<<"${plan_json}" >/dev/null || {
    printf 'Refusing server stage: the exact restart-safe Nomad bootstrap object is missing or unsafe.\n' >&2
    exit 1
  }

fi

if [[ "${stage}" == "server-safety" ]]; then
  jq -e \
    --arg project "${expected_project}" \
    --arg prefix "${expected_prefix}" '
      def one($address):
        [.resource_changes[]? | select(.address == $address)]
        | if length == 1 then .[0] else null end;
      def exact_http_check($resource; $port; $path):
        $resource != null
        and $resource.type == "google_compute_health_check"
        and ($resource.change.actions | index("delete") | not)
        and $resource.change.after.check_interval_sec == 5
        and $resource.change.after.timeout_sec == 5
        and $resource.change.after.healthy_threshold == 2
        and $resource.change.after.unhealthy_threshold == 10
        and ($resource.change.after.http_health_check | length) == 1
        and $resource.change.after.http_health_check[0].port == $port
        and $resource.change.after.http_health_check[0].request_path == $path;
      one("module.cluster.google_compute_health_check.server_nomad_check_legacy[0]") as $legacy
      | one("module.cluster.google_compute_health_check.server_voter_check") as $strict
      | one("module.cluster.terraform_data.server_mig_safety_policy[0]") as $safety
      | exact_http_check($legacy; 4646; "/v1/agent/health")
        and exact_http_check($strict; 50001; "/healthz")
        and $safety != null
        and $safety.type == "terraform_data"
        and ($safety.change.actions == ["create"]
          or $safety.change.actions == ["delete", "create"]
          or $safety.change.actions == ["create", "delete"])
        and $safety.change.after.input.phase == "server-safety"
        and $safety.change.after.input.gcp_project_id == $project
        and $safety.change.after.input.server_pool == ($prefix + "orch-server-rig")
        and $safety.change.after.input.legacy_health_check == ($prefix + "orch-server-nomad-check")
        and $safety.change.after.input.strict_health_check == ($prefix + "orch-server-voter-check")
        and $safety.change.after.input.expected_cluster_size == 3
        and ($safety.change.after.input.script_sha256 | test("^[0-9a-f]{64}$"))
    ' <<<"${plan_json}" >/dev/null || {
    printf 'Refusing server-safety stage: exact legacy/strict checks or bounded MIG safety transition is missing.\n' >&2
    exit 1
  }
fi

if [[ "${stage}" == "server" || "${stage}" == "server-health" ]]; then

  jq -e --arg stage "${stage}" '
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
    def exact_http_check($resource; $port; $path):
      $resource != null
      and $resource.type == "google_compute_health_check"
      and ($resource.change.actions | index("delete") | not)
      and (field_unknown($resource; "check_interval_sec") | not)
      and (field_unknown($resource; "timeout_sec") | not)
      and (field_unknown($resource; "healthy_threshold") | not)
      and (field_unknown($resource; "unhealthy_threshold") | not)
      and (container_unknown($resource; "http_health_check") | not)
      and $resource.change.after.check_interval_sec == 5
      and $resource.change.after.timeout_sec == 5
      and $resource.change.after.healthy_threshold == 2
      and $resource.change.after.unhealthy_threshold == 10
      and ($resource.change.after.http_health_check | length) == 1
      and $resource.change.after.http_health_check[0].port == $port
      and $resource.change.after.http_health_check[0].request_path == $path;
    one("module.cluster.google_compute_health_check.server_nomad_check_legacy[0]") as $legacy
    | one("module.cluster.google_compute_health_check.server_voter_check") as $strict
    | one("module.cluster.google_compute_region_instance_group_manager.server_pool") as $server
    | exact_http_check($legacy; 4646; "/v1/agent/health")
      and exact_http_check($strict; 50001; "/healthz")
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
      and $server.change.after.update_policy[0].max_surge_fixed == 1
      and ($server.change.after.update_policy[0].max_surge_percent // 0) == 0
      and $server.change.after.update_policy[0].min_ready_sec == 120
      and ($server.change.after.auto_healing_policies | length) == 1
      and (container_unknown($server; "auto_healing_policies") | not)
      and ($server.change.after.auto_healing_policies[0].health_check | type) == "string"
      and (
        $server.change.after.auto_healing_policies[0].health_check
        | normalize_compute_resource_id
        | endswith(
            if $stage == "server-health"
            then "/global/healthChecks/" + $strict.change.after.name
            else "/global/healthChecks/" + $legacy.change.after.name
            end
          )
      )
      and $server.change.after.auto_healing_policies[0].initial_delay_sec == 120
      and ($server.change.after.instance_lifecycle_policy | length) == 1
      and (container_unknown($server; "instance_lifecycle_policy") | not)
      and $server.change.after.instance_lifecycle_policy[0].default_action_on_failure == "REPAIR"
      and $server.change.after.instance_lifecycle_policy[0].force_update_on_repair == "NO"
      and $server.change.after.instance_lifecycle_policy[0].on_failed_health_check == "DO_NOTHING"
      and (
        if $stage == "server-safety" or $stage == "server-health" then
          ($server.change.before.version | length) == 1
          and ($server.change.after.version | length) == 1
          and $server.change.before.version[0].instance_template
            == $server.change.after.version[0].instance_template
          and (container_unknown($server; "version") | not)
        else true end
      )
  ' <<<"${plan_json}" >/dev/null || {
    printf 'Refusing %s stage: three-phase server health, substitute rollout, or one-surge invariants are unsafe.\n' "${stage}" >&2
    exit 1
  }

fi

if [[ "${stage}" == "server" ]]; then
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
                or ($matches[0].change.before.name | test("^" + $object_name + "-[0-9a-f]{5}([0-9a-f]{59})?\\.sh$"))
              )
              and ($matches[0].change.after.name | test("^" + $object_name + "-[0-9a-f]{64}\\.sh$"))
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
  if $stage == "network" or $stage == "server-safety" then []
  elif $stage == "server" or $stage == "server-health" then [
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
