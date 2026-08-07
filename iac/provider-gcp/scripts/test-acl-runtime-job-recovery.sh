#!/usr/bin/env bash

set -euo pipefail

readonly source_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/acl-runtime-job-stage.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/e2b-acl-job-recovery.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

make_executable() {
  chmod 0755 "$1"
}

write_fixture_tools() {
  local provider_root="$1"
  local scripts="$provider_root/scripts"

  mkdir -p "$scripts"
  cp "$source_script" "$scripts/acl-runtime-job-stage.sh"
  make_executable "$scripts/acl-runtime-job-stage.sh"

  cat >"$scripts/rollout-mutation-lease.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="$1"
shift
case "$mode" in
  acquire)
    [[ "$#" -eq 6 ]]
    token="$6"
    [[ ! -e "${FAKE_LEASE_LIVE:?}" ]]
    jq -nS \
      --arg bucket "$2" \
      --arg project "$3" \
      --arg region "$4" \
      --arg holder "$5" \
      --arg uri "gs://$2/operator-locks/$3/$4/workload-mutation.json" '{
        schema_version:1,
        uri:$uri,
        bucket:$bucket,
        project:$project,
        region:$region,
        holder:$holder,
        generation:"1"
      }' >"$token"
    cp "$token" "${FAKE_LEASE_LIVE}"
    chmod 0600 "$token" "${FAKE_LEASE_LIVE}"
    ;;
  assert-held)
    [[ "$#" -eq 5 ]]
    cmp -s "$5" "${FAKE_LEASE_LIVE:?}"
    ;;
  release)
    [[ "$#" -eq 2 ]]
    cmp -s "$2" "${FAKE_LEASE_LIVE:?}"
    rm -f -- "$2" "${FAKE_LEASE_LIVE}"
    ;;
  *) exit 2 ;;
esac
EOF

  cat >"$scripts/workload-plan-metadata.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="$1"
shift
case "$mode" in
  fingerprint)
    printf '%064d\n' 0
    ;;
  write)
    plan="$1"
    manifest="$2"
    shasum -a 256 "$plan" | awk '{print $1}' >"$manifest"
    chmod 0600 "$manifest"
    ;;
  verify)
    plan="$1"
    manifest="$2"
    [[ -f "$plan" && -f "$manifest" ]]
    [[ "$(shasum -a 256 "$plan" | awk '{print $1}')" == "$(<"$manifest")" ]]
    ;;
  *) exit 2 ;;
esac
EOF

  cat >"$scripts/assert-acl-runtime-job-plan.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
plan="$1"
terraform_bin="$2"
phase="$3"
plan_json="${plan}.assert.json"
"$terraform_bin" show -json "$plan" >"$plan_json"
jq -e --arg phase "$phase" '
  [.resource_changes[]?
    | select(.mode == "managed" and .type == "nomad_job")
    | {
        address,
        actions:.change.actions,
        job_id:(.change.after.jobspec
          | capture("(?m)^[[:space:]]*job[[:space:]]+\\\"(?<id>[A-Za-z0-9._-]+)\\\"").id)
      }
  ] as $jobs
  | (if $phase == "pre-server"
    then ($jobs | length) == 1
      and [$jobs[].job_id] == ["otel-collector-nomad-server"]
    else ($jobs | length) == 2
      and ([$jobs[].job_id] | sort) == ["clickhouse-backup","otel-collector-nomad-server"]
    end)
  and all($jobs[];
    (.actions == ["no-op"] or .actions == ["create"] or .actions == ["update"]))
' "$plan_json" >/dev/null
rm -f -- "$plan_json"
EOF

  cat >"$scripts/assert-workload-artifacts.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '[]'
EOF

  cat >"$scripts/assert-network-hardening-checkpoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

  cp "$(dirname "$source_script")/assert-acl-runtime-job-recovery-token.sh" \
    "$scripts/assert-acl-runtime-job-recovery-token.sh"

  cat >"$scripts/nomad-runtime-job-gate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="$1"
