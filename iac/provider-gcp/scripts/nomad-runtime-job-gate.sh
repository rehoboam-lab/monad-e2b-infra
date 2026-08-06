#!/usr/bin/env bash

set -euo pipefail

mode="${1:?usage: nomad-runtime-job-gate.sh prepare|wait}"
case "$mode" in
  prepare | wait) ;;
  *) printf 'Unknown Nomad runtime-job gate mode: %s\n' "$mode" >&2; exit 2 ;;
esac

projection="${NOMAD_JOB_GATE_PROJECTION:?NOMAD_JOB_GATE_PROJECTION is required}"
inventory_projection="${NOMAD_JOB_GATE_INVENTORY_PROJECTION:?NOMAD_JOB_GATE_INVENTORY_PROJECTION is required}"
token_file="${NOMAD_JOB_GATE_TOKEN_FILE:-}"
token_fd="${NOMAD_JOB_GATE_TOKEN_FD:-}"
base_url="${NOMAD_JOB_GATE_BASE_URL:?NOMAD_JOB_GATE_BASE_URL is required}"
evidence="${NOMAD_JOB_GATE_EVIDENCE:?NOMAD_JOB_GATE_EVIDENCE is required}"
transition_evidence="${NOMAD_JOB_GATE_TRANSITION_EVIDENCE:-}"
transition_inventory_projection="${NOMAD_JOB_GATE_TRANSITION_INVENTORY_PROJECTION:-}"
curl_bin="${NOMAD_JOB_GATE_CURL_BIN:-$(command -v curl)}"
timeout_seconds="${NOMAD_JOB_GATE_TIMEOUT_SECONDS:-900}"
poll_seconds="${NOMAD_JOB_GATE_POLL_SECONDS:-5}"
descendant_policy="${NOMAD_JOB_GATE_DESCENDANT_POLICY:-quiesce}"

[[ -f "$projection" && ! -L "$projection" ]]
[[ -f "$inventory_projection" && ! -L "$inventory_projection" ]]
[[ -z "$token_file" || -z "$token_fd" ]] || {
  printf 'Nomad runtime-job gate accepts exactly one token source.\n' >&2
  exit 1
}
[[ -n "$token_file" || "$token_fd" =~ ^[0-9]+$ ]] || {
  printf 'Nomad runtime-job gate requires a private token file or inherited token FD.\n' >&2
  exit 1
}
if [[ -n "$token_file" ]]; then
  [[ -f "$token_file" && ! -L "$token_file" ]]
  nomad_token="$(<"$token_file")"
else
  nomad_token="$(cat <&"$token_fd")"
