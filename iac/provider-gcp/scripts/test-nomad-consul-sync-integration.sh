#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly test_root_raw="$(mktemp -d "${TMPDIR:-/tmp}/e2b-nomad-consul-sync.XXXXXX")"
readonly test_root="$(cd "$test_root_raw" && pwd -P)"
readonly suffix="$(basename "$test_root" | tr -cd 'a-zA-Z0-9' | tail -c 12)"
readonly network_name="e2b-acl-sync-$suffix"
readonly consul_name="e2b-consul-$suffix"
readonly consul_client_name="e2b-consul-client-$suffix"
readonly nomad_server_name="e2b-nomad-server-$suffix"
readonly nomad_client_name="e2b-nomad-client-$suffix"
readonly management_token='11111111-1111-4111-8111-111111111111'
readonly dns_token='22222222-2222-4222-8222-222222222222'
readonly sync_token='33333333-3333-4333-8333-333333333333'
readonly consul_client_instance_id='1234567890123456789'
readonly gce_identity_audience='https://consul.monad-code.internal/e2b/gce-agent'
readonly gce_identity_issuer='https://accounts.google.com'
readonly gce_identity_service_account='e2b-api-controller@monad-code.iam.gserviceaccount.com'
readonly host_uid="$(id -u)"
readonly host_gid="$(id -g)"

cleanup() {
  status=$?
  if [[ "$status" -ne 0 ]]; then
    for failed_container in "$nomad_client_name" "$nomad_server_name" "$consul_client_name" "$consul_name"; do
      docker logs "$failed_container" 2>&1 | tail -80 >&2 || true
    done
  fi
  docker rm -f "$nomad_client_name" "$nomad_server_name" "$consul_client_name" "$consul_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  rm -rf -- "$test_root"
  return "$status"
}
trap cleanup EXIT HUP INT TERM

wait_until() {
  local description="$1"
  shift
  local attempt
  for attempt in $(seq 1 90); do
    if "$@"; then
      return 0
    fi
    sleep 1
  done
  printf 'timed out waiting for %s\n' "$description" >&2
  return 1
}

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

docker network create "$network_name" >/dev/null
mkdir -p \
  "$test_root/consul" "$test_root/consul-data" \
  "$test_root/consul-client" "$test_root/consul-client-data" \
  "$test_root/nomad-server" "$test_root/nomad-client"

cat >"$test_root/consul/config.json" <<EOF
{
  "datacenter": "dc1",
  "server": true,
  "bootstrap_expect": 1,
  "bind_addr": "0.0.0.0",
  "client_addr": "0.0.0.0",
  "acl": {
    "enabled": true,
    "default_policy": "deny",
    "enable_token_persistence": true,
    "tokens": {
      "initial_management": "$management_token"
    }
  }
}
EOF
chmod 0600 "$test_root/consul/config.json"

docker run -d \
  --name "$consul_name" \
  --user "$host_uid:$host_gid" \
  -e CONSUL_DISABLE_PERM_MGMT=1 \
  --network "$network_name" \
  -p 127.0.0.1::8500 \
  -p 127.0.0.1::8600/udp \
  -v "$test_root/consul:/test-config:ro" \
  -v "$test_root/consul-data:/consul/data" \
  hashicorp/consul:1.17.3 \
  agent -config-file=/test-config/config.json -data-dir=/consul/data >/dev/null

readonly consul_http_port="$(docker port "$consul_name" 8500/tcp | awk -F: 'NR == 1 {print $NF}')"
readonly consul_http="http://127.0.0.1:$consul_http_port"

consul_management_curl() {
  curl -fsS -H "X-Consul-Token: $management_token" "$@"
}
consul_service_count() {
  local service="$1"
  consul_management_curl "$consul_http/v1/catalog/service/$service" | jq -e 'length == 1' >/dev/null
}
consul_service_absent() {
  local service="$1"
  consul_management_curl "$consul_http/v1/catalog/service/$service" | jq -e 'length == 0' >/dev/null
}
wait_until 'Consul leader' bash -c \
  "curl -fsS -H 'X-Consul-Token: $management_token' '$consul_http/v1/status/leader' | grep -vq '\"\"'"

