#!/usr/bin/env bash
set -euo pipefail

export GCP_PROJECT_ID="monad-code"
export PREFIX="e2b-"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider_root="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${provider_root}/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

fake_terraform="${test_dir}/terraform"
# These are literal lines in the generated fixture, not parent-shell expansions.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "${1:-}" == "show" && "${2:-}" == "-json" ]] || exit 2' \
  'cat "${3:?missing plan}"' \
  >"${fake_terraform}"
chmod 0755 "${fake_terraform}"

expect_fail() {
  local description="$1"
  shift
  if "$@" >"${test_dir}/stdout" 2>"${test_dir}/stderr"; then
    printf 'expected failure: %s\n' "${description}" >&2
    exit 1
  fi
}

cluster_source="${provider_root}/nomad-cluster/main.tf"
runbook="${repo_root}/docs/MONAD_GCP_NETWORK_HARDENING.md"
grep -F 'resource "terraform_data" "network_hardening_rollout_completion_network"' \
  "${cluster_source}" >/dev/null
grep -F 'command = "\"${abspath("${path.module}/../scripts/wait-network-hardening-stage.sh")}\""' \
  "${cluster_source}" >/dev/null
grep -F 'DOMAIN_NAME                    = var.domain_name' \
  "${cluster_source}" >/dev/null
grep -F 'depends_on = [terraform_data.network_hardening_rollout_completion_network]' \
  "${cluster_source}" >/dev/null
grep -F 'from = terraform_data.network_hardening_rollout_completion' \
  "${cluster_source}" >/dev/null
grep -F 'from = terraform_data.network_hardening_rollout_stage' \
  "${cluster_source}" >/dev/null
grep -A18 -F 'resource "google_storage_bucket_object" "setup_config_objects"' \
  "${cluster_source}" | grep -F 'create_before_destroy = true' >/dev/null
for resource_suffix in network server_safety server_template server_health api worker build; do
  grep -F "resource \"terraform_data\" \"network_hardening_rollout_completion_${resource_suffix}\"" \
    "${cluster_source}" >/dev/null
  grep -F "resource \"terraform_data\" \"network_hardening_rollout_stage_${resource_suffix}\"" \
    "${cluster_source}" >/dev/null
done

expect_fail "saved plan IAM is bound to the externally selected project" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/server.plan" "${fake_terraform}" server '' other-project e2b-
expect_fail "saved plan IAM is bound to the externally selected prefix" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/server.plan" "${fake_terraform}" server '' monad-code other-
for dependency in \
  terraform_data.network_hardening_rollout_stage_network \
  terraform_data.network_hardening_rollout_stage_server_safety \
  terraform_data.network_hardening_rollout_stage_server_template \
  terraform_data.network_hardening_rollout_stage_server_health \
  terraform_data.network_hardening_rollout_stage_api \
  terraform_data.network_hardening_rollout_stage_worker \
  google_compute_region_instance_group_manager.server_pool \
  google_compute_instance_group_manager.api_pool \
  module.client_cluster \
  module.build_cluster; do
  grep -F "${dependency}" "${cluster_source}" >/dev/null
done

for recovery_target in \
  workload-cluster-recover-lease \
  workload-cluster-plan \
  workload-cluster-apply; do
  grep -F "mise exec -- make -C iac/provider-gcp ${recovery_target}" \
    "${runbook}" >/dev/null || {
    printf 'Runbook target %s must execute from the provider Makefile.\n' \
      "${recovery_target}" >&2
    exit 1
  }
done
if grep -Eq '^[[:space:]]+make workload-cluster-(recover-lease|plan|apply)' \
  "${runbook}"; then
  printf 'Runbook cannot invoke provider-only recovery targets from the repository root.\n' >&2
  exit 1
fi

apply_block="${test_dir}/workload-cluster-apply.txt"
awk '
  /^workload-cluster-apply:/ { capture=1 }
  /^workload-cluster-recover-lease:/ { capture=0 }
  capture
' "${provider_root}/Makefile" >"${apply_block}"
apply_line="$(grep -nF '$(TF) apply -input=false' "${apply_block}" | cut -d: -f1)"
lease_assert_line="$(grep -nF '"$(WORKLOAD_ROLLOUT_LEASE)" assert-held' "${apply_block}" | tail -1 | cut -d: -f1)"
wait_line="$(grep -nF './scripts/wait-network-hardening-stage.sh' "${apply_block}" | cut -d: -f1)"
release_line="$(grep -nF '"$(WORKLOAD_ROLLOUT_LEASE)" release' "${apply_block}" | tail -1 | cut -d: -f1)"
[[ -n "${lease_assert_line}" && -n "${apply_line}" && -n "${wait_line}" && -n "${release_line}" ]]
((lease_assert_line < apply_line && apply_line < wait_line && wait_line < release_line))
grep -F 'mutation_started=true' "${apply_block}" >/dev/null
grep -F 'convergence_proven=true' "${apply_block}" >/dev/null
grep -F 'DOMAIN_NAME="$(DOMAIN_NAME)"' "${apply_block}" >/dev/null
grep -F 'preserving the shared lease and private recovery directory' \
  "${apply_block}" >/dev/null

