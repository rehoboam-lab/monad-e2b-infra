#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assertion_script="$script_dir/assert-acl-runtime-job-plan.sh"
stage_script="$script_dir/acl-runtime-job-stage.sh"
provider_root="$(cd "$script_dir/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

[[ -x "$stage_script" ]]
grep -F 'unexport CONSUL_HTTP_TOKEN' "$provider_root/Makefile" >/dev/null
grep -F 'acl-runtime-job-plan:' "$provider_root/Makefile" >/dev/null
grep -F 'acl-runtime-job-apply:' "$provider_root/Makefile" >/dev/null
grep -F '"${terraform_bin}" -chdir="${provider_root}" apply -input=false "${apply_plan}"' \
  "$stage_script" >/dev/null
grep -F -- '-target=module.nomad' "$stage_script" >/dev/null
grep -F 'ACL_RUNTIME_JOB_COMPLETION_EVIDENCE' "$provider_root/Makefile" >/dev/null
grep -F 'job_projection_sha256' "$stage_script" >/dev/null
grep -F 'reviewed_plan_sha256' "$stage_script" >/dev/null
grep -F 'checkpoint_sha256' "$stage_script" >/dev/null
grep -F 'nomad-runtime-job-gate.sh' "$stage_script" >/dev/null
grep -F 'NOMAD_JOB_GATE_TRANSITION_EVIDENCE' "$stage_script" >/dev/null
grep -F 'exclusive_transition_sha256' "$stage_script" >/dev/null
grep -F 'live_nomad_convergence_sha256' "$stage_script" >/dev/null
grep -F 'monad_acl_handoff_revision = "1"' \
  "$provider_root/../modules/job-orchestrator/jobs/orchestrator.hcl" >/dev/null
grep -F 'monad_acl_handoff_revision = "1"' \
  "$provider_root/../modules/job-template-manager/jobs/template-manager.hcl" >/dev/null
grep -F 'chmod 0600 "${completion_evidence}"' "$stage_script" >/dev/null

cat >"$test_root/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == show && "${2:-}" == -json ]]; then
  cat "${3:?missing plan}"
elif [[ "${1:-}" == show && "${2:-}" == -no-color ]]; then
  printf '%s\n' "${FAKE_HUMAN_PLAN:-Plan values are redacted.}"
else
  exit 2
fi
EOF
chmod 0755 "$test_root/terraform"

job_change() {
  local address="$1"
  local jobspec="$2"
  local sensitive="${3:-false}"
  jq -cn \
    --arg address "$address" \
    --arg jobspec "$jobspec" \
    --argjson sensitive "$sensitive" '
      {
        address:$address,
        mode:"managed",
        type:"nomad_job",
        change:{
          actions:["update"],
          before:{jobspec:"legacy"},
          after:{jobspec:$jobspec},
          after_sensitive:{jobspec:$sensitive}
        }
      }
    '
}

batch_job_change() {
  local address="$1"
  local job_name="$2"
  local jobspec
  printf -v jobspec 'job "%s" {\n  type = "batch"\n}' "$job_name"
  jq -cn \
    --arg address "$address" \
    --arg jobspec "$jobspec" '
      {
        address:$address,
        mode:"managed",
        type:"nomad_job",
        change:{
          actions:["no-op"],
          before:{jobspec:$jobspec},
          after:{jobspec:$jobspec},
          after_sensitive:{jobspec:false}
        }
      }
    '
}

ledger_change() {
  local address="$1"
  local input="$2"
  jq -cn --arg address "$address" --arg input "$input" '
    {
      address:$address,
      mode:"managed",
      type:"terraform_data",
      change:{actions:["no-op"],before:{input:$input},after:{input:$input}}
    }
  '
}

