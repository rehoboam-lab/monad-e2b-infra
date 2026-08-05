#!/usr/bin/env bash
set -euo pipefail

token_path="${1:?usage: assert-network-hardening-recovery-token.sh TOKEN PROJECT REGION STAGE REPO_ROOT}"
project="${2:?project is required}"
region="${3:?region is required}"
stage="${4:?stage is required}"
repo_root="${5:?repository root is required}"

case "${stage}" in
  network | server | api | worker | build) ;;
  *)
    printf 'Invalid network-hardening recovery stage: %s\n' "${stage}" >&2
    exit 1
    ;;
esac

[[ -f "${token_path}" && ! -L "${token_path}" ]] || {
  printf 'Recovery token must be a regular, non-symlink file: %s\n' \
    "${token_path}" >&2
  exit 1
}
token_mode="$(
  stat -c '%a' "${token_path}" 2>/dev/null \
    || stat -f '%Lp' "${token_path}"
)"
if (( (8#${token_mode} & 077) != 0 )); then
  printf 'Recovery token must be private (mode 0600 or stricter): %s\n' \
    "${token_path}" >&2
  exit 1
fi

source_head="$(git -C "${repo_root}" rev-parse --verify HEAD)"
holder_prefix="cluster-apply:${stage}:${source_head}:"
jq -e \
  --arg project "${project}" \
  --arg region "${region}" \
  --arg holder_prefix "${holder_prefix}" '
    .schema_version == 1
    and .project == $project
    and .region == $region
    and (.holder | test("^" + $holder_prefix + "[0-9a-f]{64}$"))
    and ((.generation | tostring) | test("^[0-9]+$"))
  ' "${token_path}" >/dev/null || {
  printf 'Recovery token is not bound to this project, region, stage, and exact source head.\n' >&2
  exit 1
}

printf 'Network-hardening recovery token is bound to %s/%s stage %s at %s.\n' \
  "${project}" "${region}" "${stage}" "${source_head}"