make_plan() {
  local stage="$1"
  local output="$2"
  jq -n \
    --arg stage "${stage}" \
    --arg project "${GCP_PROJECT_ID}" \
    --arg prefix "${PREFIX}" '
    def iam_change($resource; $key; $secret; $member; $actions):
      {
        address:("module.cluster.google_secret_manager_secret_iam_member." + $resource + "[" + ($key | @json) + "]"),
        mode:"managed",
        type:"google_secret_manager_secret_iam_member",
        change:{
          actions:$actions,
          before:(
            if $actions == ["create"] then null else {
              project:$project,
              secret_id:$secret,
              role:"roles/secretmanager.secretAccessor",
              member:$member
            } end
          ),
          after:{
            project:$project,
            secret_id:$secret,
            role:"roles/secretmanager.secretAccessor",
            member:$member
          }
        }
      };
    def health_check($address; $name; $port; $path; $actions; $before):
      {
        address:$address,
        mode:"managed",
        type:"google_compute_health_check",
        change:{
          actions:$actions,
          before:$before,
          after:(
            if $actions == ["delete"] then null else {
              id:("projects/" + $project + "/global/healthChecks/" + $name),
              name:$name,
              check_interval_sec:5,
              timeout_sec:5,
              healthy_threshold:2,
              unhealthy_threshold:10,
              http_health_check:[{port:$port,request_path:$path}]
            } end
          ),
          after_unknown:{}
        }
      };
    {network:1,"server-safety":2,server:3,"server-health":4,api:5,worker:6,build:7} as $rank
    | ["network","server-safety","server","server-health","api","worker","build"] as $stages
    | ("1" * 64) as $previous_setup_hash
    | ("2" * 64) as $current_setup_hash
    | {
        network:"module.cluster.terraform_data.network_hardening_rollout_completion_network",
        "server-safety":"module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]",
        server:"module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]",
        "server-health":"module.cluster.terraform_data.network_hardening_rollout_completion_server_health[0]",
        api:"module.cluster.terraform_data.network_hardening_rollout_completion_api[0]",
        worker:"module.cluster.terraform_data.network_hardening_rollout_completion_worker[0]",
        build:"module.cluster.terraform_data.network_hardening_rollout_completion_build[0]"
      } as $completions
    | {
        network:"module.cluster.terraform_data.network_hardening_rollout_stage_network",
        "server-safety":"module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]",
        server:"module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]",
        "server-health":"module.cluster.terraform_data.network_hardening_rollout_stage_server_health[0]",
        api:"module.cluster.terraform_data.network_hardening_rollout_stage_api[0]",
        worker:"module.cluster.terraform_data.network_hardening_rollout_stage_worker[0]",
        build:"module.cluster.terraform_data.network_hardening_rollout_stage_build[0]"
      } as $markers
    | {
        network: [
          "module.cluster.module.network.google_compute_firewall.iap_remote_connection_firewall_ingress[0]",
          "module.cluster.module.network.google_compute_firewall.internal_remote_connection_firewall_ingress",
          "module.cluster.module.network.google_compute_firewall.remote_connection_firewall_ingress"
        ],
        "server-safety": [],
        server: [],
        "server-health": [],
        api: [
          "module.cluster.google_compute_instance_group_manager.api_pool",
          "module.cluster.google_compute_instance_template.api"
        ],
        worker: [
          "module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template",
          "module.cluster.module.client_cluster[\"default\"].google_compute_region_instance_group_manager.pool"
        ],
        build: [
          "module.cluster.google_compute_instance_group_manager.clickhouse_pool",
          "module.cluster.google_compute_instance_group_manager.loki_pool",
          "module.cluster.google_compute_instance_template.clickhouse",
          "module.cluster.google_compute_instance_template.loki",
          "module.cluster.module.build_cluster[\"default\"].google_compute_instance_template.template",
          "module.cluster.module.build_cluster[\"default\"].google_compute_region_instance_group_manager.pool"
        ]
      } as $mutations
    | [
        {address:"module.cluster.google_compute_instance_template.server", role_rank:3, identity:($prefix + "nomad-server@" + $project + ".iam.gserviceaccount.com"), server:true},
        {address:"module.cluster.google_compute_instance_template.api", role_rank:5, identity:($prefix + "api-controller@" + $project + ".iam.gserviceaccount.com")},
        {address:"module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template", role_rank:6, identity:($prefix + "infra-instances@" + $project + ".iam.gserviceaccount.com")},
        {address:"module.cluster.module.build_cluster[\"default\"].google_compute_instance_template.template", role_rank:7, identity:($prefix + "infra-instances@" + $project + ".iam.gserviceaccount.com")},
        {address:"module.cluster.google_compute_instance_template.loki", role_rank:7, identity:($prefix + "data-node@" + $project + ".iam.gserviceaccount.com")},
        {address:"module.cluster.google_compute_instance_template.clickhouse", role_rank:7, identity:($prefix + "data-node@" + $project + ".iam.gserviceaccount.com")}
      ] as $templates
    | ("projects/" + $project + "/secrets/" + $prefix) as $secret_base
    | ("serviceAccount:" + $prefix + "nomad-server@" + $project + ".iam.gserviceaccount.com") as $server_member
    | ("serviceAccount:" + $prefix + "infra-instances@" + $project + ".iam.gserviceaccount.com") as $worker_member
    | ("serviceAccount:" + $prefix + "data-node@" + $project + ".iam.gserviceaccount.com") as $data_member
    | ("serviceAccount:" + $prefix + "api-controller@" + $project + ".iam.gserviceaccount.com") as $api_member
    | [
        {key:"consul_management_candidate",secret:"consul-management-candidate-token"},
        {key:"nomad_management",secret:"nomad-secret-id"},
        {key:"consul_gossip",secret:"consul-gossip-key"},
        {key:"consul_catalog_read",secret:"consul-catalog-read-token"},
        {key:"consul_nomad_client_sync",secret:"consul-nomad-client-sync-token"},
        {key:"consul_worker_autoscaler",secret:"consul-worker-autoscaler-token"}
      ] as $server_secrets
    | [] as $worker_secrets
    | [
        {key:"consul_gossip",secret:"consul-gossip-key"},
        {key:"consul_catalog_read",secret:"consul-catalog-read-token"},
        {key:"consul_nomad_client_sync",secret:"consul-nomad-client-sync-token"}
      ] as $data_secrets
    | $data_secrets as $api_secrets
    | ($prefix + "orch-server-nomad-check") as $legacy_health_name
    | ($prefix + "orch-server-voter-check") as $strict_health_name
    | {
        id:("projects/" + $project + "/global/healthChecks/" + $legacy_health_name),
        name:$legacy_health_name,
        check_interval_sec:5, timeout_sec:5,
        healthy_threshold:2, unhealthy_threshold:10,
        http_health_check:[{port:4646,request_path:"/v1/agent/health"}]
      } as $legacy_health
    | {
        id:("projects/" + $project + "/global/healthChecks/" + $strict_health_name),
        name:$strict_health_name,
        check_interval_sec:5, timeout_sec:5,
        healthy_threshold:2, unhealthy_threshold:10,
        http_health_check:[{port:50001,request_path:"/healthz"}]
      } as $strict_health
    | {
        format_version:"1.2",
        errored:false,
        resource_changes: (
          [
            {
              address:"module.cluster.terraform_data.acl_bootstrap_environment_guard",
              mode:"managed",
              type:"terraform_data",
              change:{actions:["no-op"],before:{input:"dev"},after:{input:"dev"}}
            },
            {
              address:"module.cluster.terraform_data.os_login_operator_access_guard",
              mode:"managed",
              type:"terraform_data",
              change:{actions:["no-op"],before:{input:true},after:{input:true}}
            },
            {
              address:$completions[$stage],
              mode:"managed",
              type:"terraform_data",
              change:{
                actions:(
                  if $stage == "network" or $stage == "server-safety"
                  then ["delete","create"] else ["create"] end
                ),
                before:(
                  if $stage == "network" then {input:"disabled"}
                  elif $stage == "server-safety" then {input:"server"}
                  else null end
                ),
                after:{input:$stage}
              }
            },
            {
              address:$markers[$stage],
              mode:"managed",
              type:"terraform_data",
              change:{
                actions:(if $stage == "network" or $stage == "server-safety" then ["update"] else ["create"] end),
                before:(
                  if $stage == "network" then {input:"disabled"}
                  elif $stage == "server-safety" then {input:"server"}
                  else null end
                ),
                after:{input:$stage}
              }
            }
          ]
          + [
              $stages[0:($rank[$stage] - 1)][] as $prior
              | {
                  address:$completions[$prior],
                  mode:"managed",
                  type:"terraform_data",
                  change:{actions:["no-op"],before:{input:$prior},after:{input:$prior}}
                },
                {
                  address:$markers[$prior],
                  mode:"managed",
                  type:"terraform_data",
                  change:{actions:["no-op"],before:{input:$prior},after:{input:$prior}}
                }
            ]
          + (
              if $rank[$stage] >= $rank.server then [{
                address:"module.cluster.terraform_data.consul_management_handoff_candidate[0]",
                mode:"managed",
                type:"terraform_data",
                change:{
                  actions:(if $stage == "server" then ["create"] else ["no-op"] end),
                  before:(if $stage == "server" then null else {input:{phase:"candidate",server_stage:"server",candidate_ref:("projects/" + $project + "/secrets/" + $prefix + "consul-management-candidate-token/versions/1")}} end),
                  after:{input:{phase:"candidate",server_stage:"server",candidate_ref:("projects/" + $project + "/secrets/" + $prefix + "consul-management-candidate-token/versions/1")}}
                }
              }] else [] end
            )
          + [
              $templates[]
              | select(.role_rank <= $rank[$stage])
              | . as $template
              | {
                  address:.address,
                  mode:"managed",
                  type:"google_compute_instance_template",
                  change:{
                    actions:(if ($mutations[$stage] | index($template.address)) then ["create","delete"] else ["no-op"] end),
                    before:{metadata:{}},
                    after:{
                      metadata:{"enable-oslogin":"TRUE"},
                      service_account:[{email:$template.identity}],
                      tags:(if ($template.server // false) then [($prefix + "nomad-server")] else [] end)
                    }
                  }
                }
            ]
          + (
              if $rank[$stage] >= $rank.server then [
                "run-nomad", "run-consul", "fetch-gcp-secret"
                | . as $object
                | {
                    address:("module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/" + $object + ".sh\"]"),
                    mode:"managed",
                    type:"google_storage_bucket_object",
                    change:{
                      actions:(if $stage == "server" then ["delete","create"] else ["no-op"] end),
                      before:{
                        bucket:"monad-code-instance-setup",
                        deletion_policy:"ABANDON",
                        name:($object + "-" + (if $stage == "server" then $previous_setup_hash else $current_setup_hash end) + ".sh"),
                        source:("/repo/nomad-cluster/scripts/" + $object + ".sh")
                      },
                      after:{
                        bucket:"monad-code-instance-setup",
                        deletion_policy:"ABANDON",
                        name:($object + "-" + $current_setup_hash + ".sh"),
                        source:("/repo/nomad-cluster/scripts/" + $object + ".sh")
                      }
                    }
                  }
              ] else [] end
            )
          + (
              if $rank[$stage] < $rank.server then []
              elif $stage == "server" then [
                $server_secrets[]
                | iam_change("bootstrap_server"; .key; $secret_base + .secret; $server_member; ["create"])
              ]
              elif $stage == "server-health" then [
                $server_secrets[]
                | iam_change("bootstrap_server"; .key; $secret_base + .secret; $server_member; ["no-op"])
              ]
              elif $stage == "api" then (
                [
                  $server_secrets[]
                  | iam_change("bootstrap_server"; .key; $secret_base + .secret; $server_member; ["no-op"])
                ] + [
                  $api_secrets[]
                  | iam_change("bootstrap_api"; .key; $secret_base + .secret; $api_member; ["create"])
                ]
              )
              elif $stage == "worker" then (
                [
                  $server_secrets[]
                  | iam_change("bootstrap_server"; .key; $secret_base + .secret; $server_member; ["no-op"])
                ] + [
                  $api_secrets[]
                  | iam_change("bootstrap_api"; .key; $secret_base + .secret; $api_member; ["no-op"])
                ] + [
                  $worker_secrets[]
                  | iam_change("bootstrap_worker"; .key; $secret_base + .secret; $worker_member; ["create"])
                ]
              )
              else (
                [
                  $server_secrets[]
                  | iam_change("bootstrap_server"; .key; $secret_base + .secret; $server_member; ["no-op"])
                ] + [
                  $api_secrets[]
                  | iam_change("bootstrap_api"; .key; $secret_base + .secret; $api_member; ["no-op"])
                ] + [
                  $worker_secrets[]
                  | iam_change("bootstrap_worker"; .key; $secret_base + .secret; $worker_member; ["no-op"])
                ] + [
                  $data_secrets[]
                  | iam_change("bootstrap_data"; .key; $secret_base + .secret; $data_member; ["create"])
                ]
              ) end
            )
          + (
              if $rank[$stage] >= $rank["server-safety"] then [
                health_check(
                  "module.cluster.google_compute_health_check.server_nomad_check_legacy[0]";
                  $legacy_health_name; 4646; "/v1/agent/health";
                  (if $stage == "api" then ["delete"] else ["no-op"] end);
                  $legacy_health
                ),
                health_check(
                  "module.cluster.google_compute_health_check.server_voter_check";
                  $strict_health_name; 50001; "/healthz";
                  (if $stage == "server-safety" then ["create"] else ["no-op"] end);
                  (if $stage == "server-safety" then null else $strict_health end)
                ),
                {
                  address:"module.cluster.terraform_data.server_mig_safety_policy[0]",
                  mode:"managed",
                  type:"terraform_data",
                  change:{
                    actions:(if $stage == "server-safety" then ["create"] else ["no-op"] end),
                    before:(if $stage == "server-safety" then null else {input:{
                      phase:"server-safety",
                      gcp_project_id:$project,
                      gcp_region:"us-east4",
                      server_pool:($prefix + "orch-server-rig"),
                      legacy_health_check:$legacy_health_name,
                      strict_health_check:$strict_health_name,
                      expected_cluster_size:3,
                      script_sha256:("0" * 64)
                    }} end),
                    after:{input:{
                      phase:"server-safety",
                      gcp_project_id:$project,
                      gcp_region:"us-east4",
                      server_pool:($prefix + "orch-server-rig"),
                      legacy_health_check:$legacy_health_name,
                      strict_health_check:$strict_health_name,
                      expected_cluster_size:3,
                      script_sha256:("0" * 64)
                    }}
                  }
                }
              ] else [] end
            )
          + (
              if $rank[$stage] >= $rank.server then [
                {
                  address:"module.cluster.google_compute_region_instance_group_manager.server_pool",
                  mode:"managed",
                  type:"google_compute_region_instance_group_manager",
                  change:{
                    actions:(if $stage == "server" or $stage == "server-health" then ["update"] else ["no-op"] end),
                    before:{
                      distribution_policy_zones:["us-east4-c"],
                      version:[{instance_template:(if $stage == "server" then "old-template" else "new-template" end)}],
                      update_policy:[{
                        replacement_method:"SUBSTITUTE", max_unavailable_fixed:0,
                        max_unavailable_percent:0, max_surge_fixed:1,
                        max_surge_percent:0, min_ready_sec:120
                      }],
                      auto_healing_policies:[{
                        health_check:("projects/" + $project + "/global/healthChecks/" + $legacy_health_name),
                        initial_delay_sec:120
                      }],
                      instance_lifecycle_policy:[{
                        default_action_on_failure:"REPAIR", force_update_on_repair:"NO",
                        on_failed_health_check:"DO_NOTHING"
                      }]
                    },
                    after:{
                      distribution_policy_zones:["us-east4-c"],
                      version:[{instance_template:"new-template"}],
                      update_policy:[{
                        replacement_method:"SUBSTITUTE", max_unavailable_fixed:0,
                        max_unavailable_percent:0, max_surge_fixed:1,
                        max_surge_percent:0, min_ready_sec:120
                      }],
                      auto_healing_policies:[{
                        health_check:("projects/" + $project + "/global/healthChecks/" +
                          (if $rank[$stage] >= $rank["server-health"] then $strict_health_name else $legacy_health_name end)),
                        initial_delay_sec:120
                      }],
                      instance_lifecycle_policy:[{
                        default_action_on_failure:"REPAIR", force_update_on_repair:"NO",
                        on_failed_health_check:"DO_NOTHING"
                      }]
                    },
                    after_unknown:{}
                  }
                }
              ] else [] end
            )
          + [
              $mutations[$stage][] as $address
              | select([$templates[].address] | index($address) | not)
              | {
                  address:$address,
                  mode:"managed",
                  type:(
                    if ($address | contains("firewall")) then "google_compute_firewall"
                    elif ($address | contains("region_instance_group_manager")) then "google_compute_region_instance_group_manager"
                    else "google_compute_instance_group_manager" end
                  ),
                  change:{
                    actions:(if ($address | contains("iap_remote_connection")) then ["create"] else ["update"] end),
                    before:(if ($address | contains("iap_remote_connection")) then null else {} end),
                    after:(
                      if ($address | contains("iap_remote_connection")) then {
                        direction:"INGRESS", priority:700,
                        source_ranges:["35.235.240.0/20"], target_tags:["orch"],
                        allow:[{protocol:"tcp",ports:["22","3389"]}], deny:[],
                        log_config:[{metadata:"EXCLUDE_ALL_METADATA"}]
                      } elif ($address | contains("internal_remote_connection")) then {
                        direction:"INGRESS", priority:900,
                        source_ranges:["0.0.0.0/0","35.235.240.0/20"], target_tags:["orch"],
                        allow:[{protocol:"tcp",ports:["22","3389"]}], deny:[],
                        log_config:[{metadata:"EXCLUDE_ALL_METADATA"}]
                      } elif ($address | contains("remote_connection_firewall_ingress")) then {
                        direction:"INGRESS", priority:800,
                        source_ranges:["0.0.0.0/0"], target_tags:["orch"],
                        allow:[], deny:[{protocol:"tcp",ports:["22","3389"]}],
                        log_config:[{metadata:"EXCLUDE_ALL_METADATA"}]
                      } else {} end
                    )
                  }
                }
            ]
        )
      }
  ' >"${output}"
  chmod 0600 "${output}"
}

for stage in network server-safety server server-health api worker build; do
  plan="${test_dir}/${stage}.plan"
  make_plan "${stage}" "${plan}"
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
    "${plan}" "${fake_terraform}" "${stage}" >/dev/null
done

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.acl_bootstrap_environment_guard")
    | .change.after.input) = "prod"
' "${test_dir}/server.plan" >"${test_dir}/server-nondev-environment.plan"
expect_fail "cluster ACL migration cannot target a nondev environment" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/server-nondev-environment.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.server")
    | .change.after.service_account[0].email) = "e2b-infra-instances@monad-code.iam.gserviceaccount.com"
