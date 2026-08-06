#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${root_dir}/nomad-cluster/scripts/fetch-gcp-secret.sh"
nomad_script="${root_dir}/nomad-cluster/scripts/run-nomad.sh"
consul_script="${root_dir}/nomad-cluster/scripts/run-consul.sh"
gce_identity_script="${root_dir}/nomad-cluster/scripts/consul-gce-agent-identity.sh"
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

for startup_script in \
  "${root_dir}/modules/nodepool-api/scripts/start-api.sh" \
  "${root_dir}/nomad-cluster/scripts/start-clickhouse.sh" \
  "${root_dir}/nomad-cluster/scripts/start-server.sh"; do
  grep -F 'install_setup_script fetch-gcp-secret "${FETCH_GCP_SECRET_FILE_HASH}" /opt/fetch-gcp-secret.sh' \
    "$startup_script" >/dev/null
done

for startup_script in \
  "${root_dir}/modules/nodepool-api/scripts/start-api.sh" \
  "${root_dir}/nomad-cluster/scripts/start-clickhouse.sh"; do
  grep -F -- '--consul-token-file' "$startup_script" >/dev/null
done
grep -F -- '--nomad-server-tag-name' "${root_dir}/nomad-cluster/scripts/start-server.sh" >/dev/null
grep -F -- '--nomad-server-legacy-tag-name "${CLUSTER_TAG_NAME}"' \
  "${root_dir}/nomad-cluster/scripts/start-server.sh" >/dev/null
if grep -F '/opt/nomad/bin/run-nomad.sh' "${root_dir}/nomad-cluster/scripts/start-server.sh" \
  | grep -F -- '--consul-token-file' >/dev/null; then
  printf 'Nomad servers must use GCE retry_join with Consul integration disabled.\n' >&2
  exit 1
fi

worker_startup="${root_dir}/nomad-cluster/scripts/start-client.sh"
grep -F -- '--nomad-server-tag-name' "$worker_startup" >/dev/null
if grep -F -e 'CONSUL_TOKEN_SECRET_NAME' -e 'CONSUL_GOSSIP_SECRET_NAME' \
  -e 'CONSUL_DNS_TOKEN_SECRET_NAME' -e '--consul-token-file' -e 'fetch-gcp-secret' "$worker_startup" >/dev/null; then
  printf 'Worker/build bootstrap must not receive or fetch ACL, gossip, DNS, or management material.\n' >&2
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
set -euo pipefail
printf '%s\n' "$*" >>"${CURL_ARGV_LOG:?}"
[[ "${1:-}" == '--disable' ]]
[[ "$*" == *'--noproxy *'* ]]
for proxy_name in ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy; do
  [[ -z "${!proxy_name+x}" ]]
done
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
config=''
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == '--config' ]]; then
    config="$2"
    break
  fi
  shift
done
[[ -n "$config" ]]
grep -Eq '^url = "https://secretmanager.googleapis.com/v1/projects/test/secrets/[A-Za-z0-9._-]+/versions/[1-9][0-9]*:access"$' "$config"
if grep -Fq '/versions/latest' "$config"; then
  exit 64
fi
output="$(sed -n 's/^output = "\(.*\)"$/\1/p' "$config")"
printf '{"payload":{"data":"%s"}}\n' "${SECRET_DATA_B64:?}" >"$output"
EOF
chmod 0755 "$work_dir/bin/curl"

argv_log="$work_dir/curl.argv"
output_file="$work_dir/acl"
uuid_value='123e4567-e89b-12d3-a456-426614174000'
uuid_b64='MTIzZTQ1NjctZTg5Yi0xMmQzLWE0NTYtNDI2NjE0MTc0MDAw'
if PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64="$uuid_b64" \
  bash "$test_helper" 'projects/test/secrets/nomad' "$output_file" uuid >/dev/null 2>&1; then
  printf 'Secret-only bootstrap reference unexpectedly passed; an immutable promoted version is required.\n' >&2
  exit 1
