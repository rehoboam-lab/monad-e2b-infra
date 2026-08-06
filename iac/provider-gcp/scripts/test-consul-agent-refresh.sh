#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly consul_script="$script_dir/../nomad-cluster/scripts/run-consul.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/e2b-consul-agent-refresh.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/bash-commons" "$test_root/runtime" "$test_root/lock" "$test_root/systemd" "$test_root/config" "$test_root/data" "$test_root/bin"
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
  -e "s#readonly SYSTEMD_CONFIG_PATH=.*#readonly SYSTEMD_CONFIG_PATH=\"$test_root/systemd/consul.service\"#" \
  -e "s#readonly GCE_AGENT_RUNTIME_DIR=.*#readonly GCE_AGENT_RUNTIME_DIR=\"$test_root/runtime\"#" \
  -e "s#readonly GCE_AGENT_RUNTIME_CONFIG=.*#readonly GCE_AGENT_RUNTIME_CONFIG=\"$test_root/runtime/agent-token.json\"#" \
  -e "s#readonly GCE_AGENT_RUNTIME_TOKEN=.*#readonly GCE_AGENT_RUNTIME_TOKEN=\"$test_root/runtime/agent-token\"#" \
  -e "s#readonly GCE_AGENT_RECOVERY_TOKEN=.*#readonly GCE_AGENT_RECOVERY_TOKEN=\"$test_root/runtime/agent-recovery-token\"#" \
  -e "s#readonly GCE_AGENT_RUNTIME_LEASE=.*#readonly GCE_AGENT_RUNTIME_LEASE=\"$test_root/runtime/lease.json\"#" \
  -e "s#readonly GCE_AGENT_BOOT_READY=.*#readonly GCE_AGENT_BOOT_READY=\"$test_root/runtime/boot-ready.json\"#" \
  -e "s#readonly GCE_AGENT_ROTATION_JOURNAL=.*#readonly GCE_AGENT_ROTATION_JOURNAL=\"$test_root/runtime/rotation-transaction\"#" \
  -e "s#readonly GCE_AGENT_PENDING_REVOKE_DIR=.*#readonly GCE_AGENT_PENDING_REVOKE_DIR=\"$test_root/runtime/pending-revocations\"#" \
  -e "s#readonly GCE_AGENT_LOCK_DIR=.*#readonly GCE_AGENT_LOCK_DIR=\"$test_root/lock\"#" \
  -e "s#readonly GCE_AGENT_BOOTSTRAP_LOCK=.*#readonly GCE_AGENT_BOOTSTRAP_LOCK=\"$test_root/lock/bootstrap.lock\"#" \
  -e "s#readonly GCE_AGENT_REFRESH_SERVICE=.*#readonly GCE_AGENT_REFRESH_SERVICE=\"$test_root/systemd/e2b-consul-agent-refresh.service\"#" \
  -e "s#readonly GCE_AGENT_REFRESH_TIMER=.*#readonly GCE_AGENT_REFRESH_TIMER=\"$test_root/systemd/e2b-consul-agent-refresh.timer\"#" \
  "$consul_script" >"$test_root/run-consul.sh"

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
get_instance_id() { printf '%s\n' '1234567890123456789'; }
get_boot_id() { printf '%s\n' 'cccccccc-cccc-cccc-cccc-cccccccccccc'; }
generate_gce_agent_recovery_token() { printf '%s\n' 'dddddddd-dddd-dddd-dddd-dddddddddddd'; }