' "${test_dir}/server.plan" >"${test_dir}/server-wrong-identity.plan"
expect_fail "server stage cannot attach the worker/build identity" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/server-wrong-identity.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.server")
    | .change.after.tags) = []
' "${test_dir}/server.plan" >"${test_dir}/server-missing-discovery-tag.plan"
expect_fail "server stage requires the server-only discovery tag" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/server-missing-discovery-tag.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.loki")
    | .change.after.service_account[0].email) = "e2b-infra-instances@monad-code.iam.gserviceaccount.com"
' "${test_dir}/build.plan" >"${test_dir}/data-wrong-identity.plan"
expect_fail "data stage cannot attach the worker/build identity" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/data-wrong-identity.plan" "${fake_terraform}" build

# An interrupted create-before-destroy setup object replacement leaves a
# deposed ABANDON entry. The next exact stage may forget only that old state
# beside one current no-op; the old content-addressed cloud object is retained.
jq '
  .resource_changes += [{
    address:"module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-nomad.sh\"]",
    deposed:"8df55091",
    mode:"managed",
    type:"google_storage_bucket_object",
    change:{
      actions:["delete"],
      before:{
        bucket:"monad-code-instance-setup",
        deletion_policy:"ABANDON",
        name:"run-nomad-11111.sh",
        source:"/repo/nomad-cluster/scripts/run-nomad.sh"
      },
      after:null
    }
  }]
