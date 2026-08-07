#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

fake_gcloud="${test_dir}/gcloud"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >>"${FAKE_GCLOUD_LOG:?}"' \
  '[[ "${1:-}" == "compute" ]] || exit 2' \
  'case "${2:-}" in' \
  '  scp)' \
  '    grep -F -- "--tunnel-through-iap" <<<"$*" >/dev/null' \
  '    grep -E -- "e2b-orch-server-[123]:/tmp/e2b-(nomad-voter-health|install-nomad-voter-health)\.[0-9a-f]{64}\.(py|sh)" <<<"$*" >/dev/null' \
  '    exit 0' \
  '    ;;' \
  '  ssh)' \
  '    grep -F -- "--tunnel-through-iap" <<<"$*" >/dev/null' \
  '    grep -F -- "--command=sudo --" <<<"$*" >/dev/null' \
  '    grep -E -- "/tmp/e2b-install-nomad-voter-health\.[0-9a-f]{64}\.sh" <<<"$*" >/dev/null' \
  '    grep -E -- "/tmp/e2b-nomad-voter-health\.[0-9a-f]{64}\.py" <<<"$*" >/dev/null' \
  '    exit 0' \
  '    ;;' \
  '  health-checks)' \
  '    [[ "${3:-}" == "describe" ]] || exit 2' \
  '    case "${4:-}" in' \
  '      e2b-orch-server-nomad-check) port=4646; path=/v1/agent/health ;;' \
  '      e2b-orch-server-voter-check) port=50001; path=/healthz ;;' \
  '      *) exit 2 ;;' \
  '    esac' \
  '    jq -cn --argjson port "${port}" --arg path "${path}" "{type:\"HTTP\",checkIntervalSec:5,timeoutSec:5,healthyThreshold:2,unhealthyThreshold:10,httpHealthCheck:{port:\$port,requestPath:\$path}}"' \
  '    ;;' \
  '  instance-groups)' \
  '    [[ "${3:-}" == "managed" ]] || exit 2' \
  '    action="${4:-}"' \
  '    [[ "${5:-}" == "e2b-orch-server-rig" ]] || exit 2' \
  '    state="$(<"${FAKE_GCLOUD_STATE:?}")"' \
  '    template="https://www.googleapis.com/compute/v1/projects/monad-code/global/instanceTemplates/e2b-orch-server-live"' \
  '    if [[ "${FAKE_GCLOUD_MODE:-stable}" == "template-drift" && "${state}" == "safe" ]]; then template="${template}-changed"; fi' \
  '    if [[ "${action}" == "describe" ]]; then' \
  '      if [[ "${state}" == "safe" ]]; then surge=1; unavailable=0; failed=DO_NOTHING; health=e2b-orch-server-voter-check; else surge=0; unavailable=1; failed=DEFAULT_ACTION; health=e2b-orch-server-nomad-check; fi' \
  '      jq -cn --arg template "${template}" --arg health "${health}" --argjson surge "${surge}" --argjson unavailable "${unavailable}" --arg failed "${failed}" "{targetSize:3,versions:[{instanceTemplate:\$template}],autoHealingPolicies:[{healthCheck:(\"https://www.googleapis.com/compute/v1/projects/monad-code/global/healthChecks/\" + \$health),initialDelaySec:120}],updatePolicy:{type:\"PROACTIVE\",minimalAction:\"REPLACE\",replacementMethod:\"SUBSTITUTE\",maxSurge:{fixed:\$surge},maxUnavailable:{fixed:\$unavailable}},instanceLifecyclePolicy:{defaultActionOnFailure:\"REPAIR\",forceUpdateOnRepair:\"NO\",onFailedHealthCheck:\$failed},status:{isStable:true,versionTarget:{isReached:true}}}"' \
  '      exit 0' \
  '    fi' \
  '    if [[ "${action}" == "list-instances" ]]; then' \
  '      health_count="$(<"${FAKE_GCLOUD_HEALTH_COUNTER:?}")"' \
  '      health_count=$((health_count + 1))' \
  '      printf "%s\n" "${health_count}" >"${FAKE_GCLOUD_HEALTH_COUNTER}"' \
  '      instances="[]"' \
  '      for index in 1 2 3; do' \
  '        id="$((1000 + index))"' \
  '        current=NONE' \
  '        if [[ "${state}" == "safe" && "${FAKE_GCLOUD_MODE:-stable}" == "identity-drift" && "${index}" == 1 ]]; then id=9999; fi' \
  '        if [[ "${state}" == "safe" && "${FAKE_GCLOUD_MODE:-stable}" == "current-action" && "${index}" == 1 ]]; then current=RECREATING; fi' \
  '        health_state=HEALTHY' \
  '        if [[ "${state}" == "safe" && "${FAKE_GCLOUD_MODE:-stable}" == "unhealthy" && "${index}" == 1 ]]; then health_state=UNHEALTHY; fi' \
  '        if [[ "${state}" == "safe" && "${FAKE_GCLOUD_MODE:-stable}" == "delayed-health" && "${health_count}" -le 4 ]]; then health_state=UNKNOWN; fi' \
  '        name="e2b-orch-server-${index}"' \
  '        instance="https://www.googleapis.com/compute/v1/projects/monad-code/zones/us-east4-c/instances/${name}"' \
  '        instances="$(jq -cn --argjson current_json "${instances}" --arg id "${id}" --arg name "${name}" --arg instance "${instance}" --arg action "${current}" --arg template "${template}" --arg health "${health_state}" "\$current_json + [{id:\$id,name:\$name,instance:\$instance,currentAction:\$action,instanceStatus:\"RUNNING\",version:{instanceTemplate:\$template},instanceHealth:[{detailedHealthState:\$health}]}]")"' \
  '      done' \
  '      printf "%s\n" "${instances}"' \
  '      exit 0' \
  '    fi' \
  '    if [[ "${action}" == "update" ]]; then' \
  '      grep -F -- "--update-policy-max-surge=1" <<<"$*" >/dev/null' \
  '      grep -F -- "--update-policy-max-unavailable=0" <<<"$*" >/dev/null' \
  '      grep -F -- "--health-check=e2b-orch-server-voter-check" <<<"$*" >/dev/null' \
  '      grep -F -- "--initial-delay=120" <<<"$*" >/dev/null' \
  '      grep -F -- "--action-on-vm-failed-health-check=do-nothing" <<<"$*" >/dev/null' \
  '      printf "%s\n" safe >"${FAKE_GCLOUD_STATE}"' \
  '      exit 0' \
  '    fi' \
  '    exit 2' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  >"${fake_gcloud}"
chmod 0755 "${fake_gcloud}"

run_safety() {
  local mode="$1"
  local initial_state="${2:-legacy}"
  : >"${test_dir}/gcloud.log"
  printf '%s\n' "${initial_state}" >"${test_dir}/state"
  printf '0\n' >"${test_dir}/health-counter"
  GCP_PROJECT_ID=monad-code \
    GCP_REGION=us-east4 \
    PREFIX=e2b- \
    SERVER_CLUSTER_SIZE=3 \
    SERVER_SAFETY_WAIT_SECONDS=2 \
    SERVER_SAFETY_POLL_SECONDS=0 \
    GCLOUD_BIN="${fake_gcloud}" \
    FAKE_GCLOUD_LOG="${test_dir}/gcloud.log" \
    FAKE_GCLOUD_STATE="${test_dir}/state" \
    FAKE_GCLOUD_HEALTH_COUNTER="${test_dir}/health-counter" \
    FAKE_GCLOUD_MODE="${mode}" \
    "${script_dir}/configure-server-mig-safety.sh"
}

expect_fail() {
  local description="$1"
  shift
  if "$@" >"${test_dir}/stdout" 2>"${test_dir}/stderr"; then
    printf 'expected failure: %s\n' "${description}" >&2
    exit 1
  fi
}

run_safety stable >"${test_dir}/stable.out"
grep -F 'converged without changing template' "${test_dir}/stable.out" >/dev/null
test "$(grep -c '^compute instance-groups managed update ' "${test_dir}/gcloud.log")" -eq 1
test "$(grep -c '^compute scp ' "${test_dir}/gcloud.log")" -eq 6
test "$(grep -c '^compute ssh ' "${test_dir}/gcloud.log")" -eq 3

run_safety stable safe >/dev/null
test "$(grep -c '^compute instance-groups managed update ' "${test_dir}/gcloud.log" || true)" -eq 0

run_safety delayed-health >/dev/null
test "$(cat "${test_dir}/health-counter")" -ge 6

expect_fail "instance identity drift fails before the safety ledger" run_safety identity-drift
grep -F 'replaced or changed a managed server instance' "${test_dir}/stderr" >/dev/null
expect_fail "template drift fails before the safety ledger" run_safety template-drift
grep -F 'changed the MIG template' "${test_dir}/stderr" >/dev/null
expect_fail "a replacement currentAction fails before the safety ledger" run_safety current-action
grep -F 'instance identity became unstable' "${test_dir}/stderr" >/dev/null
expect_fail "an unhealthy strict endpoint fails before the safety ledger" run_safety unhealthy
grep -F 'strict GCE health on every exact old voter' "${test_dir}/stderr" >/dev/null

printf 'Server MIG safety transition guards passed.\n'