nomad_token="$(cat <&"${NOMAD_JOB_GATE_TOKEN_FD:?}")"
[[ "$nomad_token" == aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa ]]
case "$mode" in
  prepare)
    service_old_sha="$(printf '%s' 'job "otel-collector-nomad-server" {
  type = "service"
  meta { monad_acl_handoff_revision = "0" }
}' | shasum -a 256 | awk '{print $1}')"
    periodic_old_sha="$(printf '%s' 'job "clickhouse-backup" {
  type = "batch"
  periodic { cron = "0 1 * * *" }
}' | shasum -a 256 | awk '{print $1}')"
    jq -e --arg service "$service_old_sha" --arg periodic "$periodic_old_sha" '
      any(.[]; .job_id == "otel-collector-nomad-server"
        and .submission_source_sha256 == $service)
      and any(.[]; .job_id == "clickhouse-backup"
        and .submission_source_sha256 == $periodic)
    ' "${NOMAD_JOB_GATE_INVENTORY_PROJECTION:?}" >/dev/null
    if [[ "${NOMAD_JOB_GATE_DESCENDANT_POLICY:-quiesce}" == observe ]]; then
      jq -e '
        length == 2
        and ([.[].job_id] | sort)
          == ["clickhouse-backup","otel-collector-nomad-server"]
      ' "${NOMAD_JOB_GATE_INVENTORY_PROJECTION}" >/dev/null
      jq -e '
        length == 1
        and .[0].job_id == "otel-collector-nomad-server"
        and .[0].requires_exclusive_transition == false
      ' "${NOMAD_JOB_GATE_PROJECTION:?}" >/dev/null
      projection_sha="$(shasum -a 256 \
        "${NOMAD_JOB_GATE_PROJECTION}" | awk '{print $1}')"
      inventory_sha="$(shasum -a 256 \
        "${NOMAD_JOB_GATE_INVENTORY_PROJECTION}" | awk '{print $1}')"
      jq -nS \
        --arg projection_sha "$projection_sha" \
        --arg inventory_sha "$inventory_sha" '{
          schema_version:1,
          kind:"exclusive-runtime-transition",
          descendant_policy:"observe",
          projection_sha256:$projection_sha,
          inventory_projection_sha256:$inventory_sha,
          live_inventory:{
            schema_version:1,
            kind:"live-nomad-job-inventory",
            projection_sha256:$inventory_sha,
            completeness:"no-unreviewed-top-level-jobs",
            top_level_jobs:[],
            descendant_jobs:[{job_id:"clickhouse-backup/periodic-1"}]
          },
          descendant_quiescence:{
            schema_version:1,
            kind:"nomad-descendant-observation",
            policy:"observe",
            observed_descendants:1,
            observed_active_allocations:0,
            actions:[]
          },
          actions:[]
        }' >"${NOMAD_JOB_GATE_EVIDENCE:?}"
      chmod 0600 "${NOMAD_JOB_GATE_EVIDENCE}"
      exit 0
    fi
    : >"${FAKE_NOMAD_DRIFT:?}"
    jq -nS '[{
      job_id:"otel-collector-nomad-server",
      job_type:"service",
      parent_id:null
    }]' >"${FAKE_LIVE_JOBS:?}"
    projection_sha="$(jq -S 'map(.expected_modify_index = null)' \
      "${NOMAD_JOB_GATE_PROJECTION:?}" | shasum -a 256 | awk '{print $1}')"
    inventory_sha="$(jq -S 'map(.expected_modify_index = null)' \
      "${NOMAD_JOB_GATE_INVENTORY_PROJECTION:?}" | shasum -a 256 | awk '{print $1}')"
    jq -nS \
      --arg projection_sha "$projection_sha" \
      --arg inventory_sha "$inventory_sha" '{
        schema_version:1,
        kind:"exclusive-runtime-transition",
        projection_sha256:$projection_sha,
        inventory_projection_sha256:$inventory_sha,
        live_inventory:{
          schema_version:1,
          kind:"live-nomad-job-inventory",
          projection_sha256:$inventory_sha,
          completeness:"no-unreviewed-live-jobs",
          top_level_jobs:[],
          descendant_jobs:[]
        },
        descendant_quiescence:{
          schema_version:1,
          kind:"nomad-descendant-quiescence",
          descendant_capable_parent_ids:["clickhouse-backup"],
          stable_zero_observations:2,
          remaining_descendants:0,
          remaining_descendant_capable_parents:0,
          remaining_active_allocations:0,
          actions:[{job_id:"periodic-child",action:"purge",http:"200"}]
        },
        actions:[]
      }' >"${NOMAD_JOB_GATE_EVIDENCE:?}"
    ;;
  wait)
    if [[ "${FAKE_WAIT_FAIL_ONCE:-0}" == 1 \
      && ! -e "${FAKE_WAIT_FAILED:?}" ]]; then
      : >"${FAKE_WAIT_FAILED}"
      exit 1
    fi
    completeness=exact
    [[ "${NOMAD_JOB_GATE_DESCENDANT_POLICY:-quiesce}" == observe ]] \
      && completeness=exact-top-level-jobs
    service_new_sha="$(printf '%s' 'job "otel-collector-nomad-server" {
  type = "service"
  meta { monad_acl_handoff_revision = "1" }
}' | shasum -a 256 | awk '{print $1}')"
    periodic_new_sha="$(printf '%s' 'job "clickhouse-backup" {
  type = "batch"
  periodic { cron = "0 0 * * *" }
}' | shasum -a 256 | awk '{print $1}')"
    service_old_sha="$(printf '%s' 'job "otel-collector-nomad-server" {
  type = "service"
  meta { monad_acl_handoff_revision = "0" }
}' | shasum -a 256 | awk '{print $1}')"
    periodic_old_sha="$(printf '%s' 'job "clickhouse-backup" {
  type = "batch"
  periodic { cron = "0 1 * * *" }
}' | shasum -a 256 | awk '{print $1}')"
    periodic_expected_sha="$periodic_new_sha"
    [[ "${NOMAD_JOB_GATE_DESCENDANT_POLICY:-quiesce}" == observe ]] \
      && periodic_expected_sha="$periodic_old_sha"
    jq -e --arg service "$service_new_sha" --arg periodic "$periodic_expected_sha" '
      any(.[]; .job_id == "otel-collector-nomad-server"
        and .submission_source_sha256 == $service)
      and any(.[]; .job_id == "clickhouse-backup"
        and .submission_source_sha256 == $periodic)
    ' "${NOMAD_JOB_GATE_INVENTORY_PROJECTION:?}" >/dev/null
    jq -e --arg service "$service_old_sha" --arg periodic "$periodic_old_sha" '
      any(.[]; .job_id == "otel-collector-nomad-server"
        and .submission_source_sha256 == $service)
      and any(.[]; .job_id == "clickhouse-backup"
        and .submission_source_sha256 == $periodic)
      and all(.[]; .expected_modify_index == null)
    ' "${NOMAD_JOB_GATE_TRANSITION_INVENTORY_PROJECTION:?}" >/dev/null
    [[ "$(shasum -a 256 \
      "${NOMAD_JOB_GATE_TRANSITION_INVENTORY_PROJECTION}" | awk '{print $1}')" \
      == "$(jq -er '.inventory_projection_sha256' \
        "${NOMAD_JOB_GATE_TRANSITION_EVIDENCE:?}")" ]]
    jq -e '
      ([.[] | select(.parent_id == null) | .job_id] | sort)
        == ["clickhouse-backup","otel-collector-nomad-server"]
      and ([.[] | select(.parent_id != null)] | length) == 0
    ' "${FAKE_LIVE_JOBS:?}" >/dev/null
    jq -nS \
      --arg projection_sha "$(shasum -a 256 "${NOMAD_JOB_GATE_PROJECTION:?}" | awk '{print $1}')" \
      --arg inventory_sha "$(shasum -a 256 "${NOMAD_JOB_GATE_INVENTORY_PROJECTION:?}" | awk '{print $1}')" \
      --slurpfile live "${FAKE_LIVE_JOBS:?}" \
      --slurpfile jobs "${NOMAD_JOB_GATE_PROJECTION:?}" \
      --arg completeness "$completeness" '{
        schema_version:1,
        kind:"live-nomad-job-convergence",
        projection_sha256:$projection_sha,
        inventory_projection_sha256:$inventory_sha,
        live_inventory:{
          schema_version:1,
          kind:"live-nomad-job-inventory",
          projection_sha256:$inventory_sha,
          completeness:$completeness,
          top_level_jobs:($live[0] | map(select(.parent_id == null))),
          descendant_jobs:[]
        },
        jobs:($jobs[0] | map({
          address,
          job_id,
          job_type,
          job_modify_index:.expected_modify_index,
          jobspec_sha256
        }))
      }' >"${NOMAD_JOB_GATE_EVIDENCE:?}"
    ;;
  *) exit 2 ;;