expires_at() {
  python3 - "$1" <<'PY'
import datetime, sys
seconds = int(sys.argv[1])
print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

write_generation() {
  local token="$1" accessor="$2" lifetime="$3"
  local input="$test_root/input-token" response="$test_root/login-response.json"
  printf '%s\n' "$token" >"$input"
  jq -n --arg token "$token" --arg accessor "$accessor" --arg expiration "$(expires_at "$lifetime")" \
    '{SecretID:$token,AccessorID:$accessor,ExpirationTime:$expiration}' >"$response"
  write_gce_agent_runtime_config "$input" root "$response" '1234567890123456789'
}

readonly OLD_TOKEN='11111111-1111-1111-1111-111111111111'
readonly OLD_ACCESSOR='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
readonly NEW_TOKEN='22222222-2222-2222-2222-222222222222'
readonly NEW_ACCESSOR='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'

initialize_gce_agent_runtime_config root
write_generation "$OLD_TOKEN" "$OLD_ACCESSOR" 3600
gce_agent_runtime_has_headroom 900
mark_gce_agent_boot_ready '1234567890123456789'
gce_agent_boot_is_ready
jq -e --arg accessor "$OLD_ACCESSOR" '.schema == 2 and .accessor_id == $accessor' "$GCE_AGENT_RUNTIME_LEASE" >/dev/null
[[ "$(tr -d '\r\n' <"$GCE_AGENT_RUNTIME_TOKEN")" == "$OLD_TOKEN" ]]
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
[[ "$(file_mode "$GCE_AGENT_RUNTIME_TOKEN")" == 600 ]]
[[ "$(file_mode "$GCE_AGENT_RUNTIME_LEASE")" == 600 ]]
[[ "$(file_mode "$GCE_AGENT_RUNTIME_CONFIG")" == 640 ]]
[[ "$(file_mode "$GCE_AGENT_RECOVERY_TOKEN")" == 640 ]]

# The safety boundary is strictly greater than the maximum 12-minute timer
# interval plus margin: 901 seconds passes and 900 seconds fails.
jq --argjson expiration "$(( $(date -u +%s) + 901 ))" '.expiration_epoch=$expiration' \
  "$GCE_AGENT_RUNTIME_LEASE" >"$test_root/lease" && mv "$test_root/lease" "$GCE_AGENT_RUNTIME_LEASE"
gce_agent_runtime_has_headroom 900
jq --argjson expiration "$(( $(date -u +%s) + 900 ))" '.expiration_epoch=$expiration' \
  "$GCE_AGENT_RUNTIME_LEASE" >"$test_root/lease" && mv "$test_root/lease" "$GCE_AGENT_RUNTIME_LEASE"
if gce_agent_runtime_has_headroom 900; then
  echo 'exact 900-second expiry boundary was accepted' >&2
  exit 1
fi
write_generation "$OLD_TOKEN" "$OLD_ACCESSOR" 3600

calls="$test_root/systemctl.calls"
revoke_calls="$test_root/revoke.calls"
: >"$calls"
: >"$revoke_calls"
systemctl() {
  printf '%s\n' "$*" >>"$calls"
  case "$*" in
    'is-active --quiet consul.service') return 0 ;;
    'reload consul.service') return 0 ;;
    *) return 0 ;;
  esac
}
acquire_gce_agent_identity() {
  write_generation "$NEW_TOKEN" "$NEW_ACCESSOR" 3600
}
revoke_gce_agent_login_token() {
  tr -d '\r\n' <"$1" >>"$revoke_calls"
  printf '\n' >>"$revoke_calls"
}

refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com
[[ "$(tr -d '\r\n' <"$GCE_AGENT_RUNTIME_TOKEN")" == "$NEW_TOKEN" ]]
grep -Fqx 'reload consul.service' "$calls"
grep -Fqx "$OLD_TOKEN" "$revoke_calls"
if grep -Eq '(^| )(stop|start) consul.service($| )' "$calls"; then
  echo 'successful refresh churned Consul membership' >&2
  exit 1
fi

# A failed SIGHUP restores the complete old generation, retries SIGHUP with
# that generation, and revokes the unused candidate without stop/start.
write_generation "$OLD_TOKEN" "$OLD_ACCESSOR" 3600
: >"$calls"
: >"$revoke_calls"
reload_count=0
systemctl() {
  printf '%s\n' "$*" >>"$calls"
  case "$*" in
    'is-active --quiet consul.service') return 0 ;;
    'reload consul.service')
      reload_count=$((reload_count + 1))
      [[ "$reload_count" -gt 1 ]]
      ;;
    *) return 0 ;;
  esac
}
if refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com; then
  echo 'failed SIGHUP refresh unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(tr -d '\r\n' <"$GCE_AGENT_RUNTIME_TOKEN")" == "$OLD_TOKEN" ]]
grep -Fqx "$NEW_TOKEN" "$revoke_calls"
if grep -Eq '(^| )(stop|start) consul.service($| )' "$calls"; then
  echo 'rollback churned Consul membership' >&2
  exit 1
fi

# An active Consul process may never be mutated without a complete validated
# rollback journal. Snapshot failure must happen before the login exchange.
eval "$(declare -f snapshot_gce_agent_runtime | sed \
  '1s/snapshot_gce_agent_runtime/snapshot_gce_agent_runtime_real/')"