' "${test_dir}/api.plan" >"${test_dir}/api-deposed-abandon-cleanup.plan"
"${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/api-deposed-abandon-cleanup.plan" "${fake_terraform}" api >/dev/null

jq '
  (.resource_changes[]
    | select(.deposed == "8df55091")
    | .change.before.deletion_policy) = "DELETE"
' "${test_dir}/api-deposed-abandon-cleanup.plan" >"${test_dir}/api-deposed-delete-policy.plan"
expect_fail "deposed setup cleanup must retain the cloud object with ABANDON" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/api-deposed-delete-policy.plan" "${fake_terraform}" api

jq '
  (.resource_changes[]
    | select(
        .address == "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-nomad.sh\"]"
        and .deposed == null
      )
    | .change.actions) = ["update"]
' "${test_dir}/api-deposed-abandon-cleanup.plan" >"${test_dir}/api-deposed-current-drift.plan"
expect_fail "deposed setup cleanup requires one unchanged current object" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/api-deposed-current-drift.plan" "${fake_terraform}" api

jq '
  (.resource_changes[]
    | select(.deposed == "8df55091")
    | .change.before.bucket) = "wrong-bucket"
' "${test_dir}/api-deposed-abandon-cleanup.plan" >"${test_dir}/api-deposed-wrong-bucket.plan"
expect_fail "deposed setup cleanup is bound to the current object bucket" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/api-deposed-wrong-bucket.plan" "${fake_terraform}" api

