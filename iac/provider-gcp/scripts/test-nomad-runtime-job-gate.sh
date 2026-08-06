#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly gate="$script_dir/nomad-runtime-job-gate.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/e2b-nomad-job-gate-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

projection="$test_root/projection.json"
live_projection="$test_root/live-projection.json"
inventory_projection="$test_root/inventory-projection.json"
live_inventory_projection="$test_root/live-inventory-projection.json"
token_file="$test_root/nomad-token"
transition="$test_root/transition.json"
curl_log="$test_root/curl.log"
delete_marker="$test_root/deleted"
fake_curl="$test_root/fake-curl"
readonly token='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'

cat >"$projection" <<'JSON'
[
  {
    "address":"module.nomad.module.api.nomad_job.api",
    "job_id":"api",
    "job_type":"service",
    "requires_exclusive_transition":false,
    "jobspec_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "expected_modify_index":null
  },
  {
    "address":"module.nomad.module.orchestrator[0].nomad_job.orchestrator",
    "job_id":"orchestrator-dev",
    "job_type":"system",
    "requires_exclusive_transition":true,
    "jobspec_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "expected_modify_index":null
  }
]
JSON
mv "$projection" "$test_root/projection.raw.json"
jq -S . "$test_root/projection.raw.json" >"$projection"
jq -S 'map(
  if .job_id == "api"
  then .expected_modify_index = 40
  else .expected_modify_index = 50
  end
)' "$projection" >"$live_projection"
api_submission_source='job "api" { type = "service" }'
backup_submission_source='job "clickhouse-backup" { type = "batch" }'
orchestrator_submission_source='job "orchestrator-dev" { type = "system" }'
api_post_submission_source='job "api" { type = "service" meta { monad_acl_handoff_revision = "1" } }'
orchestrator_post_submission_source='job "orchestrator-dev" { type = "system" meta { monad_acl_handoff_revision = "1" } }'
api_submission_sha256="$(printf '%s' "$api_submission_source" \
  | shasum -a 256 | awk '{print $1}')"
backup_submission_sha256="$(printf '%s' "$backup_submission_source" \
  | shasum -a 256 | awk '{print $1}')"
orchestrator_submission_sha256="$(printf '%s' "$orchestrator_submission_source" \
  | shasum -a 256 | awk '{print $1}')"
api_post_submission_sha256="$(printf '%s' "$api_post_submission_source" \
  | shasum -a 256 | awk '{print $1}')"
orchestrator_post_submission_sha256="$(printf '%s' "$orchestrator_post_submission_source" \
  | shasum -a 256 | awk '{print $1}')"
jq -nS \
  --arg api_sha "$api_submission_sha256" \
  --arg backup_sha "$backup_submission_sha256" \
  --arg orchestrator_sha "$orchestrator_submission_sha256" '
[
  {
    "address":"module.nomad.module.api.nomad_job.api",
    "child_mode":"none",
    "expected_modify_index":null,
    "inventory_class":"managed-runtime",
    "job_id":"api",
    "job_type":"service",
    "submission_source_sha256":$api_sha
  },
  {
    "address":"module.nomad.module.clickhouse.nomad_job.clickhouse_backup",
    "child_mode":"periodic",
    "expected_modify_index":null,
    "inventory_class":"token-free-batch",
    "job_id":"clickhouse-backup",
    "job_type":"batch",
    "submission_source_sha256":$backup_sha
  },
  {
    "address":"module.nomad.module.orchestrator[0].nomad_job.orchestrator",
    "child_mode":"none",
    "expected_modify_index":null,
    "inventory_class":"managed-runtime",
    "job_id":"orchestrator-dev",
    "job_type":"system",
    "submission_source_sha256":$orchestrator_sha
  }
]
' >"$inventory_projection"
jq -S . "$inventory_projection" >"$test_root/inventory-projection.sorted.json"
mv "$test_root/inventory-projection.sorted.json" "$inventory_projection"
jq -S \
  --arg api_post_sha "$api_post_submission_sha256" \
  --arg orchestrator_post_sha "$orchestrator_post_submission_sha256" 'map(
  if .job_id == "api" then .expected_modify_index = 40
    | .submission_source_sha256 = $api_post_sha
  elif .job_id == "clickhouse-backup" then .expected_modify_index = 60
  else .expected_modify_index = 50
    | .submission_source_sha256 = $orchestrator_post_sha
  end
)' "$inventory_projection" >"$live_inventory_projection"
printf '%s\n' "$token" >"$token_file"
chmod 0600 "$token_file"