esac
chmod 0600 "${NOMAD_JOB_GATE_EVIDENCE}"
EOF

  for helper in \
    rollout-mutation-lease.sh workload-plan-metadata.sh \
    assert-acl-runtime-job-plan.sh assert-workload-artifacts.sh \
    assert-network-hardening-checkpoint.sh \
    assert-acl-runtime-job-recovery-token.sh nomad-runtime-job-gate.sh; do
    make_executable "$scripts/$helper"
  done

  cat >"$provider_root/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -chdir=* ]]; then shift; fi
command="$1"
shift
case "$command" in
  plan)
    out=""
    detailed=false
    for argument in "$@"; do
      case "$argument" in
        -out=*) out="${argument#-out=}" ;;
        -detailed-exitcode) detailed=true ;;
      esac
    done
    [[ -n "$out" ]]
    if [[ "$detailed" == true && -e "${FAKE_NOMAD_DRIFT:?}" ]]; then
      printf '%s\n' recreate >"$out"
      exit 2
    fi
    printf '%s\n' clean >"$out"
    ;;
  show)
    [[ "$1" == -json ]]
    if [[ "$#" -eq 1 ]]; then
      state_service_revision=0
      state_periodic_cron='0 1 * * *'
      if [[ -e "${FAKE_STATE_APPLIED:?}" ]]; then
        state_service_revision=1
        if [[ "${ACL_RUNTIME_JOB_PHASE:?}" != pre-server ]]; then
          state_periodic_cron='0 0 * * *'
        fi
      fi
      state_service_jobspec="$(printf 'job \"otel-collector-nomad-server\" {\n  type = \"service\"\n  meta { monad_acl_handoff_revision = \"%s\" }\n}' "$state_service_revision")"
      state_periodic_jobspec="$(printf 'job \"clickhouse-backup\" {\n  type = \"batch\"\n  periodic { cron = \"%s\" }\n}' "$state_periodic_cron")"
      jq -n \
        --arg service "$state_service_jobspec" \
        --arg periodic "$state_periodic_jobspec" '{
          values:{root_module:{child_modules:[{
            address:"module.nomad",
            resources:[
              {
                address:"module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server",
                mode:"managed",
                type:"nomad_job",
                values:{jobspec:$service,modify_index:"42"}
              },
              {
                address:"module.nomad.module.clickhouse.nomad_job.clickhouse_backup",
                mode:"managed",
                type:"nomad_job",
                values:{jobspec:$periodic,modify_index:"43"}
              }
            ]
          }]}}
        }'
      exit 0
    fi
    plan_path="$2"
    plan_kind="$(<"$plan_path")"
    action=no-op
    if [[ "$plan_kind" == recreate \
      && "${FAKE_FORCE_NOOP_RECOVERY:-0}" != 1 ]]; then
      action=create
    elif [[ "$plan_kind" == initial ]]; then
      action=update
    fi
    service_before=$'job "otel-collector-nomad-server" {\n  type = "service"\n  meta { monad_acl_handoff_revision = "0" }\n}'
    service_after=$'job "otel-collector-nomad-server" {\n  type = "service"\n  meta { monad_acl_handoff_revision = "1" }\n}'
    periodic_before=$'job "clickhouse-backup" {\n  type = "batch"\n  periodic { cron = "0 1 * * *" }\n}'
    periodic_after=$'job "clickhouse-backup" {\n  type = "batch"\n  periodic { cron = "0 0 * * *" }\n}'
    jq -n \
      --arg action "$action" \
      --arg service_before "$service_before" \
      --arg service_after "$service_after" \
      --arg periodic_before "$periodic_before" \
      --arg periodic_after "$periodic_after" '
      def change($before; $after): {
        actions:[$action],
        before:(if $action == "create" then null
          elif $action == "update" then {jobspec:$before,modify_index:"42"}
          else {jobspec:$after,modify_index:"42"} end),
        after:{jobspec:$after,modify_index:"42"},
        after_unknown:{},
        before_sensitive:{},
        after_sensitive:{}
      };
      {resource_changes:([{
          address:"module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server",
          mode:"managed",
          type:"nomad_job",
          name:"otel_collector_nomad_server",
          provider_name:"registry.terraform.io/hashicorp/nomad",
          change:change($service_before; $service_after)
        }] + (if env.ACL_RUNTIME_JOB_PHASE == "pre-server" then [] else [{
          address:"module.nomad.module.clickhouse.nomad_job.clickhouse_backup",
          mode:"managed",
          type:"nomad_job",
          name:"clickhouse_backup",
          provider_name:"registry.terraform.io/hashicorp/nomad",
          change:change($periodic_before; $periodic_after)
        }] end))}
    '
    ;;
  state)
    [[ "$1" == pull ]]
    jq -n --argjson serial "$(<"${FAKE_TF_SERIAL:?}")" '{
      version:4,
      terraform_version:"1.7.5",
      serial:$serial,
      lineage:"fixture-lineage",
      outputs:{},
      resources:[]
    }'
    ;;
  apply)
    count="$(( $(<"${FAKE_APPLY_COUNT:?}") + 1 ))"
    printf '%s\n' "$count" >"${FAKE_APPLY_COUNT}"
    serial="$(( $(<"${FAKE_TF_SERIAL:?}") + 1 ))"
    printf '%s\n' "$serial" >"${FAKE_TF_SERIAL}"
    if [[ "${FAKE_PARTIAL_APPLY_ONCE:-0}" == 1 \
      && ! -e "${FAKE_PARTIAL_APPLY_MARKER:?}" ]]; then
      : >"${FAKE_PARTIAL_APPLY_MARKER}"
      exit 1
    fi
    rm -f -- "${FAKE_NOMAD_DRIFT:?}"
    : >"${FAKE_STATE_APPLIED:?}"
    jq -nS '[
      {job_id:"otel-collector-nomad-server",job_type:"service",parent_id:null},
      {job_id:"clickhouse-backup",job_type:"batch",parent_id:null}
    ]' >"${FAKE_LIVE_JOBS:?}"
    ;;
  *) exit 2 ;;
