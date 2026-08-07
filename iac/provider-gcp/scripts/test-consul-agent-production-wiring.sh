#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly provider_root="$script_dir/.."
readonly run_consul="$provider_root/nomad-cluster/scripts/run-consul.sh"
readonly identity_helper="$provider_root/nomad-cluster/scripts/consul-gce-agent-identity.sh"
readonly cluster_main="$provider_root/nomad-cluster/main.tf"

grep -Fq 'source "$SCRIPT_DIR/consul-gce-agent-identity.sh"' "$run_consul"
grep -Fq 'setup_gce_agent_auth' "$run_consul"
grep -Fq 'acquire_gce_agent_identity "$datacenter" "$user"' "$run_consul"
grep -Fq 'install_gce_agent_refresh_timer' "$run_consul"
grep -Fq 'Static/shared Consul agent tokens are forbidden' "$run_consul"
if grep -Fq 'consul_agent_token="$nomad_client_token"' "$run_consul"; then
  printf 'Nomad service-sync token is still reused as the Consul agent token.\n' >&2
  exit 1
fi

grep -Fq '/instance/service-accounts/default/identity' "$identity_helper"
grep -Fq '/v1/acl/login' "$identity_helper"
grep -Fq 'BindType:"node"' "$identity_helper"
grep -Fq 'ConditionPathExists=$GCE_AGENT_BOOT_READY' "$identity_helper"
if grep -Eiq 'rpc[-_ ]tls|grpc_tls|verify_(incoming|outgoing)' "$identity_helper"; then
  printf 'GCE agent helper contains out-of-scope RPC TLS work.\n' >&2
  exit 1
fi

grep -Fq '"scripts/consul-gce-agent-identity.sh"' "$cluster_main"
for startup in \
  "$provider_root/nomad-cluster/scripts/start-server.sh" \
  "$provider_root/nomad-cluster/scripts/start-clickhouse.sh" \
  "$provider_root/modules/nodepool-api/scripts/start-api.sh"; do
  grep -Fq 'install_setup_script consul-gce-agent-identity' "$startup"
  grep -Fq 'systemctl stop e2b-consul-agent-refresh.timer' "$startup"
done
grep -Fq -- '--gce-agent-service-account' \
  "$provider_root/nomad-cluster/scripts/start-server.sh"

printf 'Consul GCE agent production wiring regression test passed\n'