jq '
  .resource_changes |= map(
    select(.address != "module.cluster.module.network.google_compute_firewall.iap_remote_connection_firewall_ingress[0]")
  )
' "${test_dir}/network.plan" >"${test_dir}/network-missing-iap-overlay.plan"
expect_fail "network stage requires the exact IAP overlay" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/network-missing-iap-overlay.plan" "${fake_terraform}" network

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.module.network.google_compute_firewall.iap_remote_connection_firewall_ingress[0]")
    | .change.after.priority) = 900
' "${test_dir}/network.plan" >"${test_dir}/network-wrong-iap-priority.plan"
expect_fail "IAP overlay must precede the public deny" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/network-wrong-iap-priority.plan" "${fake_terraform}" network

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.module.network.google_compute_firewall.internal_remote_connection_firewall_ingress")
    | .change.after.priority) = 750
' "${test_dir}/network.plan" >"${test_dir}/network-legacy-beats-deny.plan"
expect_fail "legacy public allow must remain shadowed by the deny" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/network-legacy-beats-deny.plan" "${fake_terraform}" network

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.module.network.google_compute_firewall.iap_remote_connection_firewall_ingress[0]")
    | .change.after.source_ranges) = ["0.0.0.0/0", "35.235.240.0/20"]
' "${test_dir}/network.plan" >"${test_dir}/network-public-iap-overlay.plan"
expect_fail "IAP overlay cannot retain a public source" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/network-public-iap-overlay.plan" "${fake_terraform}" network

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.module.network.google_compute_firewall.remote_connection_firewall_ingress")
    | .change.after.log_config) = []
