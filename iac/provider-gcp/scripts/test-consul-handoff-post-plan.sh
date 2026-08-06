#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider_root="$(cd "${script_dir}/.." && pwd)"
assertion_script="${script_dir}/assert-consul-handoff-post-plan.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT HUP INT TERM

[[ -x "${assertion_script}" ]]
grep -F 'consul-management-handoff-post-plan:' "${provider_root}/Makefile" >/dev/null
grep -F './scripts/assert-consul-handoff-post-plan.sh' "${provider_root}/Makefile" >/dev/null

active_pin='projects/monad-code/secrets/e2b-consul-secret-id/versions/2'
legacy_pin='projects/monad-code/secrets/e2b-consul-secret-id/versions/1'
candidate_pin='projects/monad-code/secrets/e2b-consul-management-candidate-token/versions/1'

jq -nS \
  --arg active "${active_pin}" \
  --arg legacy "${legacy_pin}" \
  --arg candidate "${candidate_pin}" '
    {
      schema_version:4,
      status:"staged",
      legacy_replay_http:"200",
      legacy_accessor_http:"200",
      legacy_secret_manager_state:"DISABLED",
      candidate_secret_manager_state:"ENABLED",
      unregistered_secret_manager_state:"DISABLED",
      terraform_active_version_resource:$active,
      terraform_legacy_version_resource:$legacy,
      terraform_candidate_version_resource:$candidate
    }
  ' >"${test_root}/evidence.json"
chmod 0600 "${test_root}/evidence.json"

cat >"${test_root}/terraform" <<'EOF'
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
chmod 0755 "${test_root}/terraform"

version_change() {
  local address="$1"
  local pin="$2"
  local enabled="$3"
  jq -cn \
    --arg address "${address}" \
    --arg pin "${pin}" \
    --argjson enabled "${enabled}" '
      {
        address:$address,
        mode:"managed",
        type:"google_secret_manager_secret_version",
        change:{
          actions:["no-op"],
          before:{name:$pin,enabled:$enabled,deletion_policy:"DISABLE"},
          after:{name:$pin,enabled:$enabled,deletion_policy:"DISABLE"},
          after_sensitive:{secret_data:true}
        }
      }
    '
}

jq -n \
  --argjson active "$(version_change 'module.init.google_secret_manager_secret_version.consul_acl_token_active' "${active_pin}" false)" \
  --argjson legacy "$(version_change 'module.init.google_secret_manager_secret_version.consul_acl_token_legacy' "${legacy_pin}" false)" \
  --argjson candidate "$(version_change 'module.init.google_secret_manager_secret_version.consul_acl_token_candidate' "${candidate_pin}" true)" '
    {format_version:"1.2",errored:false,resource_changes:[$active,$legacy,$candidate]}
  ' >"${test_root}/valid.plan"
chmod 0600 "${test_root}/valid.plan"

"${assertion_script}" "${test_root}/valid.plan" "${test_root}/terraform" \
  "${test_root}/evidence.json" >/dev/null

expect_rejected() {
  local plan="$1"
  local message="$2"
  if "${assertion_script}" "${plan}" "${test_root}/terraform" \
    "${test_root}/evidence.json" >/dev/null 2>&1; then
    printf '%s\n' "${message}" >&2
    exit 1
  fi
}

jq '(.resource_changes[] | select(.address | endswith("consul_acl_token_active")) | .change.after.enabled) = true' \
  "${test_root}/valid.plan" >"${test_root}/active-enabled.plan"
chmod 0600 "${test_root}/active-enabled.plan"
expect_rejected "${test_root}/active-enabled.plan" \
  'Terraform re-enabling the old active-address version escaped the post-plan guard.'

jq '(.resource_changes[] | select(.address | endswith("consul_acl_token_legacy")) | .change.after.enabled) = true' \
  "${test_root}/valid.plan" >"${test_root}/legacy-enabled.plan"
chmod 0600 "${test_root}/legacy-enabled.plan"
expect_rejected "${test_root}/legacy-enabled.plan" \
  'Terraform re-enabling the legacy-address version escaped the post-plan guard.'

jq '(.resource_changes[] | select(.address | endswith("consul_acl_token_candidate")) | .change.after.enabled) = false' \
  "${test_root}/valid.plan" >"${test_root}/candidate-disabled.plan"
chmod 0600 "${test_root}/candidate-disabled.plan"
expect_rejected "${test_root}/candidate-disabled.plan" \
  'Terraform disabling the candidate version escaped the post-plan guard.'

jq '(.resource_changes[] | select(.address | endswith("consul_acl_token_candidate")) | .change.after.name) |= sub("/1$"; "/2")' \
  "${test_root}/valid.plan" >"${test_root}/candidate-mismatch.plan"
chmod 0600 "${test_root}/candidate-mismatch.plan"
expect_rejected "${test_root}/candidate-mismatch.plan" \
  'A candidate pin different from handoff evidence escaped the post-plan guard.'

jq '(.resource_changes[] | select(.address | endswith("consul_acl_token_candidate")) | .change.actions) = ["update"]' \
  "${test_root}/valid.plan" >"${test_root}/candidate-update.plan"
chmod 0600 "${test_root}/candidate-update.plan"
expect_rejected "${test_root}/candidate-update.plan" \
  'A non-converged candidate update escaped the post-plan guard.'

jq '(.resource_changes[] | select(.address | endswith("consul_acl_token_candidate")) | .change.after_sensitive.secret_data) = false' \
  "${test_root}/valid.plan" >"${test_root}/candidate-visible.plan"
chmod 0600 "${test_root}/candidate-visible.plan"
expect_rejected "${test_root}/candidate-visible.plan" \
  'A non-sensitive candidate payload escaped the post-plan guard.'

if FAKE_HUMAN_PLAN='secret_data = 123e4567-e89b-42d3-a456-426614174000' \
  "${assertion_script}" "${test_root}/valid.plan" "${test_root}/terraform" \
  "${test_root}/evidence.json" >/dev/null 2>&1; then
  printf 'A UUID-shaped credential escaped the post-plan human-output guard.\n' >&2
  exit 1
fi

chmod 0644 "${test_root}/valid.plan"
if "${assertion_script}" "${test_root}/valid.plan" "${test_root}/terraform" \
  "${test_root}/evidence.json" >/dev/null 2>&1; then
  printf 'World-readable Terraform plan escaped the post-plan guard.\n' >&2
  exit 1
fi
chmod 0600 "${test_root}/valid.plan"

chmod 0644 "${test_root}/evidence.json"
if "${assertion_script}" "${test_root}/valid.plan" "${test_root}/terraform" \
  "${test_root}/evidence.json" >/dev/null 2>&1; then
  printf 'World-readable handoff evidence escaped the post-plan guard.\n' >&2
  exit 1
fi

printf 'Consul handoff post-plan fixtures passed.\n'
