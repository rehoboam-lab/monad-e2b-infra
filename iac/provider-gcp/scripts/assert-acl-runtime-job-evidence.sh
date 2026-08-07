#!/usr/bin/env bash
set -euo pipefail

evidence="${1:?usage: assert-acl-runtime-job-evidence.sh EVIDENCE PHASE ENVIRONMENT CHECKPOINT PROJECT REGION ZONE PREFIX REPO_ROOT}"
phase="${2:?phase is required}"
expected_environment="${3:?environment is required}"
checkpoint="${4:?checkpoint is required}"
project="${5:?project is required}"
region="${6:?region is required}"
zone="${7:?zone is required}"
prefix="${8:?prefix is required}"
repo_root="${9:?repository root is required}"

[[ "${expected_environment}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  printf 'Invalid expected ACL runtime-job environment: %s\n' \
    "${expected_environment}" >&2
  exit 1
}

case "${phase}" in
  pre-server) stage=network; descendant_policy_expected=observe ;;
  post-api) stage=api; descendant_policy_expected=quiesce ;;
  *) printf 'Invalid ACL runtime-job evidence phase: %s\n' "${phase}" >&2; exit 1 ;;
esac

for file in "${evidence}" "${checkpoint}"; do
  [[ -f "${file}" && ! -L "${file}" ]] || {
    printf 'ACL runtime-job evidence input must be a regular non-symlink: %s\n' \
      "${file}" >&2
    exit 1
  }