cat >"$test_root/dns-policy.json" <<'EOF'
{"Name":"dns-request-policy","Rules":"node_prefix \"\" { policy = \"read\" }\nservice_prefix \"\" { policy = \"read\" }"}
EOF
cat >"$test_root/sync-policy.json" <<'EOF'
{"Name":"nomad-client-sync-policy","Rules":"agent_prefix \"\" { policy = \"read\" }\nnode_prefix \"\" { policy = \"read\" }\nservice_prefix \"\" { policy = \"write\" }"}
EOF
consul_management_curl -X PUT --data-binary @"$test_root/dns-policy.json" "$consul_http/v1/acl/policy" >/dev/null
consul_management_curl -X PUT --data-binary @"$test_root/sync-policy.json" "$consul_http/v1/acl/policy" >/dev/null

jq -n --arg token "$dns_token" \
  '{SecretID:$token,Description:"DNS harness",Policies:[{Name:"dns-request-policy"}]}' \
  >"$test_root/dns-token.json"
jq -n --arg token "$sync_token" \
  '{SecretID:$token,Description:"Nomad client sync harness",Policies:[{Name:"nomad-client-sync-policy"}]}' \
  >"$test_root/sync-token.json"
consul_management_curl -X PUT --data-binary @"$test_root/dns-token.json" "$consul_http/v1/acl/token" >/dev/null
consul_management_curl -X PUT --data-binary @"$test_root/sync-token.json" "$consul_http/v1/acl/token" >/dev/null
jq -n --arg token "$dns_token" '{Token:$token}' >"$test_root/agent-dns-token.json"
consul_management_curl -X PUT --data-binary @"$test_root/agent-dns-token.json" "$consul_http/v1/agent/token/dns" >/dev/null

# Model the production GCE instance-identity exchange with a locally signed
# full-format JWT. Consul verifies signature, issuer, audience, project, zone,
# service account, and then binds the signed immutable instance ID to an exact
# node identity. The Nomad service-sync token stays separate.
openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$test_root/gce-identity-private.pem"
openssl pkey -in "$test_root/gce-identity-private.pem" -pubout \
  -out "$test_root/gce-identity-public.pem" >/dev/null 2>&1
issued_at="$(date +%s)"
expires_at="$((issued_at + 600))"
jwt_header="$({ jq -nc '{alg:"RS256",typ:"JWT"}'; } | base64url)"
jwt_payload="$(
  jq -nc \
    --arg issuer "$gce_identity_issuer" \
    --arg audience "$gce_identity_audience" \
    --arg email "$gce_identity_service_account" \
    --arg instance_id "$consul_client_instance_id" \
    --argjson issued_at "$issued_at" \
    --argjson expires_at "$expires_at" '
      {
        iss:$issuer,
        aud:$audience,
        sub:"fixture-service-account-subject",
        azp:"fixture-service-account-subject",
        email:$email,
        email_verified:true,
        iat:$issued_at,
        exp:$expires_at,
        google:{compute_engine:{
          project_id:"monad-code",
          project_number:883250301766,
          zone:"us-east4-c",
          instance_id:$instance_id,
          instance_name:"e2b-orch-api-fixture",
          instance_creation_timestamp:$issued_at
        }}
      }
    ' | base64url
)"
printf '%s' "$jwt_header.$jwt_payload" >"$test_root/gce-identity-signing-input"
openssl dgst -sha256 -sign "$test_root/gce-identity-private.pem" \
  -out "$test_root/gce-identity-signature" "$test_root/gce-identity-signing-input"
gce_identity_jwt="$jwt_header.$jwt_payload.$(base64url <"$test_root/gce-identity-signature")"

jq -n --rawfile public_key "$test_root/gce-identity-public.pem" \
  --arg audience "$gce_identity_audience" \
  --arg issuer "$gce_identity_issuer" '
    {
      Name:"gce-instance-identity",
      Type:"jwt",
      Description:"Attested GCE Consul agent identity",
      Config:{
        JWTValidationPubKeys:[$public_key],
        BoundAudiences:[$audience],
        BoundIssuer:$issuer,
        JWTSupportedAlgs:["RS256"],
        ClaimMappings:{
          "/google/compute_engine/project_id":"project_id",
          "/google/compute_engine/zone":"zone",
          "/google/compute_engine/instance_id":"instance_id",
          "email":"service_account_email",
          "email_verified":"email_verified"
        }
      }
    }
  ' >"$test_root/gce-auth-method.json"