fi
[[ ! -L "$evidence" ]]
[[ -x "$curl_bin" ]]
[[ "$base_url" =~ ^https://nomad\.[A-Za-z0-9.-]+$ ]]
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]
[[ "$poll_seconds" =~ ^[0-9]+$ ]]
[[ "$descendant_policy" == quiesce || "$descendant_policy" == observe ]]
[[ "$nomad_token" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
jq -e --arg mode "$mode" '
  type == "array" and length > 0
  and all(.[];
    (.address | type == "string" and startswith("module.nomad."))
    and (.job_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (.job_type == "service" or .job_type == "system")
    and (.requires_exclusive_transition | type == "boolean")
    and (.jobspec_sha256 | test("^[0-9a-f]{64}$"))
    and (
      if $mode == "wait"
      then (.expected_modify_index | type) == "number"
        and .expected_modify_index > 0
      else .expected_modify_index == null
      end
    )
  )
  and ([.[].job_id] | unique | length) == length
  and ([.[].address] | unique | length) == length
' "$projection" >/dev/null
jq -e --arg mode "$mode" '
  type == "array" and length > 0
  and all(.[];
    (.address | type == "string" and startswith("module.nomad."))
    and (.job_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (.job_type == "service" or .job_type == "system" or .job_type == "batch")
    and (.submission_source_sha256 | test("^[0-9a-f]{64}$"))
    and (
      if .job_type == "batch"
      then .inventory_class == "token-free-batch"
        and (.child_mode == "none"
          or .child_mode == "periodic"
          or .child_mode == "parameterized")
      else .inventory_class == "managed-runtime"
        and .child_mode == "none"
      end
    )
    and (
      if $mode == "wait"
      then (.expected_modify_index | type) == "number"
        and .expected_modify_index > 0
      else .expected_modify_index == null
      end
    )
  )
  and ([.[].job_id] | unique | length) == length
  and ([.[].address] | unique | length) == length
' "$inventory_projection" >/dev/null
if [[ "$mode" == wait ]]; then
  [[ -n "$transition_inventory_projection" ]] \
    || transition_inventory_projection="$inventory_projection"
  [[ -f "$transition_inventory_projection" \
    && ! -L "$transition_inventory_projection" ]]
  jq -e '
    type == "array" and length > 0
    and all(.[];
      (.address | type == "string" and startswith("module.nomad."))
      and (.job_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
      and (.job_type == "service" or .job_type == "system" or .job_type == "batch")
      and (.submission_source_sha256 | test("^[0-9a-f]{64}$"))
      and .expected_modify_index == null
    )
    and ([.[].job_id] | unique | length) == length
    and ([.[].address] | unique | length) == length
  ' "$transition_inventory_projection" >/dev/null
  jq -e --slurpfile before "$transition_inventory_projection" '
    map({address,job_id,job_type,inventory_class,child_mode} | del(.expected_modify_index))
      == ($before[0]
        | map({address,job_id,job_type,inventory_class,child_mode} | del(.expected_modify_index)))
  ' "$inventory_projection" >/dev/null || {
    printf 'Pre-apply and post-apply Nomad inventory identities differ.\n' >&2
    exit 1
  }
else
  transition_inventory_projection="$inventory_projection"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/e2b-nomad-job-gate.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM
chmod 0700 "$work_dir"
projection_sha256="$(shasum -a 256 "$projection" | awk '{print $1}')"
inventory_projection_sha256="$(shasum -a 256 "$inventory_projection" | awk '{print $1}')"
static_projection="$work_dir/static-projection.json"
jq -S 'map(.expected_modify_index = null)' "$projection" >"$static_projection"
static_projection_sha256="$(shasum -a 256 "$static_projection" | awk '{print $1}')"
static_inventory_projection="$work_dir/static-inventory-projection.json"
jq -S 'map(.expected_modify_index = null)' \
  "$inventory_projection" >"$static_inventory_projection"
static_inventory_projection_sha256="$(shasum -a 256 \
  "$static_inventory_projection" | awk '{print $1}')"
transition_inventory_projection_sha256="$(shasum -a 256 \
  "$transition_inventory_projection" | awk '{print $1}')"

nomad_request() {
  local method="$1"
  local path="$2"
  local destination="$3"
  local code

  code="$({
    printf 'silent\nshow-error\nconnect-timeout = 5\nmax-time = 20\n'
    printf 'header = "X-Nomad-Token: %s"\n' "$nomad_token"
  } | env \
      -u ALL_PROXY -u all_proxy \
      -u HTTP_PROXY -u http_proxy \
      -u HTTPS_PROXY -u https_proxy \
      -u NO_PROXY -u no_proxy \
      "$curl_bin" --disable --noproxy '*' --config - \
        --request "$method" --output "$destination" --write-out '%{http_code}' \
        "$base_url$path" 2>/dev/null || true)"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  REPLY="$code"
}

publish_evidence() {
  local source="$1"
  local evidence_dir
  local temp

  evidence_dir="$(dirname "$evidence")"
  [[ -d "$evidence_dir" && ! -L "$evidence_dir" ]]
  temp="$(mktemp "$evidence_dir/.nomad-job-gate.XXXXXX")"
  jq -eS . "$source" >"$temp"
  chmod 0600 "$temp"
  mv -f -- "$temp" "$evidence"
  chmod 0600 "$evidence"
}

capture_live_job_inventory() {
  local destination="$1"
  local require_complete="$2"
  local allow_descendants="${3:-false}"
  local live_jobs="$work_dir/live-job-inventory.json"
  local submission_rows="$work_dir/live-job-submissions.jsonl"
  local expected_job
  local job_id
  local expected_source_sha256
  local live_version
  local submission
  local submission_source
  local submission_source_sha256

  [[ "$require_complete" == true || "$require_complete" == false ]] || return 1
  [[ "$allow_descendants" == true || "$allow_descendants" == false ]] \
    || return 1
  nomad_request GET '/v1/jobs?namespace=default' "$live_jobs"
  [[ "$REPLY" == 200 ]] || return 1
  jq -e 'type == "array"' "$live_jobs" >/dev/null || return 1
  : >"$submission_rows"
  while IFS= read -r expected_job; do
    job_id="$(jq -r '.job_id' <<<"$expected_job")"
    expected_source_sha256="$(jq -r '.submission_source_sha256' \
      <<<"$expected_job")"
    live_version="$(jq -er --arg id "$job_id" '
      first(.[] | select(
        .ID == $id and (.ParentID == null or .ParentID == "")
      ) | .Version) // empty
    ' "$live_jobs")" || true
    [[ -n "$live_version" ]] || continue
    [[ "$live_version" =~ ^[0-9]+$ ]] || return 1
    submission="$work_dir/submission-$job_id.json"
    submission_source="$work_dir/submission-source-$job_id.hcl"
    nomad_request GET \
      "/v1/job/$job_id/submission?version=$live_version&namespace=default" \
      "$submission"
    [[ "$REPLY" == 200 ]] || return 1
    jq -e --arg id "$job_id" --argjson version "$live_version" '
      .JobID == $id
      and .Namespace == "default"
      and .Version == $version
      and .Format == "hcl2"
      and (.Source | type) == "string"
      and (.Source | length) > 0
      and (.VariableFlags == null or .VariableFlags == {})
      and (.Variables == null or .Variables == "")
    ' "$submission" >/dev/null || return 1
    jq -jr '.Source' "$submission" >"$submission_source"
    submission_source_sha256="$(shasum -a 256 "$submission_source" \
      | awk '{print $1}')"
    [[ "$submission_source_sha256" == "$expected_source_sha256" ]] \
      || return 1
    jq -nS \
      --arg job_id "$job_id" \
      --argjson version "$live_version" \
      --arg submission_source_sha256 "$submission_source_sha256" '
        {
          job_id:$job_id,
          version:$version,
          submission_source_sha256:$submission_source_sha256
        }
    ' >>"$submission_rows" || return 1
  done < <(jq -c '.[]' "$inventory_projection")
  jq -e --argjson require_complete "$require_complete" \
    --argjson allow_descendants "$allow_descendants" \
    --arg projection_sha256 "$inventory_projection_sha256" \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile projected "$inventory_projection" \
    --slurpfile submissions "$submission_rows" '
      . as $live
      | $projected[0] as $expected
      | ($live | map(select(.ParentID == null or .ParentID == ""))) as $top_level
      | ($live | map(select(.ParentID != null and .ParentID != ""))) as $children
      | select(type == "array")
      | select(all($live[];
          (.ID | type == "string" and length > 0 and length <= 256)
          and .Namespace == "default"
          and (.Type == "service" or .Type == "system" or .Type == "batch")
          and (.Version | type) == "number" and .Version >= 0
          and (.JobModifyIndex | type) == "number" and .JobModifyIndex > 0
        ))
      | select(all($top_level[];
          . as $actual
          | any($submissions[];
              .job_id == $actual.ID
              and .version == $actual.Version
            )
        ))
      | select(([$live[].ID] | unique | length) == ($live | length))
      | select(all($top_level[];
          . as $actual
          | any($expected[];
            .job_id == $actual.ID
            and .job_type == $actual.Type
            and (
              .expected_modify_index == null
              or .expected_modify_index == $actual.JobModifyIndex
            )
          )
        ))
      | select(
          ($require_complete | not)
          or ([$top_level[].ID] | sort) == ([$expected[].job_id] | sort)
        )
      # ParentID is client-controlled on ordinary Nomad registrations. Until
      # server-derived child provenance is cryptographically bound, require a
      # quiesced/purged child inventory rather than trusting a spoofable parent.
      | select($allow_descendants or ($children | length) == 0)
      | {
          schema_version:1,
          kind:"live-nomad-job-inventory",
          projection_sha256:$projection_sha256,
          completeness:(
            if $require_complete and $allow_descendants then "exact-top-level-jobs"
            elif $require_complete then "exact"
            elif $allow_descendants then "no-unreviewed-top-level-jobs"
            else "no-unreviewed-live-jobs"
            end
          ),
          observed_at:$observed_at,
          top_level_jobs:($top_level
            | map(. as $actual | {
                job_id:.ID,
                job_type:.Type,
                version:.Version,
                job_modify_index:.JobModifyIndex,
                submission_source_sha256:(
                  first($submissions[]
                    | select(.job_id == $actual.ID)
                    | .submission_source_sha256)
                ),
                status:(.Status // null)
              })
            | sort_by(.job_id)),
          descendant_jobs:($children
            | map({
                job_id:.ID,
                parent_id:.ParentID,
                job_type:.Type,
                job_modify_index:.JobModifyIndex,
                status:(.Status // null)
              })
            | sort_by(.job_id))
        }
    ' "$live_jobs" >"$destination" || return 1
}

quiesce_descendant_capable_jobs() {
  local destination="$1"
  local parents="$work_dir/descendant-capable-parents.json"
  local expected_ids="$work_dir/expected-top-level-job-ids.json"
  local tracked_ids="$work_dir/quiesced-job-ids.json"
  local jobs="$work_dir/quiesce-jobs.json"
  local allocations="$work_dir/quiesce-allocations.json"
  local delete_response="$work_dir/quiesce-delete.json"
  local actions="$work_dir/quiesce-actions.jsonl"
  local next_tracked="$work_dir/quiesced-job-ids.next.json"
  local id
  local encoded_id
  local remaining_children
  local remaining_parents
  local remaining_active
  local stable_observations=0
  local previous_state_sha256=""
  local state_sha256
  local deadline

  jq -eS '[.[] | select(.child_mode != "none") | .job_id] | unique' \
    "$inventory_projection" >"$parents"
  jq -eS '[.[].job_id] | unique' "$inventory_projection" >"$expected_ids"
  cp "$parents" "$tracked_ids"
  : >"$actions"
  deadline=$(( $(date -u +%s) + timeout_seconds ))

  while :; do
    nomad_request GET '/v1/jobs?namespace=default' "$jobs"
    [[ "$REPLY" == 200 ]] || return 1
    jq -e 'type == "array"' "$jobs" >/dev/null || return 1
    jq -eS --slurpfile tracked "$tracked_ids" '
      ($tracked[0] + [
        .[]
        | select(.ParentID != null and .ParentID != "")
        | .ID
      ]) | unique
    ' "$jobs" >"$next_tracked" || return 1
    mv "$next_tracked" "$tracked_ids"

    while IFS= read -r id; do
      encoded_id="$(jq -rn --arg value "$id" '$value | @uri')"
      nomad_request DELETE "/v1/job/$encoded_id?purge=true" "$delete_response"
      [[ "$REPLY" == 200 || "$REPLY" == 404 ]] || return 1
      jq -nS --arg job_id "$id" --arg http "$REPLY" \
        '{job_id:$job_id,action:"purge",http:$http}' >>"$actions"
    done < <(jq -r --slurpfile parents "$parents" '
      .[]
      | select(
          (.ParentID != null and .ParentID != "")
          or (.ID as $id | $parents[0] | index($id) != null)
        )
      | .ID
    ' "$jobs" | sort -u)

    nomad_request GET '/v1/allocations?namespace=default' "$allocations"
    [[ "$REPLY" == 200 ]] || return 1
    jq -e 'type == "array"' "$allocations" >/dev/null || return 1
    jq -eS --slurpfile tracked "$tracked_ids" --slurpfile expected "$expected_ids" '
      ($tracked[0] + [
        .[]
        | select(
            .DesiredStatus == "run"
            or .ClientStatus == "pending"
            or .ClientStatus == "running"
          )
        | .JobID
        | select(. as $id | $expected[0] | index($id) == null)
      ]) | unique
    ' "$allocations" >"$next_tracked" || return 1
    mv "$next_tracked" "$tracked_ids"

    remaining_children="$(jq '[.[] | select(
      .ParentID != null and .ParentID != ""
    )] | length' "$jobs")"
    remaining_parents="$(jq --slurpfile parents "$parents" '[.[] | select(
      (.ParentID == null or .ParentID == "")
      and (.ID as $id | $parents[0] | index($id) != null)
    )] | length' "$jobs")"
    remaining_active="$(jq --slurpfile tracked "$tracked_ids" '[.[] | select(
      (.JobID as $id | $tracked[0] | index($id) != null)
      and (
        .DesiredStatus == "run"
        or .ClientStatus == "pending"
        or .ClientStatus == "running"
      )
    )] | length' "$allocations")"
    state_sha256="$({
      printf '%s\n' "$remaining_children" "$remaining_parents" "$remaining_active"
      shasum -a 256 "$tracked_ids"
    } | shasum -a 256 | awk '{print $1}')"
    if [[ "$remaining_children" == 0 && "$remaining_parents" == 0 \
      && "$remaining_active" == 0 ]]; then
      if [[ "$state_sha256" == "$previous_state_sha256" ]]; then
        stable_observations=$((stable_observations + 1))
      else
        stable_observations=1
        previous_state_sha256="$state_sha256"
      fi
      if [[ "$stable_observations" -ge 2 ]]; then
        break
      fi
    else
      stable_observations=0
      previous_state_sha256=""
    fi
    (( $(date -u +%s) < deadline )) || {
      printf 'Timed out quiescing Nomad descendant-capable jobs and allocations.\n' >&2
      return 1
    }
    sleep "$poll_seconds"
  done

  jq -nS \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile parents "$parents" \
    --slurpfile tracked "$tracked_ids" \
    --slurpfile actions "$actions" '
      {
        schema_version:1,
        kind:"nomad-descendant-quiescence",
        observed_at:$observed_at,
        descendant_capable_parent_ids:$parents[0],
        tracked_job_ids:$tracked[0],
        stable_zero_observations:2,
        remaining_descendants:0,
        remaining_descendant_capable_parents:0,
        remaining_active_allocations:0,
        actions:$actions
      }
    ' >"$destination"
}