done
evidence_mode="$(stat -c '%a' "${evidence}" 2>/dev/null || stat -f '%Lp' "${evidence}")"
if (( (8#${evidence_mode} & 077) != 0 )); then
  printf 'ACL runtime-job completion evidence must be private: %s\n' "${evidence}" >&2
  exit 1
fi

source_head="$(git -C "${repo_root}" rev-parse --verify HEAD)"
checkpoint_sha256="$(shasum -a 256 "${checkpoint}" | awk '{print $1}')"

jq -e \
  --arg source_head "${source_head}" \
  --arg environment "${expected_environment}" \
  --arg project "${project}" \
  --arg region "${region}" \
  --arg zone "${zone}" \
  --arg prefix "${prefix}" \
  --arg phase "${phase}" \
  --arg stage "${stage}" \
  --arg checkpoint_sha256 "${checkpoint_sha256}" '
    .schema_version == 1
    and .source_sha == $source_head
    and .environment == $environment
    and .project_id == $project
    and .region == $region
    and .zone == $zone
    and .prefix == $prefix
    and .phase == $phase
    and .stage == $stage
    and .checkpoint_sha256 == $checkpoint_sha256
    and (.applied_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and all([
      .reviewed_plan_sha256,
      .reviewed_manifest_sha256,
      .converged_plan_sha256,
      .job_projection_sha256,
      .live_job_projection_sha256,
      .job_inventory_projection_sha256,
      .live_job_inventory_projection_sha256,
      .exclusive_transition_sha256,
      .live_nomad_convergence_sha256
    ][]; test("^[0-9a-f]{64}$"))
    and (.job_addresses | type) == "array"
    and .job_addresses == ([.live_job_projection[].address] | sort)
  ' "${evidence}" >/dev/null || {
  printf 'ACL runtime-job evidence context or top-level digest contract is invalid.\n' >&2
  exit 1
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/acl-runtime-evidence.XXXXXX")"
trap 'rm -rf -- "${work_dir}"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 0700 "${work_dir}"

assert_embedded_digest() {
  local selector="$1"
  local digest_selector="$2"
  local output="$3"
  local actual
  local expected

  jq -eS "${selector}" "${evidence}" >"${output}"
  chmod 0600 "${output}"
  actual="$(shasum -a 256 "${output}" | awk '{print $1}')"
  expected="$(jq -er "${digest_selector}" "${evidence}")"
  [[ "${actual}" == "${expected}" ]] || {
    printf 'ACL runtime-job embedded proof digest mismatch: %s\n' \
      "${digest_selector}" >&2
    exit 1
  }
}

runtime_projection="${work_dir}/runtime.json"
transition_inventory_projection="${work_dir}/transition-inventory.json"
inventory_projection="${work_dir}/inventory.json"
transition="${work_dir}/transition.json"
convergence="${work_dir}/convergence.json"
assert_embedded_digest '.live_job_projection' \
  '.live_job_projection_sha256' "${runtime_projection}"
assert_embedded_digest '.job_inventory_projection' \
  '.job_inventory_projection_sha256' "${transition_inventory_projection}"
assert_embedded_digest '.live_job_inventory_projection' \
  '.live_job_inventory_projection_sha256' "${inventory_projection}"
assert_embedded_digest '.exclusive_transition' \
  '.exclusive_transition_sha256' "${transition}"
assert_embedded_digest '.live_nomad_convergence' \
  '.live_nomad_convergence_sha256' "${convergence}"

static_runtime="${work_dir}/runtime-static.json"
static_inventory="${work_dir}/inventory-static.json"
jq -eS 'map(.expected_modify_index = null)' \
  "${runtime_projection}" >"${static_runtime}"
jq -eS . "${transition_inventory_projection}" >"${static_inventory}"
[[ "$(shasum -a 256 "${static_runtime}" | awk '{print $1}')" \
  == "$(jq -er '.job_projection_sha256' "${evidence}")" ]]
[[ "$(shasum -a 256 "${static_inventory}" | awk '{print $1}')" \
  == "$(jq -er '.job_inventory_projection_sha256' "${evidence}")" ]]

jq -e '
  type == "array" and length > 0
  and ([.[].address] | unique | length) == length
  and ([.[].job_id] | unique | length) == length
  and all(.[];
    (.address | startswith("module.nomad."))
    and (.job_id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (.job_type == "service" or .job_type == "system")
    and (.requires_exclusive_transition | type) == "boolean"
    and (.jobspec_sha256 | test("^[0-9a-f]{64}$"))
    and (.expected_modify_index | type) == "number"
    and .expected_modify_index > 0
  )
' "${runtime_projection}" >/dev/null
jq -e '
  type == "array" and length > 0
  and ([.[].address] | unique | length) == length
  and ([.[].job_id] | unique | length) == length
  and all(.[];
    (.address | startswith("module.nomad."))
    and (.job_id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (.job_type == "service" or .job_type == "system" or .job_type == "batch")
    and (.submission_source_sha256 | test("^[0-9a-f]{64}$"))
    and (.expected_modify_index | type) == "number"
    and .expected_modify_index > 0
    and (if .job_type == "batch"
      then .inventory_class == "token-free-batch"
        and (.child_mode == "none" or .child_mode == "periodic" or .child_mode == "parameterized")
      else .inventory_class == "managed-runtime" and .child_mode == "none"
      end)
  )
' "${inventory_projection}" >/dev/null
jq -e '
  type == "array" and length > 0
  and ([.[].address] | unique | length) == length
  and ([.[].job_id] | unique | length) == length
  and all(.[];
    (.submission_source_sha256 | test("^[0-9a-f]{64}$"))
    and .expected_modify_index == null
  )
' "${transition_inventory_projection}" >/dev/null
jq -e --slurpfile before "${transition_inventory_projection}" '
  map({address,job_id,job_type,inventory_class,child_mode})
    == ($before[0] | map({address,job_id,job_type,inventory_class,child_mode}))
' "${inventory_projection}" >/dev/null
jq -e --slurpfile inventory "${inventory_projection}" '
  all(.[];
    . as $runtime
    | any($inventory[0][];
        .address == $runtime.address
        and .job_id == $runtime.job_id
        and .job_type == $runtime.job_type
        and .expected_modify_index == $runtime.expected_modify_index
        and .submission_source_sha256 == $runtime.jobspec_sha256)
  )
' "${runtime_projection}" >/dev/null

if [[ "${phase}" == pre-server ]]; then
  jq -e '
    [.[].address] == ["module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server"]
  ' "${runtime_projection}" >/dev/null
fi

jq -e \
  --arg descendant_policy "${descendant_policy_expected}" \
  --arg runtime_static_sha "$(jq -er '.job_projection_sha256' "${evidence}")" \
  --arg inventory_static_sha "$(jq -er '.job_inventory_projection_sha256' "${evidence}")" \
  --slurpfile runtime "${runtime_projection}" '
    .schema_version == 1
    and .kind == "exclusive-runtime-transition"
    and .descendant_policy == $descendant_policy
    and .projection_sha256 == $runtime_static_sha
    and .inventory_projection_sha256 == $inventory_static_sha
    and .live_inventory.schema_version == 1
    and .live_inventory.kind == "live-nomad-job-inventory"
    and .live_inventory.completeness == (
      if $descendant_policy == "observe"
      then "no-unreviewed-top-level-jobs"
      else "no-unreviewed-live-jobs"
      end)
    and .live_inventory.projection_sha256 == $inventory_static_sha
    and .descendant_quiescence.schema_version == 1
    and (if $descendant_policy == "observe" then
      .descendant_quiescence.kind == "nomad-descendant-observation"
      and .descendant_quiescence.policy == "observe"
      and .descendant_quiescence.actions == []
      and (.descendant_quiescence.observed_descendants | type) == "number"
      and (.descendant_quiescence.observed_active_allocations | type) == "number"
    else
      .descendant_quiescence.kind == "nomad-descendant-quiescence"
      and .descendant_quiescence.stable_zero_observations == 2
      and .descendant_quiescence.remaining_descendants == 0
      and .descendant_quiescence.remaining_descendant_capable_parents == 0
      and .descendant_quiescence.remaining_active_allocations == 0
      and (.live_inventory.descendant_jobs | length) == 0
    end)
    and (.actions | type) == "array"
    and ([.actions[] | {address,job_id}] | sort_by(.address))
      == ([$runtime[0][]
        | select(.requires_exclusive_transition)
        | {address,job_id}] | sort_by(.address))
  ' "${transition}" >/dev/null

jq -e \
  --arg descendant_policy "${descendant_policy_expected}" \
  --arg runtime_sha "$(jq -er '.live_job_projection_sha256' "${evidence}")" \
  --arg inventory_sha "$(jq -er '.live_job_inventory_projection_sha256' "${evidence}")" \
  --slurpfile runtime "${runtime_projection}" \
  --slurpfile inventory "${inventory_projection}" '
    .schema_version == 1
    and .kind == "live-nomad-job-convergence"
    and .projection_sha256 == $runtime_sha
    and .inventory_projection_sha256 == $inventory_sha
    and .live_inventory.schema_version == 1
    and .live_inventory.kind == "live-nomad-job-inventory"
    and .live_inventory.completeness == (
      if $descendant_policy == "observe" then "exact-top-level-jobs" else "exact" end)
    and .live_inventory.projection_sha256 == $inventory_sha
    and (if $descendant_policy == "quiesce"
      then (.live_inventory.descendant_jobs | length) == 0
      else (.live_inventory.descendant_jobs | type) == "array"
      end)
    and ([.live_inventory.top_level_jobs[].job_id] | sort)
      == ([$inventory[0][].job_id] | sort)
    and all(.live_inventory.top_level_jobs[];
      . as $actual
      | any($inventory[0][];
          .job_id == $actual.job_id
          and .job_type == $actual.job_type
          and .expected_modify_index == $actual.job_modify_index
          and .submission_source_sha256 == $actual.submission_source_sha256)
    )
    and ([.jobs[].address] | sort) == ([$runtime[0][].address] | sort)
    and all(.jobs[];
      . as $actual
      | any($runtime[0][];
          .address == $actual.address
          and .job_id == $actual.job_id
          and .job_type == $actual.job_type
          and .expected_modify_index == $actual.job_modify_index
          and .jobspec_sha256 == $actual.jobspec_sha256)
    )
  ' "${convergence}" >/dev/null || {
  printf 'ACL runtime-job live Nomad convergence proof is invalid.\n' >&2
  exit 1
}

printf 'ACL runtime-job %s evidence is bound to exact source %s and live Nomad convergence.\n' \
  "${phase}" "${source_head}"