esac
EOF
  make_executable "$provider_root/terraform"

  cat >"$provider_root/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
EOF
  make_executable "$provider_root/gcloud"
}

setup_scenario() {
  local scenario="$1"
  scenario_root="$test_root/$scenario"
  provider_root="$scenario_root/provider"
  repo_root="$scenario_root/source"
  mkdir -p "$provider_root" "$repo_root"
  write_fixture_tools "$provider_root"
  printf '%s\n' source >"$repo_root/source"
  (
    cd "$repo_root"
    git init -q
    git config user.name fixture
    git config user.email fixture@example.invalid
    git add source
    git commit -qm fixture
  )
  for file in env tfvars topology packer; do
    printf '%s\n' fixture >"$scenario_root/$file"
  done
  printf '%s\n' '{"stage":"api"}' >"$scenario_root/checkpoint.json"
  printf '%s\n' 1 >"$scenario_root/tf-serial"
  printf '%s\n' 0 >"$scenario_root/apply-count"
  printf '%s\n' initial >"$scenario_root/initial.plan"
  shasum -a 256 "$scenario_root/initial.plan" | awk '{print $1}' \
    >"$scenario_root/initial.plan.manifest"
  chmod 0600 "$scenario_root/initial.plan" \
    "$scenario_root/initial.plan.manifest"

  export FAKE_LEASE_LIVE="$scenario_root/lease-live"
  export FAKE_NOMAD_DRIFT="$scenario_root/nomad-drift"
  export FAKE_WAIT_FAILED="$scenario_root/wait-failed"
  export FAKE_TF_SERIAL="$scenario_root/tf-serial"
  export FAKE_APPLY_COUNT="$scenario_root/apply-count"
  export FAKE_PARTIAL_APPLY_MARKER="$scenario_root/partial-apply"
  export FAKE_STATE_APPLIED="$scenario_root/state-applied"
  export FAKE_LIVE_JOBS="$scenario_root/live-jobs.json"
  jq -nS '[
    {job_id:"otel-collector-nomad-server",job_type:"service",parent_id:null},
    {job_id:"clickhouse-backup",job_type:"batch",parent_id:null},
    {job_id:"clickhouse-backup/periodic-1",job_type:"batch",parent_id:"clickhouse-backup"}
  ]' >"$FAKE_LIVE_JOBS"
}