' "${test_dir}/network.plan" >"${test_dir}/network-unlogged-deny.plan"
expect_fail "public deny must retain decision logging" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/network-unlogged-deny.plan" "${fake_terraform}" network

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.module.network.google_compute_firewall.remote_connection_firewall_ingress")
    | .change.after.deny[0].ports) = ["22"]
' "${test_dir}/network.plan" >"${test_dir}/network-incomplete-deny.plan"
expect_fail "public deny must cover every administrative port" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/network-incomplete-deny.plan" "${fake_terraform}" network

# A whole-module dependency on the changing authorization guard defers the
# worker/build image-family reads and turns their otherwise-stable templates
# into replacements. The network stage must reject that exact regression even
# though its exact firewall transition remains valid.
jq '
  .resource_changes += [
    {
      address:"module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template",
      mode:"managed", type:"google_compute_instance_template",
      change:{actions:["create","delete"],before:{metadata:{}},after:{metadata:{}}}
    },
    {
      address:"module.cluster.module.build_cluster[\"default\"].google_compute_instance_template.template",
      mode:"managed", type:"google_compute_instance_template",
      change:{actions:["create","delete"],before:{metadata:{}},after:{metadata:{}}}
    }
  ]
' "${test_dir}/network.plan" >"${test_dir}/network-deferred-source-image.plan"
expect_fail "network stage cannot replace worker/build templates after deferred source-image reads" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/network-deferred-source-image.plan" "${fake_terraform}" network

# A fresh state may create the network ledger directly; an initialized state
# replaces its moved disabled completion. Both are valid first transitions.
jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_network")
    | .change.actions) = ["create"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_network")
    | .change.before) = null
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_network")
    | .change.actions) = ["create"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_network")
    | .change.before) = null
' "${test_dir}/network.plan" >"${test_dir}/fresh-network.plan"
"${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/fresh-network.plan" "${fake_terraform}" network >/dev/null

# A failed server transition can leave the template committed while the MIG,
# completion, and marker remain pending. The remaining exact-stage subset is
# retryable because the completion depends on the MIG and prior network marker.
jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.server")
    | .change.actions) = ["no-op"]
' "${test_dir}/server.plan" >"${test_dir}/partial-retry.plan"
"${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/partial-retry.plan" "${fake_terraform}" server >/dev/null

# If the completion exists but the marker did not persist, a forced replacement
# re-proves live convergence before creating the marker.
jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]")
    | .change.actions) = ["delete", "create"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]")
    | .change.before) = {input:"server"}
  | (.resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.server")
    | .change.actions) = ["no-op"]
  | (.resource_changes[]
    | select(.address == "module.cluster.google_compute_region_instance_group_manager.server_pool")
    | .change.actions) = ["no-op"]
' "${test_dir}/server.plan" >"${test_dir}/marker-retry.plan"
"${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/marker-retry.plan" "${fake_terraform}" server server >/dev/null

# A completed marker can only be retried under the exact recovery context, and
# a missing forced completion remains recoverable under that held lease.
jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]")
    | .change.actions) = ["create"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]")
    | .change.before) = null
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]")
    | .change.actions) = ["no-op"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]")
    | .change.before) = {input:"server"}
' "${test_dir}/server.plan" >"${test_dir}/missing-sentinel-retry.plan"
"${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/missing-sentinel-retry.plan" "${fake_terraform}" server server >/dev/null
expect_fail "same-stage retry requires validated recovery context" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/missing-sentinel-retry.plan" "${fake_terraform}" server

# Skips are visible because the current stage depends on every cumulative prior
# marker; a prior marker that would be created or changed fails closed.
jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]")
    | .change.actions) = ["create"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]")
    | .change.before) = null
' "${test_dir}/api.plan" >"${test_dir}/missing-previous-marker.plan"
expect_fail "missing previous-stage marker cannot admit the following stage" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/missing-previous-marker.plan" "${fake_terraform}" api

jq '
  .resource_changes |= map(
    select(.address != "module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]")
  )
' "${test_dir}/api.plan" >"${test_dir}/missing-previous-completion.plan"
expect_fail "missing previous-stage completion cannot admit the following stage" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/missing-previous-completion.plan" "${fake_terraform}" api