fi
if PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64="$uuid_b64" \
  bash "$test_helper" 'projects/test/secrets/nomad/versions/latest' "$output_file" uuid >/dev/null 2>&1; then
  printf 'Mutable latest bootstrap reference unexpectedly passed.\n' >&2
  exit 1
fi
PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64="$uuid_b64" \
  ALL_PROXY=http://proxy.invalid HTTP_PROXY=http://proxy.invalid HTTPS_PROXY=http://proxy.invalid \
  CURL_HOME="$work_dir/malicious-curl-home" \
  bash "$test_helper" 'projects/test/secrets/nomad/versions/7' "$output_file" uuid

[[ "$(<"$output_file")" == "$uuid_value" ]]
output_mode="$(stat -c '%a' "$output_file" 2>/dev/null || stat -f '%Lp' "$output_file")"
[[ "$output_mode" == 600 ]]
if grep -F -e 'adc-access-token-sentinel' -e "$uuid_value" "$argv_log" >/dev/null; then
  printf 'ADC or ACL payload appeared in curl argv.\n' >&2
  exit 1
fi

# A rollback is an explicit metadata/template pin to an older enabled version;
# the helper neither lists versions nor follows the mutable latest alias.
rollback_output="$work_dir/acl-rollback"
rollback_uuid='123e4567-e89b-12d3-a456-426614174001'
rollback_b64="$(printf '%s' "$rollback_uuid" | base64 | tr -d '\n')"
PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64="$rollback_b64" \
  bash "$test_helper" 'projects/test/secrets/nomad/versions/6' "$rollback_output" uuid
[[ "$(<"$rollback_output")" == "$rollback_uuid" ]]

failed_output="$work_dir/failed"
if PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64="$uuid_b64" SECRET_FETCH_FAIL=1 \
  bash "$test_helper" 'projects/test/secrets/nomad/versions/7' "$failed_output" uuid >/dev/null 2>&1; then
  printf 'Secret Manager access failure must fail closed.\n' >&2
  exit 1
fi
[[ ! -e "$failed_output" ]]

gossip_value='AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8='
gossip_b64='QUFFQ0F3UUZCZ2NJQ1FvTERBME9EeEFSRWhNVUZSWVhHQmthR3h3ZEhoOD0='
gossip_output="$work_dir/gossip"
PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64="$gossip_b64" \
  bash "$test_helper" 'projects/test/secrets/gossip/versions/3' "$gossip_output" consul-gossip-key
[[ "$(<"$gossip_output")" == "$gossip_value" ]]

invalid_uuid="$work_dir/invalid-uuid"
if PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64='bm90LWEtdXVpZA==' \
  bash "$test_helper" 'projects/test/secrets/nomad/versions/7' "$invalid_uuid" uuid >/dev/null 2>&1; then
  printf 'Malformed UUID secret unexpectedly passed validation.\n' >&2
  exit 1
fi
[[ ! -e "$invalid_uuid" ]]

invalid_gossip="$work_dir/invalid-gossip"
if PATH="$work_dir/bin:$PATH" CURL_ARGV_LOG="$argv_log" SECRET_DATA_B64='YzJodmNuUT0=' \
  bash "$test_helper" 'projects/test/secrets/gossip/versions/3' "$invalid_gossip" consul-gossip-key >/dev/null 2>&1; then
  printf 'Non-32-byte Consul gossip key unexpectedly passed validation.\n' >&2
  exit 1
fi
[[ ! -e "$invalid_gossip" ]]

# Exercise the split Consul DNS, Nomad-client sync, worker-autoscaler, and
# management-candidate paths with stubbed
# child processes. Secrets may appear only in mode-0600 curl config/payload
# files under /run, never in child argument vectors.
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
cp "$gce_identity_script" "$work_dir/consul-gce-agent-identity.sh"