run_stage() {
  local recovery_token="${1:-}"
  local phase="${2:-post-api}"
  ACL_RUNTIME_JOB_PHASE="$phase" \
  ACL_RUNTIME_JOB_ENV=dev \
  ACL_RUNTIME_JOB_ENV_FILE="$scenario_root/env" \
  ACL_RUNTIME_JOB_TF_VAR_FILE="$scenario_root/tfvars" \
  ACL_RUNTIME_JOB_PLAN="$scenario_root/initial.plan" \
  ACL_RUNTIME_JOB_PLAN_MANIFEST="$scenario_root/initial.plan.manifest" \
  ACL_RUNTIME_JOB_COMPLETION_EVIDENCE="$scenario_root/completion.json" \
  ACL_RUNTIME_JOB_CHECKPOINT="$scenario_root/checkpoint.json" \
  ACL_RUNTIME_JOB_TERRAFORM_BIN="$provider_root/terraform" \
  ACL_RUNTIME_JOB_GCLOUD_BIN="$provider_root/gcloud" \
  ACL_RUNTIME_JOB_GCP_PROJECT_ID=monad-code \
  ACL_RUNTIME_JOB_GCP_REGION=us-east4 \
  ACL_RUNTIME_JOB_GCP_ZONE=us-east4-c \
  ACL_RUNTIME_JOB_PREFIX=e2b- \
  ACL_RUNTIME_JOB_STATE_BUCKET=monad-code-terraform-state \
  ACL_RUNTIME_JOB_STATE_PREFIX=dev \
  ACL_RUNTIME_JOB_CORE_IMAGE_REVISION=fixture \
  ACL_RUNTIME_JOB_BINARY_BUCKET=fixture-bucket \
  ACL_RUNTIME_JOB_TOPOLOGY_POLICY="$scenario_root/topology" \
  ACL_RUNTIME_JOB_PACKER_TEMPLATE="$scenario_root/packer" \
  ACL_RUNTIME_JOB_REPO_ROOT="$repo_root" \
  ACL_RUNTIME_JOB_RECOVERY_TOKEN="$recovery_token" \
  ACL_RUNTIME_JOB_DOMAIN_NAME=example.invalid \
  ACL_RUNTIME_JOB_NOMAD_TOKEN_SECRET_VERSION='projects/monad-code/secrets/e2b-nomad-secret-id/versions/1' \
  ACL_RUNTIME_JOB_CURL_BIN=/usr/bin/curl \
    "$provider_root/scripts/acl-runtime-job-stage.sh" apply
}

