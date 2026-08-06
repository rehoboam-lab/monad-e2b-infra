#!/usr/bin/env bash
set -euo pipefail

token_path="${1:?usage: assert-acl-runtime-job-recovery-token.sh TOKEN STATE_BUCKET PROJECT REGION PHASE STAGE ENVIRONMENT STATE_PREFIX REPO_ROOT}"
state_bucket="${2:?state bucket is required}"
project="${3:?project is required}"
region="${4:?region is required}"
phase="${5:?phase is required}"
stage="${6:?stage is required}"
environment="${7:?environment is required}"
state_prefix="${8:?state prefix is required}"
repo_root="${9:?repository root is required}"

case "${phase}:${stage}" in
  pre-server:network | post-api:api) ;;
  *)
    printf 'Invalid ACL runtime-job recovery phase/stage: %s/%s\n' \
      "${phase}" "${stage}" >&2
    exit 1
    ;;
esac

[[ -f "${token_path}" && ! -L "${token_path}" ]] || {
  printf 'ACL runtime-job recovery token must be a regular, non-symlink file: %s\n' \
    "${token_path}" >&2
  exit 1
}
token_mode="$(
  stat -c '%a' "${token_path}" 2>/dev/null \
    || stat -f '%Lp' "${token_path}"
)"
if (( (8#${token_mode} & 077) != 0 )); then
  printf 'ACL runtime-job recovery token must be private: %s (mode %s)\n' \
    "${token_path}" "${token_mode}" >&2
  exit 1
fi

source_head="$(git -C "${repo_root}" rev-parse --verify HEAD)"
holder_prefix="acl-job-apply:${phase}:${stage}:${environment}:${state_prefix}:${source_head}:"
expected_uri="gs://${state_bucket}/operator-locks/${project}/${region}/workload-mutation.json"
jq -e \
  --arg state_bucket "${state_bucket}" \
  --arg project "${project}" \
  --arg region "${region}" \
  --arg expected_uri "${expected_uri}" \
  --arg holder_prefix "${holder_prefix}" '
    .schema_version == 1
    and .bucket == $state_bucket
    and .project == $project
    and .region == $region
    and .uri == $expected_uri
    and (.holder | startswith($holder_prefix))
    and ((.holder | ltrimstr($holder_prefix)) | test("^[0-9a-f]{64}$"))
    and ((.generation | tostring) | test("^[0-9]+$"))
  ' "${token_path}" >/dev/null || {
  printf 'ACL runtime-job recovery token is not bound to this workflow, phase, stage, environment, backend, scope, and exact source head.\n' >&2
  exit 1
}

printf 'ACL runtime-job recovery token is bound to %s/%s/%s phase %s stage %s environment %s backend %s at %s.\n' \
  "${state_bucket}" "${project}" "${region}" "${phase}" "${stage}" \
  "${environment}" "${state_prefix}" "${source_head}"
