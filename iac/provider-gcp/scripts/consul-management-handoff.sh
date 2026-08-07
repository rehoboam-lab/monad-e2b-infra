#!/usr/bin/env bash
set -euo pipefail

mode="${1:?usage: consul-management-handoff.sh stage|verify-staged|retire|verify}"
case "${mode}" in
  stage | verify-staged | retire | verify) ;;
  *)
    printf 'Unknown Consul management handoff mode: %s\n' "${mode}" >&2
    exit 2
    ;;
esac

project_id="${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
region="${GCP_REGION:?GCP_REGION is required}"
prefix="${PREFIX:?PREFIX is required}"
legacy_version_resource="${CONSUL_LEGACY_VERSION_RESOURCE:?CONSUL_LEGACY_VERSION_RESOURCE is required}"
candidate_version_resource="${CONSUL_CANDIDATE_VERSION_RESOURCE:?CONSUL_CANDIDATE_VERSION_RESOURCE is required}"
unregistered_version_resource="${CONSUL_UNREGISTERED_VERSION_RESOURCE:?CONSUL_UNREGISTERED_VERSION_RESOURCE is required}"
terraform_active_version_resource="${CONSUL_TERRAFORM_ACTIVE_VERSION_RESOURCE:?CONSUL_TERRAFORM_ACTIVE_VERSION_RESOURCE is required}"
terraform_legacy_version_resource="${CONSUL_TERRAFORM_LEGACY_VERSION_RESOURCE:?CONSUL_TERRAFORM_LEGACY_VERSION_RESOURCE is required}"
terraform_candidate_version_resource="${CONSUL_TERRAFORM_CANDIDATE_VERSION_RESOURCE:?CONSUL_TERRAFORM_CANDIDATE_VERSION_RESOURCE is required}"
evidence_path="${CONSUL_HANDOFF_EVIDENCE:?CONSUL_HANDOFF_EVIDENCE is required}"
recovery_checkpoint="${evidence_path}.recovery"
gcloud_bin="${GCLOUD_BIN:-gcloud}"
local_port="${CONSUL_IAP_LOCAL_PORT:-18500}"
post_api_evidence="${CONSUL_HANDOFF_POST_API_EVIDENCE:-}"
build_checkpoint="${CONSUL_HANDOFF_BUILD_CHECKPOINT:-}"
repo_root="${CONSUL_HANDOFF_REPO_ROOT:-}"
retire_confirmation="${CONSUL_RETIRE_CONFIRMATION:-}"
nomad_version_resource="${CONSUL_HANDOFF_NOMAD_TOKEN_SECRET_VERSION:-}"
nomad_base_url="${CONSUL_HANDOFF_NOMAD_BASE_URL:-}"
pre_server_acl_evidence="${CONSUL_HANDOFF_PRE_SERVER_ACL_EVIDENCE:-}"
handoff_environment="${CONSUL_HANDOFF_ENVIRONMENT:-}"
state_bucket="${CONSUL_HANDOFF_STATE_BUCKET:?CONSUL_HANDOFF_STATE_BUCKET is required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nomad_job_gate_script="${CONSUL_HANDOFF_NOMAD_JOB_GATE_SCRIPT:-${script_dir}/nomad-runtime-job-gate.sh}"
acl_live_evidence_guard="${CONSUL_HANDOFF_ACL_LIVE_EVIDENCE_GUARD:-${script_dir}/assert-acl-runtime-job-live-evidence.sh}"
lease_script="${CONSUL_HANDOFF_LEASE_SCRIPT:-${script_dir}/rollout-mutation-lease.sh}"
lease_token="${recovery_checkpoint}.lease"

if [[ ! -x "${gcloud_bin}" ]] && ! command -v "${gcloud_bin}" >/dev/null 2>&1; then
  printf 'Required gcloud command is unavailable: %s\n' "${gcloud_bin}" >&2
  exit 2
fi

gcloud_direct() {
  env \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
    -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
    "${gcloud_bin}" "$@"
}

lease_call() {
  env \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
    -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
    "${lease_script}" "$@"
}