cat >"$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_NOMAD_CURL_LOG:?}"
method=GET
output=''
url=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --config | --noproxy | --write-out) shift 2 ;;
    --disable) shift ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$output" && -n "$url" ]]
path="${url#https://nomad.example.invalid}"

respond() {
  local code="$1"
  local body="${2:-}"
  printf '%s' "$body" >"$output"
  printf '%s' "$code"
  exit 0
}

respond_submission() {
  local id="$1"
  local version="$2"
  local source="$3"
  local body
  body="$(jq -n \
    --arg id "$id" \
    --argjson version "$version" \
    --arg source "$source" '
      {
        JobID:$id,
        Namespace:"default",
        Version:$version,
        Format:"hcl2",
        Source:$source,
        VariableFlags:null,
        Variables:""
      }
    ')"
  respond 200 "$body"
}

if [[ "${FAKE_NOMAD_MODE:?}" == prepare ]]; then
  case "$method:$path" in
    'GET:/v1/jobs?namespace=default')
      if [[ -e "${FAKE_NOMAD_QUIESCE_MARKER:?}" ]]; then
        respond 200 '[
          {"ID":"api","Namespace":"default","ParentID":"","Type":"service","Status":"running","Version":4,"JobModifyIndex":40},
          {"ID":"orchestrator-dev","Namespace":"default","ParentID":"","Type":"system","Status":"running","Version":3,"JobModifyIndex":30}
        ]'
      fi
      respond 200 '[
        {"ID":"api","Namespace":"default","ParentID":"","Type":"service","Status":"running","Version":4,"JobModifyIndex":40},
        {"ID":"clickhouse-backup","Namespace":"default","ParentID":"","Type":"batch","Status":"running","Version":6,"JobModifyIndex":60},
        {"ID":"clickhouse-backup/periodic-20260807","Namespace":"default","ParentID":"clickhouse-backup","Type":"batch","Status":"dead","Version":0,"JobModifyIndex":61},
        {"ID":"orchestrator-dev","Namespace":"default","ParentID":"","Type":"system","Status":"running","Version":3,"JobModifyIndex":30}
      ]'
      ;;
    'GET:/v1/job/api/submission?version=4&namespace=default')
      respond_submission api 4 'job "api" { type = "service" }'
      ;;
    'GET:/v1/job/clickhouse-backup/submission?version=6&namespace=default')
      respond_submission clickhouse-backup 6 'job "clickhouse-backup" { type = "batch" }'
      ;;
    'GET:/v1/job/orchestrator-dev/submission?version=3&namespace=default')
      respond_submission orchestrator-dev 3 'job "orchestrator-dev" { type = "system" }'
      ;;
    'DELETE:/v1/job/clickhouse-backup?purge=true')
      : >"${FAKE_NOMAD_QUIESCE_MARKER:?}"
      respond 200 '{"EvalID":null,"EvalCreateIndex":null}'
      ;;
    'DELETE:/v1/job/clickhouse-backup%2Fperiodic-20260807?purge=true')
      : >"${FAKE_NOMAD_QUIESCE_MARKER:?}"
      respond 200 '{"EvalID":null,"EvalCreateIndex":null}'
      ;;
    'GET:/v1/allocations?namespace=default')
      respond 200 '[]'
      ;;
    'GET:/v1/job/orchestrator-dev')
      if [[ -e "${FAKE_NOMAD_DELETE_MARKER:?}" ]]; then
        respond 404 '{}'
      fi
      respond 200 '{"ID":"orchestrator-dev","Namespace":"default","Type":"system","Version":3,"JobModifyIndex":30,"Meta":{"monad_acl_handoff_revision":"1"}}'
      ;;
    'GET:/v1/job/orchestrator-dev/allocations?all=true')
      if [[ -e "${FAKE_NOMAD_DELETE_MARKER:?}" ]]; then
        if [[ "${FAKE_NOMAD_SCENARIO:-healthy}" == late-allocation ]]; then
          respond 200 '[
            {"ID":"55555555-5555-4555-8555-555555555555","JobVersion":3,"DesiredStatus":"stop","ClientStatus":"complete"},
            {"ID":"66666666-6666-4666-8666-666666666666","JobVersion":3,"DesiredStatus":"run","ClientStatus":"running"}
          ]'
        fi
        respond 200 '[{"ID":"55555555-5555-4555-8555-555555555555","JobVersion":3,"DesiredStatus":"stop","ClientStatus":"complete"}]'
      fi
      if [[ "${FAKE_NOMAD_SCENARIO:-healthy}" == unsafe-old ]]; then
        respond 200 '[{"ID":"55555555-5555-4555-8555-555555555555","JobVersion":3,"DesiredStatus":"run","ClientStatus":"failed"}]'
      fi
      respond 200 '[{"ID":"55555555-5555-4555-8555-555555555555","JobVersion":3,"DesiredStatus":"run","ClientStatus":"running"}]'
      ;;
    'DELETE:/v1/job/orchestrator-dev?purge=true')
      : >"${FAKE_NOMAD_DELETE_MARKER:?}"
      respond 200 '{"EvalID":"11111111-1111-4111-8111-111111111111","EvalCreateIndex":31}'
      ;;
    'GET:/v1/allocation/55555555-5555-4555-8555-555555555555')
      if [[ "${FAKE_NOMAD_SCENARIO:-healthy}" == unsafe-old ]]; then
        respond 200 '{"ID":"55555555-5555-4555-8555-555555555555","DesiredStatus":"run","ClientStatus":"failed"}'
      fi
      respond 200 '{"ID":"55555555-5555-4555-8555-555555555555","DesiredStatus":"stop","ClientStatus":"complete"}'
      ;;
    *) respond 500 '{"error":"unexpected prepare request"}' ;;
  esac