consul_management_curl -X PUT --data-binary @"$test_root/gce-auth-method.json" \
  "$consul_http/v1/acl/auth-method/gce-instance-identity" >/dev/null
jq -n --arg email "$gce_identity_service_account" '
  {
    Description:"Exact GCE agent node identity",
    AuthMethod:"gce-instance-identity",
    Selector:(
      "value.project_id == \"monad-code\" and "
      + "value.zone == \"us-east4-c\" and "
      + "value.service_account_email == \"" + $email + "\" and "
      + "value.email_verified == \"true\""
    ),
    BindType:"node",
    BindName:"${value.instance_id}"
  }
' >"$test_root/gce-binding-rule.json"
consul_management_curl -X PUT --data-binary @"$test_root/gce-binding-rule.json" \
  "$consul_http/v1/acl/binding-rule" >/dev/null
jq -n --arg bearer "$gce_identity_jwt" \
  '{AuthMethod:"gce-instance-identity",BearerToken:$bearer}' \
  >"$test_root/gce-login.json"
curl -fsS -X POST --data-binary @"$test_root/gce-login.json" \
  "$consul_http/v1/acl/login" >"$test_root/gce-agent-token.json"
agent_token="$(jq -er '.SecretID | select(test("^[0-9A-Fa-f-]{36}$"))' \
  "$test_root/gce-agent-token.json")"
