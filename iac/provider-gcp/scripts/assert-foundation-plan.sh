#!/usr/bin/env bash
set -euo pipefail

plan_path="${1:?usage: assert-foundation-plan.sh PLAN_PATH [TERRAFORM_BIN] [apply|destroy]}"
terraform_bin="${2:-terraform}"
mode="${3:-apply}"

if [[ "${mode}" != "apply" && "${mode}" != "destroy" ]]; then
  printf 'Unsupported foundation plan inspection mode: %s\n' "${mode}" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  printf 'jq is required to inspect the saved foundation plan.\n' >&2
  exit 1
}

plan_json="$("${terraform_bin}" show -json "${plan_path}")"

changed_addresses="$(
  jq -r '
    .resource_changes[]?
    | select(.change.actions != ["no-op"])
    | .address
  ' <<<"${plan_json}"
)"
unexpected_addresses="$(
  printf '%s\n' "${changed_addresses}" \
    | sed '/^[[:space:]]*$/d' \
    | grep -Ev '^module\.init\.' \
    || true
)"
if [[ "${mode}" == "apply" ]]; then
  disallowed_changes="$(
    jq -r '
      .resource_changes[]?
      | select(.change.actions | index("delete"))
      | "\(.address): \(.change.actions | join(","))"
    ' <<<"${plan_json}"
  )"
else
  disallowed_changes="$(
    jq -r '
      .resource_changes[]?
      | select(
          .change.actions != ["no-op"]
          and .change.actions != ["delete"]
          and (.mode != "data" or .change.actions != ["read"])
        )
      | "\(.address): \(.change.actions | join(","))"
    ' <<<"${plan_json}"
  )"
fi
forbidden_credentials="$(
  jq -r '
    .resource_changes[]?
    | select(
        .type == "google_service_account_key"
        or .type == "google_storage_hmac_key"
      )
    | .address
  ' <<<"${plan_json}"
)"

if [[ -n "${unexpected_addresses}" || -n "${disallowed_changes}" || -n "${forbidden_credentials}" ]]; then
  printf 'Refusing foundation plan: review allowlist failed.\n' >&2
  if [[ -n "${unexpected_addresses}" ]]; then
    printf 'Changed addresses outside module.init:\n%s\n' "${unexpected_addresses}" >&2
  fi
  if [[ -n "${disallowed_changes}" ]]; then
    printf 'Changes are incompatible with %s inspection mode:\n%s\n' "${mode}" "${disallowed_changes}" >&2
  fi
  if [[ -n "${forbidden_credentials}" ]]; then
    printf 'Forbidden long-lived credential resources:\n%s\n' "${forbidden_credentials}" >&2
  fi
  exit 1
fi

printf 'Foundation plan allowlist passed: %s changed module.init addresses.\n' \
  "$(printf '%s\n' "${changed_addresses}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