observe_descendant_jobs() {
  local destination="$1"
  local jobs="$work_dir/observe-descendant-jobs.json"
  local allocations="$work_dir/observe-descendant-allocations.json"

  nomad_request GET '/v1/jobs?namespace=default' "$jobs"
  [[ "$REPLY" == 200 ]]
  nomad_request GET '/v1/allocations?namespace=default' "$allocations"
  [[ "$REPLY" == 200 ]]
  jq -e 'type == "array"' "$jobs" >/dev/null
  jq -e 'type == "array"' "$allocations" >/dev/null
  jq -nS \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile inventory "$inventory_projection" \
    --slurpfile jobs "$jobs" \
    --slurpfile allocations "$allocations" '
      ($inventory[0] | map(select(.child_mode != "none") | .job_id) | unique) as $parents
      | ($jobs[0] | map(select(.ParentID != null and .ParentID != ""))) as $children
      | {
          schema_version:1,
          kind:"nomad-descendant-observation",
          policy:"observe",
          observed_at:$observed_at,
          descendant_capable_parent_ids:$parents,
          tracked_job_ids:([$children[].ID] | unique | sort),
          observed_descendants:($children | length),
          observed_active_allocations:([
            $allocations[0][]
            | select(
                .DesiredStatus == "run"
                or .ClientStatus == "pending"
                or .ClientStatus == "running"
              )
          ] | length),
          actions:[]
        }
    ' >"$destination"
}

