#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${root_dir}/nomad-cluster/scripts/fetch-gcp-secret.sh"
nomad_script="${root_dir}/nomad-cluster/scripts/run-nomad.sh"
consul_script="${root_dir}/nomad-cluster/scripts/run-consul.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
runtime_root="$work_dir/runtime"
mkdir -p "$runtime_root"

test_helper="$work_dir/fetch-gcp-secret.sh"
sed "s#readonly runtime_root=\"/run\"#readonly runtime_root=\"$runtime_root\"#" \
  "$helper" >"$test_helper"
chmod 0755 "$test_helper"

startup_scripts=(
  "${root_dir}/modules/nodepool-api/scripts/start-api.sh"
  "${root_dir}/nomad-cluster/scripts/start-clickhouse.sh"
  "${root_dir}/nomad-cluster/scripts/start-client.sh"
  "${root_dir}/nomad-cluster/scripts/start-server.sh"
)
startup_terraform=(
  "${root_dir}/modules/nodepool-api/main.tf"
  "${root_dir}/nomad-cluster/nodepool-api.tf"
  "${root_dir}/nomad-cluster/nodepool-clickhouse.tf"
  "${root_dir}/nomad-cluster/nodepool-control-server.tf"
  "${root_dir}/nomad-cluster/nodepool-loki.tf"
  "${root_dir}/nomad-cluster/worker-cluster/nodepool.tf"
)

existing_startup_scripts=()
for path in "${startup_scripts[@]}"; do
  [[ ! -e "$path" ]] || existing_startup_scripts+=("$path")
done
existing_startup_terraform=()
for path in "${startup_terraform[@]}"; do
  [[ ! -e "$path" ]] || existing_startup_terraform+=("$path")
done

if [[ "${#existing_startup_scripts[@]}" -gt 0 ]] && grep -F -e '${NOMAD_TOKEN}' -e '${CONSUL_TOKEN}' \
  -e '${CONSUL_DNS_REQUEST_TOKEN}' -e '${CONSUL_GOSSIP_ENCRYPTION_KEY}' \
  "${existing_startup_scripts[@]}" >/dev/null; then
  printf 'GCE startup scripts must not contain rendered ACL or gossip values.\n' >&2
  exit 1
fi

if [[ "${#existing_startup_terraform[@]}" -gt 0 ]] && grep -E 'var\.(nomad_acl_token_secret|consul_acl_token_secret)([^_A-Za-z0-9]|$)|var\.(consul_dns_request_token_secret_data|consul_gossip_encryption_key_secret_data)([^_A-Za-z0-9]|$)' \
  "${existing_startup_terraform[@]}" >/dev/null; then
  printf 'GCE startup templates must receive Secret Manager names, not payload values.\n' >&2
  exit 1
fi

if grep -F 'NOMAD_TOKEN_SECRET_NAME' \
  "${root_dir}/nomad-cluster/nodepool-api.tf" \
  "${root_dir}/nomad-cluster/nodepool-loki.tf" \
  "${root_dir}/nomad-cluster/nodepool-clickhouse.tf" >/dev/null; then
  printf 'API, Loki, and ClickHouse startup metadata must not receive the Nomad management secret name.\n' >&2
  exit 1
fi

grep -F '%{ if SET_ORCHESTRATOR_VERSION_METADATA == "true" }' \
  "${root_dir}/nomad-cluster/scripts/start-client.sh" >/dev/null

for startup_script in "${existing_startup_scripts[@]}"; do
  grep -F 'fetch-gcp-secret-' "$startup_script" >/dev/null
done

for startup_script in \
  "${root_dir}/modules/nodepool-api/scripts/start-api.sh" \
  "${root_dir}/nomad-cluster/scripts/start-clickhouse.sh" \
  "${root_dir}/nomad-cluster/scripts/start-server.sh"; do
  grep -F -- '--consul-token-file' "$startup_script" >/dev/null
done

worker_startup="${root_dir}/nomad-cluster/scripts/start-client.sh"
grep -F -- '--nomad-server-tag-name' "$worker_startup" >/dev/null
if grep -F -e 'CONSUL_TOKEN_SECRET_NAME' -e 'CONSUL_GOSSIP_SECRET_NAME' \
  -e 'CONSUL_DNS_TOKEN_SECRET_NAME' -e '--consul-token-file' "$worker_startup" >/dev/null; then
  printf 'Worker/build bootstrap must not receive or fetch Consul ACL, gossip, or DNS material.\n' >&2
  exit 1
fi

if grep -E 'nomad node pool apply.*-token|consul acl .* -token|consul acl token create.*-secret|consul acl set-agent-token.*dns_request_token|jq .*--arg .*token' \
  "$nomad_script" "$consul_script" >/dev/null; then
  printf 'Nomad/Consul bootstrap still places ACL material in a child process argument vector.\n' >&2
  exit 1
fi
if grep -E '\$\{TMPDIR:-/tmp\}|mktemp[^\n]*/tmp/' \
  "$helper" "$nomad_script" "$consul_script" >/dev/null; then
  printf 'ACL bootstrap temporary material must remain under /run, never persistent /tmp.\n' >&2
  exit 1
fi

mkdir -p "$work_dir/bin"
cat >"$work_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CURL_ARGV_LOG:?}"
if [[ "$*" == *metadata.google.internal* ]]; then
  output=''
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == '--output' ]]; then
      output="$2"
      break
    fi
    shift
  done
  printf '{"access_token":"adc-access-token-sentinel"}\n' >"$output"
  exit 0
fi
if [[ "${SECRET_FETCH_FAIL:-0}" == 1 ]]; then
  exit 22