find_recovery_token() {
  find "$provider_root" -type f -name lease-token.json -print -quit
}

assert_no_recovery_secret_artifacts() {
  if find "$provider_root" -type f \
      \( -name nomad-token -o -name '*.raw' -o -name curl.config \) \
      -print -quit | grep -q .; then
    printf 'Recovery directory retained a plaintext secret-bearing artifact.\n' >&2
    exit 1
  fi
  if find "$provider_root" -type f -path '*/.workload-apply.acl-runtime.*/*' \
      -exec grep -Il 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' {} + \
      | grep -q .; then
    printf 'Recovery directory retained the Nomad management token bytes.\n' >&2
    exit 1
  fi
}

assert_recovery_token_scope() {
  local recovery_token="$1"
  local wrong_workflow="$scenario_root/wrong-workflow-token.json"
  local validator="$provider_root/scripts/assert-acl-runtime-job-recovery-token.sh"

  "$validator" "$recovery_token" monad-code-terraform-state monad-code \
    us-east4 post-api api dev dev "$repo_root" >/dev/null
  if "$validator" "$recovery_token" monad-code-terraform-state monad-code \
    us-east4 pre-server network dev dev "$repo_root" >/dev/null 2>&1; then
    printf 'Post-api recovery authority was accepted for pre-server.\n' >&2
    exit 1
  fi
  jq '.holder |= sub("^acl-job-apply"; "cluster-apply")' \
    "$recovery_token" >"$wrong_workflow"
  chmod 0600 "$wrong_workflow"
  if "$validator" "$wrong_workflow" monad-code-terraform-state monad-code \
    us-east4 post-api api dev dev "$repo_root" >/dev/null 2>&1; then
    printf 'Another rollout workflow authority was accepted for ACL recovery.\n' >&2
    exit 1
  fi
}

