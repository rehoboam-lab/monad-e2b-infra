#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly makefile="$script_dir/../Makefile"

block() {
  local target="$1"
  awk -v target="$target:" '
    $0 == target {active=1}
    active && $0 != target && /^[^[:space:]#.][^:]*:([[:space:]]|$)/ {exit}
    active {print}
  ' "$makefile"
}

stage="$(block consul-management-handoff-stage)"
verify_staged="$(block consul-management-handoff-verify-staged)"
retire="$(block consul-management-handoff-retire)"
post_plan="$(block consul-management-handoff-post-plan)"
cluster_guard="$(block workload-cluster-stage-guard)"

grep -F './scripts/consul-management-handoff.sh stage' <<<"$stage" >/dev/null
grep -F 'CONSUL_HANDOFF_PRE_SERVER_ACL_EVIDENCE=' <<<"$stage" >/dev/null
grep -F 'CONSUL_HANDOFF_NOMAD_TOKEN_SECRET_VERSION=' <<<"$stage" >/dev/null
grep -F 'CONSUL_HANDOFF_NOMAD_BASE_URL=' <<<"$stage" >/dev/null
grep -F 'CONSUL_HANDOFF_STATE_BUCKET=' <<<"$stage" >/dev/null

grep -F './scripts/consul-management-handoff.sh verify-staged' <<<"$verify_staged" >/dev/null
grep -F 'CONSUL_HANDOFF_STATE_BUCKET=' <<<"$verify_staged" >/dev/null
grep -F 'consul-management-handoff-verify-staged' <<<"$post_plan" >/dev/null

grep -F './scripts/consul-management-handoff.sh retire' <<<"$retire" >/dev/null
grep -F 'CONSUL_HANDOFF_POST_API_EVIDENCE=' <<<"$retire" >/dev/null
grep -F 'CONSUL_HANDOFF_BUILD_CHECKPOINT=' <<<"$retire" >/dev/null
grep -F 'CONSUL_HANDOFF_NOMAD_TOKEN_SECRET_VERSION=' <<<"$retire" >/dev/null
grep -F 'CONSUL_RETIRE_CONFIRMATION=' <<<"$retire" >/dev/null
grep -F 'CONSUL_HANDOFF_STATE_BUCKET=' <<<"$retire" >/dev/null

grep -F 'staged) handoff_mode=verify-staged' <<<"$cluster_guard" >/dev/null
grep -F 'retired) handoff_mode=verify' <<<"$cluster_guard" >/dev/null
grep -F 'CONSUL_HANDOFF_STATE_BUCKET=' <<<"$cluster_guard" >/dev/null
if grep -Fq 'consul-management-handoff-prepare' "$makefile"; then
  printf 'Retired Consul handoff prepare target remains wired.\n' >&2
  exit 1
fi

printf 'Consul handoff Make wiring regression test passed\n'