if [[ "$mode" == prepare ]]; then
  capture_live_job_inventory "$work_dir/initial-live-inventory.json" false true
  if [[ "$descendant_policy" == quiesce ]]; then
    quiesce_descendant_capable_jobs "$work_dir/descendant-quiescence.json"
    capture_live_job_inventory "$work_dir/live-inventory.json" false
  else
    jq -e 'all(.[]; .requires_exclusive_transition == false)' \
      "$projection" >/dev/null
    observe_descendant_jobs "$work_dir/descendant-quiescence.json"
    capture_live_job_inventory "$work_dir/live-inventory.json" false true
  fi
  actions="$work_dir/actions.jsonl"
  : >"$actions"
  while IFS= read -r job; do
    job_id="$(jq -r .job_id <<<"$job")"
    address="$(jq -r .address <<<"$job")"
    live_job="$work_dir/job-$job_id.json"
    allocations="$work_dir/allocations-$job_id.json"
    deregistration="$work_dir/deregister-$job_id.json"
    nomad_request GET "/v1/job/$job_id" "$live_job"
    code="$REPLY"
    if [[ "$code" == 404 ]]; then
      jq -n --arg address "$address" --arg job_id "$job_id" \
        '{address:$address,job_id:$job_id,action:"already_absent"}' >>"$actions"
      continue
    fi
    [[ "$code" == 200 ]]
    jq -e --arg id "$job_id" '
      .ID == $id
      and .Namespace == "default"
      and (.Version | type) == "number"
      and (.JobModifyIndex | type) == "number" and .JobModifyIndex > 0
    ' "$live_job" >/dev/null
    nomad_request GET "/v1/job/$job_id/allocations?all=true" "$allocations"
    [[ "$REPLY" == 200 ]]
    jq -e 'type == "array"' "$allocations" >/dev/null
    prior_active="$(jq '[.[] | select(
      .DesiredStatus == "run"
      or .ClientStatus == "pending"
      or .ClientStatus == "running"
    )] | length' "$allocations")"
    prior_version="$(jq .Version "$live_job")"
    prior_modify_index="$(jq .JobModifyIndex "$live_job")"
    nomad_request DELETE "/v1/job/$job_id?purge=true" "$deregistration"
    [[ "$REPLY" == 200 ]]
    jq -e '
      (.EvalID == null or (.EvalID | test("^[0-9A-Fa-f-]{36}$")))
      and (.EvalCreateIndex == null or (.EvalCreateIndex | type) == "number")
    ' "$deregistration" >/dev/null

    while IFS= read -r allocation_id; do
      [[ "$allocation_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
      allocation_state="$work_dir/allocation-$allocation_id.json"
      deadline=$(( $(date -u +%s) + timeout_seconds ))
      while :; do
        nomad_request GET "/v1/allocation/$allocation_id" "$allocation_state"
        if [[ "$REPLY" == 200 ]] && jq -e --arg id "$allocation_id" '
          .ID == $id
          and .DesiredStatus != "run"
          and .ClientStatus != "pending"
          and .ClientStatus != "running"
        ' "$allocation_state" >/dev/null; then
          break
        fi
        (( $(date -u +%s) < deadline )) || {
          printf 'Timed out waiting for old Nomad allocation to stop: %s/%s\n' \
            "$job_id" "$allocation_id" >&2
          exit 1
        }
        sleep "$poll_seconds"
      done
    done < <(jq -r '.[] | select(
      .DesiredStatus == "run"
      or .ClientStatus == "pending"
      or .ClientStatus == "running"
    ) | .ID' "$allocations")

    # DELETE commits the scheduler stop, but an allocation created by an
    # already-running evaluation can race the pre-delete snapshot. Re-read the
    # authoritative job allocation index until two identical, wholly terminal
    # observations prove there is no uncaptured old allocation.
    stable_observations=0
    previous_allocation_state_sha256=""
    deadline=$(( $(date -u +%s) + timeout_seconds ))
    while :; do
      nomad_request GET "/v1/job/$job_id/allocations?all=true" "$allocations"
      if [[ "$REPLY" == 200 ]] && jq -e '
        type == "array"
        and all(.[];
          .DesiredStatus != "run"
          and .ClientStatus != "pending"
          and .ClientStatus != "running"
        )
      ' "$allocations" >/dev/null; then
        allocation_state_sha256="$(jq -cS '[.[] | {
          ID,DesiredStatus,ClientStatus
        }] | sort_by(.ID)' "$allocations" | shasum -a 256 | awk '{print $1}')"
        if [[ "$allocation_state_sha256" == "$previous_allocation_state_sha256" ]]; then
          stable_observations=$((stable_observations + 1))
        else
          stable_observations=1
          previous_allocation_state_sha256="$allocation_state_sha256"
        fi
        [[ "$stable_observations" -ge 2 ]] && break
      else
        stable_observations=0
        previous_allocation_state_sha256=""
      fi
      (( $(date -u +%s) < deadline )) || {
        printf 'Timed out proving complete old Nomad allocation quiescence: %s\n' \
          "$job_id" >&2
        exit 1
      }
      sleep "$poll_seconds"
    done
    nomad_request GET "/v1/job/$job_id" "$live_job"
    [[ "$REPLY" == 404 ]]
    jq -n \
      --arg address "$address" \
      --arg job_id "$job_id" \
      --argjson version "$prior_version" \
      --argjson modify_index "$prior_modify_index" \
      --argjson prior_active "$prior_active" \
      --arg eval_id "$(jq -r '.EvalID // ""' "$deregistration")" '
        {
          address:$address,
          job_id:$job_id,
          action:"purged_before_first_locking_rollout",
          prior_version:$version,
          prior_modify_index:$modify_index,
          prior_active_allocations:$prior_active,
          deregistration_eval_id:(if $eval_id == "" then null else $eval_id end),
          post_stop_active_allocations:0
        }
      ' >>"$actions"
  done < <(jq -c '.[] | select(.requires_exclusive_transition)' "$projection")

  jq -nS \
    --arg projection_sha256 "$static_projection_sha256" \
    --arg inventory_projection_sha256 "$static_inventory_projection_sha256" \
    --arg descendant_policy "$descendant_policy" \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile live_inventory "$work_dir/live-inventory.json" \
    --slurpfile descendant_quiescence "$work_dir/descendant-quiescence.json" \
    --slurpfile actions "$actions" '
      {
        schema_version:1,
        kind:"exclusive-runtime-transition",
        projection_sha256:$projection_sha256,
        inventory_projection_sha256:$inventory_projection_sha256,
        descendant_policy:$descendant_policy,
        observed_at:$observed_at,
        live_inventory:$live_inventory[0],
        descendant_quiescence:$descendant_quiescence[0],
        actions:$actions
      }
    ' >"$work_dir/transition.json"
  publish_evidence "$work_dir/transition.json"
  printf 'Nomad exclusive runtime transition gate passed: %s\n' "$evidence"
  exit 0