fi

scenario="${FAKE_NOMAD_SCENARIO:-healthy}"
case "$method:$path" in
  'GET:/v1/jobs?namespace=default')
    if [[ "$scenario" == extra-job ]]; then
      respond 200 '[
        {"ID":"api","Namespace":"default","ParentID":"","Type":"service","Status":"running","Version":4,"JobModifyIndex":40},
        {"ID":"clickhouse-backup","Namespace":"default","ParentID":"","Type":"batch","Status":"running","Version":6,"JobModifyIndex":60},
        {"ID":"orchestrator-dev","Namespace":"default","ParentID":"","Type":"system","Status":"running","Version":4,"JobModifyIndex":50},
        {"ID":"rogue-default-job","Namespace":"default","ParentID":"","Type":"service","Status":"running","Version":1,"JobModifyIndex":70}
      ]'
    fi
    if [[ "$scenario" == spoofed-child ]]; then
      respond 200 '[
        {"ID":"api","Namespace":"default","ParentID":"","Type":"service","Status":"running","Version":4,"JobModifyIndex":40},
        {"ID":"clickhouse-backup","Namespace":"default","ParentID":"","Type":"batch","Status":"running","Version":6,"JobModifyIndex":60},
        {"ID":"manual-token-job","Namespace":"default","ParentID":"clickhouse-backup","Type":"batch","Status":"running","Version":1,"JobModifyIndex":62},
        {"ID":"orchestrator-dev","Namespace":"default","ParentID":"","Type":"system","Status":"running","Version":4,"JobModifyIndex":50}
      ]'
    fi
    respond 200 '[
      {"ID":"api","Namespace":"default","ParentID":"","Type":"service","Status":"running","Version":4,"JobModifyIndex":40},
      {"ID":"clickhouse-backup","Namespace":"default","ParentID":"","Type":"batch","Status":"running","Version":6,"JobModifyIndex":60},
      {"ID":"orchestrator-dev","Namespace":"default","ParentID":"","Type":"system","Status":"running","Version":4,"JobModifyIndex":50}
    ]'
    ;;
  'GET:/v1/job/api/submission?version=4&namespace=default')
    if [[ "$scenario" == missing-submission ]]; then
      respond 404 '{}'
    fi
    if [[ "$scenario" == changed-submission ]]; then
      respond_submission api 4 'job "api" { type = "service" env { CONSUL_TOKEN = "legacy" } }'
    fi
    respond_submission api 4 'job "api" { type = "service" meta { monad_acl_handoff_revision = "1" } }'
    ;;
  'GET:/v1/job/clickhouse-backup/submission?version=6&namespace=default')
    respond_submission clickhouse-backup 6 'job "clickhouse-backup" { type = "batch" }'
    ;;
  'GET:/v1/job/orchestrator-dev/submission?version=4&namespace=default')
    respond_submission orchestrator-dev 4 'job "orchestrator-dev" { type = "system" meta { monad_acl_handoff_revision = "1" } }'
    ;;
  'GET:/v1/nodes')
    respond 200 '[
      {"ID":"node-1","Status":"ready","SchedulingEligibility":"eligible","Drain":false,"NodePool":"default","Datacenter":"us-east4"},
      {"ID":"node-2","Status":"ready","SchedulingEligibility":"eligible","Drain":false,"NodePool":"default","Datacenter":"us-east4"}
    ]'
    ;;
  'GET:/v1/job/api')
    if [[ "$scenario" == wrong-index ]]; then
      respond 200 '{"ID":"api","Namespace":"default","Type":"service","Status":"running","Version":4,"JobModifyIndex":41,"Meta":{"monad_acl_handoff_revision":"1"}}'
    fi
    respond 200 '{"ID":"api","Namespace":"default","Type":"service","Status":"running","Version":4,"JobModifyIndex":40,"Meta":{"monad_acl_handoff_revision":"1"}}'
    ;;
  'GET:/v1/job/api/evaluations')
    if [[ "$scenario" == pending ]]; then
      respond 200 '[{"ID":"22222222-2222-4222-8222-222222222222","CreateIndex":40,"JobModifyIndex":40,"Status":"pending","FailedTGAllocs":{},"BlockedEval":null}]'
    fi
    respond 200 '[{"ID":"22222222-2222-4222-8222-222222222222","CreateIndex":40,"JobModifyIndex":40,"Status":"complete","FailedTGAllocs":{},"BlockedEval":null}]'
    ;;
  'GET:/v1/job/api/deployments')
    respond 200 '[{"ID":"33333333-3333-4333-8333-333333333333","CreateIndex":41,"JobVersion":4,"Status":"successful","TaskGroups":{"web":{"DesiredTotal":1,"PlacedAllocs":1,"HealthyAllocs":1,"UnhealthyAllocs":0}}}]'
    ;;
  'GET:/v1/job/api/allocations?all=true')
    if [[ "$scenario" == stale ]]; then
      respond 200 '[
        {"ID":"api-current","NodeID":"node-1","TaskGroup":"web","JobVersion":4,"DesiredStatus":"run","ClientStatus":"running","DeploymentStatus":{"Healthy":true},"TaskStates":{"api":{"State":"running","Failed":false}}},
        {"ID":"api-stale","NodeID":"node-2","TaskGroup":"web","JobVersion":3,"DesiredStatus":"run","ClientStatus":"running","DeploymentStatus":{"Healthy":true},"TaskStates":{"api":{"State":"running","Failed":false}}}
      ]'
    fi
    respond 200 '[{"ID":"api-current","NodeID":"node-1","TaskGroup":"web","JobVersion":4,"DesiredStatus":"run","ClientStatus":"running","DeploymentStatus":{"Healthy":true},"TaskStates":{"api":{"State":"running","Failed":false}}}]'
    ;;
  'GET:/v1/job/orchestrator-dev')
    respond 200 '{"ID":"orchestrator-dev","Namespace":"default","Type":"system","Status":"running","Version":4,"JobModifyIndex":50,"NodePool":"default","Datacenters":["us-east4"],"TaskGroups":[{"Name":"orchestrator"}],"Meta":{"monad_acl_handoff_revision":"1"}}'
    ;;
  'GET:/v1/job/orchestrator-dev/evaluations')
    respond 200 '[{"ID":"44444444-4444-4444-8444-444444444444","CreateIndex":50,"JobModifyIndex":50,"Status":"complete","FailedTGAllocs":{},"BlockedEval":null}]'
    ;;
  'GET:/v1/job/orchestrator-dev/deployments')
    respond 200 '[]'
    ;;
  'GET:/v1/job/orchestrator-dev/allocations?all=true')
    if [[ "$scenario" == missing-node ]]; then
      respond 200 '[{"ID":"orch-1","NodeID":"node-1","TaskGroup":"orchestrator","JobVersion":4,"DesiredStatus":"run","ClientStatus":"running","TaskStates":{"orchestrator":{"State":"running","Failed":false}}}]'
    fi
    respond 200 '[
      {"ID":"orch-1","NodeID":"node-1","TaskGroup":"orchestrator","JobVersion":4,"DesiredStatus":"run","ClientStatus":"running","TaskStates":{"orchestrator":{"State":"running","Failed":false}}},
      {"ID":"orch-2","NodeID":"node-2","TaskGroup":"orchestrator","JobVersion":4,"DesiredStatus":"run","ClientStatus":"running","TaskStates":{"orchestrator":{"State":"running","Failed":false}}}
    ]'
    ;;
  *) respond 500 '{"error":"unexpected wait request"}' ;;
