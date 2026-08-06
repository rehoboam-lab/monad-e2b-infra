#!/usr/bin/env bash
set -euo pipefail

evidence="${1:?usage: assert-acl-runtime-job-live-evidence.sh EVIDENCE ENVIRONMENT PROJECT REGION PREFIX STATE_BUCKET DOMAIN NOMAD_SECRET_VERSION GCLOUD_BIN LEASE_SCRIPT GATE_SCRIPT}"
environment="${2:?environment is required}"
project="${3:?project is required}"
region="${4:?region is required}"
prefix="${5:?prefix is required}"
state_bucket="${6:?state bucket is required}"
domain="${7:?domain is required}"
nomad_secret_version="${8:?Nomad secret version is required}"
gcloud_bin="${9:?gcloud binary is required}"
lease_script="${10:?rollout lease script is required}"
gate_script="${11:?Nomad live gate script is required}"
curl_bin="${ACL_RUNTIME_JOB_LIVE_CURL_BIN:-$(command -v curl)}"
timeout_seconds="${ACL_RUNTIME_JOB_LIVE_TIMEOUT_SECONDS:-120}"
poll_seconds="${ACL_RUNTIME_JOB_LIVE_POLL_SECONDS:-5}"

[[ -f "${evidence}" && ! -L "${evidence}" ]] || {
  printf 'ACL runtime-job live guard requires regular completion evidence.\n' >&2
  exit 1
}
evidence_mode="$(stat -c '%a' "${evidence}" 2>/dev/null || stat -f '%Lp' "${evidence}")"
if (( (8#${evidence_mode} & 077) != 0 )); then
  printf 'ACL runtime-job live guard requires private completion evidence.\n' >&2
  exit 1
fi
[[ "${environment}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
[[ "${project}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "${region}" =~ ^[a-z]+-[a-z]+[0-9]$ ]]
[[ "${prefix}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?-$ ]]
[[ "${state_bucket}" == "${project}-terraform-state" ]]
[[ "${domain}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]
[[ "${nomad_secret_version}" =~ ^projects/${project}/secrets/${prefix}nomad-secret-id/versions/[1-9][0-9]*$ ]] || {
  printf 'ACL runtime-job live guard requires the exact immutable Nomad token version.\n' >&2
  exit 1
}
[[ -x "${gcloud_bin}" && -x "${lease_script}" \
  && -x "${gate_script}" && -x "${curl_bin}" ]]
[[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]]
[[ "${poll_seconds}" =~ ^[0-9]+$ ]]

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/acl-runtime-live-evidence.XXXXXX")"
provided_lease_token="${ACL_RUNTIME_JOB_LIVE_LEASE_TOKEN:-}"
lease_token="${work_dir}/lease-token.json"
runtime_projection="${work_dir}/runtime.json"
inventory_projection="${work_dir}/inventory.json"
transition_inventory="${work_dir}/transition-inventory.json"
transition="${work_dir}/transition.json"
live_proof="${work_dir}/live-convergence.json"
lease_owned=false

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${lease_owned}" == true ]]; then
    if ! "${lease_script}" release "${gcloud_bin}" "${lease_token}"; then
      printf 'ACL runtime-job live guard could not release its shared rollout lease.\n' >&2
      status=1
    fi
  fi
  rm -rf -- "${work_dir}"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077

jq -eS '.live_job_projection' "${evidence}" >"${runtime_projection}"
jq -eS '.live_job_inventory_projection' "${evidence}" >"${inventory_projection}"
jq -eS '.job_inventory_projection' "${evidence}" >"${transition_inventory}"
jq -eS '.exclusive_transition' "${evidence}" >"${transition}"
descendant_policy="$(jq -er '
  .exclusive_transition.descendant_policy
  | select(. == "observe" or . == "quiesce")
' "${evidence}")"

holder_digest="$({
  shasum -a 256 "${evidence}"
  printf '%s\n' "${environment}" "$$" "$(date -u +%s)"
} | shasum -a 256 | awk '{print $1}')"
if [[ -n "${provided_lease_token}" ]]; then
  [[ -f "${provided_lease_token}" && ! -L "${provided_lease_token}" ]] || {
    printf 'Provided shared rollout lease token is not a regular file.\n' >&2
    exit 1
  }
  provided_mode="$(stat -c '%a' "${provided_lease_token}" 2>/dev/null \
    || stat -f '%Lp' "${provided_lease_token}")"
  (( (8#${provided_mode} & 077) == 0 )) || {
    printf 'Provided shared rollout lease token must be private.\n' >&2
    exit 1
  }
  lease_token="${provided_lease_token}"
else
  "${lease_script}" acquire "${gcloud_bin}" "${state_bucket}" \
    "${project}" "${region}" "acl-live-verify:${holder_digest}" "${lease_token}"
  lease_owned=true
fi
"${lease_script}" assert-held "${gcloud_bin}" "${state_bucket}" \
  "${project}" "${region}" "${lease_token}"

nomad_secret="${prefix}nomad-secret-id"
nomad_version="${nomad_secret_version##*/}"
exec 9< <(
  env \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
    -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
    "${gcloud_bin}" secrets versions access "${nomad_version}" \
      --secret="${nomad_secret}" --project="${project}"
)
set +e
NOMAD_JOB_GATE_PROJECTION="${runtime_projection}" \
  NOMAD_JOB_GATE_INVENTORY_PROJECTION="${inventory_projection}" \
  NOMAD_JOB_GATE_TRANSITION_INVENTORY_PROJECTION="${transition_inventory}" \
  NOMAD_JOB_GATE_TRANSITION_EVIDENCE="${transition}" \
  NOMAD_JOB_GATE_TOKEN_FD=9 \
  NOMAD_JOB_GATE_BASE_URL="https://nomad.${domain}" \
  NOMAD_JOB_GATE_EVIDENCE="${live_proof}" \
  NOMAD_JOB_GATE_DESCENDANT_POLICY="${descendant_policy}" \
  NOMAD_JOB_GATE_CURL_BIN="${curl_bin}" \
  NOMAD_JOB_GATE_TIMEOUT_SECONDS="${timeout_seconds}" \
  NOMAD_JOB_GATE_POLL_SECONDS="${poll_seconds}" \
  "${gate_script}" wait
gate_status=$?
set -e
exec 9<&-
[[ "${gate_status}" -eq 0 ]] || {
  printf 'Archived ACL runtime-job evidence no longer matches live Nomad state.\n' >&2
  exit 1
}
"${lease_script}" assert-held "${gcloud_bin}" "${state_bucket}" \
  "${project}" "${region}" "${lease_token}"

printf 'Live Nomad still matches the exact ACL runtime-job evidence under the shared rollout lease.\n'