fi
config="$2"
output="$(sed -n 's/^output = "\(.*\)"$/\1/p' "$config")"
printf '{"payload":{"data":"%s"}}\n' "${SECRET_DATA_B64:?}" >"$output"
EOF
chmod 0755 "$work_dir/bin/curl"

argv_log="$work_dir/curl.argv"
output_file="$work_dir/acl"
uuid_value='123e4567-e89b-12d3-a456-426614174000'
uuid_b64='MTIzZTQ1NjctZTg5Yi0xMmQzLWE0NTYtNDI2NjE0MTc0MDAw'
PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64="$uuid_b64" \
  bash "$test_helper" 'projects/test/secrets/nomad' "$output_file" uuid

[[ "$(<"$output_file")" == "$uuid_value" ]]
output_mode="$(stat -c '%a' "$output_file" 2>/dev/null || stat -f '%Lp' "$output_file")"
[[ "$output_mode" == 600 ]]
if grep -F -e 'adc-access-token-sentinel' -e "$uuid_value" "$argv_log" >/dev/null; then
  printf 'ADC or ACL payload appeared in curl argv.\n' >&2
  exit 1
fi

failed_output="$work_dir/failed"
if PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64="$uuid_b64" SECRET_FETCH_FAIL=1 \
  bash "$test_helper" 'projects/test/secrets/nomad' "$failed_output" uuid >/dev/null 2>&1; then
  printf 'Secret Manager access failure must fail closed.\n' >&2
  exit 1
fi
[[ ! -e "$failed_output" ]]

gossip_value='AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8='
gossip_b64='QUFFQ0F3UUZCZ2NJQ1FvTERBME9EeEFSRWhNVUZSWVhHQmthR3h3ZEhoOD0='
gossip_output="$work_dir/gossip"
PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64="$gossip_b64" \
  bash "$test_helper" 'projects/test/secrets/gossip' "$gossip_output" consul-gossip-key
[[ "$(<"$gossip_output")" == "$gossip_value" ]]

invalid_uuid="$work_dir/invalid-uuid"
if PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64='bm90LWEtdXVpZA==' \
  bash "$test_helper" 'projects/test/secrets/nomad' "$invalid_uuid" uuid >/dev/null 2>&1; then
  printf 'Malformed UUID secret unexpectedly passed validation.\n' >&2
  exit 1
fi
[[ ! -e "$invalid_uuid" ]]

invalid_gossip="$work_dir/invalid-gossip"
if PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64='YzJodmNuUT0=' \
  bash "$test_helper" 'projects/test/secrets/gossip' "$invalid_gossip" consul-gossip-key >/dev/null 2>&1; then
  printf 'Non-32-byte Consul gossip key unexpectedly passed validation.\n' >&2
  exit 1
fi
[[ ! -e "$invalid_gossip" ]]

# Exercise the Consul DNS-token path with stubbed child processes. The parent
# shell reads secret files; no child argument vector may contain either value.
mkdir -p "$work_dir/bash-commons" "$work_dir/consul-bin"
cat >"$work_dir/bash-commons/assert.sh" <<'EOF'
assert_not_empty() { [[ -n "${2:-}" ]]; }
EOF
cat >"$work_dir/bash-commons/log.sh" <<'EOF'
log_info() { :; }
log_warn() { :; }
log_error() { printf '%s\n' "$1" >&2; }
EOF
: >"$work_dir/bash-commons/os.sh"
sed \
  -e "s#readonly BASH_COMMONS_DIR=.*#readonly BASH_COMMONS_DIR=\"$work_dir/bash-commons\"#" \
  -e "s#readonly BOOTSTRAP_RUNTIME_ROOT=.*#readonly BOOTSTRAP_RUNTIME_ROOT=\"$runtime_root\"#" \
  "$consul_script" >"$work_dir/run-consul.sh"

cat >"$work_dir/consul-bin/consul" <<'EOF'
#!/usr/bin/env bash
printf 'consul %s\n' "$*" >>"${CHILD_ARGV_LOG:?}"
[[ "$(<"${CONSUL_HTTP_TOKEN_FILE:?}")" == 'consul-master-sentinel' ]]
case "$*" in
  'info') exit 0 ;;
  'acl policy read -name=dns-request-policy') exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat >"$work_dir/consul-bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${CHILD_ARGV_LOG:?}"
config="$2"
payload="${6#@}"
grep -Fq 'X-Consul-Token: consul-master-sentinel' "$config"
grep -Fq 'consul-dns-sentinel' "$payload"
EOF
chmod 0755 "$work_dir/consul-bin/consul" "$work_dir/consul-bin/curl"
printf '%s' 'consul-master-sentinel' >"$work_dir/consul-master"
printf '%s' 'consul-dns-sentinel' >"$work_dir/consul-dns"
chmod 0600 "$work_dir/consul-master" "$work_dir/consul-dns"
child_argv_log="$work_dir/child.argv"
PATH="$work_dir/consul-bin:$PATH" CHILD_ARGV_LOG="$child_argv_log" bash -c '
  source "$1"
  consul_token="$(<"$2")"
  dns_token="$(<"$3")"
  setup_dns_resolving "$consul_token" "$dns_token"
' bash "$work_dir/run-consul.sh" "$work_dir/consul-master" "$work_dir/consul-dns"
if grep -F -e 'consul-master-sentinel' -e 'consul-dns-sentinel' "$child_argv_log" >/dev/null; then
  printf 'Consul ACL material appeared in a child process argument vector.\n' >&2
  exit 1
fi
if find "$runtime_root" -mindepth 1 -print -quit | grep -q .; then
  printf 'Consul bootstrap left temporary runtime material behind.\n' >&2
  exit 1
fi

printf 'ACL Secret Manager bootstrap regression test passed.\n'