run_reviewed_recreation_scenario() {
  setup_scenario recreate
  first_log="$scenario_root/first-apply.log"
  if run_stage >"$first_log" 2>&1; then
    printf 'Destructive prepare applied a stale reviewed plan.\n' >&2
    exit 1
  fi
  recovery_token="$(find_recovery_token)"
  [[ -n "$recovery_token" && -f "$recovery_token" ]]
  assert_recovery_token_scope "$recovery_token"
  assert_no_recovery_secret_artifacts
  [[ -f "$scenario_root/initial.plan.manifest.recovery.json" ]] || {
    sed -n '1,120p' "$first_log" >&2
    exit 1
  }
  jq -e '.state == {lineage:"fixture-lineage",serial:1}' \
    "$scenario_root/initial.plan.manifest.recovery.json" >/dev/null
  run_stage "$recovery_token" >/dev/null
  [[ "$(<"$scenario_root/apply-count")" == 1 ]]
  [[ ! -e "$scenario_root/nomad-drift" ]]
  [[ -f "$scenario_root/completion.json" ]]
  [[ ! -e "$FAKE_LEASE_LIVE" && ! -e "$recovery_token" ]]
  assert_no_recovery_secret_artifacts
}

run_noop_recovery_rejected_scenario() {
  setup_scenario noop-recovery
  export FAKE_FORCE_NOOP_RECOVERY=1
  if run_stage >/dev/null 2>&1; then
    printf 'No-op recovery plan was accepted after destructive quiescence.\n' >&2
    exit 1
  fi
  [[ ! -e "$scenario_root/initial.plan.manifest.recovery.json" ]]
  [[ "$(<"$scenario_root/apply-count")" == 0 ]]
  assert_no_recovery_secret_artifacts
  unset FAKE_FORCE_NOOP_RECOVERY
}