# Drift in a completed prior pool is present through the cumulative dependency
# chain and cannot be hidden by the exact current-stage mutation allowlist.
jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.server")
    | .change.actions) = ["create", "delete"]
' "${test_dir}/api.plan" >"${test_dir}/prior-server-drift.plan"
expect_fail "API stage rejects completed server-pool drift" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/prior-server-drift.plan" "${fake_terraform}" api

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_storage_bucket_object.setup_config_objects[\"scripts/run-nomad.sh\"]")
    | .change.after.name) = "run-nomad-unsafe.sh"
' "${test_dir}/server.plan" >"${test_dir}/unsafe-run-nomad-object.plan"
expect_fail "server stage rejects an unbound Nomad bootstrap object" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/unsafe-run-nomad-object.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_compute_region_instance_group_manager.server_pool")
    | .change.after.auto_healing_policies[0].health_check)
    = "projects/monad-code/global/healthChecks/permissive-agent-health"
' "${test_dir}/server.plan" >"${test_dir}/wrong-server-autoheal-health-check.plan"
expect_fail "server stage binds auto-healing to the exact voter health resource" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/wrong-server-autoheal-health-check.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_compute_region_instance_group_manager.server_pool")
    | .change.after_unknown.auto_healing_policies) = [{health_check:true}]
' "${test_dir}/server.plan" >"${test_dir}/unknown-server-autoheal-health-check.plan"
expect_fail "server stage rejects unknown auto-healing health identity" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/unknown-server-autoheal-health-check.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_compute_region_instance_group_manager.server_pool")
    | .change.after.instance_lifecycle_policy[0].on_failed_health_check) = "REPAIR"
' "${test_dir}/server.plan" >"${test_dir}/unsafe-server-health-repair.plan"
expect_fail "server stage forbids quorum-health-triggered auto-repair" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/unsafe-server-health-repair.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.google_compute_region_instance_group_manager.server_pool")
    | .change.after_unknown.instance_lifecycle_policy) = [true]
' "${test_dir}/server.plan" >"${test_dir}/unknown-server-health-repair.plan"
expect_fail "server stage rejects unknown lifecycle repair policy" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/unknown-server-health-repair.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.type == "google_secret_manager_secret_iam_member")
    | .change.after.role) = "roles/owner"
' "${test_dir}/server.plan" >"${test_dir}/unsafe-bootstrap-iam.plan"
expect_fail "server stage rejects over-broad bootstrap secret IAM" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/unsafe-bootstrap-iam.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.type == "google_secret_manager_secret_iam_member")
    | .change.after.project) = "other-project"
' "${test_dir}/server.plan" >"${test_dir}/wrong-project-bootstrap-iam.plan"
expect_fail "server stage binds bootstrap IAM to the selected project" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/wrong-project-bootstrap-iam.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.type == "google_secret_manager_secret_iam_member")
    | .change.after.member) = "serviceAccount:wrong@monad-code.iam.gserviceaccount.com"
' "${test_dir}/server.plan" >"${test_dir}/wrong-member-bootstrap-iam.plan"
expect_fail "server stage binds bootstrap IAM to the exact attached identity" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/wrong-member-bootstrap-iam.plan" "${fake_terraform}" server

jq '
  .resource_changes |= map(
    select(.address != "module.cluster.google_secret_manager_secret_iam_member.bootstrap_server[\"nomad_management\"]")
  )
' "${test_dir}/server.plan" >"${test_dir}/missing-bootstrap-iam.plan"
expect_fail "server stage requires the exact eight-resource server IAM set" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/missing-bootstrap-iam.plan" "${fake_terraform}" server

jq '
  .resource_changes += [{
    address:"module.cluster.google_secret_manager_secret_iam_member.bootstrap_api[\"nomad_management\"]",
    mode:"managed",
    type:"google_secret_manager_secret_iam_member",
    change:{
      actions:["create"],
      before:null,
      after:{
        project:"monad-code",
        secret_id:"projects/monad-code/secrets/e2b-nomad-secret-id",
        role:"roles/secretmanager.secretAccessor",
        member:"serviceAccount:e2b-api-controller@monad-code.iam.gserviceaccount.com"
      }
    }
  }]
' "${test_dir}/api.plan" >"${test_dir}/api-nomad-bootstrap-iam.plan"
expect_fail "API stage cannot grant the Nomad management secret" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/api-nomad-bootstrap-iam.plan" "${fake_terraform}" api

jq '
  (.resource_changes[]
    | select(.type == "google_secret_manager_secret_iam_member")
    | .change.actions) = ["update"]
' "${test_dir}/worker.plan" >"${test_dir}/worker-bootstrap-iam.plan"
expect_fail "worker stage cannot mutate bootstrap secret IAM" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/worker-bootstrap-iam.plan" "${fake_terraform}" worker

jq '
  .resource_changes |= map(
    if .type == "google_secret_manager_secret_iam_member" then
      .change.actions = ["no-op"] | .change.before = .change.after
    else . end
  )
' "${test_dir}/server.plan" >"${test_dir}/server-bootstrap-iam-noop.plan"
"${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/server-bootstrap-iam-noop.plan" "${fake_terraform}" server >/dev/null

jq '
  (.resource_changes[]
    | select(.type == "google_secret_manager_secret_iam_member")
    | .change.actions) = ["delete"]