cat >"$work_dir/consul-bin/consul" <<'EOF'
#!/usr/bin/env bash
printf 'consul %s\n' "$*" >>"${CHILD_ARGV_LOG:?}"
[[ "$(<"${CONSUL_HTTP_TOKEN_FILE:?}")" == 'consul-master-sentinel' ]]
case "$*" in
  'info') exit 0 ;;
  'acl policy read -name=dns-request-policy') exit 0 ;;
  'acl policy read -name=register-service-policy') exit 0 ;;
  'acl policy read -name=worker-autoscaler-policy') exit 0 ;;
  'acl policy update -name dns-request-policy -rules '*'dns-request-policy.hcl')
    rules="${*: -1}"
    rules="${rules#@}"
    grep -Fq 'node_prefix ""' "$rules"
    grep -Fq 'service_prefix ""' "$rules"
    ! grep -Fq 'policy = "write"' "$rules"
    ;;
  'acl policy update -name register-service-policy -rules '*'register-service-policy.hcl')
    rules="${*: -1}"
    rules="${rules#@}"
    grep -Fq 'agent_prefix ""' "$rules"
    grep -Fq 'node_prefix ""' "$rules"
    grep -Fq 'service_prefix ""' "$rules"
    [[ "$(grep -Fc 'policy = "read"' "$rules")" == 2 ]]
    [[ "$(grep -Fc 'policy = "write"' "$rules")" == 1 ]]
    ! grep -Eq '(^|[[:space:]])(acl|key)(_prefix)?[[:space:]]' "$rules"
    ;;
  'acl policy update -name worker-autoscaler-policy -rules '*'worker-autoscaler-policy.hcl')
    rules="${*: -1}"
    rules="${rules#@}"
    grep -Fq 'key_prefix "service/monad-worker-autoscaler/"' "$rules"
    grep -Fq 'session_prefix ""' "$rules"
    [[ "$(grep -Fc 'policy = "write"' "$rules")" == 2 ]]
    ! grep -Eq '(^|[[:space:]])(acl|agent|node|service)(_prefix)?[[:space:]]' "$rules"
    ;;
  *) exit 1 ;;
esac
EOF
cat >"$work_dir/consul-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"${CHILD_ARGV_LOG:?}"
[[ "${1:-}" == '--disable' ]]
[[ "$*" == *'--noproxy *'* ]]
for proxy_name in ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy; do
  [[ -z "${!proxy_name+x}" ]]
done
request_args="$*"
config=''
output=''
payload=''
url="${*: -1}"
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == '--config' ]]; then
    config="$2"
    shift
  elif [[ "$1" == '--output' ]]; then
    output="$2"
    shift
  elif [[ "$1" == '--data-binary' ]]; then
    payload="${2#@}"
    shift
  fi
  shift
done
[[ -n "$config" ]]

if [[ -n "$output" && "$url" == */v1/acl/token/self ]]; then
  if grep -Fq 'X-Consul-Token: consul-dns-sentinel' "$config"; then
    printf '%s\n' '{"AccessorID":"11111111-1111-1111-1111-111111111111","Description":"E2B Consul DNS token","Policies":[{"Name":"dns-request-policy"}]}' >"$output"
  elif grep -Fq 'X-Consul-Token: consul-sync-sentinel' "$config"; then
    printf '%s\n' '{"AccessorID":"22222222-2222-2222-2222-222222222222","Description":"E2B Consul Nomad-client sync token","Policies":[{"Name":"register-service-policy"}]}' >"$output"
  elif grep -Fq 'X-Consul-Token: consul-autoscaler-sentinel' "$config"; then
    printf '%s\n' '{"AccessorID":"33333333-3333-3333-3333-333333333333","Description":"E2B Consul worker-autoscaler token","Policies":[{"Name":"worker-autoscaler-policy"}]}' >"$output"
  elif grep -Fq 'X-Consul-Token: consul-candidate-sentinel' "$config"; then
    [[ -f "${ROTATION_REGISTERED:?}" ]] || exit 22
    printf '%s\n' '{"AccessorID":"44444444-4444-4444-4444-444444444444","Description":"E2B Consul promoted management token","Policies":[{"Name":"global-management"}]}' >"$output"
  else
    exit 1
  fi
  exit 0