esac
EOF
chmod 0755 "$fake_curl"

run_gate() {
  local mode="$1"
  local evidence="$2"
  local scenario="${3:-healthy}"
  local selected_projection="$projection"
  local selected_inventory_projection="$inventory_projection"
  [[ "$mode" == prepare ]] || selected_projection="$live_projection"
  [[ "$mode" == prepare ]] \
    || selected_inventory_projection="$live_inventory_projection"
  FAKE_NOMAD_MODE="$mode" \
    FAKE_NOMAD_SCENARIO="$scenario" \
    FAKE_NOMAD_CURL_LOG="$curl_log" \
    FAKE_NOMAD_DELETE_MARKER="$delete_marker" \
    FAKE_NOMAD_QUIESCE_MARKER="$test_root/quiesced" \
    NOMAD_JOB_GATE_PROJECTION="$selected_projection" \
    NOMAD_JOB_GATE_INVENTORY_PROJECTION="$selected_inventory_projection" \
    NOMAD_JOB_GATE_TOKEN_FILE="$token_file" \
    NOMAD_JOB_GATE_BASE_URL='https://nomad.example.invalid' \
    NOMAD_JOB_GATE_EVIDENCE="$evidence" \
    NOMAD_JOB_GATE_TRANSITION_EVIDENCE="$transition" \
    NOMAD_JOB_GATE_TRANSITION_INVENTORY_PROJECTION="$inventory_projection" \
    NOMAD_JOB_GATE_CURL_BIN="$fake_curl" \
    NOMAD_JOB_GATE_TIMEOUT_SECONDS=3 \
    NOMAD_JOB_GATE_POLL_SECONDS=0 \
    "$gate" "$mode"
}