snapshot_gce_agent_runtime() { return 1; }
acquire_calls="$test_root/acquire.calls"
: >"$acquire_calls"
acquire_gce_agent_identity() {
  printf 'acquire\n' >>"$acquire_calls"
  write_generation "$NEW_TOKEN" "$NEW_ACCESSOR" 3600
}
systemctl() {
  printf '%s\n' "$*" >>"$calls"
  case "$*" in
    'is-active --quiet consul.service') return 0 ;;
    'reload consul.service') return 0 ;;
    *) return 0 ;;
  esac
}
write_generation "$OLD_TOKEN" "$OLD_ACCESSOR" 3600
rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
: >"$calls"
if refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com; then
  echo 'refresh mutated an active agent without a rollback journal' >&2
  exit 1
fi
[[ ! -s "$acquire_calls" ]]
[[ "$(tr -d '\r\n' <"$GCE_AGENT_RUNTIME_TOKEN")" == "$OLD_TOKEN" ]]
[[ ! -e "$GCE_AGENT_ROTATION_JOURNAL" ]]
eval "$(declare -f snapshot_gce_agent_runtime_real | sed \
  '1s/snapshot_gce_agent_runtime_real/snapshot_gce_agent_runtime/')"
unset -f snapshot_gce_agent_runtime_real

# If both candidate reload and rollback reload fail, the agent is fail-closed
# and the root-only journal survives for the next timer/manual recovery.
fail_close_calls="$test_root/fail-close.calls"
: >"$fail_close_calls"
fail_close_consul_agent() { printf 'fail-close\n' >>"$fail_close_calls"; }
acquire_gce_agent_identity() {
  write_generation "$NEW_TOKEN" "$NEW_ACCESSOR" 3600
}
revoke_gce_agent_login_token() {
  tr -d '\r\n' <"$1" >>"$revoke_calls"
  printf '\n' >>"$revoke_calls"
}
systemctl() {
  printf '%s\n' "$*" >>"$calls"
  case "$*" in
    'is-active --quiet consul.service') return 0 ;;
    'reload consul.service') return 1 ;;
    *) return 0 ;;
  esac
}
write_generation "$OLD_TOKEN" "$OLD_ACCESSOR" 3600
rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
: >"$calls"
: >"$revoke_calls"
if refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com; then
  echo 'double reload failure was reported as converged' >&2
  exit 1
fi
[[ -d "$GCE_AGENT_ROTATION_JOURNAL" ]]
[[ "$(file_mode "$GCE_AGENT_ROTATION_JOURNAL")" == 700 ]]
[[ "$(file_mode "$GCE_AGENT_ROTATION_JOURNAL/agent-token")" == 600 ]]
[[ "$(tr -d '\r\n' <"$GCE_AGENT_RUNTIME_TOKEN")" == "$OLD_TOKEN" ]]
grep -Fqx 'fail-close' "$fail_close_calls"

# Recovery from that fail-close must start the restored current generation,
# revoke the unused candidate, and remove the journal only after both succeed.
consul_active=false
systemctl() {
  printf '%s\n' "$*" >>"$calls"
  case "$*" in
    'is-active --quiet consul.service') [[ "$consul_active" == true ]] ;;
    'start consul.service') consul_active=true ;;
    *) return 0 ;;
  esac
}
: >"$calls"
: >"$revoke_calls"
reconcile_interrupted_gce_agent_rotation root
[[ "$REPLY" == complete ]]
[[ ! -e "$GCE_AGENT_ROTATION_JOURNAL" ]]
grep -Fqx "$NEW_TOKEN" "$revoke_calls"
grep -Fqx 'start consul.service' "$calls"

# A failed old-token logout is a failed rotation. The candidate remains live,
# but the durable transaction must survive and be resumed before another login.
write_generation "$OLD_TOKEN" "$OLD_ACCESSOR" 3600
rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
logout_failure_marker="$test_root/logout-failed-once"
rm -f -- "$logout_failure_marker"
consul_active=true
systemctl() {
  printf '%s\n' "$*" >>"$calls"
  case "$*" in
    'is-active --quiet consul.service') [[ "$consul_active" == true ]] ;;
    'reload consul.service') return 0 ;;
    *) return 0 ;;
  esac
}
revoke_gce_agent_login_token() {
  if [[ "$(tr -d '\r\n' <"$1")" == "$OLD_TOKEN" \
    && ! -e "$logout_failure_marker" ]]; then
    : >"$logout_failure_marker"
    return 1
  fi
  tr -d '\r\n' <"$1" >>"$revoke_calls"
  printf '\n' >>"$revoke_calls"
}
if refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com; then
  echo 'old-token logout failure was reported as converged' >&2
  exit 1