guard_change="$(ledger_change 'module.cluster.terraform_data.acl_bootstrap_environment_guard' dev)"
network_completion="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_completion_network' network)"
network_marker="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_stage_network' network)"
server_safety_completion="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]' server-safety)"
server_safety_marker="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]' server-safety)"
server_completion="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]' server)"
server_marker="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]' server)"
server_health_completion="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_completion_server_health[0]' server-health)"
server_health_marker="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_stage_server_health[0]' server-health)"
api_completion="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_completion_api[0]' api)"
api_marker="$(ledger_change 'module.cluster.terraform_data.network_hardening_rollout_stage_api[0]' api)"
handoff_change="$(jq -cn '
  {
    address:"module.cluster.terraform_data.consul_management_handoff_candidate[0]",
    mode:"managed",
    type:"terraform_data",
    change:{
      actions:["no-op"],
      before:{input:{phase:"candidate",server_stage:"server",candidate_ref:"projects/monad-code/secrets/e2b-consul-management-candidate-token/versions/1"}},
      after:{input:{phase:"candidate",server_stage:"server",candidate_ref:"projects/monad-code/secrets/e2b-consul-management-candidate-token/versions/1"}}
    }
  }
')"

pre_jobspec=$'meta { monad_acl_handoff_revision = "1" }\ngce_sd_configs:\n  - project: "monad-code"\n    zone: "us-east4-c"\n    filter: \'name eq e2b-orch-server-.*\''
jq -n \
  --argjson job "$(job_change 'module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server' "$pre_jobspec")" \
  --argjson guard "$guard_change" \
  --argjson completion "$network_completion" \
  --argjson marker "$network_marker" \
  '{format_version:"1.2",errored:false,resource_changes:[$guard,$completion,$marker,$job]}' \
  >"$test_root/pre.plan"
"$assertion_script" "$test_root/pre.plan" "$test_root/terraform" \
  pre-server monad-code us-east4-c e2b- >/dev/null

jq '
  (.resource_changes[]
    | select(.address == "module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server")
    | .change.after.jobspec) |=
    sub("name eq e2b-orch-server-\\.\\*"; "status = RUNNING AND tags.items = e2b-nomad-server")
' "$test_root/pre.plan" >"$test_root/pre-invalid-tag-filter.plan"
if "$assertion_script" "$test_root/pre-invalid-tag-filter.plan" "$test_root/terraform" \
  pre-server monad-code us-east4-c e2b- >/dev/null 2>&1; then
  printf 'Compute-invalid tags.items discovery filter escaped the pre-server plan guard.\n' >&2
  exit 1
fi

post_changes='[]'
while IFS='|' read -r address jobspec sensitive; do
  post_changes="$(jq -cn \
    --argjson existing "$post_changes" \
    --argjson next "$(job_change "$address" "$jobspec" "$sensitive")" \
    '$existing + [$next]')"
done <<'EOF'
module.nomad.module.api.nomad_job.api|meta { monad_acl_handoff_revision = "1" }|false
module.nomad.module.dashboard_api[0].nomad_job.dashboard_api|meta { monad_acl_handoff_revision = "1" }|false
module.nomad.module.client_proxy.nomad_job.client_proxy|meta { monad_acl_handoff_revision = "1" }|false
module.nomad.module.ingress.nomad_job.ingress|meta { monad_acl_handoff_revision = "1" } catalog token redacted|true
module.nomad.module.logs_collector.nomad_job.logs_collector|meta { monad_acl_handoff_revision = "1" } service { provider = "nomad" }|false
module.nomad.module.loki.nomad_job.loki|meta { monad_acl_handoff_revision = "1" }|false
module.nomad.module.clickhouse.nomad_job.clickhouse|meta { monad_acl_handoff_revision = "1" }|false
module.nomad.module.orchestrator[0].nomad_job.orchestrator|meta { monad_acl_handoff_revision = "1" } workload token redacted|true
module.nomad.module.otel_collector.nomad_job.otel_collector|meta { monad_acl_handoff_revision = "1" } service { provider = "nomad" }|false
module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server|meta { monad_acl_handoff_revision = "1" } gce_sd_configs: filter: '(status = RUNNING) (labels.monad_role = e2b-nomad-server)'|false
module.nomad.module.redis[0].nomad_job.redis|meta { monad_acl_handoff_revision = "1" }|false
module.nomad.module.template_manager.nomad_job.template_manager|meta { monad_acl_handoff_revision = "1" } workload token redacted|true
module.nomad.module.template_manager_autoscaler[0].nomad_job.nomad_nodepool_apm|meta { monad_acl_handoff_revision = "1" } protected nomad token|true
module.nomad.module.monad_worker_autoscaler[0].nomad_job.shadow|meta { monad_acl_handoff_revision = "1" } protected nomad and consul tokens|true
module.nomad.nomad_job.docker_reverse_proxy|meta { monad_acl_handoff_revision = "1" }|false
EOF
while IFS='|' read -r address job_name; do
  post_changes="$(jq -cn \
    --argjson existing "$post_changes" \
    --argjson next "$(batch_job_change "$address" "$job_name")" \
    '$existing + [$next]')"