fi

if ! grep -Fq 'X-Consul-Token: consul-master-sentinel' "$config"; then
  grep -Fq 'X-Consul-Token: consul-candidate-sentinel' "$config"
  [[ -f "${ROTATION_REGISTERED:?}" ]]
fi

if [[ -n "$output" && "$url" == */v1/kv/e2b/acl-lineage/management\?raw ]]; then
  [[ -f "${ROTATION_LINEAGE:?}" ]]
  cp "${ROTATION_LINEAGE:?}" "$output"
  exit 0
fi

if [[ -n "$output" && "$url" == */v1/acl/tokens ]]; then
  printf '%s\n' '[{"AccessorID":"11111111-1111-1111-1111-111111111111","Description":"E2B Consul DNS token"},{"AccessorID":"22222222-2222-2222-2222-222222222222","Description":"E2B Consul Nomad-client sync token"},{"AccessorID":"33333333-3333-3333-3333-333333333333","Description":"E2B Consul worker-autoscaler token"},{"AccessorID":"44444444-4444-4444-4444-444444444444","Description":"E2B Consul promoted management token"},{"AccessorID":"55555555-5555-5555-5555-555555555555","Description":"E2B Consul promoted management token"}]' >"$output"
  exit 0
fi

if [[ "$url" == */v1/acl/token/55555555-5555-5555-5555-555555555555 ]]; then
  if [[ "$request_args" == *'--request DELETE'* ]]; then
    : >"${ROTATION_REVOKED:?}"
    exit 0
  fi
  [[ ! -f "${ROTATION_REVOKED:?}" ]] || exit 22
  [[ -n "$output" ]] && printf '%s\n' '{"AccessorID":"55555555-5555-5555-5555-555555555555"}' >"$output"
  exit 0
fi

if [[ "$url" == */v1/acl/token && -n "$payload" ]] \
  && grep -Fq 'consul-candidate-sentinel' "$payload"; then
  jq -e '
    .Description == "E2B Consul promoted management token"
    and ([.Policies[].Name] | sort) == ["global-management"]
  ' "$payload" >/dev/null
  : >"${ROTATION_REGISTERED:?}"
  exit 0
fi

[[ -n "$payload" ]]
case "$url" in
  */v1/acl/token/11111111-1111-1111-1111-111111111111)
    grep -Fq 'consul-dns-sentinel' "$payload"
    jq -e '([.Policies[].Name] | sort) == ["dns-request-policy"]' "$payload" >/dev/null
    ;;
  */v1/acl/token/22222222-2222-2222-2222-222222222222)
    grep -Fq 'consul-sync-sentinel' "$payload"
    jq -e '([.Policies[].Name] | sort) == ["register-service-policy"]' "$payload" >/dev/null
    ;;
  */v1/acl/token/33333333-3333-3333-3333-333333333333)
    grep -Fq 'consul-autoscaler-sentinel' "$payload"
    jq -e '([.Policies[].Name] | sort) == ["worker-autoscaler-policy"]' "$payload" >/dev/null
    ;;
  */v1/kv/e2b/acl-lineage/dns)
    jq -e '.version_resource == "projects/test/secrets/dns/versions/4"' "$payload" >/dev/null
    ;;
  */v1/kv/e2b/acl-lineage/nomad-client-sync)
    jq -e '.version_resource == "projects/test/secrets/sync/versions/5"' "$payload" >/dev/null
    ;;
  */v1/kv/e2b/acl-lineage/worker-autoscaler)
    jq -e '.version_resource == "projects/test/secrets/autoscaler/versions/6"' "$payload" >/dev/null
    ;;
  */v1/kv/e2b/acl-lineage/management)
    if [[ -f "${ROTATION_REVOKED:?}" ]]; then
      jq -e '
        .version_resource == "projects/test/secrets/candidate/versions/7"
        and .current_accessor == "44444444-4444-4444-4444-444444444444"
        and .superseded_accessors == []
        and .revoked_accessors == ["55555555-5555-5555-5555-555555555555"]
      ' "$payload" >/dev/null
    else
      jq -e '
        .version_resource == "projects/test/secrets/candidate/versions/7"
        and .current_accessor == "44444444-4444-4444-4444-444444444444"
        and .superseded_accessors == ["55555555-5555-5555-5555-555555555555"]
        and .revoked_accessors == []
      ' "$payload" >/dev/null
    fi
    cp "$payload" "${ROTATION_LINEAGE:?}"
    ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$work_dir/consul-bin/consul" "$work_dir/consul-bin/curl"
