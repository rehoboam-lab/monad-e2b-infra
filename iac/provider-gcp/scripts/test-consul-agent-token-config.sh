#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly consul_script="$script_dir/../nomad-cluster/scripts/run-consul.sh"
readonly gce_identity_script="$script_dir/../nomad-cluster/scripts/consul-gce-agent-identity.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/e2b-consul-agent-token.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/bash-commons" "$test_root/client" "$test_root/server" "$test_root/runtime"
cat >"$test_root/bash-commons/assert.sh" <<'EOF'
assert_not_empty() { [[ -n "${2:-}" ]]; }
EOF
cat >"$test_root/bash-commons/log.sh" <<'EOF'
log_info() { :; }
log_warn() { :; }
log_error() { printf '%s\n' "$1" >&2; }
EOF
: >"$test_root/bash-commons/os.sh"
sed \
  -e "s#readonly BASH_COMMONS_DIR=.*#readonly BASH_COMMONS_DIR=\"$test_root/bash-commons\"#" \
  -e "s#readonly BOOTSTRAP_RUNTIME_ROOT=.*#readonly BOOTSTRAP_RUNTIME_ROOT=\"$test_root/runtime\"#" \
  "$consul_script" >"$test_root/run-consul.sh"
cp "$gce_identity_script" "$test_root/consul-gce-agent-identity.sh"

# shellcheck source=/dev/null
source "$test_root/run-consul.sh"
get_instance_ip_address() { echo '10.0.0.10'; }
get_instance_id() { echo '1234567890123456789'; }
get_instance_name() { echo 'consul-fixture'; }
get_instance_region() { echo 'us-east4'; }
get_instance_project_id() { echo 'monad-code'; }
get_instance_custom_metadata_value() { echo '3'; }
chown() { :; }

render_config() {
  local server="$1"
  local config_dir="$2"
  local agent_token="$3"
  generate_consul_config \
    "$server" '00000000-0000-0000-0000-000000000002' \
    "$config_dir" root monad-cluster cluster-size us-east4 \
    false '' false false '' '' '' \
    true 200ms 250 10s az false '' "$agent_token"
}

render_config false "$test_root/client" ''
render_config true "$test_root/server" ''

jq -e '
  .node_name == "1234567890123456789"
  and .client_addr == "127.0.0.1"
  and .addresses == {
    dns:"0.0.0.0",
    http:"127.0.0.1",
    https:"127.0.0.1",
    grpc:"127.0.0.1"
  }
  and
  .acl.default_policy == "deny"
  and .acl.tokens == {"dns":"00000000-0000-0000-0000-000000000002"}
  and (.acl.tokens | has("agent") | not)
  and (.acl.tokens | has("default") | not)
' "$test_root/client/default.json" >/dev/null
jq -e '
  .node_name == "1234567890123456789"
  and .client_addr == "127.0.0.1"
  and .addresses.http == "127.0.0.1"
  and .addresses.dns == "0.0.0.0"
  and .acl.tokens == {"dns":"00000000-0000-0000-0000-000000000002"}
  and (.acl.tokens | has("agent") | not)
  and (.acl.tokens | has("default") | not)
' "$test_root/server/default.json" >/dev/null

for config in "$test_root/client/default.json" "$test_root/server/default.json"; do
  mode="$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config")"
  [[ "$mode" == 600 ]]
done

echo 'Consul agent-token configuration regression test passed'
