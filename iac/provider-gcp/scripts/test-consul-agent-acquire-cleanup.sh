#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly consul_script="$script_dir/../nomad-cluster/scripts/run-consul.sh"
readonly gce_identity_script="$script_dir/../nomad-cluster/scripts/consul-gce-agent-identity.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/e2b-consul-agent-acquire.XXXXXX")"
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf -- "$test_root"
  exit "$status"
}
trap cleanup EXIT

mkdir -p "$test_root/bash-commons" "$test_root/runtime"
cat >"$test_root/bash-commons/assert.sh" <<'EOF'
assert_not_empty() { [[ -n "${2:-}" ]]; }
assert_is_installed() { :; }
EOF
cat >"$test_root/bash-commons/log.sh" <<'EOF'
log_info() { :; }
log_warn() { :; }
log_error() { printf '%s\n' "$1" >&2; }
EOF
: >"$test_root/bash-commons/os.sh"
sed \
  -e "s#readonly BASH_COMMONS_DIR=.*#readonly BASH_COMMONS_DIR=\"$test_root/bash-commons\"#" \
  -e "s#readonly BOOTSTRAP_RUNTIME_ROOT=.*#readonly BOOTSTRAP_RUNTIME_ROOT=\"$test_root\"#" \
  -e "s#readonly GCE_AGENT_RUNTIME_DIR=.*#readonly GCE_AGENT_RUNTIME_DIR=\"$test_root/runtime\"#" \
  -e "s#readonly GCE_AGENT_RUNTIME_CONFIG=.*#readonly GCE_AGENT_RUNTIME_CONFIG=\"$test_root/runtime/agent-token.json\"#" \
  -e "s#readonly GCE_AGENT_RUNTIME_TOKEN=.*#readonly GCE_AGENT_RUNTIME_TOKEN=\"$test_root/runtime/agent-token\"#" \
  -e "s#readonly GCE_AGENT_RECOVERY_TOKEN=.*#readonly GCE_AGENT_RECOVERY_TOKEN=\"$test_root/runtime/agent-recovery-token\"#" \
  -e "s#readonly GCE_AGENT_RUNTIME_LEASE=.*#readonly GCE_AGENT_RUNTIME_LEASE=\"$test_root/runtime/lease.json\"#" \
  -e "s#readonly GCE_AGENT_BOOT_READY=.*#readonly GCE_AGENT_BOOT_READY=\"$test_root/runtime/boot-ready.json\"#" \
  -e "s#readonly GCE_AGENT_ROTATION_JOURNAL=.*#readonly GCE_AGENT_ROTATION_JOURNAL=\"$test_root/runtime/rotation-transaction\"#" \
  -e "s#readonly GCE_AGENT_PENDING_REVOKE_DIR=.*#readonly GCE_AGENT_PENDING_REVOKE_DIR=\"$test_root/runtime/pending-revocations\"#" \
  "$consul_script" >"$test_root/run-consul.sh"
cp "$gce_identity_script" "$test_root/consul-gce-agent-identity.sh"

# shellcheck source=/dev/null
source "$test_root/run-consul.sh"

chown() { :; }
install() {
  local -a args=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -o|-g) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  command install "${args[@]}"
}
sleep() { :; }
get_instance_project_id() { printf '%s\n' monad-code; }
get_instance_id() { printf '%s\n' 1234567890123456789; }
get_instance_zone() { printf '%s\n' us-east4-c; }
get_instance_service_account_email() {
  printf '%s\n' e2b-api-controller@monad-code.iam.gserviceaccount.com
}
get_boot_id() { printf '%s\n' cccccccc-cccc-cccc-cccc-cccccccccccc; }
generate_gce_agent_recovery_token() {
  printf '%s\n' dddddddd-dddd-dddd-dddd-dddddddddddd
}
decode_gce_agent_jwt_segment() { :; }
decode_jwt_segment() {
  case "$1" in
    header)
      printf '%s\n' '{"alg":"RS256","kid":"fixture"}'
      ;;
    payload)
      jq -n \
        --argjson now "$(date -u +%s)" '
          {
            iss:"https://accounts.google.com",
            aud:"https://consul.monad-code.internal/e2b/gce-agent",
            email:"e2b-api-controller@monad-code.iam.gserviceaccount.com",
            email_verified:true,
            iat:$now,
            exp:($now + 3600),
            google:{compute_engine:{
              project_id:"monad-code",
              zone:"us-east4-c",
              instance_id:"1234567890123456789"
            }}
          }
        '
      ;;
    *) return 1 ;;
  esac
}

readonly candidate_token='22222222-2222-2222-2222-222222222222'
readonly candidate_accessor='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
curl_argv="$test_root/curl.argv"
logout_calls="$test_root/logout.calls"
: >"$curl_argv"
: >"$logout_calls"
ACQUIRE_MODE=success
FAIL_LOGOUT=false

