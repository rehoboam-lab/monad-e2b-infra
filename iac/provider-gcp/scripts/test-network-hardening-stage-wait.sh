#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

fake_gcloud="${test_dir}/gcloud"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >>"${FAKE_GCLOUD_LOG:?}"' \
  '[[ "${1:-}" == "compute" ]] || exit 2' \
  'case "${2:-}" in' \
  '  firewall-rules)' \
  '    name="${4:?}"' \
  '    if [[ "${name}" == *internal-remote-connection-firewall-ingress ]]; then' \
  '      printf "%s\n" "{\"direction\":\"INGRESS\",\"disabled\":false,\"priority\":900,\"sourceRanges\":[\"35.235.240.0/20\"],\"targetTags\":[\"orch\"],\"allowed\":[{\"IPProtocol\":\"tcp\",\"ports\":[\"22\",\"3389\"]}],\"logConfig\":{\"enable\":true,\"metadata\":\"EXCLUDE_ALL_METADATA\"}}"' \
  '    else' \
  '      printf "%s\n" "{\"direction\":\"INGRESS\",\"disabled\":false,\"priority\":1000,\"sourceRanges\":[\"0.0.0.0/0\"],\"targetTags\":[\"orch\"],\"denied\":[{\"IPProtocol\":\"tcp\",\"ports\":[\"22\",\"3389\"]}],\"logConfig\":{\"enable\":true,\"metadata\":\"EXCLUDE_ALL_METADATA\"}}"' \
  '    fi' \
  '    ;;' \
  '  instance-groups)' \
  '    count="$(<"${FAKE_GCLOUD_COUNTER:?}")"' \
  '    count=$((count + 1))' \
  '    printf "%s\n" "${count}" >"${FAKE_GCLOUD_COUNTER}"' \
  '    mode="${FAKE_GCLOUD_MODE:-stable}"' \
  '    if [[ "${mode}" == "delayed" && "${count}" -gt 1 ]]; then mode=stable; fi' \
  '    if [[ "${mode}" == "stable" ]]; then' \
  '      printf "%s\n" "{\"targetSize\":2,\"status\":{\"isStable\":true,\"versionTarget\":{\"isReached\":true}},\"currentActions\":{\"none\":2}}"' \
  '    elif [[ "${mode}" == "missing-version" ]]; then' \
  '      printf "%s\n" "{\"targetSize\":2,\"status\":{\"isStable\":true},\"currentActions\":{\"none\":2}}"' \
  '    else' \
  '      printf "%s\n" "{\"targetSize\":2,\"status\":{\"isStable\":false,\"versionTarget\":{\"isReached\":false}},\"currentActions\":{\"none\":1,\"recreating\":1}}"' \
  '    fi' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  >"${fake_gcloud}"
chmod 0755 "${fake_gcloud}"

run_stage() {
  local stage="$1"
  local mode="${2:-stable}"
  local max_seconds="${3:-3}"
  local poll_seconds="${4:-0}"

  : >"${test_dir}/gcloud.log"
  printf '0\n' >"${test_dir}/counter"
  GCP_PROJECT_ID=monad-code \
    GCP_REGION=us-east4 \
    GCP_ZONE=us-east4-c \
    PREFIX=e2b- \
    NETWORK_HARDENING_ROLLOUT_STAGE="${stage}" \
    NETWORK_HARDENING_WAIT_SECONDS="${max_seconds}" \
    NETWORK_HARDENING_POLL_SECONDS="${poll_seconds}" \
    GCLOUD_BIN="${fake_gcloud}" \
    FAKE_GCLOUD_LOG="${test_dir}/gcloud.log" \
    FAKE_GCLOUD_COUNTER="${test_dir}/counter" \
    FAKE_GCLOUD_MODE="${mode}" \
    "${script_dir}/wait-network-hardening-stage.sh"
}

expect_fail() {
  local description="$1"
  shift
  if "$@" >"${test_dir}/stdout" 2>"${test_dir}/stderr"; then
    printf 'expected failure: %s\n' "${description}" >&2
    exit 1
  fi
}

run_stage disabled >/dev/null
[[ ! -s "${test_dir}/gcloud.log" ]]

for stage in network server api worker build; do
  run_stage "${stage}" >/dev/null
done

run_stage worker delayed 3 0 >/dev/null
[[ "$(cat "${test_dir}/counter")" -ge 2 ]]
grep -F 'instance-groups managed describe e2b-orch-client-rig --region=us-east4' \
  "${test_dir}/gcloud.log" >/dev/null

run_stage build stable 3 0 >/dev/null
grep -F 'instance-groups managed describe e2b-orch-build-default-rig --region=us-east4' \
  "${test_dir}/gcloud.log" >/dev/null
grep -F 'instance-groups managed describe e2b-orch-loki-ig --zone=us-east4-c' \
  "${test_dir}/gcloud.log" >/dev/null
grep -F 'instance-groups managed describe e2b-clickhouse-ig --zone=us-east4-c' \
  "${test_dir}/gcloud.log" >/dev/null

expect_fail "unstable MIG times out" run_stage worker unstable 1 1
grep -F 'did not converge' "${test_dir}/stderr" >/dev/null
expect_fail "missing versionTarget.isReached fails closed" run_stage api missing-version 1 1

printf 'Network-hardening stage convergence guards passed.\n'