fi

[[ -n "$transition_evidence" && -f "$transition_evidence" \
  && ! -L "$transition_evidence" ]]
jq -e \
  --arg projection_sha256 "$static_projection_sha256" \
  --arg inventory_projection_sha256 "$transition_inventory_projection_sha256" \
  --arg descendant_policy "$descendant_policy" \
  --slurpfile projection "$projection" '
  .schema_version == 1
  and .kind == "exclusive-runtime-transition"
  and .projection_sha256 == $projection_sha256
  and .inventory_projection_sha256 == $inventory_projection_sha256
  and .descendant_policy == $descendant_policy
  and .live_inventory.schema_version == 1
  and .live_inventory.kind == "live-nomad-job-inventory"
  and .live_inventory.completeness == (
    if $descendant_policy == "quiesce"
    then "no-unreviewed-live-jobs"
    else "no-unreviewed-top-level-jobs"
    end)
  and .live_inventory.projection_sha256 == $inventory_projection_sha256
  and .descendant_quiescence.schema_version == 1
  and (if $descendant_policy == "quiesce" then
    .descendant_quiescence.kind == "nomad-descendant-quiescence"
    and .descendant_quiescence.stable_zero_observations == 2
    and .descendant_quiescence.remaining_descendants == 0
    and .descendant_quiescence.remaining_descendant_capable_parents == 0
    and .descendant_quiescence.remaining_active_allocations == 0
  else
    .descendant_quiescence.kind == "nomad-descendant-observation"
    and .descendant_quiescence.policy == "observe"
    and (.descendant_quiescence.observed_descendants | type) == "number"
    and (.descendant_quiescence.observed_active_allocations | type) == "number"
    and .descendant_quiescence.actions == []
    and all($projection[0][]; .requires_exclusive_transition == false)
  end)
  and (.actions | type) == "array"
  and ([.actions[] | {address,job_id}] | sort_by(.address))
    == ([$projection[0][]
      | select(.requires_exclusive_transition)
      | {address,job_id}] | sort_by(.address))
  and ([.actions[].address] | unique | length) == (.actions | length)
  and ([.actions[].job_id] | unique | length) == (.actions | length)