: >"$curl_log"
rm -f -- "$test_root/quiesced"
run_gate prepare "$transition"
jq -e '
  .kind == "exclusive-runtime-transition"
  and .live_inventory.kind == "live-nomad-job-inventory"
  and .live_inventory.completeness == "no-unreviewed-live-jobs"
  and ([.live_inventory.top_level_jobs[].job_id] | sort)
    == ["api","orchestrator-dev"]
  and .live_inventory.descendant_jobs == []
  and .descendant_quiescence.kind == "nomad-descendant-quiescence"
  and .descendant_quiescence.descendant_capable_parent_ids == ["clickhouse-backup"]
  and (.descendant_quiescence.tracked_job_ids | index(
    "clickhouse-backup/periodic-20260807"
  )) != null
  and .descendant_quiescence.stable_zero_observations == 2
  and .actions == [{
    address:"module.nomad.module.orchestrator[0].nomad_job.orchestrator",
    job_id:"orchestrator-dev",
    action:"purged_before_first_locking_rollout",
    prior_version:3,
    prior_modify_index:30,
    prior_active_allocations:1,
    deregistration_eval_id:"11111111-1111-4111-8111-111111111111",
    post_stop_active_allocations:0
  }]
' "$transition" >/dev/null

healthy="$test_root/healthy.json"
run_gate wait "$healthy"
jq -e '
  .kind == "live-nomad-job-convergence"
  and .live_inventory.kind == "live-nomad-job-inventory"
  and .live_inventory.completeness == "exact"
  and ([.jobs[].job_id] | sort) == ["api","orchestrator-dev"]
  and (.jobs[] | select(.job_id == "api") | .healthy_allocation_ids) == ["api-current"]
  and (.jobs[] | select(.job_id == "orchestrator-dev") | .eligible_node_ids)
    == ["node-1","node-2"]
' "$healthy" >/dev/null

for scenario in \
  pending stale missing-node wrong-index extra-job spoofed-child \
  missing-submission changed-submission; do
  if run_gate wait "$test_root/$scenario.json" "$scenario" >/dev/null 2>&1; then
    printf 'Nomad convergence gate accepted unsafe scenario: %s\n' "$scenario" >&2
    exit 1
  fi
done

rm -f -- "$delete_marker"
rm -f -- "$test_root/quiesced"
if run_gate prepare "$test_root/unsafe-transition.json" unsafe-old \
  >/dev/null 2>&1; then
  printf 'Nomad transition gate accepted desired-run failed old allocation.\n' >&2
  exit 1
fi
rm -f -- "$delete_marker"
rm -f -- "$test_root/quiesced"
if run_gate prepare "$test_root/late-transition.json" late-allocation \
  >/dev/null 2>&1; then
  printf 'Nomad transition gate missed a post-snapshot old allocation.\n' >&2
  exit 1
fi

if grep -F "$token" "$curl_log" >/dev/null; then
  printf 'Nomad token leaked into curl argv.\n' >&2
  exit 1
fi

printf 'Nomad runtime-job transition and live convergence fixtures passed.\n'
