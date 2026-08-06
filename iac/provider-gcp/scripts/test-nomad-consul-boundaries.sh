#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly run_nomad="$script_dir/../nomad-cluster/scripts/run-nomad.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/e2b-nomad-consul-config.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

# shellcheck source=/dev/null
source "$run_nomad"
get_instance_name() { echo 'nomad-fixture'; }
get_instance_ip_address() { echo '127.0.0.1'; }
get_instance_region() { echo 'us-east4'; }
get_instance_zone() { echo 'us-east4-c'; }
get_instance_project_id() { echo 'monad-code'; }
get_instance_custom_metadata_value() { return 1; }
chown() { :; }

render_config() {
  local name="$1"
  local server="$2"
  local client="$3"
  local token="$4"
  local config_dir="$test_root/$name"
  mkdir -p "$config_dir"
  generate_nomad_config \
    "$server" "$client" '3' "$config_dir" 'root' "$token" \
    'default' '' '' 'monad-nomad-server' 'orch'
  cp "$config_dir/default.hcl" "$config_dir/validate.hcl"
  printf '\ndata_dir = "/tmp/nomad"\n' >>"$config_dir/validate.hcl"
  if ! docker run --rm \
    -v "$config_dir:/config:ro" \
    -e NOMAD_SKIP_DOCKER_IMAGE_WARN=1 \
    hashicorp/nomad:1.8.4 config validate /config/validate.hcl >/dev/null; then
    echo "Nomad 1.8.4 rejected rendered $name config" >&2
    return 1
  fi
  printf '%s' "$config_dir/default.hcl"
}

server_config="$(render_config server true false '')"
worker_config="$(render_config worker false true '')"
api_config="$(render_config api false true '00000000-0000-0000-0000-000000000111')"

for tokenless_config in "$server_config" "$worker_config"; do
  grep -Fq 'auto_advertise = false' "$tokenless_config"
  grep -Fq 'client_auto_join = false' "$tokenless_config"
  grep -Fq 'server_auto_join = false' "$tokenless_config"
  if grep -Fq 'token =' "$tokenless_config"; then
    echo "tokenless Nomad role rendered a Consul token" >&2
    exit 1
  fi
done

grep -Fq 'server_join {' "$server_config"
grep -Fq 'provider=gce project_name=monad-code tag_value=orch zone_pattern=us-east4-.*' "$server_config"
grep -Fq 'provider=gce project_name=monad-code tag_value=monad-nomad-server zone_pattern=us-east4-.*' "$server_config"
[[ "$(grep -Fc 'provider=gce project_name=monad-code tag_value=' "$server_config")" == 2 ]]
grep -Fq 'server_join {' "$worker_config"

grep -Fq 'auto_advertise = true' "$api_config"
grep -Fq 'client_auto_join = false' "$api_config"
grep -Fq 'server_auto_join = false' "$api_config"
grep -Fq 'token = "00000000-0000-0000-0000-000000000111"' "$api_config"

# Every service-bearing job that can run on a tokenless host must use Nomad's
# native service registry. API and data jobs retain Consul-backed discovery on
# the only roles that receive the narrow sync token.
for job in \
  "$script_dir/../../modules/job-logs-collector/jobs/logs-collector.hcl" \
  "$script_dir/../../modules/job-otel-collector/jobs/otel-collector.hcl" \
  "$script_dir/../../modules/job-otel-collector-nomad-server/jobs/otel-collector-nomad-server.hcl" \
  "$script_dir/../../modules/job-orchestrator/jobs/orchestrator.hcl" \
  "$script_dir/../../modules/job-template-manager/jobs/template-manager.hcl" \
  "$script_dir/../../modules/job-template-manager-autoscaler/jobs/nomad-autoscaler.hcl" \
  "$script_dir/../../modules/job-monad-worker-autoscaler/jobs/monad-worker-autoscaler.hcl"; do
  grep -Fq 'provider = "nomad"' "$job" || {
    printf 'Tokenless-host job still depends on Consul registration: %s\n' "$job" >&2
    exit 1
  }
done

echo 'Nomad and Consul role-boundary config regression test passed'
