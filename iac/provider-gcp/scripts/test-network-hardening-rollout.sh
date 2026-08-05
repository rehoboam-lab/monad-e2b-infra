#!/usr/bin/env bash
set -euo pipefail

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

make_plan() {
  local stage="$1"
  local output="$2"
  jq -n --arg stage "${stage}" '
    {network:1,server:2,api:3,worker:4,build:5} as $rank
    | {network:"disabled",server:"network",api:"server",worker:"api",build:"worker"} as $previous
    | {
        network: [
          "module.cluster.module.network.google_compute_firewall.internal_remote_connection_firewall_ingress",
          "module.cluster.module.network.google_compute_firewall.remote_connection_firewall_ingress"
        ],
        server: [
          "module.cluster.google_compute_instance_template.server",
          "module.cluster.google_compute_region_instance_group_manager.server_pool"
        ],
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
        {address:"module.cluster.google_compute_instance_template.server", role_rank:2},
        {address:"module.cluster.google_compute_instance_template.api", role_rank:3},
        {address:"module.cluster.module.client_cluster[\"default\"].google_compute_instance_template.template", role_rank:4},
        {address:"module.cluster.module.build_cluster[\"default\"].google_compute_instance_template.template", role_rank:5},
        {address:"module.cluster.google_compute_instance_template.loki", role_rank:5},
        {address:"module.cluster.google_compute_instance_template.clickhouse", role_rank:5}
      ] as $templates
    | {
        format_version:"1.2",
        errored:false,
        resource_changes: (
          [
            {
              address:"module.cluster.terraform_data.os_login_operator_access_guard",
              mode:"managed",
              type:"terraform_data",
              change:{actions:["no-op"],before:{input:true},after:{input:true}}
            },
            {
              address:"module.cluster.terraform_data.network_hardening_rollout_stage",
              mode:"managed",
              type:"terraform_data",
              change:{actions:["update"],before:{input:$previous[$stage]},after:{input:$stage}}
            }
          ]
          + [
              $templates[]
              | . as $template
              | ($rank[$stage] >= .role_rank) as $enabled
              | {
                  address:.address,
                  mode:"managed",
                  type:"google_compute_instance_template",
                  change:{
                    actions:(if ($mutations[$stage] | index($template.address)) then ["create","delete"] else ["no-op"] end),
                    before:{metadata:{}},
                    after:{metadata:(if $enabled then {"enable-oslogin":"TRUE"} else {} end)}
                  }
                }
            ]
          + [
              $mutations[$stage][] as $address
              | select([$templates[].address] | index($address) | not)
              | {
                  address:$address,
                  mode:"managed",
                  type:(if ($address | contains("firewall")) then "google_compute_firewall" else "google_compute_instance_group_manager" end),
                  change:{actions:["update"],before:{},after:{}}
                }
            ]
        )
      }
  ' >"${output}"
  chmod 0600 "${output}"
}

for stage in network server api worker build; do
  plan="${test_dir}/${stage}.plan"
  make_plan "${stage}" "${plan}"
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
    "${plan}" "${fake_terraform}" "${stage}" >/dev/null
done

jq '(.resource_changes[] | select(.address == "module.cluster.terraform_data.os_login_operator_access_guard") | .change.after.input) = false' \
  "${test_dir}/server.plan" >"${test_dir}/closed.plan"
expect_fail "closed in-graph authorization guard" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/closed.plan" "${fake_terraform}" server

jq '(.resource_changes[] | select(.address == "module.cluster.terraform_data.network_hardening_rollout_stage") | .change.before.input) = "disabled"' \
  "${test_dir}/worker.plan" >"${test_dir}/skipped.plan"
expect_fail "skipped serial stage" \
  "${script_dir}/assert-network-hardening-stage-plan.sh" \
  "${test_dir}/skipped.plan" "${fake_terraform}" worker

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