done <<'EOF'
module.nomad.module.clickhouse.nomad_job.clickhouse_backup|clickhouse-backup
module.nomad.module.clickhouse.nomad_job.clickhouse_backup_restore|clickhouse-backup-restore
module.nomad.module.clickhouse.nomad_job.clickhouse_migrator|clickhouse-migrator
module.nomad.nomad_job.clean_nfs_cache|filestore-cleanup
EOF
jq -n --argjson changes "$post_changes" \
  --argjson guard "$guard_change" \
  --argjson network_completion "$network_completion" \
  --argjson network_marker "$network_marker" \
  --argjson server_safety_completion "$server_safety_completion" \
  --argjson server_safety_marker "$server_safety_marker" \
  --argjson server_completion "$server_completion" \
  --argjson server_marker "$server_marker" \
  --argjson server_health_completion "$server_health_completion" \
  --argjson server_health_marker "$server_health_marker" \
  --argjson api_completion "$api_completion" \
  --argjson api_marker "$api_marker" \
  --argjson handoff "$handoff_change" \
  '{format_version:"1.2",errored:false,resource_changes:([$guard,$network_completion,$network_marker,$server_safety_completion,$server_safety_marker,$server_completion,$server_marker,$server_health_completion,$server_health_marker,$api_completion,$api_marker,$handoff] + $changes)}' \
  >"$test_root/post.plan"
"$assertion_script" "$test_root/post.plan" "$test_root/terraform" \
  post-api monad-code us-east4-c e2b- >/dev/null

jq '.resource_changes += [{address:"google_compute_instance.worker",change:{actions:["delete"],after:null}}]' \
  "$test_root/post.plan" >"$test_root/extra.plan"
if "$assertion_script" "$test_root/extra.plan" "$test_root/terraform" \
  post-api monad-code us-east4-c e2b- >/dev/null 2>&1; then
  printf 'Unreviewed infrastructure mutation escaped the ACL job-stage plan guard.\n' >&2
  exit 1
fi

jq '(.resource_changes[] | select(.address == "module.nomad.module.ingress.nomad_job.ingress") | .change.after_sensitive.jobspec) = false' \
  "$test_root/post.plan" >"$test_root/unredacted.plan"
if "$assertion_script" "$test_root/unredacted.plan" "$test_root/terraform" \
  post-api monad-code us-east4-c e2b- >/dev/null 2>&1; then
  printf 'Unredacted credential-bearing jobspec escaped the ACL job-stage plan guard.\n' >&2
  exit 1
fi

for sensitive_autoscaler in \
  'module.nomad.module.template_manager_autoscaler[0].nomad_job.nomad_nodepool_apm' \
  'module.nomad.module.monad_worker_autoscaler[0].nomad_job.shadow'; do
  jq --arg address "${sensitive_autoscaler}" '
    (.resource_changes[]
      | select(.address == $address)
      | .change.after_sensitive.jobspec) = false
  ' "$test_root/post.plan" >"$test_root/unredacted-autoscaler.plan"
  if "$assertion_script" "$test_root/unredacted-autoscaler.plan" "$test_root/terraform" \
    post-api monad-code us-east4-c e2b- >/dev/null 2>&1; then
    printf 'Unredacted autoscaler jobspec escaped the ACL job-stage plan guard: %s\n' \
      "${sensitive_autoscaler}" >&2
    exit 1
  fi
done

jq '(.resource_changes[] | select(.address == "module.nomad.module.monad_worker_autoscaler[0].nomad_job.shadow") | .change.after.jobspec) = "meta { shadow = true }"' \
  "$test_root/post.plan" >"$test_root/unmarked-autoscaler.plan"
