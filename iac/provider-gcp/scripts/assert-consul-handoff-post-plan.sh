#!/usr/bin/env bash
set -euo pipefail

plan_path="${1:?usage: assert-consul-handoff-post-plan.sh PLAN TERRAFORM_BIN EVIDENCE}"
terraform_bin="${2:?usage: assert-consul-handoff-post-plan.sh PLAN TERRAFORM_BIN EVIDENCE}"
evidence_path="${3:?usage: assert-consul-handoff-post-plan.sh PLAN TERRAFORM_BIN EVIDENCE}"

[[ -f "${plan_path}" && ! -L "${plan_path}" ]] || {
  printf 'Consul handoff post-plan must be a regular, non-symlink file.\n' >&2
  exit 1
}
[[ -f "${evidence_path}" && ! -L "${evidence_path}" ]] || {
  printf 'Consul handoff evidence must be a regular, non-symlink file.\n' >&2
  exit 1
}

plan_permissions="$(stat -f '%Lp' "${plan_path}" 2>/dev/null || stat -c '%a' "${plan_path}")"
evidence_permissions="$(stat -f '%Lp' "${evidence_path}" 2>/dev/null || stat -c '%a' "${evidence_path}")"
[[ "${plan_permissions}" == 600 ]] || {
  printf 'Consul handoff post-plan must have mode 0600.\n' >&2
  exit 1
}
[[ "${evidence_permissions}" == 600 ]] || {
  printf 'Consul handoff evidence must have mode 0600.\n' >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  printf 'jq is required to inspect the Consul handoff post-plan.\n' >&2
  exit 2
}

umask 077
inspection_dir="$(mktemp -d)"
plan_json_path="${inspection_dir}/plan.json"
plan_text_path="${inspection_dir}/plan.txt"
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf -- "${inspection_dir}"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"${terraform_bin}" show -json "${plan_path}" >"${plan_json_path}"
"${terraform_bin}" show -no-color "${plan_path}" >"${plan_text_path}"
chmod 0600 "${plan_json_path}" "${plan_text_path}"

jq -e '.errored != true' "${plan_json_path}" >/dev/null || {
  printf 'Refusing errored Consul handoff post-plan.\n' >&2
  exit 1
}

jq -e '
  .schema_version == 4
  and (.status == "staged" or .status == "retired")
  and .legacy_secret_manager_state == "DISABLED"
  and .candidate_secret_manager_state == "ENABLED"
  and .unregistered_secret_manager_state == "DISABLED"
  and (.terraform_active_version_resource | test("^projects/[^/]+/secrets/[^/]+/versions/[1-9][0-9]*$"))
  and (.terraform_legacy_version_resource | test("^projects/[^/]+/secrets/[^/]+/versions/[1-9][0-9]*$"))
  and (.terraform_candidate_version_resource | test("^projects/[^/]+/secrets/[^/]+/versions/[1-9][0-9]*$"))
  and (
    if .status == "staged" then
      .legacy_replay_http == "200"
      and .legacy_accessor_http == "200"
    else
      .legacy_replay_http == "not-reaccessed"
      and .legacy_accessor_http == "404"
      and (.staged_evidence_sha256 | test("^[0-9a-f]{64}$"))
    end
  )
' "${evidence_path}" >/dev/null || {
  printf 'Consul handoff evidence is incomplete or does not record the final Secret Manager states.\n' >&2
  exit 1
}

active_pin="$(jq -er '.terraform_active_version_resource' "${evidence_path}")"
legacy_pin="$(jq -er '.terraform_legacy_version_resource' "${evidence_path}")"
candidate_pin="$(jq -er '.terraform_candidate_version_resource' "${evidence_path}")"

jq -e \
  --arg active_pin "${active_pin}" \
  --arg legacy_pin "${legacy_pin}" \
  --arg candidate_pin "${candidate_pin}" '
    def exact_version($address; $pin; $enabled):
      [.resource_changes[]? | select(.address == $address)] as $matches
      | ($matches | length) == 1
        and $matches[0].mode == "managed"
        and $matches[0].type == "google_secret_manager_secret_version"
        and $matches[0].change.actions == ["no-op"]
        and $matches[0].change.before.name == $pin
        and $matches[0].change.after.name == $pin
        and $matches[0].change.before.enabled == $enabled
        and $matches[0].change.after.enabled == $enabled
        and $matches[0].change.before.deletion_policy == "DISABLE"
        and $matches[0].change.after.deletion_policy == "DISABLE"
        and $matches[0].change.after_sensitive.secret_data == true;
    all(.resource_changes[]?;
      .change.actions == ["no-op"]
      or (.mode == "data" and .change.actions == ["read"])
    )
    and exact_version(
      "module.init.google_secret_manager_secret_version.consul_acl_token_active";
      $active_pin;
      false
    )
    and exact_version(
      "module.init.google_secret_manager_secret_version.consul_acl_token_legacy";
      $legacy_pin;
      false
    )
    and exact_version(
      "module.init.google_secret_manager_secret_version.consul_acl_token_candidate";
      $candidate_pin;
      true
    )
  ' "${plan_json_path}" >/dev/null || {
  printf 'Refusing Consul handoff post-plan: exact old/candidate pins are not a fully converged disabled/disabled/enabled no-op.\n' >&2
  exit 1
}

if grep -E '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}' \
  "${plan_text_path}" >/dev/null; then
  printf 'Consul handoff post-plan exposed a UUID-shaped credential.\n' >&2
  exit 1
fi

printf 'Consul handoff post-plan passed: old versions remain disabled and the exact candidate remains enabled.\n'