fi
[[ -d "$GCE_AGENT_ROTATION_JOURNAL" ]]
[[ "$(tr -d '\r\n' <"$GCE_AGENT_RUNTIME_TOKEN")" == "$NEW_TOKEN" ]]
acquire_gce_agent_identity() {
  printf 'unexpected second login\n' >>"$acquire_calls"
  return 1
}
: >"$acquire_calls"
: >"$revoke_calls"
refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com
[[ ! -e "$GCE_AGENT_ROTATION_JOURNAL" ]]
[[ ! -s "$acquire_calls" ]]
grep -Fqx "$OLD_TOKEN" "$revoke_calls"

# SIGKILL-equivalent persisted state: the old transaction is durable, the new
# tuple reached disk, but the process died before recording/revoking anything.
# The next invocation must adopt the candidate synchronously and retire old.
write_generation "$OLD_TOKEN" "$OLD_ACCESSOR" 3600
rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
prepare_gce_agent_rotation_journal
write_generation "$NEW_TOKEN" "$NEW_ACCESSOR" 3600
[[ "$(jq -r .state "$GCE_AGENT_ROTATION_JOURNAL/transaction.json")" == prepared ]]
acquire_gce_agent_identity() {
  printf 'unexpected login after crash recovery\n' >>"$acquire_calls"
  return 1
}
: >"$acquire_calls"
: >"$revoke_calls"
refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com
[[ ! -e "$GCE_AGENT_ROTATION_JOURNAL" ]]
[[ ! -s "$acquire_calls" ]]
grep -Fqx "$OLD_TOKEN" "$revoke_calls"

# SIGKILL-equivalent first-login state: there is no older generation or
# rotation journal, but the newly installed tuple still has its acquisition
# self-revocation record. The next refresh must synchronously start that exact
# tuple, acknowledge it, and must not acquire a second login token.
rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL" "$GCE_AGENT_PENDING_REVOKE_DIR"
mkdir -p "$GCE_AGENT_PENDING_REVOKE_DIR"
chmod 0700 "$GCE_AGENT_PENDING_REVOKE_DIR"
write_generation "$NEW_TOKEN" "$NEW_ACCESSOR" 3600
persist_gce_agent_pending_revoke "$GCE_AGENT_RUNTIME_TOKEN" '10.0.0.10'
pending_first_login="$REPLY"
[[ -f "$pending_first_login" ]]
consul_active=false
systemctl() {
  printf '%s\n' "$*" >>"$calls"
  case "$*" in
    'is-active --quiet consul.service') [[ "$consul_active" == true ]] ;;
    'start consul.service') consul_active=true ;;
    *) return 0 ;;
  esac
}
acquire_gce_agent_identity() {
  printf 'unexpected login while adopting first generation\n' >>"$acquire_calls"
  return 1
}
: >"$calls"
: >"$acquire_calls"
refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com
[[ "$consul_active" == true ]]
[[ ! -e "$pending_first_login" ]]
[[ ! -s "$acquire_calls" ]]
grep -Fqx 'start consul.service' "$calls"

# A failed activation cannot turn the durable pending record into an
# acknowledgement. It fail-closes, retains the retry barrier, and still must
# not issue a second login.
persist_gce_agent_pending_revoke "$GCE_AGENT_RUNTIME_TOKEN" '10.0.0.10'
failed_activation_pending="$REPLY"
consul_active=false
systemctl() {
  printf '%s\n' "$*" >>"$calls"
  case "$*" in
    'is-active --quiet consul.service') return 1 ;;
    'start consul.service') return 1 ;;
    *) return 0 ;;
  esac
}
: >"$calls"
: >"$acquire_calls"
: >"$fail_close_calls"
if refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com; then
  echo 'failed first-generation activation was reported as converged' >&2
  exit 1