[[ "${project_id}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "${region}" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]
[[ "${prefix}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?-$ ]]
[[ "${state_bucket}" == "${project_id}-terraform-state" ]] || {
  printf 'Consul handoff requires the canonical project rollout-lease bucket.\n' >&2
  exit 1
}
[[ "${local_port}" =~ ^[1-9][0-9]*$ ]] && ((local_port >= 1024 && local_port <= 65535))
[[ ! -L "${evidence_path}" ]]
[[ ! -L "${recovery_checkpoint}" ]]
[[ ! -L "${lease_token}" ]]
[[ -x "${lease_script}" ]] || {
  printf 'Shared rollout mutation lease helper is unavailable: %s\n' "${lease_script}" >&2
  exit 1
}
[[ -x "${nomad_job_gate_script}" ]] || {
  printf 'Nomad retirement job gate is unavailable: %s\n' "${nomad_job_gate_script}" >&2
  exit 1
}
[[ -x "${acl_live_evidence_guard}" ]] || {
  printf 'ACL runtime-job live evidence guard is unavailable: %s\n' \
    "${acl_live_evidence_guard}" >&2
  exit 1
}
recovery_checkpoint_present=false
[[ ! -e "${recovery_checkpoint}" ]] || recovery_checkpoint_present=true

parse_version_resource() {
  local resource="$1"
  local expected_secret="$2"
  local parsed_project
  local parsed_secret
  local parsed_version

  [[ "${resource}" =~ ^projects/([^/]+)/secrets/([^/]+)/versions/([1-9][0-9]*)$ ]] || return 1
  parsed_project="${BASH_REMATCH[1]}"
  parsed_secret="${BASH_REMATCH[2]}"
  parsed_version="${BASH_REMATCH[3]}"
  [[ "${parsed_secret}" == "${expected_secret}" ]] || return 1
  printf '%s|%s|%s\n' "${parsed_project}" "${parsed_secret}" "${parsed_version}"
}

legacy_parts="$(parse_version_resource "${legacy_version_resource}" "${prefix}consul-secret-id")" || {
  printf 'Legacy Consul version resource is not the exact expected secret/version.\n' >&2
  exit 1
}
candidate_parts="$(parse_version_resource "${candidate_version_resource}" "${prefix}consul-management-candidate-token")" || {
  printf 'Candidate Consul version resource is not the exact expected secret/version.\n' >&2
  exit 1
}
IFS='|' read -r legacy_project legacy_secret legacy_version <<<"${legacy_parts}"
IFS='|' read -r candidate_project candidate_secret candidate_version <<<"${candidate_parts}"
unregistered_parts="$(parse_version_resource "${unregistered_version_resource}" "${prefix}consul-secret-id")" || {
  printf 'Unregistered Consul version resource is not the exact expected secret/version.\n' >&2
  exit 1
}
terraform_active_parts="$(parse_version_resource "${terraform_active_version_resource}" "${prefix}consul-secret-id")" || {
  printf 'Terraform active-address Consul version output is invalid.\n' >&2
  exit 1
}
terraform_legacy_parts="$(parse_version_resource "${terraform_legacy_version_resource}" "${prefix}consul-secret-id")" || {
  printf 'Terraform legacy-address Consul version output is invalid.\n' >&2
  exit 1
}
terraform_candidate_parts="$(parse_version_resource "${terraform_candidate_version_resource}" "${prefix}consul-management-candidate-token")" || {
  printf 'Terraform candidate Consul version output is invalid.\n' >&2
  exit 1
}
IFS='|' read -r unregistered_project unregistered_secret unregistered_version <<<"${unregistered_parts}"
IFS='|' read -r terraform_active_project _ terraform_active_version <<<"${terraform_active_parts}"
IFS='|' read -r terraform_legacy_project _ terraform_legacy_version <<<"${terraform_legacy_parts}"
IFS='|' read -r terraform_candidate_project _ terraform_candidate_version <<<"${terraform_candidate_parts}"
nomad_project=""
nomad_secret=""
nomad_version=""
if [[ "${mode}" == stage || "${mode}" == retire ]]; then
  nomad_parts="$(parse_version_resource \
    "${nomad_version_resource}" "${prefix}nomad-secret-id")" || {
    printf 'Nomad retirement gate token is not an immutable version of the expected secret.\n' >&2
    exit 1
  }
  IFS='|' read -r nomad_project nomad_secret nomad_version <<<"${nomad_parts}"
  [[ "${nomad_base_url}" =~ ^https://nomad\.[A-Za-z0-9.-]+$ ]] || {
    printf 'Nomad retirement gate requires the exact HTTPS Nomad base URL.\n' >&2
    exit 1
  }
fi
if [[ "${mode}" == stage ]]; then
  [[ -n "${pre_server_acl_evidence}" \
    && -f "${pre_server_acl_evidence}" \
    && ! -L "${pre_server_acl_evidence}" ]] || {
    printf 'Consul stage requires the private pre-server ACL completion evidence.\n' >&2
    exit 1
  }
  [[ "${handoff_environment}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Consul stage requires the exact ACL evidence environment.\n' >&2
    exit 1
  }
fi
[[ "${unregistered_version}" != "${legacy_version}" ]]
[[ "${terraform_active_version}" != "${terraform_legacy_version}" ]]
[[ "${candidate_version_resource}" == "${terraform_candidate_version_resource}" ]] || {
  printf 'Candidate input does not match the immutable Terraform/server-template pin.\n' >&2
  exit 1
}
manual_old_versions="$(printf '%s\n%s\n' "${legacy_version_resource}" "${unregistered_version_resource}" | sort)"
terraform_old_versions="$(printf '%s\n%s\n' "${terraform_active_version_resource}" "${terraform_legacy_version_resource}" | sort)"
[[ "${manual_old_versions}" == "${terraform_old_versions}" ]] || {
  printf 'Registered/unregistered classification does not exactly cover both Terraform old-version outputs.\n' >&2
  exit 1
}
project_number="$(gcloud_direct projects describe "${project_id}" --format='value(projectNumber)')"
[[ -n "${project_number}" ]]
for resource_project in \
  "${legacy_project}" "${candidate_project}" "${unregistered_project}" \
  "${terraform_active_project}" "${terraform_legacy_project}" "${terraform_candidate_project}"; do
  [[ -z "${resource_project}" ]] && continue
  [[ "${resource_project}" == "${project_id}" || "${resource_project}" == "${project_number}" ]] || {
    printf 'Consul version resource belongs to a different project.\n' >&2
    exit 1
  }
done
if [[ -n "${nomad_project}" ]]; then
  [[ "${nomad_project}" == "${project_id}" \
    || "${nomad_project}" == "${project_number}" ]] || {
    printf 'Nomad retirement token version belongs to a different project.\n' >&2
    exit 1
  }
fi

command -v jq >/dev/null
command -v curl >/dev/null
command -v lsof >/dev/null
command -v python3 >/dev/null
command -v shasum >/dev/null
[[ -x "${script_dir}/classify-consul-token-authority.py" ]] || {
  printf 'Consul ACL authority classifier is missing or not executable.\n' >&2
  exit 2
}
if lsof -nP -iTCP:"${local_port}" -sTCP:LISTEN >/dev/null 2>&1; then
  printf 'Refusing to reuse occupied local IAP port %s.\n' "${local_port}" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
chmod 0700 "${work_dir}"
tunnel_pid=""
candidate_created=false
lineage_mutated=false
revocation_started=false
old_revoked=false
staging_committed=false
prior_lineage_present=false
legacy_initial_state=""
candidate_initial_state=""
unregistered_initial_state=""
unregistered_replay_http="not-applicable"
candidate_token_sha256=""
legacy_token_sha256=""
unregistered_token_sha256=""
candidate_accessor_for_recovery=""
selected_server=""
selected_zone=""
selected_template=""
selected_inventory='[]'
authority_inventory_sha256=""
revocation_lineage_modify_index=""
lease_acquired=false
lease_borrowed=false
use_legacy_secret=false
existing_evidence_status=""
legacy_accessor_http=""
legacy_accessor_status=0
recovery_schema=""
recovery_phase=""
stage_enable_intent_active=false

secret_state() {
  local secret="$1"
  local version="$2"
  gcloud_direct secrets versions describe "${version}" \
    --secret="${secret}" --project="${project_id}" --format='value(state)'
}

set_secret_state() {
  local action="$1"
  local secret="$2"
  local version="$3"
  gcloud_direct secrets versions "${action}" "${version}" \
    --secret="${secret}" --project="${project_id}" --quiet >/dev/null
}

access_secret() {
  local secret="$1"
  local version="$2"
  local destination="$3"
  gcloud_direct secrets versions access "${version}" \
    --secret="${secret}" --project="${project_id}" \
    --out-file="${destination}" >/dev/null 2>&1
  chmod 0600 "${destination}"
  [[ "$(LC_ALL=C wc -c <"${destination}" | tr -d '[:space:]')" == 36 ]]
  grep -Ex '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}' \
    "${destination}" >/dev/null
}

digest_file() {
  local path="$1"
  shasum -a 256 "${path}" | awk '{print $1}' | grep -Ex '[0-9a-f]{64}'
}

durable_publish_private() {
  local source_path="$1"
  local destination_path="$2"
  chmod 0600 "${source_path}"
  python3 - "${source_path}" "${destination_path}" <<'PY'
import os
import sys

source, destination = sys.argv[1:]
with open(source, "rb") as stream:
    os.fsync(stream.fileno())
os.replace(source, destination)
os.chmod(destination, 0o600)
directory = os.path.dirname(os.path.abspath(destination)) or "."
directory_fd = os.open(directory, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

durable_remove_private() {
  local path="$1"
  local directory
  [[ ! -e "${path}" ]] || {
    [[ -f "${path}" && ! -L "${path}" ]]
    : >"${path}"
    rm -f -- "${path}"
  }
  directory="$(dirname "${path}")"
  python3 - "${directory}" <<'PY'
import os
import sys

directory_fd = os.open(os.path.abspath(sys.argv[1]), os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

json_equal() {
  local left="$1"
  local right="$2"
  [[ "$(jq -Sc . "${left}")" == "$(jq -Sc . "${right}")" ]]
}

list_secret_versions() {
  local secret="$1"
  local destination="$2"
  gcloud_direct secrets versions list \
    --secret="${secret}" --project="${project_id}" \
    --format='json(name,state)' >"${destination}"
  chmod 0600 "${destination}"
  jq -e '
    type == "array"
    and all(.[];
      (.name | type) == "string"
      and (.name | test("/versions/[1-9][0-9]*$"))
      and (.state | IN("ENABLED", "DISABLED", "DESTROYED"))
    )
  ' "${destination}" >/dev/null
}

assert_no_unexpected_enabled_legacy_versions() {
  local inventory="$1"
  jq -e \
    --arg legacy "${legacy_version}" \
    --arg unregistered "${unregistered_version}" '
      all(.[];
        .state != "ENABLED"
        or ((.name | split("/") | last) == $legacy)
        or ($unregistered != "" and (.name | split("/") | last) == $unregistered)
      )
    ' "${inventory}" >/dev/null
}

assert_legacy_secret_fully_disabled() {
  local inventory="$1"
  jq -e 'all(.[]; .state != "ENABLED")' "${inventory}" >/dev/null
}

assert_private_evidence() {
  local path="$1"
  local permissions
  [[ -f "${path}" && ! -L "${path}" ]]
  permissions="$(stat -c '%a' "${path}" 2>/dev/null || stat -f '%Lp' "${path}")"
  [[ "${permissions}" == 600 ]]
}

finalize_management_lineage() {
  local input_file="$1"
  local legacy_accessor="$2"
  local output_file="$3"
  local envelope_file="${work_dir}/lineage-final-envelope.json"
  local live_payload="${work_dir}/lineage-final-live.json"
  local modify_index

  api_request "${work_dir}/candidate.curl" GET \
    '/v1/kv/e2b/acl-lineage/management' "${envelope_file}"
  http_is 200
  decode_lineage_envelope "${envelope_file}" "${live_payload}"
  json_equal "${input_file}" "${live_payload}"
  modify_index="$(jq -er '.[0].ModifyIndex | select(type == "number" and . >= 1) | tostring' \
    "${envelope_file}")"

  jq \
    --arg old "${legacy_accessor}" '
      .superseded_accessors = []
      | .revoked_accessors = (((.revoked_accessors // []) + [$old]) | unique | sort)
      | .last_revoked_accessor = $old
      | del(.handoff_pending_accessor)
    ' "${input_file}" >"${output_file}"
  api_request "${work_dir}/candidate.curl" PUT \
    "/v1/kv/e2b/acl-lineage/management?cas=${modify_index}" \
    "${work_dir}/lineage-final-write.json" \
    "${output_file}"
  http_is 200
  jq -e '. == true' "${work_dir}/lineage-final-write.json" >/dev/null
  api_request "${work_dir}/candidate.curl" GET \
    '/v1/kv/e2b/acl-lineage/management?raw' \
    "${work_dir}/lineage-final-readback.json"
  http_is 200
  json_equal "${output_file}" "${work_dir}/lineage-final-readback.json"
}

decode_lineage_envelope() {
  local envelope_file="$1"
  local output_file="$2"
  jq -e '
    type == "array"
    and length == 1
    and .[0].Key == "e2b/acl-lineage/management"
    and (.[0].ModifyIndex | type) == "number"
    and (.[0].Value | type) == "string"
  ' "${envelope_file}" >/dev/null
  jq -er '.[0].Value' "${envelope_file}" \
    | openssl base64 -d -A >"${output_file}"
  chmod 0600 "${output_file}"
  jq -e 'type == "object"' "${output_file}" >/dev/null
}

write_retired_evidence() {
  local legacy_accessor="$1"
  local candidate_accessor="$2"
  local legacy_accessor_http="$3"
  local unregistered_replay_http="$4"
  local unregistered_final_state="NOT_APPLICABLE"
  local evidence_tmp="${work_dir}/handoff-evidence.json"
  local evidence_dir
  local staged_evidence_sha256

  staged_evidence_sha256="$(digest_file "${evidence_path}")"

  [[ "$(secret_state "${legacy_secret}" "${legacy_version}")" == DISABLED ]]
  [[ "$(secret_state "${candidate_secret}" "${candidate_version}")" == ENABLED ]]
  list_secret_versions "${legacy_secret}" "${work_dir}/legacy-secret-versions-final.json"
  assert_legacy_secret_fully_disabled "${work_dir}/legacy-secret-versions-final.json" || {
    printf 'At least one old Consul management Secret Manager version remains enabled.\n' >&2
    return 1
  }
  if [[ -n "${unregistered_version}" ]]; then
    unregistered_final_state="$(secret_state "${unregistered_secret}" "${unregistered_version}")"
    [[ "${unregistered_final_state}" == DISABLED ]]
  fi

  jq -nS \
    --arg project_id "${project_id}" \
    --arg region "${region}" \
    --arg server "${selected_server}" \
    --arg zone "${selected_zone}" \
    --arg legacy_version_resource "${legacy_version_resource}" \
    --arg candidate_version_resource "${candidate_version_resource}" \
    --arg terraform_active_version_resource "${terraform_active_version_resource}" \
    --arg terraform_legacy_version_resource "${terraform_legacy_version_resource}" \
    --arg terraform_candidate_version_resource "${terraform_candidate_version_resource}" \
    --arg unregistered_version_resource "${unregistered_version_resource}" \
    --arg legacy_accessor "${legacy_accessor}" \
    --arg candidate_accessor "${candidate_accessor}" \
    --arg legacy_token_sha256 "${legacy_token_sha256}" \
    --arg candidate_token_sha256 "${candidate_token_sha256}" \
    --arg unregistered_token_sha256 "${unregistered_token_sha256}" \
    --arg authority_inventory_sha256 "${authority_inventory_sha256}" \
    --arg staged_evidence_sha256 "${staged_evidence_sha256}" \
    --arg legacy_accessor_http "${legacy_accessor_http}" \
    --arg unregistered_replay_http "${unregistered_replay_http}" \
    --arg unregistered_secret_manager_state "${unregistered_final_state}" \
    --arg server_template "${selected_template}" \
    --argjson server_instances "${selected_inventory}" \
    --arg retired_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {
        schema_version:4,
        status:"retired",
        project_id:$project_id,
        region:$region,
        iap_server:$server,
        iap_zone:$zone,
        legacy_version_resource:$legacy_version_resource,
        candidate_version_resource:$candidate_version_resource,
        terraform_active_version_resource:$terraform_active_version_resource,
        terraform_legacy_version_resource:$terraform_legacy_version_resource,
        terraform_candidate_version_resource:$terraform_candidate_version_resource,
        unregistered_version_resource:$unregistered_version_resource,
        legacy_accessor:$legacy_accessor,
        candidate_accessor:$candidate_accessor,
        legacy_token_sha256:$legacy_token_sha256,
        candidate_token_sha256:$candidate_token_sha256,
        unregistered_token_sha256:$unregistered_token_sha256,
        authority_inventory_sha256:$authority_inventory_sha256,
        staged_evidence_sha256:$staged_evidence_sha256,
        candidate_policies:["global-management"],
        legacy_replay_http:"not-reaccessed",
        legacy_accessor_http:$legacy_accessor_http,
        unregistered_replay_http:$unregistered_replay_http,
        legacy_secret_manager_state:"DISABLED",
        candidate_secret_manager_state:"ENABLED",
        unregistered_secret_manager_state:$unregistered_secret_manager_state,
        server_template:$server_template,
        server_instances:$server_instances,
        retired_at:$retired_at
      }
    ' >"${evidence_tmp}"
  chmod 0600 "${evidence_tmp}"
  evidence_dir="$(dirname "${evidence_path}")"
  [[ -d "${evidence_dir}" && ! -L "${evidence_dir}" ]]
  durable_publish_private "${evidence_tmp}" "${evidence_path}"
  assert_private_evidence "${evidence_path}"
  if [[ -f "${recovery_checkpoint}" && ! -L "${recovery_checkpoint}" ]]; then
    durable_remove_private "${recovery_checkpoint}"
    recovery_checkpoint_present=false
  fi
}

write_staged_evidence() {
  local legacy_accessor="$1"
  local candidate_accessor="$2"
  local legacy_final_state
  local evidence_tmp="${work_dir}/handoff-staged-evidence.json"
  local evidence_dir

  legacy_final_state="$(secret_state "${legacy_secret}" "${legacy_version}")"
  [[ "${legacy_final_state}" == DISABLED ]]
  [[ "$(secret_state "${candidate_secret}" "${candidate_version}")" == ENABLED ]]
  [[ "$(secret_state "${unregistered_secret}" "${unregistered_version}")" == DISABLED ]]

  jq -nS \
    --arg project_id "${project_id}" \
    --arg region "${region}" \
    --arg server "${selected_server}" \
    --arg zone "${selected_zone}" \
    --arg legacy_version_resource "${legacy_version_resource}" \
    --arg candidate_version_resource "${candidate_version_resource}" \
    --arg terraform_active_version_resource "${terraform_active_version_resource}" \
    --arg terraform_legacy_version_resource "${terraform_legacy_version_resource}" \
    --arg terraform_candidate_version_resource "${terraform_candidate_version_resource}" \
    --arg unregistered_version_resource "${unregistered_version_resource}" \
    --arg legacy_accessor "${legacy_accessor}" \
    --arg candidate_accessor "${candidate_accessor}" \
    --arg legacy_token_sha256 "${legacy_token_sha256}" \
    --arg candidate_token_sha256 "${candidate_token_sha256}" \
    --arg unregistered_token_sha256 "${unregistered_token_sha256}" \
    --arg authority_inventory_sha256 "${authority_inventory_sha256}" \
    --arg legacy_secret_manager_state "${legacy_final_state}" \
    --arg server_template "${selected_template}" \
    --argjson server_instances "${selected_inventory}" \
    --arg staged_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {
        schema_version:4,
        status:"staged",
        project_id:$project_id,
        region:$region,
        iap_server:$server,
        iap_zone:$zone,
        legacy_version_resource:$legacy_version_resource,
        candidate_version_resource:$candidate_version_resource,
        terraform_active_version_resource:$terraform_active_version_resource,
        terraform_legacy_version_resource:$terraform_legacy_version_resource,
        terraform_candidate_version_resource:$terraform_candidate_version_resource,
        unregistered_version_resource:$unregistered_version_resource,
        legacy_accessor:$legacy_accessor,
        candidate_accessor:$candidate_accessor,
        legacy_token_sha256:$legacy_token_sha256,
        candidate_token_sha256:$candidate_token_sha256,
        unregistered_token_sha256:$unregistered_token_sha256,
        authority_inventory_sha256:$authority_inventory_sha256,
        candidate_policies:["global-management"],
        legacy_replay_http:"200",
        legacy_accessor_http:"200",
        unregistered_replay_http:"403",
        legacy_secret_manager_state:$legacy_secret_manager_state,
        candidate_secret_manager_state:"ENABLED",
        unregistered_secret_manager_state:"DISABLED",
        server_template:$server_template,
        server_instances:$server_instances,
        staged_at:$staged_at
      }
    ' >"${evidence_tmp}"
  chmod 0600 "${evidence_tmp}"
  evidence_dir="$(dirname "${evidence_path}")"
  [[ -d "${evidence_dir}" && ! -L "${evidence_dir}" ]]
  durable_publish_private "${evidence_tmp}" "${evidence_path}"
  assert_private_evidence "${evidence_path}"
}

make_curl_config() {
  local token_file="$1"
  local destination="$2"
  {
    printf 'silent\nshow-error\nheader = "Host: localhost"\nheader = "X-Consul-Token: '
    tr -d '\r\n' <"${token_file}"
    printf '"\n'
  } >"${destination}"
  chmod 0600 "${destination}"
}

api_request() {
  local config_file="$1"
  local method="$2"
  local path="$3"
  local output_file="$4"
  local payload_file="${5:-}"

  set +e
  if [[ -n "${payload_file}" ]]; then
    API_HTTP_CODE="$(curl --disable --noproxy '*' --proto '=http' \
      --connect-timeout 5 --max-time 30 --config "${config_file}" \
      --request "${method}" \
      --output "${output_file}" \
      --write-out '%{http_code}' \
      --data-binary "@${payload_file}" \
      "http://127.0.0.1:${local_port}${path}" \
      2>>"${work_dir}/curl-errors.log")"
  else
    API_HTTP_CODE="$(curl --disable --noproxy '*' --proto '=http' \
      --connect-timeout 5 --max-time 30 --config "${config_file}" \
      --request "${method}" \
      --output "${output_file}" \
      --write-out '%{http_code}' \
      "http://127.0.0.1:${local_port}${path}" \
      2>>"${work_dir}/curl-errors.log")"
  fi
  API_STATUS=$?
  set -e
  chmod 0600 "${output_file}" 2>/dev/null || true
}

http_is() {
  local expected="$1"
  [[ "${API_STATUS}" -eq 0 && "${API_HTTP_CODE}" == "${expected}" ]]
}

http_is_one_of() {
  local expected
  [[ "${API_STATUS}" -eq 0 ]] || return 1
  for expected in "$@"; do
    [[ "${API_HTTP_CODE}" == "${expected}" ]] && return 0
  done
  return 1
}

assert_global_management() {
  local token_document="$1"
  jq -e '
    (.AccessorID | type) == "string"
    and (.AccessorID | test("^[0-9A-Fa-f-]{36}$"))
    and ([.Policies[]?.Name] | sort) == ["global-management"]
  ' "${token_document}" >/dev/null
}

assert_durable_candidate_management() {
  local token_document="$1"
  jq -e '
    (.AccessorID | type) == "string"
    and (.AccessorID | test("^[0-9A-Fa-f-]{36}$"))
    and .Description == "E2B Consul promoted management token"
    and ([.Policies[]? | {ID:(.ID // ""),Name:(.Name // "")}] | map(.Name) | sort)
      == ["global-management"]
    and ((.Roles // []) | length) == 0
    and ((.ServiceIdentities // []) | length) == 0
    and ((.NodeIdentities // []) | length) == 0
    and ((.TemplatedPolicies // []) | length) == 0
    and .Local == false
    and ((.AuthMethod // "") == "")
    and ((.AuthMethodNamespace // "") == "")
    and ((.ExpirationTTL // 0) == 0)
    and ((.ExpirationTime // null) == null)
  ' "${token_document}" >/dev/null
}

assert_accessor_absent() {
  local management_config="$1"
  local accessor="$2"
  local output_file="$3"
  [[ "${accessor}" =~ ^[0-9A-Fa-f-]{36}$ ]]
  api_request "${management_config}" GET "/v1/acl/token/${accessor}" "${output_file}"
  http_is 404
}

capture_acl_authority_inventory() {
  local list_file="${work_dir}/tokens-authority-list.json"
  local rows_file="${work_dir}/tokens-authority-rows.jsonl"
  local inventory_file="${work_dir}/tokens-authority-inventory.json"
  local token_file="${work_dir}/token-authority-expanded.json"
  local accessor

  api_request "${work_dir}/candidate.curl" GET '/v1/acl/tokens' "${list_file}"
  http_is 200
  jq -e '
    type == "array"
    and all(.[];
      (.AccessorID | type) == "string"
      and (.AccessorID | test("^[0-9A-Fa-f-]{36}$"))
    )
    and ([.[].AccessorID] | unique | length) == length
  ' "${list_file}" >/dev/null

  : >"${rows_file}"
  while IFS= read -r accessor; do
    api_request "${work_dir}/candidate.curl" GET \
      "/v1/acl/token/${accessor}?expanded=true" "${token_file}"
    http_is 200
    "${script_dir}/classify-consul-token-authority.py" \
      "${token_file}" "${accessor}" >>"${rows_file}"
  done < <(jq -r 'sort_by(.AccessorID)[].AccessorID' "${list_file}")

  jq -eS --slurp '
    sort_by(.accessor)
    | select(length > 0)
    | select(([.[].accessor] | unique | length) == length)
  ' "${rows_file}" >"${inventory_file}"
  chmod 0600 "${inventory_file}"
  authority_inventory_sha256="$(digest_file "${inventory_file}")"
}

assert_candidate_inventory_row() {
  local candidate_accessor="$1"
  jq -e --arg candidate "${candidate_accessor}" '
    [.[] | select(.accessor == $candidate)] as $matches
    | ($matches | length) == 1
      and $matches[0].description == "E2B Consul promoted management token"
      and $matches[0].local == false
      and $matches[0].auth_method == ""
      and $matches[0].auth_method_namespace == ""
      and $matches[0].expiration_ttl == 0
      and $matches[0].expiration_time == null
      and ([$matches[0].policies[].name] | sort) == ["global-management"]
      and ($matches[0].roles | length) == 0
      and ($matches[0].templated_policies | length) == 0
      and $matches[0].acl_write == true
  ' "${work_dir}/tokens-authority-inventory.json" >/dev/null
}

assert_only_candidate_management() {
  local candidate_accessor="$1"
  capture_acl_authority_inventory
  assert_candidate_inventory_row "${candidate_accessor}"
  jq -e \
    --arg candidate "${candidate_accessor}" '
      [
        .[]?
        | select(.acl_write == true)
        | .accessor
      ]
      | unique
      | sort
      | . == [$candidate]
    ' "${work_dir}/tokens-authority-inventory.json" >/dev/null
}

assert_staged_management_pair() {
  local legacy_accessor="$1"
  local candidate_accessor="$2"
  capture_acl_authority_inventory
  assert_candidate_inventory_row "${candidate_accessor}"
  jq -e \
    --arg legacy "${legacy_accessor}" \
    --arg candidate "${candidate_accessor}" '
      [
        .[]?
        | select(.acl_write == true)
        | .accessor
      ]
      | unique
      | sort
      | . == ([$legacy, $candidate] | sort)
    ' "${work_dir}/tokens-authority-inventory.json" >/dev/null
}

select_server() {
  local inventory="${work_dir}/servers.json"
  gcloud_direct compute instance-groups managed list-instances \
    "${prefix}orch-server-rig" \
    --region="${region}" --project="${project_id}" --format=json >"${inventory}"
  jq -e '
    type == "array"
    and length == 3
    and ([.[].id | tostring] | unique | length) == 3
    and ([.[].name] | unique | length) == 3
    and ([.[].version.instanceTemplate] | unique | length) == 1
    and all(.[];
      .currentAction == "NONE"
      and .instanceStatus == "RUNNING"
      and (.id | tostring | test("^[0-9]+$"))
      and (.version.instanceTemplate | type) == "string"
      and (.version.instanceTemplate | test("/instanceTemplates/[a-z0-9-]+$"))
    )
  ' "${inventory}" >/dev/null
  selected_server="$(jq -er 'sort_by(.name)[0].name' "${inventory}")"
  selected_zone="$(jq -er 'sort_by(.name)[0].instance | capture("/zones/(?<zone>[^/]+)/instances/").zone' "${inventory}")"
  selected_template="$(jq -er '.[0].version.instanceTemplate' "${inventory}")"
  selected_inventory="$(jq -ceS '[.[] | {id:(.id|tostring),name,instance,template:.version.instanceTemplate}] | sort_by(.name)' "${inventory}")"
  [[ "${selected_zone}" =~ ^${region}-[a-z]$ ]]
}

assert_server_inventory_unchanged() {
  local inventory="${work_dir}/servers-recheck.json"
  local canonical
  gcloud_direct compute instance-groups managed list-instances \
    "${prefix}orch-server-rig" \
    --region="${region}" --project="${project_id}" --format=json >"${inventory}"
  canonical="$(jq -ceS '
    if (
      type == "array"
      and length == 3
      and all(.[]; .currentAction == "NONE" and .instanceStatus == "RUNNING")
    ) then
      [.[] | {id:(.id|tostring),name,instance,template:.version.instanceTemplate}]
      | sort_by(.name)
    else error("server inventory is not stable") end
  ' "${inventory}")"
  [[ "${canonical}" == "${selected_inventory}" ]]
}

start_tunnel() {
  select_server
  env \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
    -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
    "${gcloud_bin}" compute ssh "${selected_server}" \
    --tunnel-through-iap \
    --zone="${selected_zone}" --project="${project_id}" \
    --ssh-flag='-N' \
    --ssh-flag='-oExitOnForwardFailure=yes' \
    --ssh-flag='-oServerAliveInterval=15' \
    --ssh-flag='-oServerAliveCountMax=2' \
    --ssh-flag="-L127.0.0.1:${local_port}:127.0.0.1:8500" \
    --quiet >"${work_dir}/iap.log" 2>&1 &
  tunnel_pid=$!
  for _ in {1..120}; do
    kill -0 "${tunnel_pid}" >/dev/null 2>&1 || {
      printf 'IAP tunnel exited before the local Consul endpoint became ready.\n' >&2
      return 1
    }
    if curl --disable --noproxy '*' --proto '=http' \
      --connect-timeout 2 --max-time 3 --fail --silent --show-error \
      --header 'Host: localhost' \
      "http://127.0.0.1:${local_port}/v1/status/leader" \
      >"${work_dir}/leader.json" 2>/dev/null \
      && jq -e 'type == "string" and length > 0' "${work_dir}/leader.json" >/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  printf 'IAP-local Consul endpoint did not become ready.\n' >&2
  return 1
}

restore_secret_states() {
  local desired_legacy_state="${legacy_initial_state}"
  local desired_candidate_state="${candidate_initial_state}"
  local desired_unregistered_state="${unregistered_initial_state}"
  local failed=0

  if [[ "${revocation_started}" == true || "${old_revoked}" == true ]]; then
    desired_legacy_state=DISABLED
    desired_candidate_state=ENABLED
    desired_unregistered_state=DISABLED
  elif [[ "${staging_committed}" == true ]]; then
    desired_legacy_state=DISABLED
    desired_candidate_state=ENABLED
    desired_unregistered_state=DISABLED
  fi
  if [[ -n "${desired_legacy_state}" ]]; then
    set_and_verify_secret_state "${legacy_secret}" "${legacy_version}" \
      "${desired_legacy_state}" || failed=1
  fi
  if [[ -n "${desired_candidate_state}" ]]; then
    set_and_verify_secret_state "${candidate_secret}" "${candidate_version}" \
      "${desired_candidate_state}" || failed=1
  fi
  if [[ -n "${desired_unregistered_state}" ]]; then
    set_and_verify_secret_state "${unregistered_secret}" "${unregistered_version}" \
      "${desired_unregistered_state}" || failed=1
  fi
  return "${failed}"
}

set_and_verify_secret_state() {
  local secret="$1"
  local version="$2"
  local desired_state="$3"
  local current_state
  current_state="$(secret_state "${secret}" "${version}")" || return 1
  if [[ "${current_state}" != "${desired_state}" ]]; then
    case "${desired_state}" in
      ENABLED) set_secret_state enable "${secret}" "${version}" || return 1 ;;
      DISABLED) set_secret_state disable "${secret}" "${version}" || return 1 ;;
      *) return 1 ;;
    esac
  fi
  [[ "$(secret_state "${secret}" "${version}")" == "${desired_state}" ]]
}

write_recovery_checkpoint() {
  local phase="$1"
  local checkpoint_tmp="${work_dir}/recovery-checkpoint.json"
  local accessor_json=null
  if [[ -f "${recovery_checkpoint}" && ! -L "${recovery_checkpoint}" ]] \
    && jq -e '.schema_version == 3 and .phase == "legacy-secret-enable-intent"' \
      "${recovery_checkpoint}" >/dev/null 2>&1; then
    jq -S \
      --arg last_failure_phase "${phase}" \
      --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .last_failure_phase = $last_failure_phase | .recorded_at = $recorded_at
      ' "${recovery_checkpoint}" >"${checkpoint_tmp}"
    durable_publish_private "${checkpoint_tmp}" "${recovery_checkpoint}"
    recovery_checkpoint_present=true
    return 0
  fi
  if [[ -f "${recovery_checkpoint}" && ! -L "${recovery_checkpoint}" ]] \
    && jq -e '.schema_version == 2 and (.phase | IN("revocation-intent", "forward-recovery-required"))' \
      "${recovery_checkpoint}" >/dev/null 2>&1; then
    jq -S \
      --arg phase "${phase}" \
      --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .phase = $phase | .recorded_at = $recorded_at
      ' "${recovery_checkpoint}" >"${checkpoint_tmp}"
    durable_publish_private "${checkpoint_tmp}" "${recovery_checkpoint}"
    recovery_checkpoint_present=true
    return 0
  fi
  if [[ "${candidate_accessor_for_recovery}" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    accessor_json="$(jq -cn --arg value "${candidate_accessor_for_recovery}" '$value')"
  fi
  jq -nS \
    --arg phase "${phase}" \
    --arg project_id "${project_id}" \
    --arg legacy_version_resource "${legacy_version_resource}" \
    --arg unregistered_version_resource "${unregistered_version_resource}" \
    --arg candidate_version_resource "${candidate_version_resource}" \
    --arg terraform_active_version_resource "${terraform_active_version_resource}" \
    --arg terraform_legacy_version_resource "${terraform_legacy_version_resource}" \
    --arg terraform_candidate_version_resource "${terraform_candidate_version_resource}" \
    --arg candidate_token_sha256 "${candidate_token_sha256}" \
    --argjson candidate_accessor "${accessor_json}" \
    --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {
        schema_version:1,
        phase:$phase,
        project_id:$project_id,
        legacy_version_resource:$legacy_version_resource,
        unregistered_version_resource:$unregistered_version_resource,
        candidate_version_resource:$candidate_version_resource,
        terraform_active_version_resource:$terraform_active_version_resource,
        terraform_legacy_version_resource:$terraform_legacy_version_resource,
        terraform_candidate_version_resource:$terraform_candidate_version_resource,
        candidate_token_sha256:$candidate_token_sha256,
        candidate_accessor:$candidate_accessor,
        recorded_at:$recorded_at
      }
    ' >"${checkpoint_tmp}"
  durable_publish_private "${checkpoint_tmp}" "${recovery_checkpoint}"
  recovery_checkpoint_present=true
}

write_stage_enable_intent_journal() {
  local journal_tmp="${work_dir}/legacy-secret-enable-intent.json"
  assert_private_evidence "${lease_token}"
  [[ "${legacy_initial_state}" == DISABLED \
    && "${candidate_initial_state}" == ENABLED \
    && "${unregistered_initial_state}" == DISABLED ]] || {
    printf 'Fresh management handoff requires exact Secret Manager states DISABLED/ENABLED/DISABLED.\n' >&2
    return 1
  }
  jq -nS \
    --arg project_id "${project_id}" \
    --arg region "${region}" \
    --arg prefix "${prefix}" \
    --arg legacy_version_resource "${legacy_version_resource}" \
    --arg unregistered_version_resource "${unregistered_version_resource}" \
    --arg candidate_version_resource "${candidate_version_resource}" \
    --arg terraform_active_version_resource "${terraform_active_version_resource}" \
    --arg terraform_legacy_version_resource "${terraform_legacy_version_resource}" \
    --arg terraform_candidate_version_resource "${terraform_candidate_version_resource}" \
    --arg legacy_initial_state "${legacy_initial_state}" \
    --arg candidate_initial_state "${candidate_initial_state}" \
    --arg unregistered_initial_state "${unregistered_initial_state}" \
    --arg lease_token_sha256 "$(digest_file "${lease_token}")" \
    --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {
        schema_version:3,
        phase:"legacy-secret-enable-intent",
        project_id:$project_id,
        region:$region,
        prefix:$prefix,
        legacy_version_resource:$legacy_version_resource,
        unregistered_version_resource:$unregistered_version_resource,
        candidate_version_resource:$candidate_version_resource,
        terraform_active_version_resource:$terraform_active_version_resource,
        terraform_legacy_version_resource:$terraform_legacy_version_resource,
        terraform_candidate_version_resource:$terraform_candidate_version_resource,
        legacy_initial_state:$legacy_initial_state,
        candidate_initial_state:$candidate_initial_state,
        unregistered_initial_state:$unregistered_initial_state,
        lease_token_sha256:$lease_token_sha256,
        recorded_at:$recorded_at
      }
    ' >"${journal_tmp}"
  durable_publish_private "${journal_tmp}" "${recovery_checkpoint}"
  recovery_checkpoint_present=true
  recovery_schema=3
  recovery_phase=legacy-secret-enable-intent
  stage_enable_intent_active=true
}

validate_stage_enable_intent_journal() {
  local observed_legacy_state="$1"
  local observed_candidate_state="$2"
  local observed_unregistered_state="$3"
  assert_private_evidence "${recovery_checkpoint}"
  assert_private_evidence "${lease_token}"
  jq -e \
    --arg project "${project_id}" \
    --arg region "${region}" \
    --arg prefix "${prefix}" \
    --arg legacy "${legacy_version_resource}" \
    --arg unregistered "${unregistered_version_resource}" \
    --arg candidate "${candidate_version_resource}" \
    --arg terraform_active "${terraform_active_version_resource}" \
    --arg terraform_legacy "${terraform_legacy_version_resource}" \
    --arg terraform_candidate "${terraform_candidate_version_resource}" \
    --arg lease_digest "$(digest_file "${lease_token}")" '
      .schema_version == 3
      and .phase == "legacy-secret-enable-intent"
      and .project_id == $project
      and .region == $region
      and .prefix == $prefix
      and .legacy_version_resource == $legacy
      and .unregistered_version_resource == $unregistered
      and .candidate_version_resource == $candidate
      and .terraform_active_version_resource == $terraform_active
      and .terraform_legacy_version_resource == $terraform_legacy
      and .terraform_candidate_version_resource == $terraform_candidate
      and .legacy_initial_state == "DISABLED"
      and .candidate_initial_state == "ENABLED"
      and .unregistered_initial_state == "DISABLED"
      and .lease_token_sha256 == $lease_digest
      and (.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    ' "${recovery_checkpoint}" >/dev/null

  legacy_initial_state="$(jq -er '.legacy_initial_state' "${recovery_checkpoint}")"
  candidate_initial_state="$(jq -er '.candidate_initial_state' "${recovery_checkpoint}")"
  unregistered_initial_state="$(jq -er '.unregistered_initial_state' "${recovery_checkpoint}")"
  [[ "${observed_legacy_state}" == "${legacy_initial_state}" \
    || "${observed_legacy_state}" == ENABLED ]]
  [[ "${observed_candidate_state}" == "${candidate_initial_state}" \
    || "${observed_candidate_state}" == ENABLED ]]
  [[ "${observed_unregistered_state}" == "${unregistered_initial_state}" \
    || "${observed_unregistered_state}" == ENABLED ]]
  stage_enable_intent_active=true
}

complete_stage_enable_intent() {
  [[ "${stage_enable_intent_active}" == true ]] || return 0
  assert_private_evidence "${recovery_checkpoint}"
  jq -e '.schema_version == 3 and .phase == "legacy-secret-enable-intent"' \
    "${recovery_checkpoint}" >/dev/null
  durable_remove_private "${recovery_checkpoint}"
  recovery_checkpoint_present=false
  stage_enable_intent_active=false
}

write_revocation_intent_journal() {
  local legacy_accessor="$1"
  local candidate_accessor="$2"
  local lineage_file="$3"
  local lineage_modify_index="$4"
  local journal_tmp="${work_dir}/revocation-intent.json"

  [[ "${legacy_accessor}" =~ ^[0-9A-Fa-f-]{36}$ ]]
  [[ "${candidate_accessor}" =~ ^[0-9A-Fa-f-]{36}$ ]]
  [[ "${lineage_modify_index}" =~ ^[1-9][0-9]*$ ]]
  assert_private_evidence "${evidence_path}"
  assert_private_evidence "${post_api_evidence}"
  assert_private_evidence "${build_checkpoint}"
  jq -nS \
    --arg project_id "${project_id}" \
    --arg legacy_version_resource "${legacy_version_resource}" \
    --arg unregistered_version_resource "${unregistered_version_resource}" \
    --arg candidate_version_resource "${candidate_version_resource}" \
    --arg terraform_active_version_resource "${terraform_active_version_resource}" \
    --arg terraform_legacy_version_resource "${terraform_legacy_version_resource}" \
    --arg terraform_candidate_version_resource "${terraform_candidate_version_resource}" \
    --arg legacy_accessor "${legacy_accessor}" \
    --arg candidate_accessor "${candidate_accessor}" \
    --arg legacy_token_sha256 "${legacy_token_sha256}" \
    --arg candidate_token_sha256 "${candidate_token_sha256}" \
    --arg staged_lineage_sha256 "$(digest_file "${lineage_file}")" \
    --arg staged_evidence_sha256 "$(digest_file "${evidence_path}")" \
    --arg post_api_evidence_sha256 "$(digest_file "${post_api_evidence}")" \
    --arg build_checkpoint_sha256 "$(digest_file "${build_checkpoint}")" \
    --argjson lineage_modify_index "${lineage_modify_index}" \
    --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {
        schema_version:2,
        phase:"revocation-intent",
        project_id:$project_id,
        legacy_version_resource:$legacy_version_resource,
        unregistered_version_resource:$unregistered_version_resource,
        candidate_version_resource:$candidate_version_resource,
        terraform_active_version_resource:$terraform_active_version_resource,
        terraform_legacy_version_resource:$terraform_legacy_version_resource,
        terraform_candidate_version_resource:$terraform_candidate_version_resource,
        legacy_accessor:$legacy_accessor,
        candidate_accessor:$candidate_accessor,
        legacy_token_sha256:$legacy_token_sha256,
        candidate_token_sha256:$candidate_token_sha256,
        staged_lineage_modify_index:$lineage_modify_index,
        staged_lineage_sha256:$staged_lineage_sha256,
        staged_evidence_sha256:$staged_evidence_sha256,
        post_api_evidence_sha256:$post_api_evidence_sha256,
        build_checkpoint_sha256:$build_checkpoint_sha256,
        recorded_at:$recorded_at
      }
    ' >"${journal_tmp}"
  durable_publish_private "${journal_tmp}" "${recovery_checkpoint}"
  recovery_checkpoint_present=true
}

validate_revocation_intent_journal() {
  local legacy_accessor="$1"
  local candidate_accessor="$2"
  local lineage_file="${3:-}"
  local lineage_modify_index="${4:-}"
  local expected_lineage_sha256=""
  local expected_staged_evidence_sha256
  [[ -z "${lineage_file}" ]] || expected_lineage_sha256="$(digest_file "${lineage_file}")"
  if [[ "$(jq -er '.status' "${evidence_path}")" == retired ]]; then
    expected_staged_evidence_sha256="$(jq -er \
      '.staged_evidence_sha256 | select(test("^[0-9a-f]{64}$"))' \
      "${evidence_path}")"
  else
    expected_staged_evidence_sha256="$(digest_file "${evidence_path}")"
  fi
  [[ -z "${lineage_modify_index}" || "${lineage_modify_index}" =~ ^[1-9][0-9]*$ ]]
  assert_private_evidence "${recovery_checkpoint}"
  jq -e \
    --arg project "${project_id}" \
    --arg legacy_version "${legacy_version_resource}" \
    --arg unregistered_version "${unregistered_version_resource}" \
    --arg candidate_version "${candidate_version_resource}" \
    --arg terraform_active "${terraform_active_version_resource}" \
    --arg terraform_legacy "${terraform_legacy_version_resource}" \
    --arg terraform_candidate "${terraform_candidate_version_resource}" \
    --arg legacy_accessor "${legacy_accessor}" \
    --arg candidate_accessor "${candidate_accessor}" \
    --arg legacy_digest "${legacy_token_sha256}" \
    --arg candidate_digest "${candidate_token_sha256}" \
    --arg lineage_digest "${expected_lineage_sha256}" \
    --arg lineage_modify_index "${lineage_modify_index}" \
    --arg evidence_digest "${expected_staged_evidence_sha256}" \
    --arg post_api_digest "$(digest_file "${post_api_evidence}")" \
    --arg build_digest "$(digest_file "${build_checkpoint}")" '
      .schema_version == 2
      and (.phase | IN("revocation-intent", "forward-recovery-required"))
      and .project_id == $project
      and .legacy_version_resource == $legacy_version
      and .unregistered_version_resource == $unregistered_version
      and .candidate_version_resource == $candidate_version
      and .terraform_active_version_resource == $terraform_active
      and .terraform_legacy_version_resource == $terraform_legacy
      and .terraform_candidate_version_resource == $terraform_candidate
      and .legacy_accessor == $legacy_accessor
      and .candidate_accessor == $candidate_accessor
      and .legacy_token_sha256 == $legacy_digest
      and .candidate_token_sha256 == $candidate_digest
      and (.staged_lineage_modify_index | type) == "number"
      and .staged_lineage_modify_index >= 1
      and ($lineage_modify_index == "" or (.staged_lineage_modify_index | tostring) == $lineage_modify_index)
      and (.staged_lineage_sha256 | test("^[0-9a-f]{64}$"))
      and ($lineage_digest == "" or .staged_lineage_sha256 == $lineage_digest)
      and .staged_evidence_sha256 == $evidence_digest
      and .post_api_evidence_sha256 == $post_api_digest
      and .build_checkpoint_sha256 == $build_digest
    ' "${recovery_checkpoint}" >/dev/null
}

rollback_pre_revocation() {
  local candidate_accessor=""
  local rollback_accessor
  local rollback_modify_index
  local -a rollback_candidates=()
  [[ "${mode}" == stage && "${revocation_started}" == false && "${old_revoked}" == false ]] || return 0
  [[ "${candidate_created}" == true || "${lineage_mutated}" == true ]] || return 0
  [[ -f "${work_dir}/old.curl" && -f "${work_dir}/candidate.curl" ]] || return 1

  if [[ "${lineage_mutated}" == true ]]; then
    api_request "${work_dir}/old.curl" GET '/v1/kv/e2b/acl-lineage/management' \
      "${work_dir}/lineage-rollback-current-envelope.json"
    http_is 200 || return 1
    decode_lineage_envelope \
      "${work_dir}/lineage-rollback-current-envelope.json" \
      "${work_dir}/lineage-rollback-current.json" || return 1
    json_equal "${work_dir}/lineage-before-revoke.json" \
      "${work_dir}/lineage-rollback-current.json" || return 1
    rollback_modify_index="$(jq -er '.[0].ModifyIndex | select(type == "number" and . >= 1) | tostring' \
      "${work_dir}/lineage-rollback-current-envelope.json")" || return 1
    if [[ "${prior_lineage_present}" == true && -f "${work_dir}/prior-lineage.json" ]]; then
      api_request "${work_dir}/old.curl" PUT \
        "/v1/kv/e2b/acl-lineage/management?cas=${rollback_modify_index}" \
        "${work_dir}/lineage-rollback-response.json" "${work_dir}/prior-lineage.json"
      http_is 200 || return 1
      jq -e '. == true' "${work_dir}/lineage-rollback-response.json" >/dev/null || return 1
      api_request "${work_dir}/old.curl" GET '/v1/kv/e2b/acl-lineage/management?raw' \
        "${work_dir}/lineage-rollback-verify.json"
      http_is 200 && json_equal "${work_dir}/prior-lineage.json" \
        "${work_dir}/lineage-rollback-verify.json" || return 1
    else
      api_request "${work_dir}/old.curl" DELETE \
        "/v1/kv/e2b/acl-lineage/management?cas=${rollback_modify_index}" \
        "${work_dir}/lineage-rollback-response.json"
      http_is 200 || return 1
      jq -e '. == true' "${work_dir}/lineage-rollback-response.json" >/dev/null || return 1
      api_request "${work_dir}/old.curl" GET '/v1/kv/e2b/acl-lineage/management?raw' \
        "${work_dir}/lineage-rollback-verify.json"
      http_is 404 || return 1
    fi
    lineage_mutated=false
  fi

  if [[ "${candidate_created}" == true ]]; then
    [[ -f "${work_dir}/candidate-precreate-accessors.json" ]] || return 1
    if [[ -f "${work_dir}/candidate-create-response.json" ]]; then
      candidate_accessor="$(jq -er '.AccessorID | select(type == "string" and test("^[0-9A-Fa-f-]{36}$"))' \
        "${work_dir}/candidate-create-response.json" 2>/dev/null || true)"
    fi
    api_request "${work_dir}/candidate.curl" GET '/v1/acl/token/self' \
      "${work_dir}/candidate-rollback-self.json"
    http_is_one_of 200 403 || return 1
    if [[ "${API_HTTP_CODE}" == 200 ]]; then
      assert_durable_candidate_management "${work_dir}/candidate-rollback-self.json" || return 1
      candidate_accessor="$(jq -er '.AccessorID' "${work_dir}/candidate-rollback-self.json")"
      jq -e --arg accessor "${candidate_accessor}" \
        'index($accessor) == null' \
        "${work_dir}/candidate-precreate-accessors.json" >/dev/null || return 1
    else
      api_request "${work_dir}/old.curl" GET '/v1/acl/tokens' \
        "${work_dir}/candidate-rollback-tokens.json"
      http_is 200 || return 1
      while IFS= read -r rollback_accessor; do
        [[ -n "${rollback_accessor}" ]] && rollback_candidates+=("${rollback_accessor}")
      done < <(
        jq -r --slurpfile before \
          "${work_dir}/candidate-precreate-accessors.json" '
            .[]?
            | select(
                .Description == "E2B Consul promoted management token"
                and ([.Policies[]?.Name] | sort) == ["global-management"]
                and (.AccessorID as $accessor
                  | $before[0] | index($accessor) == null)
              )
            | .AccessorID
          ' "${work_dir}/candidate-rollback-tokens.json"
      )
      [[ "${#rollback_candidates[@]}" -le 1 ]] || return 1
      if [[ "${#rollback_candidates[@]}" -eq 1 ]]; then
        if [[ -n "${candidate_accessor}" && "${candidate_accessor}" != "${rollback_candidates[0]}" ]]; then
          return 1
        fi
        candidate_accessor="${rollback_candidates[0]}"
      fi
    fi
    if [[ -n "${candidate_accessor}" ]]; then
      [[ "${candidate_accessor}" =~ ^[0-9A-Fa-f-]{36}$ ]] || return 1
      jq -e --arg accessor "${candidate_accessor}" \
        'index($accessor) == null' \
        "${work_dir}/candidate-precreate-accessors.json" >/dev/null || return 1
      candidate_accessor_for_recovery="${candidate_accessor}"
      api_request "${work_dir}/old.curl" DELETE \
        "/v1/acl/token/${candidate_accessor}" "${work_dir}/candidate-rollback-delete.json"
      api_request "${work_dir}/candidate.curl" GET '/v1/acl/token/self' \
        "${work_dir}/candidate-rollback-replay.json"
      http_is 403 || return 1
      assert_accessor_absent "${work_dir}/old.curl" "${candidate_accessor}" \
        "${work_dir}/candidate-rollback-accessor.json" || return 1
    fi
    candidate_created=false
  fi
}

acquire_or_resume_rollout_lease() {
  local holder_digest
  if [[ -e "${lease_token}" ]]; then
    assert_private_evidence "${lease_token}"
    if [[ "${recovery_checkpoint_present}" != true ]] \
      || ! { [[ "${mode}" == retire \
          && ( "${recovery_schema}" == 1 || "${recovery_schema}" == 2 ) ]] \
        || [[ "${mode}" == stage && "${recovery_schema}" == 3 \
          && "${recovery_phase}" == legacy-secret-enable-intent ]]; }; then
      printf 'A prior Consul handoff lease exists without an automatic recovery path: %s\n' \
        "${lease_token}" >&2
      return 1
    fi
    lease_call assert-held "${gcloud_bin}" "${state_bucket}" \
      "${project_id}" "${region}" "${lease_token}" >/dev/null
    lease_acquired=true
    lease_borrowed=true
    return 0
  fi

  holder_digest="$(
    {
      printf '%s\n' "${project_id}" "${region}" "${prefix}" "${mode}" "$$" \
        "$(date -u +%s)"
      [[ -z "${repo_root}" ]] || git -C "${repo_root}" rev-parse --verify HEAD
    } | shasum -a 256 | awk '{print $1}'
  )"
  lease_call acquire "${gcloud_bin}" "${state_bucket}" \
    "${project_id}" "${region}" "consul-handoff:${mode}:${holder_digest}" \
    "${lease_token}" >/dev/null
  lease_acquired=true
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  local cleanup_failed=0
  if [[ "${status}" -ne 0 && "${revocation_started}" == false && "${old_revoked}" == false ]]; then
    if ! rollback_pre_revocation; then
      write_recovery_checkpoint pre-revocation-rollback-unproven || true
      cleanup_failed=1
    fi
  elif [[ "${status}" -ne 0 ]]; then
    write_recovery_checkpoint forward-recovery-required || true
  fi
  if ! restore_secret_states; then
    [[ "${revocation_started}" == true || "${old_revoked}" == true ]] \
      && write_recovery_checkpoint forward-recovery-required || true
    cleanup_failed=1
  fi
  if [[ -n "${tunnel_pid}" ]]; then
    kill "${tunnel_pid}" >/dev/null 2>&1 || true
    wait "${tunnel_pid}" >/dev/null 2>&1 || true
  fi
  if [[ "${lease_acquired}" == true ]]; then
    if [[ "${status}" -ne 0 && "${recovery_checkpoint_present}" == true ]]; then
      printf 'Preserving the shared rollout lease for Consul handoff recovery: %s\n' \
        "${lease_token}" >&2
    elif ! lease_call release "${gcloud_bin}" "${lease_token}" >/dev/null; then
      printf 'Shared rollout lease release failed; inspect before another mutation.\n' >&2
      cleanup_failed=1
    else
      lease_acquired=false
      lease_borrowed=false
    fi
  fi
  find "${work_dir}" -type f -exec sh -c 'for file do : >"$file"; done' sh {} + 2>/dev/null || true
  rm -rf -- "${work_dir}"
  [[ "${cleanup_failed}" -eq 0 ]] || status=1
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${recovery_checkpoint_present}" == true ]]; then
  assert_private_evidence "${recovery_checkpoint}" || {
    printf 'Consul recovery checkpoint is not a private regular file: %s\n' \
      "${recovery_checkpoint}" >&2
    exit 1
  }
  jq -e \
    --arg project "${project_id}" \
    --arg region "${region}" \
    --arg prefix "${prefix}" \
    --arg legacy "${legacy_version_resource}" \
    --arg unregistered "${unregistered_version_resource}" \
    --arg candidate "${candidate_version_resource}" \
    --arg terraform_active "${terraform_active_version_resource}" \
    --arg terraform_legacy "${terraform_legacy_version_resource}" \
    --arg terraform_candidate "${terraform_candidate_version_resource}" '
      (.schema_version | IN(1, 2, 3))
      and .project_id == $project
      and .legacy_version_resource == $legacy
      and .unregistered_version_resource == $unregistered
      and .candidate_version_resource == $candidate
      and .terraform_active_version_resource == $terraform_active
      and .terraform_legacy_version_resource == $terraform_legacy
      and .terraform_candidate_version_resource == $terraform_candidate
      and (
        if .schema_version == 2 then
          (.candidate_accessor | test("^[0-9A-Fa-f-]{36}$"))
          and (.candidate_token_sha256 | test("^[0-9a-f]{64}$"))
          and (.legacy_accessor | test("^[0-9A-Fa-f-]{36}$"))
          and (.legacy_token_sha256 | test("^[0-9a-f]{64}$"))
          and (.staged_lineage_modify_index | type) == "number"
          and .staged_lineage_modify_index >= 1
          and (.staged_lineage_sha256 | test("^[0-9a-f]{64}$"))
          and (.staged_evidence_sha256 | test("^[0-9a-f]{64}$"))
          and (.post_api_evidence_sha256 | test("^[0-9a-f]{64}$"))
          and (.build_checkpoint_sha256 | test("^[0-9a-f]{64}$"))
        elif .schema_version == 3 then
          .phase == "legacy-secret-enable-intent"
          and .region == $region
          and .prefix == $prefix
          and .legacy_initial_state == "DISABLED"
          and .candidate_initial_state == "ENABLED"
          and .unregistered_initial_state == "DISABLED"
          and (.lease_token_sha256 | test("^[0-9a-f]{64}$"))
        else
          (.candidate_accessor == null or (.candidate_accessor | test("^[0-9A-Fa-f-]{36}$")))
          and (.candidate_token_sha256 == "" or (.candidate_token_sha256 | test("^[0-9a-f]{64}$")))
        end
      )
    ' "${recovery_checkpoint}" >/dev/null
  recovery_phase="$(jq -er '.phase' "${recovery_checkpoint}")"
  recovery_schema="$(jq -er '.schema_version' "${recovery_checkpoint}")"
  if ! { [[ "${mode}" == retire && "${recovery_schema}" == 1 \
      && "${recovery_phase}" == forward-recovery-required ]] \
    || [[ "${mode}" == retire && "${recovery_schema}" == 2 \
      && ( "${recovery_phase}" == revocation-intent \
        || "${recovery_phase}" == forward-recovery-required ) ]] \
    || [[ "${mode}" == stage && "${recovery_schema}" == 3 \
      && "${recovery_phase}" == legacy-secret-enable-intent ]]; }; then
    printf 'Recovery checkpoint requires manual resolution before this operation: %s\n' \
      "${recovery_checkpoint}" >&2
    exit 1
  fi
fi

acquire_or_resume_rollout_lease

assert_pre_server_acl_live_state() {
  [[ "${mode}" == stage ]] || return 0
  ACL_RUNTIME_JOB_LIVE_LEASE_TOKEN="${lease_token}" \
    ACL_RUNTIME_JOB_LIVE_CURL_BIN="$(command -v curl)" \
    env \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
      -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
      "${acl_live_evidence_guard}" \
        "${pre_server_acl_evidence}" "${handoff_environment}" \
        "${project_id}" "${region}" "${prefix}" "${state_bucket}" \
        "${nomad_base_url#https://nomad.}" "${nomad_version_resource}" \
        "${gcloud_bin}" "${lease_script}" "${nomad_job_gate_script}"
}

assert_pre_server_acl_live_state

validate_handoff_evidence() {
  local expected_status="$1"
  assert_private_evidence "${evidence_path}" || return 1
  jq -e \
    --arg expected_status "${expected_status}" \
    --arg project "${project_id}" \
    --arg region "${region}" \
    --arg legacy_version "${legacy_version_resource}" \
    --arg candidate_version "${candidate_version_resource}" \
    --arg unregistered_version "${unregistered_version_resource}" \
    --arg terraform_active_version "${terraform_active_version_resource}" \
    --arg terraform_legacy_version "${terraform_legacy_version_resource}" \
    --arg terraform_candidate_version "${terraform_candidate_version_resource}" \
    --arg legacy_digest "${legacy_token_sha256}" \
    --arg candidate_digest "${candidate_token_sha256}" '
      .schema_version == 4
      and .status == $expected_status
      and .project_id == $project
      and .region == $region
      and .legacy_version_resource == $legacy_version
      and .candidate_version_resource == $candidate_version
      and .unregistered_version_resource == $unregistered_version
      and .terraform_active_version_resource == $terraform_active_version
      and .terraform_legacy_version_resource == $terraform_legacy_version
      and .terraform_candidate_version_resource == $terraform_candidate_version
      and (.legacy_accessor | test("^[0-9A-Fa-f-]{36}$"))
      and (.candidate_accessor | test("^[0-9A-Fa-f-]{36}$"))
      and .legacy_accessor != .candidate_accessor
      and .legacy_token_sha256 == $legacy_digest
      and .candidate_token_sha256 == $candidate_digest
      and (.unregistered_token_sha256 | test("^[0-9a-f]{64}$"))
      and (.authority_inventory_sha256 | test("^[0-9a-f]{64}$"))
      and .candidate_policies == ["global-management"]
      and .unregistered_replay_http == "403"
      and .candidate_secret_manager_state == "ENABLED"
      and .unregistered_secret_manager_state == "DISABLED"
      and (.server_template | test("/instanceTemplates/[a-z0-9-]+$"))
      and (.server_instances | type) == "array"
      and (.server_instances | length) == 3
      and ([.server_instances[].id] | unique | length) == 3
      and ([.server_instances[].name] | unique | length) == 3
      and (.server_template as $template | all(.server_instances[]; .template == $template))
      and (
        if $expected_status == "staged" then
          .legacy_replay_http == "200"
          and .legacy_accessor_http == "200"
          and .legacy_secret_manager_state == "DISABLED"
          and (.staged_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
        else
          .legacy_replay_http == "not-reaccessed"
          and .legacy_accessor_http == "404"
          and .legacy_secret_manager_state == "DISABLED"
          and (.staged_evidence_sha256 | test("^[0-9a-f]{64}$"))
          and (.retired_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
        end
      )
    ' "${evidence_path}" >/dev/null
  evidence_old="$(jq -er '.legacy_accessor' "${evidence_path}")"
  evidence_candidate="$(jq -er '.candidate_accessor' "${evidence_path}")"
  unregistered_token_sha256="$(jq -er '.unregistered_token_sha256' "${evidence_path}")"
  unregistered_replay_http="$(jq -er '.unregistered_replay_http' "${evidence_path}")"
}

assert_staged_lineage() {
  local candidate_accessor="$1"
  local legacy_accessor="$2"
  local destination="$3"
  api_request "${work_dir}/candidate.curl" GET \
    '/v1/kv/e2b/acl-lineage/management?raw' "${destination}"
  http_is 200
  jq -e \
    --arg current "${candidate_accessor}" \
    --arg old "${legacy_accessor}" \
    --arg version "${candidate_version_resource}" '
      .current_accessor == $current
      and .version_resource == $version
      and (.superseded_accessors | index($old)) != null
      and (.revoked_accessors | index($old)) == null
      and .handoff_pending_accessor == $old
    ' "${destination}" >/dev/null
}

capture_staged_lineage_for_revocation() {
  local candidate_accessor="$1"
  local legacy_accessor="$2"
  local envelope="${work_dir}/lineage-revocation-envelope.json"
  local destination="${work_dir}/lineage-before-revoke.json"
  api_request "${work_dir}/candidate.curl" GET \
    '/v1/kv/e2b/acl-lineage/management' "${envelope}"
  http_is 200
  decode_lineage_envelope "${envelope}" "${destination}"
  jq -e \
    --arg current "${candidate_accessor}" \
    --arg old "${legacy_accessor}" \
    --arg version "${candidate_version_resource}" '
      .current_accessor == $current
      and .version_resource == $version
      and (.superseded_accessors | index($old)) != null
      and (.revoked_accessors | index($old)) == null
      and .handoff_pending_accessor == $old
    ' "${destination}" >/dev/null
  revocation_lineage_modify_index="$(jq -er \
    '.[0].ModifyIndex | select(type == "number" and . >= 1) | tostring' \
    "${envelope}")"
}

assert_retirement_gates() {
  [[ "${mode}" == retire ]] || return 0
  [[ -n "${post_api_evidence}" && -n "${build_checkpoint}" && -n "${repo_root}" ]]
  assert_private_evidence "${post_api_evidence}"
  repo_root="$(cd "${repo_root}" && pwd -P)"
  source_head="$(git -C "${repo_root}" rev-parse --verify HEAD)"
  jq -e \
    --arg source_sha "${source_head}" \
    --arg project "${project_id}" \
    --arg region "${region}" \
    --arg prefix "${prefix}" '
      . as $evidence
      | .schema_version == 1
      and .source_sha == $source_sha
      and .project_id == $project
      and .region == $region
      and .prefix == $prefix
      and .phase == "post-api"
      and .stage == "api"
      and (.checkpoint_sha256 | test("^[0-9a-f]{64}$"))
      and (.reviewed_plan_sha256 | test("^[0-9a-f]{64}$"))
      and (.reviewed_manifest_sha256 | test("^[0-9a-f]{64}$"))
      and (.converged_plan_sha256 | test("^[0-9a-f]{64}$"))
      and (.job_projection_sha256 | test("^[0-9a-f]{64}$"))
      and (.live_job_projection_sha256 | test("^[0-9a-f]{64}$"))
      and (.job_inventory_projection_sha256 | test("^[0-9a-f]{64}$"))
      and (.live_job_inventory_projection_sha256 | test("^[0-9a-f]{64}$"))
      and (.exclusive_transition_sha256 | test("^[0-9a-f]{64}$"))
      and (.live_nomad_convergence_sha256 | test("^[0-9a-f]{64}$"))
      and (.job_addresses | type) == "array"
      and (.job_addresses | length) > 0
      and (.job_addresses | unique | length) == (.job_addresses | length)
      and all(.job_addresses[]; startswith("module.nomad."))
      and .exclusive_transition.schema_version == 1
      and .exclusive_transition.kind == "exclusive-runtime-transition"
      and .exclusive_transition.projection_sha256 == .job_projection_sha256
      and .exclusive_transition.inventory_projection_sha256
        == .job_inventory_projection_sha256
      and .exclusive_transition.live_inventory.kind
        == "live-nomad-job-inventory"
      and .exclusive_transition.live_inventory.completeness
        == "no-unreviewed-live-jobs"
      and .exclusive_transition.live_inventory.projection_sha256
        == .job_inventory_projection_sha256
      and .exclusive_transition.descendant_quiescence.kind
        == "nomad-descendant-quiescence"
      and .exclusive_transition.descendant_quiescence.stable_zero_observations == 2
      and .exclusive_transition.descendant_quiescence.remaining_descendants == 0
      and .exclusive_transition.descendant_quiescence.remaining_descendant_capable_parents == 0
      and .exclusive_transition.descendant_quiescence.remaining_active_allocations == 0
      and ([.exclusive_transition.actions[].address] | sort) == [
        "module.nomad.module.orchestrator[0].nomad_job.orchestrator",
        "module.nomad.module.template_manager.nomad_job.template_manager"
      ]
      and all(.exclusive_transition.actions[];
        (.action | IN(
          "already_absent",
          "already_locking",
          "purged_before_first_locking_rollout"
        )))
      and .live_nomad_convergence.schema_version == 1
      and .live_nomad_convergence.kind == "live-nomad-job-convergence"
      and .live_nomad_convergence.projection_sha256
        == .live_job_projection_sha256
      and .live_nomad_convergence.inventory_projection_sha256
        == .live_job_inventory_projection_sha256
      and .live_nomad_convergence.live_inventory.kind
        == "live-nomad-job-inventory"
      and .live_nomad_convergence.live_inventory.completeness == "exact"
      and .live_nomad_convergence.live_inventory.projection_sha256
        == .live_job_inventory_projection_sha256
      and (.live_job_projection | type) == "array"
      and (.live_job_projection | length) == (.job_addresses | length)
      and ([.live_job_projection[].address] | sort)
        == (.job_addresses | sort)
      and all(.live_job_projection[];
        (.expected_modify_index | type) == "number"
        and .expected_modify_index > 0
        and (.jobspec_sha256 | test("^[0-9a-f]{64}$"))
      )
      and (.live_job_inventory_projection | type) == "array"
      and (.live_job_inventory_projection | length) >= (.job_addresses | length)
      and all(.live_job_inventory_projection[];
        (.address | startswith("module.nomad."))
        and (.expected_modify_index | type) == "number"
        and .expected_modify_index > 0
        and (.submission_source_sha256 | test("^[0-9a-f]{64}$"))
        and (
          if .job_type == "batch"
          then .inventory_class == "token-free-batch"
            and (.child_mode | IN("none", "periodic", "parameterized"))
          else (.job_type == "service" or .job_type == "system")
            and .inventory_class == "managed-runtime"
            and .child_mode == "none"
          end
        )
      )
      and ([.live_nomad_convergence.live_inventory.top_level_jobs[].job_id] | sort)
        == ([.live_job_inventory_projection[].job_id] | sort)
      and all(.live_nomad_convergence.live_inventory.top_level_jobs[];
        . as $actual
        | (.version | type) == "number"
        and .version >= 0
        and any($evidence.live_job_inventory_projection[];
          .job_id == $actual.job_id
          and .job_type == $actual.job_type
          and .expected_modify_index == $actual.job_modify_index
          and .submission_source_sha256 == $actual.submission_source_sha256
        )
      )
      and ([.live_nomad_convergence.jobs[].address] | sort)
        == (.job_addresses | sort)
      and all(.live_nomad_convergence.jobs[];
        (.job_type == "service" or .job_type == "system")
        and (.version | type) == "number"
        and (.job_modify_index | type) == "number"
        and (.healthy_allocation_ids | length) > 0
      )
    ' "${post_api_evidence}" >/dev/null

  jq -eS '.live_job_projection' "${post_api_evidence}" \
    >"${work_dir}/retirement-live-job-projection.json"
  jq -eS 'map(.expected_modify_index = null)' \
    "${work_dir}/retirement-live-job-projection.json" \
    >"${work_dir}/retirement-static-job-projection.json"
  jq -eS '.live_job_inventory_projection' "${post_api_evidence}" \
    >"${work_dir}/retirement-live-job-inventory-projection.json"
  jq -eS 'map(.expected_modify_index = null)' \
    "${work_dir}/retirement-live-job-inventory-projection.json" \
    >"${work_dir}/retirement-static-job-inventory-projection.json"
  jq -eS '.exclusive_transition' "${post_api_evidence}" \
    >"${work_dir}/retirement-transition-evidence.json"
  jq -eS '.live_nomad_convergence' "${post_api_evidence}" \
    >"${work_dir}/retirement-recorded-live-convergence.json"
  [[ "$(digest_file "${work_dir}/retirement-live-job-projection.json")" \
    == "$(jq -er '.live_job_projection_sha256' "${post_api_evidence}")" ]]
  [[ "$(digest_file "${work_dir}/retirement-static-job-projection.json")" \
    == "$(jq -er '.job_projection_sha256' "${post_api_evidence}")" ]]
  [[ "$(digest_file "${work_dir}/retirement-live-job-inventory-projection.json")" \
    == "$(jq -er '.live_job_inventory_projection_sha256' "${post_api_evidence}")" ]]
  [[ "$(digest_file "${work_dir}/retirement-static-job-inventory-projection.json")" \
    == "$(jq -er '.job_inventory_projection_sha256' "${post_api_evidence}")" ]]
  [[ "$(digest_file "${work_dir}/retirement-transition-evidence.json")" \
    == "$(jq -er '.exclusive_transition_sha256' "${post_api_evidence}")" ]]
  [[ "$(digest_file "${work_dir}/retirement-recorded-live-convergence.json")" \
    == "$(jq -er '.live_nomad_convergence_sha256' "${post_api_evidence}")" ]]

  "$(dirname "$0")/assert-network-hardening-checkpoint.sh" \
    build "${build_checkpoint}" "${project_id}" "${region}" \
    "${selected_zone}" "${prefix}" "${repo_root}" >/dev/null

  access_secret "${nomad_secret}" "${nomad_version}" \
    "${work_dir}/retirement-nomad-token"
  NOMAD_JOB_GATE_PROJECTION="${work_dir}/retirement-live-job-projection.json" \
    NOMAD_JOB_GATE_INVENTORY_PROJECTION="${work_dir}/retirement-live-job-inventory-projection.json" \
    NOMAD_JOB_GATE_TOKEN_FILE="${work_dir}/retirement-nomad-token" \
    NOMAD_JOB_GATE_BASE_URL="${nomad_base_url}" \
    NOMAD_JOB_GATE_EVIDENCE="${work_dir}/retirement-live-nomad-evidence.json" \
    NOMAD_JOB_GATE_TRANSITION_EVIDENCE="${work_dir}/retirement-transition-evidence.json" \
    NOMAD_JOB_GATE_TIMEOUT_SECONDS=60 \
    NOMAD_JOB_GATE_POLL_SECONDS=2 \
    "${nomad_job_gate_script}" wait
  jq -e '
    .schema_version == 1
    and .kind == "live-nomad-job-convergence"
    and .live_inventory.kind == "live-nomad-job-inventory"
    and .live_inventory.completeness == "exact"
  ' "${work_dir}/retirement-live-nomad-evidence.json" >/dev/null
}

assert_irreversible_retirement_confirmation() {
  local -r legacy_accessor="$1"
  local evidence_sha256
  local expected

  [[ "${mode}" == retire ]] || return 0
  evidence_sha256="$(digest_file "${evidence_path}")"
  expected="RETIRE CONSUL MANAGEMENT ${project_id} ${region} ${legacy_accessor} ${evidence_sha256}"
  if [[ "${retire_confirmation}" != "${expected}" ]]; then
    printf 'Refusing irreversible Consul retirement. Set CONSUL_RETIRE_CONFIRMATION exactly to: %s\n' \
      "${expected}" >&2
    exit 1
  fi
}

legacy_observed_state="$(secret_state "${legacy_secret}" "${legacy_version}")"
candidate_observed_state="$(secret_state "${candidate_secret}" "${candidate_version}")"
unregistered_observed_state="$(secret_state "${unregistered_secret}" "${unregistered_version}")"
legacy_initial_state="${legacy_observed_state}"
candidate_initial_state="${candidate_observed_state}"
unregistered_initial_state="${unregistered_observed_state}"
for state in "${legacy_initial_state}" "${candidate_initial_state}" "${unregistered_initial_state}"; do
  [[ "${state}" == ENABLED || "${state}" == DISABLED ]]
done
list_secret_versions "${legacy_secret}" "${work_dir}/legacy-secret-versions-initial.json"
assert_no_unexpected_enabled_legacy_versions "${work_dir}/legacy-secret-versions-initial.json" || {
  printf 'An enabled Consul management version was not explicitly classified.\n' >&2
  exit 1
}

if [[ -f "${evidence_path}" ]]; then
  assert_private_evidence "${evidence_path}"
  existing_evidence_status="$(jq -er '.status | select(. == "staged" or . == "retired")' \
    "${evidence_path}")"
fi
case "${mode}" in
  stage)
    if [[ -z "${existing_evidence_status}" ]]; then
      use_legacy_secret=true
    else
      [[ "${existing_evidence_status}" == staged ]] || {
        printf 'A retired Consul lineage cannot be staged again.\n' >&2
        exit 1
      }
    fi
    ;;
  verify-staged)
    [[ "${existing_evidence_status}" == staged ]]
    ;;
  retire)
    [[ "${existing_evidence_status}" == staged \
      || "${existing_evidence_status}" == retired ]]
    ;;
  verify)
    [[ "${existing_evidence_status}" == retired ]]
    ;;
esac

if [[ "${use_legacy_secret}" != true ]]; then
  [[ "${legacy_initial_state}" == DISABLED ]] || {
    printf 'Post-stage operations require the legacy Secret Manager version to remain disabled.\n' >&2
    exit 1
  }
  legacy_token_sha256="$(jq -er \
    '.legacy_token_sha256 | select(test("^[0-9a-f]{64}$"))' "${evidence_path}")"
  legacy_accessor="$(jq -er \
    '.legacy_accessor | select(test("^[0-9A-Fa-f-]{36}$"))' "${evidence_path}")"
  unregistered_token_sha256="$(jq -er \
    '.unregistered_token_sha256 | select(test("^[0-9a-f]{64}$"))' "${evidence_path}")"
  unregistered_replay_http="$(jq -er '.unregistered_replay_http | select(. == "403")' \
    "${evidence_path}")"
fi

if [[ "${recovery_schema}" == 3 ]]; then
  validate_stage_enable_intent_journal \
    "${legacy_observed_state}" "${candidate_observed_state}" \
    "${unregistered_observed_state}"
elif [[ "${mode}" == stage && "${use_legacy_secret}" == true ]]; then
  write_stage_enable_intent_journal
fi

if [[ "${candidate_initial_state}" == DISABLED ]]; then
  [[ "${mode}" == stage ]] || {
    printf 'Candidate Secret Manager version is disabled outside the staging operation.\n' >&2
    exit 1
  }
  set_secret_state enable "${candidate_secret}" "${candidate_version}"
fi
access_secret "${candidate_secret}" "${candidate_version}" "${work_dir}/candidate-token"
candidate_token_sha256="$(digest_file "${work_dir}/candidate-token")"
make_curl_config "${work_dir}/candidate-token" "${work_dir}/candidate.curl"

if [[ "${use_legacy_secret}" == true ]]; then
  if [[ "${legacy_initial_state}" == DISABLED ]]; then
    set_secret_state enable "${legacy_secret}" "${legacy_version}"
  fi
  access_secret "${legacy_secret}" "${legacy_version}" "${work_dir}/old-token"
  legacy_token_sha256="$(digest_file "${work_dir}/old-token")"
  make_curl_config "${work_dir}/old-token" "${work_dir}/old.curl"
fi

start_tunnel
assert_retirement_gates

if [[ "${use_legacy_secret}" == true ]]; then
  if [[ "${unregistered_initial_state}" == DISABLED ]]; then
    set_secret_state enable "${unregistered_secret}" "${unregistered_version}"
  fi
  access_secret "${unregistered_secret}" "${unregistered_version}" "${work_dir}/unregistered-token"
  unregistered_token_sha256="$(digest_file "${work_dir}/unregistered-token")"
  make_curl_config "${work_dir}/unregistered-token" "${work_dir}/unregistered.curl"
  api_request "${work_dir}/unregistered.curl" GET '/v1/acl/token/self' \
    "${work_dir}/unregistered-self.json"
  unregistered_replay_http="${API_HTTP_CODE}"
  http_is 403 || {
    printf 'The unregistered version did not return exact Consul denial HTTP 403.\n' >&2
    exit 1
  }
  set_secret_state disable "${unregistered_secret}" "${unregistered_version}"
else
  [[ "${unregistered_initial_state}" == DISABLED ]] || {
    printf 'Unregistered Consul version is enabled after staging.\n' >&2
    exit 1
  }
fi

api_request "${work_dir}/candidate.curl" GET '/v1/acl/token/self' \
  "${work_dir}/candidate-self.json"
candidate_probe_code="${API_HTTP_CODE}"
http_is_one_of 200 403 || {
  printf 'Candidate Consul probe did not return exact HTTP 200 or 403.\n' >&2
  exit 1
}
if [[ "${candidate_probe_code}" == 200 ]]; then
  assert_durable_candidate_management "${work_dir}/candidate-self.json"
  candidate_accessor="$(jq -er '.AccessorID' "${work_dir}/candidate-self.json")"
  candidate_accessor_for_recovery="${candidate_accessor}"
fi
if [[ "${use_legacy_secret}" == true ]]; then
  api_request "${work_dir}/old.curl" GET '/v1/acl/token/self' \
    "${work_dir}/old-self.json"
  legacy_probe_code="${API_HTTP_CODE}"
  http_is_one_of 200 403 || {
    printf 'Initial legacy Consul self-probe did not return exact HTTP 200 or 403.\n' >&2
    exit 1
  }
  if [[ "${legacy_probe_code}" == 200 ]]; then
    assert_global_management "${work_dir}/old-self.json"
    legacy_accessor="$(jq -er '.AccessorID' "${work_dir}/old-self.json")"
  fi
else
  [[ "${candidate_probe_code}" == 200 ]]
  api_request "${work_dir}/candidate.curl" GET "/v1/acl/token/${legacy_accessor}" \
    "${work_dir}/legacy-accessor.json"
  legacy_probe_code="${API_HTTP_CODE}"
  http_is_one_of 200 404 || {
    printf 'Legacy Consul accessor probe did not return exact HTTP 200 or 404.\n' >&2
    exit 1
  }
  if [[ "${legacy_probe_code}" == 200 ]]; then
    assert_global_management "${work_dir}/legacy-accessor.json"
    [[ "$(jq -er '.AccessorID' "${work_dir}/legacy-accessor.json")" == "${legacy_accessor}" ]]
  fi
fi

if [[ "${mode}" == retire && "${candidate_probe_code}" == 200 \
  && "${legacy_probe_code}" == 404 && -f "${evidence_path}" \
  && "$(jq -er '.status' "${evidence_path}" 2>/dev/null || true)" == retired ]]; then
  validate_handoff_evidence retired
  [[ "${candidate_accessor}" == "${evidence_candidate}" ]]
  [[ "${legacy_initial_state}" == DISABLED ]]
  [[ "${candidate_initial_state}" == ENABLED ]]
  [[ "${unregistered_initial_state}" == DISABLED ]]
  if [[ "${recovery_checkpoint_present}" == true ]]; then
    validate_revocation_intent_journal "${evidence_old}" "${candidate_accessor}"
  fi
  assert_accessor_absent "${work_dir}/candidate.curl" "${evidence_old}" \
    "${work_dir}/legacy-accessor-retire-idempotent.json"
  assert_only_candidate_management "${candidate_accessor}"
  api_request "${work_dir}/candidate.curl" GET \
    '/v1/kv/e2b/acl-lineage/management?raw' \
    "${work_dir}/lineage-retire-idempotent.json"
  http_is 200
  jq -e --arg current "${candidate_accessor}" --arg old "${evidence_old}" \
    --arg version "${candidate_version_resource}" '
      .current_accessor == $current
      and .version_resource == $version
      and .superseded_accessors == []
      and (.revoked_accessors | index($old)) != null
      and (.handoff_pending_accessor == null)
    ' "${work_dir}/lineage-retire-idempotent.json" >/dev/null
  assert_server_inventory_unchanged
  if [[ "${recovery_checkpoint_present}" == true ]]; then
    durable_remove_private "${recovery_checkpoint}"
    recovery_checkpoint_present=false
  fi
  printf 'Consul management lineage is already retired and verified.\n'
  exit 0
fi

if [[ "${mode}" == verify ]]; then
  [[ "${candidate_probe_code}" == 200 && "${legacy_probe_code}" == 404 ]]
  validate_handoff_evidence retired
  [[ "${candidate_accessor}" == "${evidence_candidate}" ]]
  assert_accessor_absent "${work_dir}/candidate.curl" "${evidence_old}" \
    "${work_dir}/legacy-accessor-verify.json"
  assert_only_candidate_management "${candidate_accessor}"
  api_request "${work_dir}/candidate.curl" GET \
    '/v1/kv/e2b/acl-lineage/management?raw' "${work_dir}/lineage-retired.json"
  http_is 200
  jq -e --arg current "${candidate_accessor}" --arg old "${evidence_old}" \
    --arg version "${candidate_version_resource}" '
      .current_accessor == $current
      and .version_resource == $version
      and .superseded_accessors == []
      and (.revoked_accessors | index($old)) != null
      and (.handoff_pending_accessor == null)
    ' "${work_dir}/lineage-retired.json" >/dev/null
  assert_server_inventory_unchanged
  printf 'Verified retired Consul management lineage and exact candidate scope.\n'
  exit 0
fi

if [[ "${mode}" == verify-staged ]]; then
  [[ "${candidate_probe_code}" == 200 && "${legacy_probe_code}" == 200 ]]
  validate_handoff_evidence staged
  [[ "${candidate_accessor}" == "${evidence_candidate}" && "${legacy_accessor}" == "${evidence_old}" ]]
  assert_staged_lineage "${candidate_accessor}" "${legacy_accessor}" \
    "${work_dir}/lineage-staged-verify.json"
  assert_staged_management_pair "${legacy_accessor}" "${candidate_accessor}"
  assert_server_inventory_unchanged
  printf 'Verified staged Consul candidate while the legacy accessor remains live.\n'
  exit 0
fi

if [[ "${mode}" == stage ]]; then
  [[ "${legacy_probe_code}" == 200 ]] || {
    printf 'Staging requires the live legacy global-management identity.\n' >&2
    exit 1
  }
  if [[ "${candidate_probe_code}" == 200 && -f "${evidence_path}" ]]; then
    validate_handoff_evidence staged
    [[ "${candidate_accessor}" == "${evidence_candidate}" && "${legacy_accessor}" == "${evidence_old}" ]]
    assert_staged_lineage "${candidate_accessor}" "${legacy_accessor}" \
      "${work_dir}/lineage-staged-idempotent.json"
    assert_staged_management_pair "${legacy_accessor}" "${candidate_accessor}"
    staging_committed=true
    assert_server_inventory_unchanged
    complete_stage_enable_intent
    printf 'Consul candidate handoff is already staged; legacy remains live.\n'
    exit 0
  fi

  assert_server_inventory_unchanged
  if [[ "${candidate_probe_code}" == 403 ]]; then
    api_request "${work_dir}/old.curl" GET '/v1/acl/tokens' \
      "${work_dir}/candidate-precreate-tokens.json"
    http_is 200
    jq -eS '[
      .[]?
      | select(
          .Description == "E2B Consul promoted management token"
          and ([.Policies[]?.Name] | sort) == ["global-management"]
        )
      | .AccessorID
      | select(type == "string" and test("^[0-9A-Fa-f-]{36}$"))
    ] | unique | sort' "${work_dir}/candidate-precreate-tokens.json" \
      >"${work_dir}/candidate-precreate-accessors.json"
    chmod 0600 "${work_dir}/candidate-precreate-accessors.json"
    jq -n --rawfile token "${work_dir}/candidate-token" \
      '{
        SecretID:$token,
        Description:"E2B Consul promoted management token",
        Policies:[{Name:"global-management"}],
        Roles:[],
        ServiceIdentities:[],
        NodeIdentities:[],
        TemplatedPolicies:[],
        Local:false
      }' \
      >"${work_dir}/candidate-create.json"
    candidate_created=true
    api_request "${work_dir}/old.curl" PUT '/v1/acl/token' \
      "${work_dir}/candidate-create-response.json" "${work_dir}/candidate-create.json"
    http_is 200 || {
      printf 'Candidate Consul token registration failed.\n' >&2
      exit 1
    }
    api_request "${work_dir}/candidate.curl" GET '/v1/acl/token/self' \
      "${work_dir}/candidate-self.json"
    http_is 200 && assert_durable_candidate_management "${work_dir}/candidate-self.json"
    candidate_accessor="$(jq -er '.AccessorID' "${work_dir}/candidate-self.json")"
    candidate_accessor_for_recovery="${candidate_accessor}"
  fi
  [[ "${candidate_accessor}" != "${legacy_accessor}" ]]
  assert_staged_management_pair "${legacy_accessor}" "${candidate_accessor}"

  api_request "${work_dir}/candidate.curl" GET \
    '/v1/kv/e2b/acl-lineage/management' "${work_dir}/prior-lineage-envelope.json"
  http_is_one_of 200 404
  if [[ "${API_HTTP_CODE}" == 200 ]]; then
    prior_lineage_present=true
    decode_lineage_envelope "${work_dir}/prior-lineage-envelope.json" \
      "${work_dir}/prior-lineage.json"
    prior_lineage_modify_index="$(jq -er '.[0].ModifyIndex | select(type == "number" and . >= 1) | tostring' \
      "${work_dir}/prior-lineage-envelope.json")"
    jq -e '(.superseded_accessors | type) == "array" and (.revoked_accessors | type) == "array"' \
      "${work_dir}/prior-lineage.json" >/dev/null
  else
    prior_lineage_modify_index=0
    printf '%s\n' '{"superseded_accessors":[],"revoked_accessors":[]}' >"${work_dir}/prior-lineage.json"
  fi
  jq --arg current "${candidate_accessor}" --arg old "${legacy_accessor}" \
    --arg version "${candidate_version_resource}" '
      .current_accessor = $current
      | .version_resource = $version
      | .superseded_accessors = (((.superseded_accessors // []) + [$old]) - (.revoked_accessors // []) | unique | sort)
      | .revoked_accessors = ((.revoked_accessors // []) | unique | sort)
      | .handoff_pending_accessor = $old
    ' "${work_dir}/prior-lineage.json" >"${work_dir}/lineage-before-revoke.json"
  assert_server_inventory_unchanged
  api_request "${work_dir}/candidate.curl" PUT \
    "/v1/kv/e2b/acl-lineage/management?cas=${prior_lineage_modify_index}" \
    "${work_dir}/lineage-write.json" "${work_dir}/lineage-before-revoke.json"
  http_is 200
  jq -e '. == true' "${work_dir}/lineage-write.json" >/dev/null
  lineage_mutated=true
  assert_staged_lineage "${candidate_accessor}" "${legacy_accessor}" \
    "${work_dir}/lineage-staged-readback.json"
  set_secret_state disable "${legacy_secret}" "${legacy_version}"
  assert_server_inventory_unchanged
  write_staged_evidence "${legacy_accessor}" "${candidate_accessor}"
  staging_committed=true
  complete_stage_enable_intent
  printf 'Staged Consul candidate; legacy accessor remains live. Evidence: %s\n' "${evidence_path}"
  exit 0
fi

# retire: require staged evidence, complete post-API job proof, and the current
# build-stage checkpoint before crossing the irreversible revocation point.
validate_handoff_evidence staged
candidate_accessor="${evidence_candidate}"
legacy_accessor="${evidence_old}"
candidate_accessor_for_recovery="${candidate_accessor}"
[[ "${candidate_probe_code}" == 200 ]]
[[ "$(jq -er '.AccessorID' "${work_dir}/candidate-self.json")" == "${candidate_accessor}" ]]
assert_irreversible_retirement_confirmation "${legacy_accessor}"

if [[ "${legacy_probe_code}" == 404 ]]; then
  [[ "${recovery_checkpoint_present}" == true ]]
  api_request "${work_dir}/candidate.curl" GET \
    '/v1/kv/e2b/acl-lineage/management' "${work_dir}/lineage-recovery-envelope.json"
  http_is 200
  decode_lineage_envelope "${work_dir}/lineage-recovery-envelope.json" \
    "${work_dir}/lineage-recovery.json"
  revocation_lineage_modify_index="$(jq -er \
    '.[0].ModifyIndex | select(type == "number" and . >= 1) | tostring' \
    "${work_dir}/lineage-recovery-envelope.json")"
  revocation_started=true
  old_revoked=true
  legacy_accessor_http=404
  if jq -e --arg old "${legacy_accessor}" \
    '.handoff_pending_accessor == $old and (.revoked_accessors | index($old)) == null' \
    "${work_dir}/lineage-recovery.json" >/dev/null; then
    validate_revocation_intent_journal "${legacy_accessor}" "${candidate_accessor}" \
      "${work_dir}/lineage-recovery.json" "${revocation_lineage_modify_index}"
    finalize_management_lineage "${work_dir}/lineage-recovery.json" \
      "${legacy_accessor}" "${work_dir}/lineage-recovered.json"
  else
    validate_revocation_intent_journal "${legacy_accessor}" "${candidate_accessor}"
    jq -e --arg current "${candidate_accessor}" --arg old "${legacy_accessor}" \
      --arg version "${candidate_version_resource}" '
        .current_accessor == $current
        and .version_resource == $version
        and .superseded_accessors == []
        and (.revoked_accessors | index($old)) != null
      ' "${work_dir}/lineage-recovery.json" >/dev/null
  fi
else
  [[ "${legacy_probe_code}" == 200 ]]
  [[ "$(jq -er '.AccessorID' "${work_dir}/legacy-accessor.json")" == "${legacy_accessor}" ]]
  capture_staged_lineage_for_revocation "${candidate_accessor}" "${legacy_accessor}"
  assert_staged_management_pair "${legacy_accessor}" "${candidate_accessor}"
  assert_server_inventory_unchanged
  if [[ "${recovery_checkpoint_present}" == true ]]; then
    validate_revocation_intent_journal "${legacy_accessor}" "${candidate_accessor}" \
      "${work_dir}/lineage-before-revoke.json" "${revocation_lineage_modify_index}"
  else
    write_revocation_intent_journal "${legacy_accessor}" "${candidate_accessor}" \
      "${work_dir}/lineage-before-revoke.json" "${revocation_lineage_modify_index}"
  fi
  revocation_started=true
  api_request "${work_dir}/candidate.curl" DELETE \
    "/v1/acl/token/${legacy_accessor}" "${work_dir}/legacy-delete.json"
  legacy_delete_http="${API_HTTP_CODE}"
  legacy_delete_status="${API_STATUS}"
  api_request "${work_dir}/candidate.curl" GET "/v1/acl/token/${legacy_accessor}" \
    "${work_dir}/legacy-accessor-after-delete.json"
  legacy_accessor_http="${API_HTTP_CODE}"
  legacy_accessor_status="${API_STATUS}"
  if [[ "${legacy_accessor_status}" -eq 0 && "${legacy_accessor_http}" == 200 \
      && ( "${legacy_delete_status}" -ne 0 || "${legacy_delete_http}" != 200 ) ]]; then
    revocation_started=false
    printf 'Legacy Consul accessor revocation failed before mutation.\n' >&2
    exit 1
  fi
  old_revoked=true
  [[ "${legacy_accessor_status}" -eq 0 && "${legacy_accessor_http}" == 404 ]]
  finalize_management_lineage "${work_dir}/lineage-before-revoke.json" \
    "${legacy_accessor}" "${work_dir}/lineage-after-revoke.json"
fi

assert_accessor_absent "${work_dir}/candidate.curl" "${legacy_accessor}" \
  "${work_dir}/legacy-accessor-final.json"
assert_only_candidate_management "${candidate_accessor}"
set_secret_state disable "${legacy_secret}" "${legacy_version}"
set_secret_state disable "${unregistered_secret}" "${unregistered_version}"
assert_server_inventory_unchanged
write_retired_evidence "${legacy_accessor}" "${candidate_accessor}" \
  "${legacy_accessor_http}" "${unregistered_replay_http}"
printf 'Retired legacy Consul management accessor after post-API/build gates. Evidence: %s\n' \
  "${evidence_path}"