expiration_time() {
  python3 - <<'PY'
import datetime
print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

curl_direct() {
  local output=''
  local config=''
  local request='GET'
  local url=''
  local arg

  printf '%s\n' "$*" >>"$curl_argv"
  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --output) output="$2"; shift 2; continue ;;
      --config) config="$2"; shift 2; continue ;;
      --request) request="$2"; shift 2; continue ;;
      http://*|https://*) url="$arg" ;;
    esac
    shift
  done

  case "$url" in
    */instance/service-accounts/default/identity)
      printf '%s\n' 'header.payload.signature' >"$output"
      ;;
    */v1/acl/login)
      jq -n \
        --arg token "$candidate_token" \
        --arg accessor "$candidate_accessor" \
        --arg expiration "$(expiration_time)" \
        --arg mode "$ACQUIRE_MODE" '
          {
            Local:($mode != "invalid-response"),
            Policies:[],Roles:[],ServiceIdentities:[],
            NodeIdentities:[{NodeName:"1234567890123456789",Datacenter:"us-east4"}],
            SecretID:$token,AccessorID:$accessor,ExpirationTime:$expiration
          }
        ' >"$output"
      printf 200
      ;;
    */v1/acl/logout)
      printf 'logout\n' >>"$logout_calls"
      if [[ "$FAIL_LOGOUT" == true ]]; then
        printf 500
      else
        printf 200
      fi
      ;;
    */v1/acl/token/self)
      if [[ "$config" == *logout.curl ]]; then
        # In the failure fixture the token remains positively valid.
        printf 200
      elif [[ "$ACQUIRE_MODE" == probe-failure ]]; then
        printf '%s\n' '{}' >"$output"
        printf 500
      else
        jq -n --arg expiration "$(expiration_time)" '
          {
            Policies:[],Roles:[],ServiceIdentities:[],
            NodeIdentities:[{NodeName:"1234567890123456789",Datacenter:"us-east4"}],
            ExpirationTime:$expiration
          }
        ' >"$output"
        printf 200
      fi
      ;;
    *) return 1 ;;
  esac
}

pending_count() {
  [[ -d "$GCE_AGENT_PENDING_REVOKE_DIR" ]] || {
    printf 0
    return
  }
  find "$GCE_AGENT_PENDING_REVOKE_DIR" -type f -name 'token-*.json' \
    | wc -l | tr -d ' '
}

reset_generation() {
  rm -rf -- "$GCE_AGENT_PENDING_REVOKE_DIR" "$GCE_AGENT_ROTATION_JOURNAL"
  initialize_gce_agent_runtime_config root
  : >"$logout_calls"
}

run_expected_failure() {
  local mode="$1"
  ACQUIRE_MODE="$mode"
  if acquire_gce_agent_identity us-east4 root; then
    printf 'acquire mode %s unexpectedly succeeded\n' "$mode" >&2
    exit 1
  fi
  [[ ! -e "$GCE_AGENT_RUNTIME_TOKEN" ]]
}

reset_generation
run_expected_failure invalid-response
[[ "$(pending_count)" == 0 ]]
[[ "$(wc -l <"$logout_calls" | tr -d ' ')" == 1 ]]

reset_generation
run_expected_failure probe-failure
[[ "$(pending_count)" == 0 ]]
[[ "$(wc -l <"$logout_calls" | tr -d ' ')" == 1 ]]

eval "$(declare -f write_gce_agent_runtime_config | sed \
  '1s/write_gce_agent_runtime_config/write_gce_agent_runtime_config_real/')"
write_gce_agent_runtime_config() { return 1; }
reset_generation
run_expected_failure runtime-write-failure
[[ "$(pending_count)" == 0 ]]
[[ "$(wc -l <"$logout_calls" | tr -d ' ')" == 1 ]]
eval "$(declare -f write_gce_agent_runtime_config_real | sed \
  '1s/write_gce_agent_runtime_config_real/write_gce_agent_runtime_config/')"
unset -f write_gce_agent_runtime_config_real

# If cleanup itself cannot reach Consul, the token remains in a root-only
# pending journal and the next login is refused until reconciliation succeeds.
reset_generation
FAIL_LOGOUT=true
run_expected_failure invalid-response
[[ "$(pending_count)" == 1 ]]
pending_file="$(find "$GCE_AGENT_PENDING_REVOKE_DIR" -type f -name 'token-*.json')"
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
[[ "$(file_mode "$GCE_AGENT_PENDING_REVOKE_DIR")" == 700 ]]
[[ "$(file_mode "$pending_file")" == 600 ]]
if acquire_gce_agent_identity us-east4 root >/dev/null 2>&1; then
  echo 'new login proceeded while an orphan token was pending revocation' >&2
  exit 1
fi
FAIL_LOGOUT=false
ACQUIRE_MODE=success
reconcile_gce_agent_pending_revokes
[[ "$(pending_count)" == 0 ]]

# A successful acquisition remains journaled only until the caller proves the
# runtime generation active, then acknowledgement removes the pending entry.
reset_generation
ACQUIRE_MODE=success
acquire_gce_agent_identity us-east4 root
[[ "$(pending_count)" == 1 ]]
[[ "$(tr -d '\r\n' <"$GCE_AGENT_RUNTIME_TOKEN")" == "$candidate_token" ]]
acknowledge_gce_agent_login_token "$GCE_AGENT_RUNTIME_TOKEN"
[[ "$(pending_count)" == 0 ]]

if grep -F "$candidate_token" "$curl_argv" >/dev/null; then
  echo 'GCE agent token appeared in a curl argument vector' >&2
  exit 1
fi
if grep -E 'http://(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
  "$curl_argv" >/dev/null; then
  echo 'GCE identity or Consul SecretID crossed a remote plaintext HTTP path' >&2
  exit 1
fi
grep -F 'http://127.0.0.1:8500/v1/acl/login' "$curl_argv" >/dev/null
grep -F 'http://127.0.0.1:8500/v1/acl/token/self' "$curl_argv" >/dev/null
grep -F 'http://127.0.0.1:8500/v1/acl/logout' "$curl_argv" >/dev/null

echo 'Consul GCE agent acquisition cleanup regression test passed'