fi
[[ -f "$failed_activation_pending" ]]
[[ ! -s "$acquire_calls" ]]
grep -Fqx 'fail-close' "$fail_close_calls"
rm -f -- "$failed_activation_pending"

reload_api_calls="$test_root/reload-api.calls"
: >"$reload_api_calls"
consul_local_with_token() { printf '%s\n' "$*" >>"$reload_api_calls"; }
reload_gce_agent_identity
grep -Fqx "$GCE_AGENT_RECOVERY_TOKEN reload" "$reload_api_calls"
if grep -Fq "$OLD_TOKEN" "$reload_api_calls" || grep -Fq "$NEW_TOKEN" "$reload_api_calls"; then
  echo 'registered GCE token was used for AgentReload' >&2
  exit 1
fi

# No boot marker means a stale timer cannot acquire, rewrite, or start Consul.
rm -f -- "$GCE_AGENT_BOOT_READY"
: >"$calls"
if refresh_gce_agent_identity tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com >/dev/null 2>&1; then
  echo 'refresh without boot generation unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -s "$calls" ]]

# Generated units use SIGHUP, are conditioned on this boot's marker, and the
# timer is started only for this boot (never persistently enabled).
systemctl() { printf '%s\n' "$*" >>"$calls"; }
: >"$calls"
install_gce_agent_refresh_timer tag us-east4 root server-rig nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com
grep -Eq '^ExecReload=.*/run-consul\.sh --reload-gce-agent$' < <(
  generate_systemd_config "$test_root/systemd/generated-consul.service" \
    "$test_root/config" "$test_root/data" '' '' "$test_root/bin" root \
    'ENVIRONMENT=dev'
  grep '^ExecReload=' "$test_root/systemd/generated-consul.service"
)
grep -Fq "ConditionPathExists=$GCE_AGENT_BOOT_READY" "$GCE_AGENT_REFRESH_SERVICE"
grep -Fqx 'disable e2b-consul-agent-refresh.timer' "$calls"
grep -Fqx 'start e2b-consul-agent-refresh.timer' "$calls"
if grep -Eq 'enable( |$)' "$calls"; then
  echo 'refresh timer was persistently enabled' >&2
  exit 1
fi

for startup in \
  "$script_dir/../nomad-cluster/scripts/start-server.sh" \
  "$script_dir/../nomad-cluster/scripts/start-client.sh" \
  "$script_dir/../nomad-cluster/scripts/start-clickhouse.sh" \
  "$script_dir/../modules/nodepool-api/scripts/start-api.sh"; do
  grep -Fq 'systemctl stop e2b-consul-agent-refresh.timer e2b-consul-agent-refresh.service' "$startup"
  grep -Fq 'systemctl mask --runtime e2b-consul-agent-refresh.timer e2b-consul-agent-refresh.service' "$startup"
  grep -Fq 'rm -f -- /run/e2b-consul-agent/boot-ready.json' "$startup"
done

# Exercise the public mode parser: a timer invocation must take the nonblocking
# bootstrap lock before dispatching exactly one refresh with the exact identity
# boundary. This prevents a future grep-only test from passing while the mode
# is unparsed or races metadata bootstrap.
dispatch_calls="$test_root/dispatch.calls"
: >"$dispatch_calls"
acquire_gce_agent_bootstrap_lock() { printf 'lock:%s\n' "$1" >>"$dispatch_calls"; }
refresh_gce_agent_identity() { printf 'refresh:%s\n' "$*" >>"$dispatch_calls"; }
run --refresh-gce-agent --datacenter us-east4 --user root \
  --gce-agent-server-tag-name e2b-orch-server \
  --gce-agent-server-mig-name e2b-orch-server-rig \
  --gce-agent-server-role-label nomad-server \
  --gce-agent-server-service-account e2b-nomad-server@monad-code.iam.gserviceaccount.com
cat >"$test_root/expected-dispatch" <<'EOF'
lock:nonblock
refresh:e2b-orch-server us-east4 root e2b-orch-server-rig nomad-server e2b-nomad-server@monad-code.iam.gserviceaccount.com
EOF
cmp "$test_root/expected-dispatch" "$dispatch_calls"

: >"$dispatch_calls"
reload_gce_agent_identity() { printf 'reload\n' >>"$dispatch_calls"; }
run --reload-gce-agent
grep -Fqx 'reload' "$dispatch_calls"

echo 'Consul GCE agent refresh/reboot regression test passed'