if "$assertion_script" "$test_root/unmarked-autoscaler.plan" "$test_root/terraform" \
  post-api monad-code us-east4-c e2b- >/dev/null 2>&1; then
  printf 'Active conditional worker autoscaler escaped without the ACL handoff marker.\n' >&2
  exit 1
fi

jq '
  (.resource_changes[]
    | select(.address == "module.nomad.module.clickhouse.nomad_job.clickhouse_migrator")
    | .change.actions) = ["update"]
' "$test_root/post.plan" >"$test_root/batch-rerun.plan"
if "$assertion_script" "$test_root/batch-rerun.plan" "$test_root/terraform" \
  post-api monad-code us-east4-c e2b- >/dev/null 2>&1; then
  printf 'Metadata-only batch job rerun escaped the ACL job-stage plan guard.\n' >&2
  exit 1
fi

for batch_jobspec in \
  "$provider_root/../modules/job-clickhouse/jobs/clickhouse-migrator.hcl" \
  "$provider_root/../modules/job-clickhouse/jobs/clickhouse-backup.hcl" \
  "$provider_root/../modules/job-clickhouse/jobs/clickhouse-backup-restore.hcl" \
  "$provider_root/nomad/jobs/clean-nfs-cache.hcl"; do
  if grep -F 'monad_acl_handoff_revision' "$batch_jobspec" >/dev/null; then
    printf 'Batch jobspec carries an ACL marker that could trigger a rerun: %s\n' \
      "$batch_jobspec" >&2
    exit 1
  fi
done

if FAKE_HUMAN_PLAN='token = 123e4567-e89b-42d3-a456-426614174000' \
  "$assertion_script" "$test_root/post.plan" "$test_root/terraform" \
  post-api monad-code us-east4-c e2b- >/dev/null 2>&1; then
  printf 'UUID-shaped credential escaped the human-plan redaction guard.\n' >&2
  exit 1
fi

# Exercise the stage's projection function against the Nomad provider's real
# schema shape: modify_index is a decimal JSON string even though Nomad's API
# returns JobModifyIndex as a number.
eval "$(awk '
  /^write_job_projection\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$stage_script")"
projection_jobspec=$'job "api" {\n  type = "service"\n  meta { monad_acl_handoff_revision = "1" }\n}'
jq -n --arg jobspec "$projection_jobspec" '
  {
    resource_changes:[{
      address:"module.nomad.module.api.nomad_job.api",
      mode:"managed",
      type:"nomad_job",
      change:{after:{jobspec:$jobspec,modify_index:"123"}}
    }]
  }
' >"$test_root/projection.plan"
terraform_bin="$test_root/terraform"
write_job_projection "$test_root/projection.plan" \
  "$test_root/static-projection.json" "$test_root/static-projection-plan.json" false \
  "$test_root/static-inventory-projection.json"
write_job_projection "$test_root/projection.plan" \
  "$test_root/live-projection.json" "$test_root/live-projection-plan.json" true \
  "$test_root/live-inventory-projection.json"
expected_jobspec_sha256="$(printf '%s' "$projection_jobspec" \
  | shasum -a 256 | awk '{print $1}')"
jq -e --arg sha "$expected_jobspec_sha256" '
  length == 1
  and .[0].expected_modify_index == null
  and .[0].jobspec_sha256 == $sha
' "$test_root/static-projection.json" >/dev/null
jq -e --arg sha "$expected_jobspec_sha256" '
  length == 1
  and .[0].expected_modify_index == 123
  and (.[0].expected_modify_index | type) == "number"
  and .[0].jobspec_sha256 == $sha
' "$test_root/live-projection.json" >/dev/null
jq -e '
  length == 1
  and .[0].address == "module.nomad.module.api.nomad_job.api"
  and .[0].job_id == "api"
  and .[0].job_type == "service"
  and .[0].inventory_class == "managed-runtime"
  and .[0].expected_modify_index == null
  and .[0].submission_source_sha256 == $sha
' --arg sha "$expected_jobspec_sha256" \
  "$test_root/static-inventory-projection.json" >/dev/null
jq -e '
  length == 1
  and .[0].expected_modify_index == 123
' "$test_root/live-inventory-projection.json" >/dev/null

printf 'ACL runtime-job stage plan fixtures passed.\n'