printf '%s' 'consul-master-sentinel' >"$work_dir/consul-master"
printf '%s' 'consul-dns-sentinel' >"$work_dir/consul-dns"
printf '%s' 'consul-sync-sentinel' >"$work_dir/consul-sync"
printf '%s' 'consul-autoscaler-sentinel' >"$work_dir/consul-autoscaler"
printf '%s' 'consul-candidate-sentinel' >"$work_dir/consul-candidate"
chmod 0600 "$work_dir/consul-master" "$work_dir/consul-dns" "$work_dir/consul-sync" \
  "$work_dir/consul-autoscaler" "$work_dir/consul-candidate"
child_argv_log="$work_dir/child.argv"
rotation_registered="$work_dir/rotation.registered"
rotation_revoked="$work_dir/rotation.revoked"
rotation_lineage="$work_dir/rotation.lineage"
PATH="$work_dir/consul-bin:$PATH" CHILD_ARGV_LOG="$child_argv_log" \
  ALL_PROXY=http://proxy.invalid HTTP_PROXY=http://proxy.invalid HTTPS_PROXY=http://proxy.invalid \
  ROTATION_REGISTERED="$rotation_registered" ROTATION_REVOKED="$rotation_revoked" \
  ROTATION_LINEAGE="$rotation_lineage" bash -c '
  source "$1"
  consul_token="$(<"$2")"
  dns_token="$(<"$3")"
  sync_token="$(<"$4")"
  autoscaler_token="$(<"$5")"
  candidate_token="$(<"$6")"
  setup_dns_resolving \
    "$consul_token" \
    "$dns_token" "projects/test/secrets/dns/versions/4" \
    "$sync_token" "projects/test/secrets/sync/versions/5" \
    "$autoscaler_token" "projects/test/secrets/autoscaler/versions/6"
  setup_management_access \
    "$consul_token" "$candidate_token" \
    "projects/test/secrets/candidate/versions/7"
  [[ -f "${ROTATION_REGISTERED:?}" && ! -f "${ROTATION_REVOKED:?}" ]]
  retire_consul_token_lineage \
    "$candidate_token" "$candidate_token" \
    "E2B Consul promoted management token" "management" \
    "projects/test/secrets/candidate/versions/7"
' bash "$work_dir/run-consul.sh" "$work_dir/consul-master" "$work_dir/consul-dns" \
  "$work_dir/consul-sync" "$work_dir/consul-autoscaler" "$work_dir/consul-candidate"
if grep -F -e 'consul-master-sentinel' -e 'consul-dns-sentinel' -e 'consul-sync-sentinel' \
  -e 'consul-autoscaler-sentinel' -e 'consul-candidate-sentinel' \
  "$child_argv_log" >/dev/null; then
  printf 'Consul ACL material appeared in a child process argument vector.\n' >&2
  exit 1
fi
[[ -f "$rotation_registered" && -f "$rotation_revoked" ]] || {
  printf 'Consul management rotation did not exercise create and superseded-token revocation.\n' >&2
  exit 1
}
if find "$runtime_root" -mindepth 1 -print -quit | grep -q .; then
  printf 'Consul bootstrap left temporary runtime material behind.\n' >&2
  exit 1
fi

printf 'ACL Secret Manager bootstrap regression test passed.\n'