jq -e --arg node "$consul_client_instance_id" '
  .Local == true
  and (.Policies // []) == []
  and (.Roles // []) == []
  and (.ServiceIdentities // []) == []
  and .NodeIdentities == [{NodeName:$node,Datacenter:"dc1"}]
' "$test_root/gce-agent-token.json" >/dev/null

cat >"$test_root/consul-client/config.json" <<EOF
{
  "datacenter": "dc1",
  "node_name": "$consul_client_instance_id",
  "server": false,
  "bind_addr": "0.0.0.0",
  "client_addr": "0.0.0.0",
  "retry_join": ["$consul_name"],
  "acl": {
    "enabled": true,
    "default_policy": "deny",
    "enable_token_persistence": true,
    "tokens": {
      "dns": "$dns_token",
      "agent": "$agent_token"
    }
  }
}
EOF
chmod 0600 "$test_root/consul-client/config.json"
docker run -d \
  --name "$consul_client_name" \
  --user "$host_uid:$host_gid" \
  -e CONSUL_DISABLE_PERM_MGMT=1 \
  --hostname "$consul_client_name" \
  --network "$network_name" \
  -p 127.0.0.1::8500 \
  -p 127.0.0.1::8600/udp \
  -v "$test_root/consul-client:/test-config:ro" \
  -v "$test_root/consul-client-data:/consul/data" \
  hashicorp/consul:1.17.3 \
  agent -config-file=/test-config/config.json -data-dir=/consul/data >/dev/null
readonly consul_client_http_port="$(docker port "$consul_client_name" 8500/tcp | awk -F: 'NR == 1 {print $NF}')"
readonly consul_dns_port="$(docker port "$consul_client_name" 8600/udp | awk -F: 'NR == 1 {print $NF}')"
readonly consul_client_http="http://127.0.0.1:$consul_client_http_port"
wait_until 'Consul client join' bash -c \
  "curl -fsS -H 'X-Consul-Token: $sync_token' '$consul_client_http/v1/agent/self' | jq -e '.Config.Server == false' >/dev/null"

# The internal agent token can update only the JWT-bound node. It cannot write
# a sibling identity, ACLs, KV, or services.
jq -n --arg node "$consul_client_instance_id" \
  '{Node:$node,Address:"192.0.2.10"}' >"$test_root/own-node.json"
jq -n '{Node:"9876543210987654321",Address:"192.0.2.11"}' \
  >"$test_root/other-node.json"
[[ "$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "X-Consul-Token: $agent_token" -X PUT \
  --data-binary @"$test_root/own-node.json" \
  "$consul_http/v1/catalog/register")" == 200 ]]
[[ "$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "X-Consul-Token: $agent_token" -X PUT \
  --data-binary @"$test_root/other-node.json" \
  "$consul_http/v1/catalog/register")" == 403 ]]

# Anonymous and DNS-only callers cannot poison service discovery. The Nomad
# client sync token has no KV or ACL-management capability.
cat >"$test_root/poison-service.json" <<'EOF'
{"Name":"poison","ID":"poison","Address":"203.0.113.10","Port":1}
EOF
for auth_header in '' "X-Consul-Token: $dns_token"; do
  curl_args=(-sS -o /dev/null -w '%{http_code}' -X PUT --data-binary @"$test_root/poison-service.json")
  [[ -z "$auth_header" ]] || curl_args+=(-H "$auth_header")
  status="$(curl "${curl_args[@]}" "$consul_client_http/v1/agent/service/register")"
  [[ "$status" == 403 ]]
done
[[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Consul-Token: $sync_token" \
  -X PUT --data 'poison' "$consul_client_http/v1/kv/e2b/poison")" == 403 ]]
[[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Consul-Token: $sync_token" \
  "$consul_client_http/v1/acl/tokens")" == 403 ]]
[[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Consul-Token: $sync_token" \
  "$consul_client_http/v1/agent/services")" == 200 ]]

cat >"$test_root/nomad-server/server.hcl" <<'EOF'
datacenter = "dc1"
region = "global"
bind_addr = "0.0.0.0"
data_dir = "/nomad/data"
server {
  enabled = true
  bootstrap_expect = 1
}
client { enabled = false }
consul {
  auto_advertise = false
  client_auto_join = false
  server_auto_join = false
}
EOF
cat >"$test_root/nomad-client/client.hcl" <<EOF
datacenter = "dc1"
region = "global"
bind_addr = "0.0.0.0"
data_dir = "/nomad/data"
server { enabled = false }
client {
  enabled = true
  cpu_total_compute = 10000
  memory_total_mb = 2048
  server_join {
    retry_join = ["$nomad_server_name:4647"]
    retry_interval = "1s"
    retry_max = 60
  }
}
plugin "raw_exec" { config { enabled = true } }
consul {
  address = "$consul_client_name:8500"
  token = "$sync_token"
  auto_advertise = true
  client_auto_join = false
  server_auto_join = false
}
EOF
chmod 0600 "$test_root/nomad-server/server.hcl" "$test_root/nomad-client/client.hcl"

docker run -d \
  --name "$nomad_server_name" \
  --hostname "$nomad_server_name" \
  --network "$network_name" \
  -p 127.0.0.1::4646 \
  -v "$test_root/nomad-server:/test-config:ro" \
  -e NOMAD_SKIP_DOCKER_IMAGE_WARN=1 \
  hashicorp/nomad:1.8.4 agent -config=/test-config/server.hcl >/dev/null
readonly nomad_http_port="$(docker port "$nomad_server_name" 4646/tcp | awk -F: 'NR == 1 {print $NF}')"
readonly nomad_http="http://127.0.0.1:$nomad_http_port"
wait_until 'Nomad server leader' bash -c "curl -fsS '$nomad_http/v1/status/leader' | grep -vq '\"\"'"

docker run -d \
  --privileged \
  --cgroupns=host \
  --name "$nomad_client_name" \
  --hostname "$nomad_client_name" \
  --network "$network_name" \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$test_root/nomad-client:/test-config:ro" \
  -e NOMAD_SKIP_DOCKER_IMAGE_WARN=1 \
  hashicorp/nomad:1.8.4 agent -config=/test-config/client.hcl >/dev/null
wait_until 'ready Nomad client' bash -c \
  "curl -fsS '$nomad_http/v1/nodes' | jq -e 'map(select(.Status == \"ready\")) | length == 1' >/dev/null"
wait_until 'Nomad client with schedulable CPU' bash -c \
  "node_id=\$(curl -fsS '$nomad_http/v1/nodes' | jq -er 'map(select(.Status == \"ready\"))[0].ID'); curl -fsS '$nomad_http/v1/node/'\"\$node_id\" | jq -e '((.NodeResources.Cpu.CpuShares // .Resources.CPU // 0) | tonumber) > 0' >/dev/null"
wait_until 'auto-advertised Nomad client service' consul_service_count nomad-client

cat >"$test_root/service.nomad.hcl" <<'EOF'
job "acl-sync-harness" {
  datacenters = ["dc1"]
  type = "service"
  group "service" {
    network {
      port "http" {
        static = 18080
      }
    }
    service {
      name = "acl-sync-harness"
      port = "http"
      provider = "consul"
    }
    task "sleep" {
      driver = "raw_exec"
      resources {
        cpu    = 50
        memory = 32
      }
      config {
        command = "/bin/sh"
        args = ["-c", "sleep 300"]
      }
    }
  }
}
EOF
docker cp "$test_root/service.nomad.hcl" "$nomad_server_name:/tmp/service.nomad.hcl"
docker exec "$nomad_server_name" nomad job run -detach /tmp/service.nomad.hcl >/dev/null
wait_until 'running Nomad allocation' bash -c \
  "curl -fsS '$nomad_http/v1/job/acl-sync-harness/allocations' | jq -e 'any(.[]; .ClientStatus == \"running\")' >/dev/null"
wait_until 'Consul-backed Nomad allocation service' consul_service_count acl-sync-harness

dns_answer="$(dig @127.0.0.1 -p "$consul_dns_port" +short acl-sync-harness.service.consul A)"
[[ -n "$dns_answer" ]]

# A hard-killed client may leave a stale allocation registration. Restart must
# reconcile it to one entry, not duplicate it.
docker kill --signal KILL "$nomad_client_name" >/dev/null
docker start "$nomad_client_name" >/dev/null
wait_until 'Nomad client recovery' bash -c \
  "curl -fsS '$nomad_http/v1/nodes' | jq -e 'map(select(.Status == \"ready\")) | length == 1' >/dev/null"
wait_until 'single recovered Consul service' consul_service_count acl-sync-harness
docker exec "$nomad_server_name" nomad job stop -purge acl-sync-harness >/dev/null
cleanup_started="$(date +%s)"
wait_until 'Consul allocation-service deregistration' consul_service_absent acl-sync-harness
allocation_cleanup_seconds=$(($(date +%s) - cleanup_started))
if [[ -n "$(dig @127.0.0.1 -p "$consul_dns_port" +short acl-sync-harness.service.consul A)" ]]; then
  echo 'purged allocation remained discoverable through Consul DNS' >&2
  exit 1
fi

# Graceful Nomad shutdown clears its auto-advertised service through the
# separate Consul agent token. The agent remains up to perform anti-entropy.
cleanup_started="$(date +%s)"
docker stop --time 20 "$nomad_client_name" >/dev/null
wait_until 'Nomad client catalog cleanup' consul_service_absent nomad-client
nomad_cleanup_seconds=$(($(date +%s) - cleanup_started))
if [[ -n "$(dig @127.0.0.1 -p "$consul_dns_port" +short nomad-client.service.consul A)" ]]; then
  echo 'stopped Nomad client remained discoverable through Consul DNS' >&2
  exit 1
fi

# Tokenless Nomad server logs must contain no Consul ACL failures or service
# registrations. The only Nomad service registered is the API/data-shaped
# client using the bounded sync token.
if docker logs "$nomad_server_name" 2>&1 | grep -Ei 'consul.*(403|permission denied|acl)'; then
  echo 'tokenless Nomad server attempted unauthorized Consul integration' >&2
  exit 1
fi
if docker logs "$consul_client_name" 2>&1 \
  | grep -Ei 'Node info update blocked by ACLs|Coordinate update blocked by ACLs|agent\.anti_entropy.*permission denied|Catalog\.Register.*permission denied'; then
  echo 'Consul client anti-entropy was unhealthy under its exact node identity' >&2
  exit 1
fi

printf 'Consul cleanup timings: allocation=%ss nomad-client=%ss\n' \
  "$allocation_cleanup_seconds" "$nomad_cleanup_seconds"
echo 'Nomad Consul client-sync integration regression test passed'