' "$transition_evidence" >/dev/null

check_convergence_once() {
  local candidate="$1"
  local nodes="$work_dir/nodes.json"
  local live_inventory="$work_dir/converged-live-inventory.json"
  local rows="$work_dir/converged.jsonl"
  local job
  local job_id
  local address
  local job_type
  local requires_transition
  local expected_modify_index
  local jobspec_sha256
  local live_job
  local evaluations
  local deployments
  local allocations
  local row

  : >"$rows"
  if [[ "$descendant_policy" == observe ]]; then
    capture_live_job_inventory "$live_inventory" true true
  else
    capture_live_job_inventory "$live_inventory" true
  fi
  nomad_request GET '/v1/nodes' "$nodes"
  [[ "$REPLY" == 200 ]]
  jq -e 'type == "array"' "$nodes" >/dev/null

  while IFS= read -r job; do
    job_id="$(jq -r .job_id <<<"$job")"
    address="$(jq -r .address <<<"$job")"
    job_type="$(jq -r .job_type <<<"$job")"
    requires_transition="$(jq -r .requires_exclusive_transition <<<"$job")"
    expected_modify_index="$(jq -r .expected_modify_index <<<"$job")"
    jobspec_sha256="$(jq -r .jobspec_sha256 <<<"$job")"
    live_job="$work_dir/live-$job_id.json"
    evaluations="$work_dir/evals-$job_id.json"
    deployments="$work_dir/deployments-$job_id.json"
    allocations="$work_dir/allocs-$job_id.json"
    row="$work_dir/row-$job_id.json"

    nomad_request GET "/v1/job/$job_id" "$live_job"
    [[ "$REPLY" == 200 ]]
    nomad_request GET "/v1/job/$job_id/evaluations" "$evaluations"
    [[ "$REPLY" == 200 ]]
    nomad_request GET "/v1/job/$job_id/deployments" "$deployments"
    [[ "$REPLY" == 200 ]]
    nomad_request GET "/v1/job/$job_id/allocations?all=true" "$allocations"
    [[ "$REPLY" == 200 ]]

    if [[ "$job_type" == service ]]; then
      jq -en \
        --arg address "$address" \
        --arg id "$job_id" \
        --argjson requires_transition "$requires_transition" \
        --argjson expected_modify_index "$expected_modify_index" \
        --arg jobspec_sha256 "$jobspec_sha256" \
        --slurpfile job "$live_job" \
        --slurpfile evals "$evaluations" \
        --slurpfile deployments "$deployments" \
        --slurpfile allocs "$allocations" '
          $job[0] as $j
          | ($evals[0] | sort_by(.CreateIndex) | last) as $latest_eval
          | ($evals[0] | map(select(.JobModifyIndex == $j.JobModifyIndex))
              | sort_by(.CreateIndex) | last) as $registration_eval
          | ($deployments[0] | map(select(.JobVersion == $j.Version))
              | sort_by(.CreateIndex) | last) as $deployment
          | ($allocs[0] | map(select(.JobVersion == $j.Version))) as $current
          | ($current | map(select(
              .DesiredStatus == "run" and .ClientStatus == "running"
            ))) as $active
          | select(
              $j.ID == $id
              and $j.Type == "service"
              and $j.Namespace == "default"
              and $j.Status == "running"
              and ($j.Version | type) == "number"
              and ($j.JobModifyIndex | type) == "number" and $j.JobModifyIndex > 0
              and $j.JobModifyIndex == $expected_modify_index
              and $j.Meta.monad_acl_handoff_revision == "1"
              and ($latest_eval | type) == "object"
              and $latest_eval.Status == "complete"
              and (($latest_eval.FailedTGAllocs // {}) | length) == 0
              and ($latest_eval.BlockedEval == null or $latest_eval.BlockedEval == "")
              and ($registration_eval | type) == "object"
              and $registration_eval.Status == "complete"
              and (($registration_eval.FailedTGAllocs // {}) | length) == 0
              and all($evals[0][];
                .Status != "pending" and .Status != "blocked")
              and all($evals[0][] | select(.JobModifyIndex == $j.JobModifyIndex);
                .Status != "failed")
              and ($deployment | type) == "object"
              and $deployment.Status == "successful"
              and ($deployment.TaskGroups | type) == "object"
              and ($deployment.TaskGroups | length) > 0
              and all($deployment.TaskGroups | to_entries[];
                . as $task_group
                | $task_group.value.DesiredTotal > 0
                and $task_group.value.PlacedAllocs == $task_group.value.DesiredTotal
                and $task_group.value.HealthyAllocs == $task_group.value.DesiredTotal
                and $task_group.value.UnhealthyAllocs == 0
                and ([$active[] | select(.TaskGroup == $task_group.key)] | length)
                  == $task_group.value.DesiredTotal
              )
              and ($active | length) > 0
              and all($active[];
                .DeploymentStatus.Healthy == true
                and all(.TaskStates[]?; .Failed != true)
              )
              and all($allocs[0][];
                .JobVersion == $j.Version
                or (
                  .DesiredStatus != "run"
                  and .ClientStatus != "pending"
                  and .ClientStatus != "running"
                )
              )
            )
          | {
              address:$address,
              job_id:$id,
              job_type:"service",
              version:$j.Version,
              job_modify_index:$j.JobModifyIndex,
              jobspec_sha256:$jobspec_sha256,
              latest_eval_id:$latest_eval.ID,
              registration_eval_id:$registration_eval.ID,
              deployment_id:$deployment.ID,
              desired_allocations:([$deployment.TaskGroups[] | .DesiredTotal] | add),
              healthy_allocation_ids:([$active[].ID] | sort),
              healthy_node_ids:([$active[].NodeID] | unique | sort)
            }
        ' >"$row"
    else
      jq -en \
        --arg address "$address" \
        --arg id "$job_id" \
        --argjson requires_transition "$requires_transition" \
        --argjson expected_modify_index "$expected_modify_index" \
        --arg jobspec_sha256 "$jobspec_sha256" \
        --slurpfile job "$live_job" \
        --slurpfile evals "$evaluations" \
        --slurpfile deployments "$deployments" \
        --slurpfile allocs "$allocations" \
        --slurpfile nodes "$nodes" '
          $job[0] as $j
          | ($evals[0] | sort_by(.CreateIndex) | last) as $latest_eval
          | ($allocs[0] | map(select(.JobVersion == $j.Version))) as $current
          | ($current | map(select(
              .DesiredStatus == "run" and .ClientStatus == "running"
            ))) as $active
          | ($nodes[0] | map(
              . as $node
              | select(
                $node.Status == "ready"
                and $node.SchedulingEligibility == "eligible"
                and ($node.Drain != true)
                and ($j.NodePool == "all" or $node.NodePool == $j.NodePool)
                and (($j.Datacenters | index("*")) != null
                  or ($j.Datacenters | index($node.Datacenter)) != null)
              )
            )) as $eligible
          | select(
              $j.ID == $id
              and $j.Type == "system"
              and $j.Namespace == "default"
              and $j.Status == "running"
              and ($j.Version | type) == "number"
              and ($j.JobModifyIndex | type) == "number" and $j.JobModifyIndex > 0
              and $j.JobModifyIndex == $expected_modify_index
              and $j.Meta.monad_acl_handoff_revision == "1"
              and ($latest_eval | type) == "object"
              and $latest_eval.Status == "complete"
              and (($latest_eval.FailedTGAllocs // {}) | length) == 0
              and ($latest_eval.BlockedEval == null or $latest_eval.BlockedEval == "")
              and all($evals[0][];
                .Status != "pending" and .Status != "blocked")
              and all($evals[0][] | select(.JobModifyIndex == $j.JobModifyIndex);
                .Status != "failed")
              and ($deployments[0] | length) == 0
              and ($eligible | length) > 0
              and ($j.TaskGroups | length) > 0
              and all($j.TaskGroups[];
                .Name as $group
                | ([$active[] | select(.TaskGroup == $group)] | length) == ($eligible | length)
                and ([$active[] | select(.TaskGroup == $group) | .NodeID]
                  | unique | sort) == ([$eligible[].ID] | unique | sort)
              )
              and all($active[];
                (any(.TaskStates[]?; .State == "running"))
                and all(.TaskStates[]?; .Failed != true)
              )
              and all($allocs[0][];
                .JobVersion == $j.Version
                or (
                  .DesiredStatus != "run"
                  and .ClientStatus != "pending"
                  and .ClientStatus != "running"
                )
              )
            )
          | {
              address:$address,
              job_id:$id,
              job_type:"system",
              version:$j.Version,
              job_modify_index:$j.JobModifyIndex,
              jobspec_sha256:$jobspec_sha256,
              latest_eval_id:$latest_eval.ID,
              eligible_node_ids:([$eligible[].ID] | unique | sort),
              healthy_allocation_ids:([$active[].ID] | sort),
              healthy_node_ids:([$active[].NodeID] | unique | sort)
            }
        ' >"$row"
    fi
    jq -e . "$row" >/dev/null
    cat "$row" >>"$rows"
  done < <(jq -c '.[]' "$projection")

  jq -nS \
    --arg projection_sha256 "$projection_sha256" \
    --arg inventory_projection_sha256 "$inventory_projection_sha256" \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile live_inventory "$live_inventory" \
    --slurpfile jobs "$rows" '
      {
        schema_version:1,
        kind:"live-nomad-job-convergence",
        projection_sha256:$projection_sha256,
        inventory_projection_sha256:$inventory_projection_sha256,
        observed_at:$observed_at,
        live_inventory:$live_inventory[0],
        jobs:($jobs | sort_by(.address))
      }
    ' >"$candidate"
  jq -e --argjson expected "$(jq length "$projection")" '
    (.jobs | length) == $expected
  ' "$candidate" >/dev/null
}

deadline=$(( $(date -u +%s) + timeout_seconds ))
last_error="$work_dir/last-error"
candidate="$work_dir/convergence.json"
while :; do
  set +e
  (
    # check_convergence_once contains many fail-closed assertions. Run it in a
    # dedicated errexit context; invoking a function directly as an `if`
    # condition would make Bash ignore `set -e` throughout the function body.
    set -e
    check_convergence_once "$candidate"
  ) 2>"$last_error"
  convergence_status=$?
  set -e
  if [[ "$convergence_status" -eq 0 ]]; then
    publish_evidence "$candidate"
    printf 'Live Nomad runtime-job convergence gate passed: %s\n' "$evidence"
    exit 0
  fi
  (( $(date -u +%s) < deadline )) || {
    printf 'Timed out waiting for live Nomad runtime-job convergence.\n' >&2
    sed -n '1,20p' "$last_error" >&2
    exit 1
  }
  sleep "$poll_seconds"
done
