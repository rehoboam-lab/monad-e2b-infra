#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:?usage: network-hardening-source-fingerprints.sh REPO_ROOT}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
metadata_script="${script_dir}/workload-plan-metadata.sh"
repo_root="$(cd "${repo_root}" && pwd -P)"
config_root="${repo_root}/iac/provider-gcp"

[[ -d "${config_root}" && -d "${repo_root}/iac/modules" ]]
[[ -f "${repo_root}/.tool-versions" && ! -L "${repo_root}/.tool-versions" ]]
[[ -x "${metadata_script}" ]]

validation_paths=(
  iac/provider-gcp/scripts/assert-network-hardening-checkpoint.sh
  iac/provider-gcp/scripts/assert-network-hardening-stage-plan.sh
  iac/provider-gcp/scripts/network-hardening-source-fingerprints.sh
  iac/provider-gcp/scripts/test-network-hardening-rollout.sh
  iac/provider-gcp/scripts/test-network-hardening-stage-wait.sh
  iac/provider-gcp/scripts/test-network-security-guards.sh
  iac/provider-gcp/scripts/wait-network-hardening-stage.sh
  iac/provider-gcp/scripts/workload-plan-metadata.sh
)

validation_rows="$({
  for relative in "${validation_paths[@]}"; do
    path="${repo_root}/${relative}"
    [[ -f "${path}" && ! -L "${path}" ]] || {
      printf 'Missing network-hardening validation artifact: %s\n' \
        "${relative}" >&2
      exit 1
    }
    printf '%s\t%s\n' "${relative}" \
      "$(shasum -a 256 "${path}" | awk '{print $1}')"
  done
} | shasum -a 256 | awk '{print $1}')"
configuration_sha256="$(${metadata_script} configuration-sha256 \
  "${config_root}" "${repo_root}")"

jq -nS \
  --arg configuration_sha256 "${configuration_sha256}" \
  --arg validation_artifacts_sha256 "${validation_rows}" '{
    source_configuration_sha256:$configuration_sha256,
    validation_artifacts_sha256:$validation_artifacts_sha256
  }'