' "${test_dir}/server.plan" >"${test_dir}/deleting-bootstrap-iam.plan"
expect_fail "server recovery rejects destructive bootstrap IAM shapes" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/deleting-bootstrap-iam.plan" "${fake_terraform}" server

# After a successful stage, only a recovery-token retry may keep the current
# marker as a no-op while replacing the completion sentinel.
jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]")
    | .change.actions) = ["delete", "create"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]")
    | .change.before) = {input:"server"}
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]")
    | .change.actions) = ["no-op"]
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]")
    | .change.before) = {input:"server"}
  | (.resource_changes[]
    | select(.address == "module.cluster.google_compute_instance_template.server")
    | .change.actions) = ["no-op"]
' "${test_dir}/server.plan" >"${test_dir}/post-apply-drift-retry.plan"
"${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/post-apply-drift-retry.plan" "${fake_terraform}" server server >/dev/null
expect_fail "completed stage cannot be re-entered without recovery context" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/post-apply-drift-retry.plan" "${fake_terraform}" server

# A later reviewed server hardening change can deliberately re-enter the
# already-completed stage under a fresh checkpoint and normal rollout lease.
# The persisted marker remains immutable while the forced convergence sentinel
# and exact server boundary are re-proved.
"${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/post-apply-drift-retry.plan" "${fake_terraform}" server "" server >/dev/null
expect_fail "planned refresh cannot recreate a missing convergence sentinel" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/missing-sentinel-retry.plan" "${fake_terraform}" server "" server
expect_fail "planned refresh must match the reviewed stage" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/post-apply-drift-retry.plan" "${fake_terraform}" server "" api
expect_fail "planned refresh cannot borrow a recovery context" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/post-apply-drift-retry.plan" "${fake_terraform}" server server server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]")
    | .change.actions) = ["update"]
' "${test_dir}/post-apply-drift-retry.plan" >"${test_dir}/post-apply-marker-update.plan"
expect_fail "same-stage retry cannot mutate the persisted marker" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/post-apply-marker-update.plan" "${fake_terraform}" server server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]")
    | .change.before.input) = "network"
' "${test_dir}/post-apply-drift-retry.plan" >"${test_dir}/mismatched-current-marker.plan"
expect_fail "current marker requires its exact completion replacement" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/mismatched-current-marker.plan" "${fake_terraform}" server server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]")
    | .change.actions) = ["no-op"]
' "${test_dir}/post-apply-drift-retry.plan" >"${test_dir}/marker-retry-without-convergence.plan"
expect_fail "marker retry without forced convergence replacement" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/marker-retry-without-convergence.plan" "${fake_terraform}" server server

jq '(.resource_changes[] | select(.address == "module.cluster.terraform_data.os_login_operator_access_guard") | .change.after.input) = false' \
  "${test_dir}/server.plan" >"${test_dir}/closed.plan"
expect_fail "closed in-graph authorization guard" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/closed.plan" "${fake_terraform}" server

jq '
  (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_completion_network")
    | .change.before) = {input:"network"}
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_network")
    | .change.before) = {input:"network"}
  | (.resource_changes[]
    | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage_network")
    | .change.actions) = ["no-op"]
' "${test_dir}/network.plan" >"${test_dir}/rollback.plan"
expect_fail "normal workflow cannot reverse or repeat a completed stage" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/rollback.plan" "${fake_terraform}" network

jq '.resource_changes += [{address:"module.cluster.module.client_cluster[\"default\"].google_compute_region_autoscaler.autoscaler[0]",mode:"managed",type:"google_compute_region_autoscaler",change:{actions:["delete"],before:{},after:null}}]' \
  "${test_dir}/worker.plan" >"${test_dir}/ownership.plan"
expect_fail "generic autoscaler ownership mutation" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/ownership.plan" "${fake_terraform}" worker

now="$(date -u +%s)"
git_head="$(git -C "${repo_root}" rev-parse --verify HEAD)"
checkpoint="${test_dir}/checkpoint.json"
jq -n \
  --arg head "${git_head}" \
  --argjson now "${now}" '
    {
      schema_version:1,
      stage:"worker",
      gcp_project_id:"monad-code",
      gcp_region:"us-east4",
      gcp_zone:"us-east4-c",
      prefix:"e2b-",
      source_git_head:$head,
      operator_principal:"operator@example.invalid",
      observed_unix:$now,
      expires_unix:($now + 900),
      checks:{
        durable_sessions_preserved:true,
        iap_tunnel_access:true,
        os_login_admin_access:true,
        target_pool_drained:true,
        zero_target_allocations:true,
        zero_target_workcells:true
      },
      evidence:{
        durable_sessions_preserved:"inventory://durable",
        iap_tunnel_access:"gcloud://iap",
        os_login_admin_access:"gcloud://os-login",
        target_pool_drained:"nomad://drain",
        zero_target_allocations:"nomad://allocations",
        zero_target_workcells:"e2b://inventory"
      }
    }
  ' >"${checkpoint}"
chmod 0600 "${checkpoint}"
"${script_dir}/assert-network-hardening-checkpoint.sh" \
  worker "${checkpoint}" monad-code us-east4 us-east4-c e2b- "${repo_root}" >/dev/null

jq '.expires_unix = 1' "${checkpoint}" >"${test_dir}/stale.json"
chmod 0600 "${test_dir}/stale.json"
expect_fail "stale operator checkpoint" \
  "${script_dir}/assert-network-hardening-checkpoint.sh" \
  worker "${test_dir}/stale.json" monad-code us-east4 us-east4-c e2b- "${repo_root}"

printf 'Network-hardening rollout guards passed.\n'