run_pre_server_complete_inventory_scenario() {
  setup_scenario pre-server-inventory
  printf '%s\n' '{"stage":"network"}' >"$scenario_root/checkpoint.json"
  run_stage '' pre-server >/dev/null
  [[ "$(<"$scenario_root/apply-count")" == 1 ]]
  [[ -f "$scenario_root/completion.json" ]]
  jq -e '
    .phase == "pre-server"
    and .exclusive_transition.descendant_policy == "observe"
    and .exclusive_transition.descendant_quiescence.kind
      == "nomad-descendant-observation"
    and ([.job_inventory_projection[].job_id] | sort)
      == ["clickhouse-backup","otel-collector-nomad-server"]
    and ([.live_job_inventory_projection[].job_id] | sort)
      == ["clickhouse-backup","otel-collector-nomad-server"]
  ' "$scenario_root/completion.json" >/dev/null
  [[ ! -e "$scenario_root/initial.plan.manifest.recovery.json" ]]
  assert_no_recovery_secret_artifacts
}

run_clean_state_recovery_scenario() {
  setup_scenario clean-recovery
  if run_stage >/dev/null 2>&1; then exit 1; fi
  recovery_token="$(find_recovery_token)"
  FAKE_WAIT_FAIL_ONCE=1 run_stage "$recovery_token" >/dev/null 2>&1 || true
  [[ "$(<"$scenario_root/apply-count")" == 1 ]]
  [[ -e "$scenario_root/wait-failed" && ! -e "$scenario_root/nomad-drift" ]]
  FAKE_WAIT_FAIL_ONCE=1 run_stage "$recovery_token" >/dev/null
  [[ "$(<"$scenario_root/apply-count")" == 1 ]]
  [[ -f "$scenario_root/completion.json" ]]
  [[ ! -e "$FAKE_LEASE_LIVE" && ! -e "$recovery_token" ]]
}

run_partial_apply_scenario() {
  setup_scenario partial
  if run_stage >/dev/null 2>&1; then exit 1; fi
  recovery_token="$(find_recovery_token)"
  FAKE_PARTIAL_APPLY_ONCE=1 run_stage "$recovery_token" >/dev/null 2>&1 || true
  [[ "$(<"$scenario_root/apply-count")" == 1 ]]
  [[ "$(<"$scenario_root/tf-serial")" == 2 && -e "$scenario_root/nomad-drift" ]]
  if FAKE_PARTIAL_APPLY_ONCE=1 run_stage "$recovery_token" >/dev/null 2>&1; then
    printf 'State-serial advance reused the stale recovery plan.\n' >&2
    exit 1
  fi
  jq -e '.state == {lineage:"fixture-lineage",serial:2}' \
    "$scenario_root/initial.plan.manifest.recovery.json" >/dev/null
  FAKE_PARTIAL_APPLY_ONCE=1 run_stage "$recovery_token" >/dev/null
  [[ "$(<"$scenario_root/apply-count")" == 2 ]]
  [[ ! -e "$scenario_root/nomad-drift" ]]
  [[ -f "$scenario_root/completion.json" ]]
}

run_reviewed_recreation_scenario
run_noop_recovery_rejected_scenario
run_pre_server_complete_inventory_scenario
run_clean_state_recovery_scenario
run_partial_apply_scenario

printf 'ACL runtime-job reviewed recovery, state-serial advance, and convergence-only fixtures passed.\n'
