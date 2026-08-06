#!/bin/bash
# This script is used to configure and run Consul on a Google Compute Instance.

set -e
umask 077

# Import the appropriate bash commons libraries
readonly BASH_COMMONS_DIR="/opt/gruntwork/bash-commons"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly CONSUL_CONFIG_FILE="default.json"
readonly SYSTEMD_CONFIG_PATH="/etc/systemd/system/consul.service"
readonly BOOTSTRAP_RUNTIME_ROOT="/run"

readonly COMPUTE_INSTANCE_METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
readonly GOOGLE_CLOUD_METADATA_REQUEST_HEADER="Metadata-Flavor: Google"
readonly CLUSTER_SIZE_INSTANCE_METADATA_KEY_NAME="cluster-size"

readonly DEFAULT_RAFT_PROTOCOL="3"

readonly DEFAULT_AUTOPILOT_CLEANUP_DEAD_SERVERS="true"
readonly DEFAULT_AUTOPILOT_LAST_CONTACT_THRESHOLD="200ms"
readonly DEFAULT_AUTOPILOT_MAX_TRAILING_LOGS="250"
readonly DEFAULT_AUTOPILOT_SERVER_STABILIZATION_TIME="10s"
readonly DEFAULT_AUTOPILOT_REDUNDANCY_ZONE_TAG="az"
readonly DEFAULT_AUTOPILOT_DISABLE_UPGRADE_MIGRATION="false"

function curl_direct {
  env \
    -u ALL_PROXY -u all_proxy \
    -u HTTP_PROXY -u http_proxy \
    -u HTTPS_PROXY -u https_proxy \
    -u NO_PROXY -u no_proxy \
    curl --disable --noproxy '*' "$@"
}

if [[ ! -d "$BASH_COMMONS_DIR" ]]; then
  echo "ERROR: this script requires that bash-commons is installed in $BASH_COMMONS_DIR. See https://github.com/gruntwork-io/bash-commons for more info."
  exit 1
fi

source "$BASH_COMMONS_DIR/assert.sh"
source "$BASH_COMMONS_DIR/log.sh"
source "$BASH_COMMONS_DIR/os.sh"

function print_usage {
  echo
  echo "Usage: run-consul [OPTIONS]"
  echo
  echho "This script is used to configure and run Consul on a Google Compute Instance."
  echo
  echo "Options:"
  echo
  echo -e "  --server\t\tIf set, run in server mode. Optional. Exactly one of --server or --client must be set."
  echo -e "  --client\t\tIf set, run in client mode. Optional. Exactly one of --server or --client must be set."
  echo -e "  --consul-token-file\tPath to the mode-0600 file containing the Consul ACL token."
  echo -e "  --consul-token-candidate-file\tPath to the mode-0600 candidate global-management token file (server mode)."
  echo -e "  --consul-token-candidate-version\tImmutable Secret Manager version for management-token lineage (server mode)."
  echo -e "  --cluster-tag-name\tAutomatically form a cluster with Instances that have the same value for this Compute Instance tag name. Optional."
  echo -e "  --datacenter\t\tThe name of the datacenter Consul is running in. Optional. If not specified, will default to GCP region name."
  echo -e "  --config-dir\t\tThe path to the Consul config folder. Optional. Default is the absolute path of '../config', relative to this script."
  echo -e "  --data-dir\t\tThe path to the Consul data folder. Optional. Default is the absolute path of '../data', relative to this script."
  echo -e "  --systemd-stdout\t\tThe StandardOutput option of the systemd unit.  Optional.  If not configured, uses systemd's default (journal)."
  echo -e "  --systemd-stderr\t\tThe StandardError option of the systemd unit.  Optional.  If not configured, uses systemd's default (inherit)."
  echo -e "  --bin-dir\t\tThe path to the folder with Consul binary. Optional. Default is the absolute path of the parent folder of this script."
  echo -e "  --user\t\tThe user to run Consul as. Optional. Default is to use the owner of --config-dir."
  echo -e "  --enable-gossip-encryption\t\tEnable encryption of gossip traffic between nodes. Optional. Must also specify --gossip-encryption-key."
  echo -e "  --gossip-encryption-key-file\tPath to the mode-0600 gossip encryption key file."
  echo -e "  --dns-request-token-file\tPath to the mode-0600 Consul DNS token file."
  echo -e "  --dns-request-token-version\tImmutable Secret Manager version resource for DNS-token lineage (server mode)."
  echo -e "  --nomad-client-token-file\tPath to the mode-0600 Consul token for API/data Nomad client service sync."
  echo -e "  --nomad-client-token-version\tImmutable Secret Manager version resource for Nomad-client token lineage (server mode)."
  echo -e "  --worker-autoscaler-token-file\tPath to the mode-0600 Consul token for the worker autoscaler's bounded leader lock."
  echo -e "  --worker-autoscaler-token-version\tImmutable Secret Manager version resource for worker-autoscaler token lineage (server mode)."
  echo -e "  --enable-rpc-encryption\t\tEnable encryption of RPC traffic between nodes. Optional. Must also specify --ca-file-path, --cert-file-path and --key-file-path."
  echo -e "  --ca-path\t\tPath to the directory of CA files used to verify outgoing connections. Optional. Must be specified with --enable-rpc-encryption."
  echo -e "  --cert-file-path\tPath to the certificate file used to verify incoming connections. Optional. Must be specified with --enable-rpc-encryption and --key-file-path."
  echo -e "  --key-file-path\tPath to the certificate key used to verify incoming connections. Optional. Must be specified with --enable-rpc-encryption and --cert-file-path."
  echo -e "  --verify-server-hostname\tWhen passed in, enable server hostname verification as part of RPC encryption. Each server in Consul should get their own certificate that contains SERVERNAME.DATACENTERNAME.consul in the hostname or SAN. This prevents an authenticated agent from being converted into a server that streams all data, bypassing ACLs."
  echo -e "  --environment\t\tA single environment variable in the key/value pair form 'KEY=\"val\"' to pass to Consul as environment variable when starting it up. Repeat this option for additional variables. Optional."
  echo -e "  --skip-consul-config\tIf this flag is set, don't generate a Consul configuration file. Optional. Default is false."
  echo -e "  --recursor\tThis flag provides address of upstream DNS server that is used to recursively resolve queries if they are not inside the service domain for Consul. Repeat this option for additional variables. Optional."
  echo
  echo "Options for Consul Autopilot:"
  echo
  echo -e "  --autopilot-cleanup-dead-servers\tSet to true or false to control the automatic removal of dead server nodes periodically and whenever a new server is added to the cluster. Defaults to $DEFAULT_AUTOPILOT_CLEANUP_DEAD_SERVERS. Optional."
  echo -e "  --autopilot-last-contact-threshold\tControls the maximum amount of time a server can go without contact from the leader before being considered unhealthy. Must be a duration value such as 10s. Defaults to $DEFAULT_AUTOPILOT_LAST_CONTACT_THRESHOLD. Optional."
  echo -e "  --autopilot-max-trailing-logs\t\tControls the maximum number of log entries that a server can trail the leader by before being considered unhealthy. Defaults to $DEFAULT_AUTOPILOT_MAX_TRAILING_LOGS. Optional."
  echo -e "  --autopilot-server-stabilization-time\tControls the minimum amount of time a server must be stable in the 'healthy' state before being added to the cluster. Only takes effect if all servers are running Raft protocol version 3 or higher. Must be a duration value such as 30s. Defaults to $DEFAULT_AUTOPILOT_SERVER_STABILIZATION_TIME. Optional."
  echo -e "  --autopilot-redundancy-zone-tag\t\t(Enterprise-only) This controls the -node-meta key to use when Autopilot is separating servers into zones for redundancy. Only one server in each zone can be a voting member at one time. If left blank, this feature will be disabled. Defaults to $DEFAULT_AUTOPILOT_REDUNDANCY_ZONE_TAG. Optional."
  echo -e "  --autopilot-disable-upgrade-migration\t(Enterprise-only) If this flag is set, this will disable Autopilot's upgrade migration strategy in Consul Enterprise of waiting until enough newer-versioned servers have been added to the cluster before promoting any of them to voters. Defaults to $DEFAULT_AUTOPILOT_DISABLE_UPGRADE_MIGRATION. Optional."
  echo -e "  --autopilot-upgrade-version-tag\t\t(Enterprise-only) That tag to be used to override the version information used during a migration. Optional."
  echo
  echo
  echo "Example:"
  echo
  echo "  run-consul.sh --server --cluster-tag-name consul-xyz --config-dir /custom/path/to/consul/config"
}

# Get the value at a specific Instance Metadata path.
function get_instance_metadata_value {
  local -r path="$1"

  log_info "Looking up Metadata value at $COMPUTE_INSTANCE_METADATA_URL/$path"
  curl_direct --proto '=http' --proto-redir '=http' \
    --silent --show-error --location \
    --header "$GOOGLE_CLOUD_METADATA_REQUEST_HEADER" \
    "$COMPUTE_INSTANCE_METADATA_URL/$path"
}

function read_secret_file {
  local -r arg_name="$1"
  local -r path="$2"
  local mode

  if [[ ! -f "$path" || -L "$path" ]]; then
    log_error "The value for '$arg_name' must name a regular, non-symlink file"
    exit 1
  fi
  if mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
    :
  else
    mode="$(stat -f '%Lp' "$path")"
  fi
  if ((8#$mode & 077)); then
    log_error "The file for '$arg_name' must not be accessible by group or other users"
    exit 1
  fi

  REPLY="$(<"$path")"
  assert_not_empty "$arg_name" "$REPLY"
}

function consul_api_put_file {
  (
    local -r consul_token="$1"
    local -r path="$2"
    local -r payload_file="$3"
    local request_dir
    local curl_config

    umask 077
    request_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-api.XXXXXX")"
    curl_config="$request_dir/request.curl"
    trap 'rm -rf -- "$request_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    cat >"$curl_config" <<EOF
fail
silent
show-error
header = "X-Consul-Token: $consul_token"
header = "Content-Type: application/json"
EOF
    curl_direct --proto '=http' --config "$curl_config" \
      --request PUT --data-binary "@$payload_file" \
      "http://127.0.0.1:8500$path" >/dev/null
  )
}

function consul_api_get_file {
  (
    local -r consul_token="$1"
    local -r path="$2"
    local -r output_file="$3"
    local request_dir
    local curl_config

    umask 077
    request_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-api.XXXXXX")"
    curl_config="$request_dir/request.curl"
    trap 'rm -rf -- "$request_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    cat >"$curl_config" <<EOF
fail
silent
show-error
header = "X-Consul-Token: $consul_token"
EOF
    curl_direct --proto '=http' --config "$curl_config" --output "$output_file" \
      "http://127.0.0.1:8500$path"
  )
}

function ensure_consul_policy {
  local -r consul_token_file="$1"
  local -r policy_name="$2"
  local -r policy_file="$3"

  if CONSUL_HTTP_TOKEN_FILE="$consul_token_file" consul acl policy read \
    -name="$policy_name" >/dev/null 2>&1; then
    CONSUL_HTTP_TOKEN_FILE="$consul_token_file" consul acl policy update \
      -name "$policy_name" -rules "@$policy_file" >/dev/null
  elif ! CONSUL_HTTP_TOKEN_FILE="$consul_token_file" consul acl policy create \
    -name "$policy_name" -rules "@$policy_file" >/dev/null 2>&1; then
    # Another server may have won the create race. Re-read and update the exact
    # document; any unrelated error remains fatal.
    CONSUL_HTTP_TOKEN_FILE="$consul_token_file" consul acl policy read \
      -name="$policy_name" >/dev/null
    CONSUL_HTTP_TOKEN_FILE="$consul_token_file" consul acl policy update \
      -name "$policy_name" -rules "@$policy_file" >/dev/null
  fi
}

function consul_api_delete {
  (
    local -r consul_token="$1"
    local -r path="$2"
    local request_dir
    local curl_config

    umask 077
    request_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-api.XXXXXX")"
    curl_config="$request_dir/request.curl"
    trap 'rm -rf -- "$request_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    cat >"$curl_config" <<EOF
fail
silent
show-error
header = "X-Consul-Token: $consul_token"
EOF
    curl_direct --proto '=http' --config "$curl_config" --request DELETE \
      "http://127.0.0.1:8500$path" >/dev/null
  )
}

function reconcile_consul_token {
  (
    local management_token="$1"
    local desired_token="$2"
    local description="$3"
    local lineage_key="$4"
    local version_resource="$5"
    shift 5
    local -a policy_names=("$@")
    local work_dir
    local desired_token_file
    local token_payload
    local token_self
    local tokens_list
    local policies_json
    local current_accessor
    local lineage_payload
    local prior_lineage
    local superseded_accessors_json
    local revoked_accessors_json='[]'
    local -a superseded_accessors=()

    [[ "${#policy_names[@]}" -gt 0 ]] || return 1
    [[ "$lineage_key" =~ ^[a-z0-9-]+$ ]] || return 1
    [[ "$version_resource" =~ /versions/[1-9][0-9]*$ ]] || return 1

    umask 077
    work_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-token-reconcile.XXXXXX")"
    trap 'rm -rf -- "$work_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    desired_token_file="$work_dir/desired-token"
    token_payload="$work_dir/token.json"
    token_self="$work_dir/token-self.json"
    tokens_list="$work_dir/tokens.json"
    policies_json="$work_dir/policies.json"
    lineage_payload="$work_dir/lineage.json"
    prior_lineage="$work_dir/prior-lineage.json"
    printf '%s' "$desired_token" >"$desired_token_file"
    printf '%s\n' "${policy_names[@]}" | jq -R '{Name:.}' | jq -s 'sort_by(.Name)' >"$policies_json"

    if consul_api_get_file "$desired_token" '/v1/acl/token/self' "$token_self" 2>/dev/null; then
      current_accessor="$(jq -er '.AccessorID | select(type == "string" and length > 0)' "$token_self")"
      jq -n \
        --arg accessor "$current_accessor" \
        --arg description "$description" \
        --rawfile token "$desired_token_file" \
        --slurpfile policies "$policies_json" \
        '{AccessorID:$accessor,SecretID:$token,Description:$description,Policies:$policies[0]}' \
        >"$token_payload"
      consul_api_put_file "$management_token" "/v1/acl/token/$current_accessor" "$token_payload"
    else
      jq -n \
        --arg description "$description" \
        --rawfile token "$desired_token_file" \
        --slurpfile policies "$policies_json" \
        '{SecretID:$token,Description:$description,Policies:$policies[0]}' \
        >"$token_payload"
      if ! consul_api_put_file "$management_token" '/v1/acl/token' "$token_payload"; then
        sleep 1
      fi
    fi

    consul_api_get_file "$desired_token" '/v1/acl/token/self' "$token_self"
    jq -e --slurpfile expected "$policies_json" '
      ([.Policies[]? | {Name}] | sort_by(.Name)) == $expected[0]
    ' "$token_self" >/dev/null
    current_accessor="$(jq -er '.AccessorID | select(type == "string" and length > 0)' "$token_self")"

    consul_api_get_file "$management_token" '/v1/acl/tokens' "$tokens_list"
    superseded_accessors=()
    while IFS= read -r old_accessor; do
      [[ -n "$old_accessor" ]] && superseded_accessors+=("$old_accessor")
    done < <(
      jq -r \
        --arg description "$description" \
        --arg current "$current_accessor" '
          .[]?
          | select(.Description == $description and .AccessorID != $current)
          | .AccessorID
          | select(type == "string" and test("^[0-9A-Fa-f-]{36}$"))
        ' "$tokens_list"
    )
    # Registration and retirement are deliberately separate rollout phases.
    # Existing API/data hosts and Nomad allocations may still use the previous
    # SecretID until their own exact stage converges. Record those accessors for
    # an explicit post-client cleanup; never revoke them during server boot.
    superseded_accessors_json="$(jq -n --args '$ARGS.positional' -- "${superseded_accessors[@]}")"
    if consul_api_get_file "$management_token" "/v1/kv/e2b/acl-lineage/$lineage_key?raw" "$prior_lineage" 2>/dev/null \
      && jq -e '
        (.superseded_accessors | type) == "array"
        and all(.superseded_accessors[]; type == "string" and test("^[0-9A-Fa-f-]{36}$"))
        and (.revoked_accessors | type) == "array"
        and all(.revoked_accessors[]; type == "string" and test("^[0-9A-Fa-f-]{36}$"))
      ' "$prior_lineage" >/dev/null; then
      revoked_accessors_json="$(jq -c '.revoked_accessors | unique | sort' "$prior_lineage")"
      superseded_accessors_json="$(
        jq -cn \
          --argjson discovered "$superseded_accessors_json" \
          --argjson prior "$(jq -c '.superseded_accessors' "$prior_lineage")" \
          --argjson revoked "$revoked_accessors_json" \
          --arg current "$current_accessor" '
            (($discovered + $prior) - $revoked)
            | map(select(. != $current))
            | unique
            | sort
          '
      )"
    fi
    jq -n \
      --arg current_accessor "$current_accessor" \
      --arg version_resource "$version_resource" \
      --argjson superseded_accessors "$superseded_accessors_json" \
      --argjson revoked_accessors "$revoked_accessors_json" \
      '{current_accessor:$current_accessor,version_resource:$version_resource,superseded_accessors:$superseded_accessors,revoked_accessors:$revoked_accessors}' \
      >"$lineage_payload"
    consul_api_put_file "$management_token" "/v1/kv/e2b/acl-lineage/$lineage_key" "$lineage_payload"
  )
}

function retire_consul_token_lineage {
  (
    local management_token="$1"
    local desired_token="$2"
    local description="$3"
    local lineage_key="$4"
    local version_resource="$5"
    local work_dir
    local token_self
    local tokens_list
    local lineage_payload
    local current_accessor
    local old_accessor
    local revoked_accessors_json
    local -a superseded_accessors=()

    [[ "$lineage_key" =~ ^[a-z0-9-]+$ ]] || return 1
    [[ "$version_resource" =~ /versions/[1-9][0-9]*$ ]] || return 1

    umask 077
    work_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-token-retire.XXXXXX")"
    trap 'rm -rf -- "$work_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    token_self="$work_dir/token-self.json"
    tokens_list="$work_dir/tokens.json"
    lineage_payload="$work_dir/lineage.json"

    consul_api_get_file "$desired_token" '/v1/acl/token/self' "$token_self"
    current_accessor="$(jq -er '.AccessorID | select(type == "string" and test("^[0-9A-Fa-f-]{36}$"))' "$token_self")"
    consul_api_get_file "$management_token" "/v1/kv/e2b/acl-lineage/$lineage_key?raw" "$lineage_payload"
    jq -e \
      --arg current "$current_accessor" \
      --arg version "$version_resource" '
        .current_accessor == $current
        and .version_resource == $version
        and (.superseded_accessors | type) == "array"
        and all(.superseded_accessors[]; type == "string" and test("^[0-9A-Fa-f-]{36}$"))
        and (.revoked_accessors | type) == "array"
        and all(.revoked_accessors[]; type == "string" and test("^[0-9A-Fa-f-]{36}$"))
      ' "$lineage_payload" >/dev/null

    while IFS= read -r old_accessor; do
      [[ -n "$old_accessor" ]] && superseded_accessors+=("$old_accessor")
    done < <(jq -r '.superseded_accessors[]?' "$lineage_payload")

    consul_api_get_file "$management_token" '/v1/acl/tokens' "$tokens_list"
    for old_accessor in "${superseded_accessors[@]}"; do
      jq -e \
        --arg accessor "$old_accessor" \
        --arg description "$description" \
        --arg current "$current_accessor" '
          any(.[]?;
            .AccessorID == $accessor
            and .AccessorID != $current
            and .Description == $description
          )
        ' "$tokens_list" >/dev/null
      consul_api_delete "$management_token" "/v1/acl/token/$old_accessor"
      if consul_api_get_file "$management_token" "/v1/acl/token/$old_accessor" "$work_dir/revoked.json" 2>/dev/null; then
        log_error "Superseded Consul token remained valid after explicit retirement"
        return 1
      fi
    done

    revoked_accessors_json="$(
      jq -c \
        --argjson newly_revoked "$(jq -n --args '$ARGS.positional' -- "${superseded_accessors[@]}")" \
        '((.revoked_accessors // []) + $newly_revoked) | unique | sort' \
        "$lineage_payload"
    )"
    jq -n \
      --arg current_accessor "$current_accessor" \
      --arg version_resource "$version_resource" \
      --argjson revoked_accessors "$revoked_accessors_json" \
      '{current_accessor:$current_accessor,version_resource:$version_resource,superseded_accessors:[],revoked_accessors:$revoked_accessors}' \
      >"$lineage_payload"
    consul_api_put_file "$management_token" "/v1/kv/e2b/acl-lineage/$lineage_key" "$lineage_payload"
    log_info "Explicitly retired superseded Consul token lineage: $lineage_key"
  )
}

# Get the value of the given Custom Metadata Key
function get_instance_custom_metadata_value {
  local -r key="$1"

  log_info "Looking up Custom Instance Metadata value for key \"$key\""
  get_instance_metadata_value "instance/attributes/$key"
}

# Get the ID of the Project in which this Compute Instance currently resides
function get_instance_project_id {
  log_info "Looking up Project ID"
  get_instance_metadata_value "project/project-id"
}

# Get the GCE Region in which this Compute Instance currently resides
function get_instance_region {
  log_info "Looking up Region of the current Compute Instance"

  # The value returned for zone will be of the form "projects/121238320500/zones/us-west1-a" so we need to split the string
  # by "/" and return the 4th string.
  # Then we split again by '-' and return the first two fields.
  # from 'europe-west1-b' to 'europe-west1'
  get_instance_metadata_value "instance/zone" | cut -d'/' -f4 | awk -F'-' '{ print $1"-"$2 }'
}

# Get the name of the current Compute Instance
function get_instance_name {
  log_info "Looking up current Compute Instance name"
  get_instance_metadata_value "instance/name"
}

# Use the immutable numeric GCE instance ID for Consul node identity. Hostnames
# can be reused across template replacements and must not alias prior agents.
function get_instance_id {
  log_info "Looking up current Compute Instance ID"
  get_instance_metadata_value "instance/id"
}

# Get the IP Address of the current Compute Instance
function get_instance_ip_address {
  local network_interface_number="$1"

  # If no network interface number was specified, default to the first one
  if [[ -z "$network_interface_number" ]]; then
    network_interface_number=0
  fi

  log_info "Looking up Compute Instance IP Address on Network Interface $network_interface_number"
  get_instance_metadata_value "instance/network-interfaces/$network_interface_number/ip"
}

function split_by_lines {
  local prefix="$1"
  shift

  for var in "$@"; do
    echo "${prefix}${var}"
  done
}

function generate_consul_config {
  local -r server="${1}"
  local -r dns_request_token="${2}"
  local -r config_dir="${3}"
  local -r user="${4}"
  local -r cluster_tag_name="${5}"
  local -r cluster_size_instance_metadata_key_name="${6}"
  local -r datacenter="${7}"
  local -r enable_gossip_encryption="${8}"
  local -r gossip_encryption_key="${9}"
  local -r enable_rpc_encryption="${10}"
  local -r verify_server_hostname="${11}"
  local -r ca_path="${12}"
  local -r cert_file_path="${13}"
  local -r key_file_path="${14}"
  local -r cleanup_dead_servers="${15}"
  local -r last_contact_threshold="${16}"
  local -r max_trailing_logs="${17}"
  local -r server_stabilization_time="${18}"
  local -r redundancy_zone_tag="${19}"
  local -r disable_upgrade_migration="${20}"
  local -r upgrade_version_tag=${21}
  local -r agent_token="${22}"
  local -r config_path="$config_dir/$CONSUL_CONFIG_FILE"

  shift 22
  local -ar recursors=("$@")

  local instance_id=""
  local instance_name=""
  local project_id=""
  local instance_ip_address=""
  local instance_region=""
  local ui="false"

  instance_ip_address=$(get_instance_ip_address)
  instance_id=$(get_instance_id)
  instance_name=$(get_instance_name)
  instance_region=$(get_instance_region)
  project_id=$(get_instance_project_id)

  # Configure Cloud Auto Join. See https://www.consul.io/docs/install/cloud-auto-join#google-compute-engine for more info.
  local retry_join_json=""
  if [[ -z "$cluster_tag_name" ]]; then
    log_warn "The --cluster-tag-name property is empty. Will not automatically try to form a cluster based on Cluster Tag Name."
  else
    retry_join_json=$(
      cat <<EOF
"retry_join": ["provider=gce project_name=$project_id tag_value=$cluster_tag_name zone_pattern=$instance_region-.*"],
EOF
    )
  fi

  local recursors_config=""
  if [[ ${#recursors[@]} -ne 0 ]]; then
    recursors_config="\"recursors\" : [ "
    for recursor in "${recursors[@]}"; do
      recursors_config="${recursors_config}\"${recursor}\", "
    done
    recursors_config=$(echo "${recursors_config}" | sed 's/, $//')" ],"
  fi

  local bootstrap_expect=""
  if [[ "$server" == "true" ]]; then
    local cluster_size=""

    cluster_size=$(get_instance_custom_metadata_value "$cluster_size_instance_metadata_key_name")

    bootstrap_expect="\"bootstrap_expect\": $cluster_size,"
    ui="true"
  fi

  local autopilot_configuration
  autopilot_configuration=$(
    cat <<EOF
"autopilot": {
  "cleanup_dead_servers": $cleanup_dead_servers,
  "last_contact_threshold": "$last_contact_threshold",
  "max_trailing_logs": $max_trailing_logs,
  "server_stabilization_time": "$server_stabilization_time",
  "redundancy_zone_tag": "$redundancy_zone_tag",
  "disable_upgrade_migration": $disable_upgrade_migration,
  "upgrade_version_tag": "$upgrade_version_tag"
},
EOF
  )

  local gossip_encryption_configuration=""
  if [[ "$enable_gossip_encryption" == "true" && -n "$gossip_encryption_key" ]]; then
    log_info "Creating gossip encryption configuration"
    gossip_encryption_configuration="\"encrypt\": \"$gossip_encryption_key\","
  fi

  # Consul's internal anti-entropy loop needs the API/data Nomad client-sync
  # token to deregister services on allocation shutdown. Use the dedicated
  # agent slot, never default: unauthenticated HTTP requests must continue to
  # receive the deny-default anonymous identity.
  local agent_token_configuration=""
  if [[ -n "$agent_token" ]]; then
    agent_token_configuration=$(cat <<EOF
,
      "agent": "$agent_token"
EOF
    )
  fi

  local rpc_encryption_configuration=""
  if [[ "$enable_rpc_encryption" == "true" && -n "$ca_path" && -n "$cert_file_path" && -n "$key_file_path" ]]; then
    log_info "Creating RPC encryption configuration"
    rpc_encryption_configuration=$(
      cat <<EOF
"verify_outgoing": true,
"verify_incoming": true,
"verify_server_hostname": $verify_server_hostname,
"ca_path": "$ca_path",
"cert_file": "$cert_file_path",
"key_file": "$key_file_path",
EOF
    )
  fi

  log_info "Creating default Consul configuration"
  local default_config_json
  default_config_json=$(
    cat <<EOF
{
  "connect": {
    "enabled": true
  },
  "acl": {
    "enabled": true,
    "default_policy": "deny",
    "enable_token_persistence": true,
    "tokens": {
      "dns": "$dns_request_token"$agent_token_configuration
    }
  },
  "telemetry": {
    "prometheus_retention_time": "2h",
    "disable_hostname": true
  },
  "limits": {
    "http_max_conns_per_client": 80
  },
  "advertise_addr": "$instance_ip_address",
  "bind_addr": "$instance_ip_address",
  $bootstrap_expect
  "client_addr": "127.0.0.1",
  "addresses": {
    "dns": "0.0.0.0",
    "http": "127.0.0.1",
    "https": "127.0.0.1",
    "grpc": "127.0.0.1"
  },
  "datacenter": "$datacenter",
  "node_name": "$instance_id",
  "leave_on_terminate": true,
  "skip_leave_on_interrupt": true,
  $recursors_config
  $retry_join_json
  "server": $server,
  $gossip_encryption_configuration
  $rpc_encryption_configuration
  $autopilot_configuration
  "ui": $ui
}
EOF
  )

  log_info "Installing Consul config file in $config_path"
  echo "$default_config_json" | jq '.' >"$config_path"
  chmod 0600 "$config_path"
  chown "$user:$user" "$config_path"
}

function generate_systemd_config {
  local -r systemd_config_path="$1"
  local -r consul_config_dir="$2"
  local -r consul_data_dir="$3"
  local -r consul_systemd_stdout="$4"
  local -r consul_systemd_stderr="$5"
  local -r consul_bin_dir="$6"
  local -r consul_user="$7"
  shift 7
  local -ar environment=("$@")
  local -r config_path="$consul_config_dir/$CONSUL_CONFIG_FILE"

  log_info "Creating systemd config file to run Consul in $systemd_config_path"

  local -r unit_config=$(
    cat <<EOF
[Unit]
Description="HashiCorp Consul - A service mesh solution"
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=$config_path
EOF
  )

  local -r service_config=$(
    cat <<EOF
[Service]
Type=notify
User=$consul_user
Group=$consul_user
ExecStart=$consul_bin_dir/consul agent -config-dir $consul_config_dir -data-dir $consul_data_dir
ExecReload=$consul_bin_dir/consul reload
ExecStop=$consul_bin_dir/consul leave
KillMode=process
Restart=on-failure
TimeoutSec=300s
LimitNOFILE=65536
$(split_by_lines "Environment=" "${environment[@]}")
EOF
  )

  local log_config=""
  if [[ -n $consul_systemd_stdout ]]; then
    log_config+="StandardOutput=$consul_systemd_stdout\n"
  fi
  if [[ -n $consul_systemd_stderr ]]; then
    log_config+="StandardError=$consul_systemd_stderr\n"
  fi

  local -r install_config=$(
    cat <<EOF
[Install]
WantedBy=multi-user.target
EOF
  )

  echo -e "$unit_config" >"$systemd_config_path"
  echo -e "$service_config" >>"$systemd_config_path"
  echo -e "$log_config" >>"$systemd_config_path"
  echo -e "$install_config" >>"$systemd_config_path"
}

function start_consul {
  log_info "Reloading systemd config and explicitly starting Consul"

  # Bootstrap keeps Consul runtime-masked until all required credentials have
  # been fetched and validated. Never enable this unit: a reboot must execute
  # metadata startup and revalidate credentials before Consul can run.
  sudo systemctl unmask --runtime consul.service
  sudo systemctl daemon-reload
  sudo systemctl disable consul.service
  sudo systemctl restart consul.service
}

function bootstrap {
  (
  log_info "Waiting for Consul to start"
  instance_ip_address=$(get_instance_ip_address)
  log_info "Instance IP Address: $instance_ip_address"

  while true; do
    consul_leader_addr=$(curl_direct --proto '=http' \
      http://localhost:8500/v1/status/leader 2>/dev/null || true)
    log_info "Consul leader address: $consul_leader_addr"

    if [[ "$consul_leader_addr" == "\"$instance_ip_address:8300\"" ]]; then
      local consul_token="$1"
      local bootstrap_dir
      local token_file
      local bootstrap_output
      local bootstrap_status
      log_info "Bootstrapping Consul"
      bootstrap_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-bootstrap.XXXXXX")"
      trap 'rm -rf -- "$bootstrap_dir"' EXIT
      trap 'exit 1' HUP INT TERM
      token_file="$bootstrap_dir/token"
      : >"$token_file"
      chmod 0600 "$token_file"
      printf '%s\n' "$consul_token" >"$token_file"
      set +e
      bootstrap_output="$(consul acl bootstrap "$token_file" 2>&1)"
      bootstrap_status=$?
      set -e
      if [[ "$bootstrap_status" -ne 0 ]]; then
        if [[ "$bootstrap_output" == *"ACL bootstrap no longer allowed"* || "$bootstrap_output" == *"ACL bootstrap already"* ]]; then
          unset bootstrap_output
          log_info "Consul ACLs were already bootstrapped"
          break
        fi
        unset bootstrap_output
        log_error "Consul ACL bootstrap failed"
        return "$bootstrap_status"
      fi
      unset bootstrap_output
      log_info "Consul ACL bootstrap completed"

      break
    fi

    # Consul leader address was already set, but it isn't the current instance
    if [[ -n "$consul_leader_addr" && "$consul_leader_addr" != "\"\"" ]]; then
      log_info "Consul is already bootstrapped"
      break
    fi

    log_info "Waiting for Consul to start"
    sleep 1
  done
  )
}

function setup_management_access {
  (
    local legacy_token="$1"
    local candidate_token="$2"
    local candidate_token_version="$3"
    local work_dir
    local token_self
    local candidate_self
    local lineage_payload
    local legacy_accessor=""
    local candidate_accessor
    local management_token="$legacy_token"

    umask 077
    work_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-management-bootstrap.XXXXXX")"
    trap 'rm -rf -- "$work_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    token_self="$work_dir/token-self.json"
    candidate_self="$work_dir/candidate-self.json"
    lineage_payload="$work_dir/lineage.json"

    if consul_api_get_file "$legacy_token" '/v1/acl/token/self' "$token_self" 2>/dev/null; then
      legacy_accessor="$(jq -er '.AccessorID | select(type == "string" and test("^[0-9A-Fa-f-]{36}$"))' "$token_self")"
    fi

    # After the old SecretID is revoked, reboot remains safe: a proven
    # candidate global-management token can reconcile itself and all leaf
    # identities without depending on the retired credential.
    if consul_api_get_file "$candidate_token" '/v1/acl/token/self' "$token_self" 2>/dev/null \
      && jq -e '([.Policies[]?.Name] | sort) == ["global-management"]' "$token_self" >/dev/null; then
      management_token="$candidate_token"
    fi

    reconcile_consul_token \
      "$management_token" "$candidate_token" \
      "E2B Consul promoted management token" "management" \
      "$candidate_token_version" "global-management"

    # The pre-existing bootstrap token has a different description from the
    # promoted token, so generic same-description rotation cannot discover it.
    # Record it explicitly for the post-client retirement phase without
    # revoking it during the server rollout.
    if [[ -n "$legacy_accessor" ]]; then
      consul_api_get_file "$candidate_token" '/v1/acl/token/self' "$candidate_self"
      candidate_accessor="$(jq -er '.AccessorID | select(type == "string" and test("^[0-9A-Fa-f-]{36}$"))' "$candidate_self")"
      if [[ "$legacy_accessor" != "$candidate_accessor" ]]; then
        consul_api_get_file "$candidate_token" '/v1/kv/e2b/acl-lineage/management?raw' "$lineage_payload"
        jq \
          --arg legacy "$legacy_accessor" '
            .superseded_accessors = ((.superseded_accessors + [$legacy]) - .revoked_accessors | unique | sort)
          ' "$lineage_payload" >"$work_dir/lineage-updated.json"
        consul_api_put_file "$candidate_token" '/v1/kv/e2b/acl-lineage/management' "$work_dir/lineage-updated.json"
      fi
    fi
    log_info "Consul candidate management token registered and proven"
  )
}

function setup_dns_resolving {
  (
    local consul_token="$1"
    local dns_request_token="$2"
    local dns_request_token_version="$3"
    local nomad_client_token="$4"
    local nomad_client_token_version="$5"
    local worker_autoscaler_token="$6"
    local worker_autoscaler_token_version="$7"
    local work_dir
    local dns_policy
    local register_policy
    local worker_autoscaler_policy
    local consul_token_file

    umask 077
    work_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-dns-bootstrap.XXXXXX")"
    trap 'rm -rf -- "$work_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    dns_policy="$work_dir/dns-request-policy.hcl"
    register_policy="$work_dir/register-service-policy.hcl"
    worker_autoscaler_policy="$work_dir/worker-autoscaler-policy.hcl"
    consul_token_file="$work_dir/consul-token"
    printf '%s' "$consul_token" >"$consul_token_file"

    until CONSUL_HTTP_TOKEN_FILE="$consul_token_file" consul info >/dev/null 2>&1; do
      log_info "Waiting for Consul to start"
      sleep 1
    done

    # Based on https://developer.hashicorp.com/consul/tutorials/security/access-control-setup-production#token-for-dns
    cat <<EOF >"$dns_policy"
node_prefix "" {
  policy = "read"
}
service_prefix "" {
  policy = "read"
}
EOF

    cat <<EOF >"$register_policy"
agent_prefix "" {
  policy = "read"
}
node_prefix "" {
  policy = "read"
}
service_prefix "" {
  policy = "write"
}
EOF

    cat <<EOF >"$worker_autoscaler_policy"
key_prefix "service/monad-worker-autoscaler/" {
  policy = "write"
}
session_prefix "" {
  policy = "write"
}
EOF

    ensure_consul_policy "$consul_token_file" "dns-request-policy" "$dns_policy"
    ensure_consul_policy "$consul_token_file" "register-service-policy" "$register_policy"
    ensure_consul_policy "$consul_token_file" "worker-autoscaler-policy" "$worker_autoscaler_policy"

    reconcile_consul_token \
      "$consul_token" "$dns_request_token" \
      "E2B Consul DNS token" "dns" \
      "$dns_request_token_version" "dns-request-policy"
    reconcile_consul_token \
      "$consul_token" "$nomad_client_token" \
      "E2B Consul Nomad-client sync token" "nomad-client-sync" \
      "$nomad_client_token_version" "register-service-policy"
    reconcile_consul_token \
      "$consul_token" "$worker_autoscaler_token" \
      "E2B Consul worker-autoscaler token" "worker-autoscaler" \
      "$worker_autoscaler_token_version" "worker-autoscaler-policy"
    log_info "Consul DNS, Nomad-client sync, and worker-autoscaler tokens reconciled"
  )
}

# Based on: http://unix.stackexchange.com/a/7732/215969
function get_owner_of_path {
  local -r path="$1"
  ls -ld "$path" | awk '{print $3}'
}

function get_owner_home_dir {
  local -r user="$1"

  local home_dir=""
  home_dir=$(sudo su - $user -c 'echo $HOME')

  if [[ "$home_dir" == "/" ]]; then
    log_error "No \$HOME directory is set for user $user. This may cause unpredictable behavior with Consul in GCP. Exiting."
    exit 1
  fi

  echo "$home_dir"
}

function run {
  local server="false"
  local client="false"
  local config_dir=""
  local data_dir=""
  local systemd_stdout=""
  local systemd_stderr=""
  local bin_dir=""
  local user=""
  local cluster_tag_name=""
  local datacenter=""
  local upgrade_version_tag=""
  local enable_gossip_encryption="false"
  local gossip_encryption_key=""
  local enable_rpc_encryption="false"
  local verify_server_hostname="false"
  local ca_path=""
  local cert_file_path=""
  local key_file_path=""
  local environment=()
  local skip_consul_config="false"
  local recursors=()
  local cleanup_dead_servers="$DEFAULT_AUTOPILOT_CLEANUP_DEAD_SERVERS"
  local last_contact_threshold="$DEFAULT_AUTOPILOT_LAST_CONTACT_THRESHOLD"
  local max_trailing_logs="$DEFAULT_AUTOPILOT_MAX_TRAILING_LOGS"
  local server_stabilization_time="$DEFAULT_AUTOPILOT_SERVER_STABILIZATION_TIME"
  local redundancy_zone_tag="$DEFAULT_AUTOPILOT_REDUNDANCY_ZONE_TAG"
  local disable_upgrade_migration="$DEFAULT_AUTOPILOT_DISABLE_UPGRADE_MIGRATION"
  local consul_token=""
  local consul_token_candidate=""
  local consul_token_candidate_version=""
  local dns_request_token=""
  local dns_request_token_version=""
  local nomad_client_token=""
  local nomad_client_token_version=""
  local worker_autoscaler_token=""
  local worker_autoscaler_token_version=""
  local consul_agent_token=""

  while [[ $# -gt 0 ]]; do
    local key="$1"

    case "$key" in
    --server)
      server="true"
      ;;
    --client)
      client="true"
      ;;
    --consul-token-file)
      read_secret_file "$key" "$2"
      consul_token="$REPLY"
      shift
      ;;
    --consul-token-candidate-file)
      read_secret_file "$key" "$2"
      consul_token_candidate="$REPLY"
      shift
      ;;
    --consul-token-candidate-version)
      assert_not_empty "$key" "$2"
      consul_token_candidate_version="$2"
      shift
      ;;
    --config-dir)
      assert_not_empty "$key" "$2"
      config_dir="$2"
      shift
      ;;
    --data-dir)
      assert_not_empty "$key" "$2"
      data_dir="$2"
      shift
      ;;
    --systemd-stdout)
      assert_not_empty "$key" "$2"
      systemd_stdout="$2"
      shift
      ;;
    --systemd-stderr)
      assert_not_empty "$key" "$2"
      systemd_stderr="$2"
      shift
      ;;
    --bin-dir)
      assert_not_empty "$key" "$2"
      bin_dir="$2"
      shift
      ;;
    --user)
      assert_not_empty "$key" "$2"
      user="$2"
      shift
      ;;
    --cluster-tag-name)
      assert_not_empty "$key" "$2"
      cluster_tag_name="$2"
      shift
      ;;
    --datacenter)
      assert_not_empty "$key" "$2"
      datacenter="$2"
      shift
      ;;
    --autopilot-cleanup-dead-servers)
      assert_not_empty "$key" "$2"
      cleanup_dead_servers="$2"
      shift
      ;;
    --autopilot-last-contact-threshold)
      assert_not_empty "$key" "$2"
      last_contact_threshold="$2"
      shift
      ;;
    --autopilot-max-trailing-logs)
      assert_not_empty "$key" "$2"
      max_trailing_logs="$2"
      shift
      ;;
    --autopilot-server-stabilization-time)
      assert_not_empty "$key" "$2"
      server_stabilization_time="$2"
      shift
      ;;
    --autopilot-redundancy-zone-tag)
      assert_not_empty "$key" "$2"
      redundancy_zone_tag="$2"
      shift
      ;;
    --autopilot-disable-upgrade-migration)
      disable_upgrade_migration="true"
      shift
      ;;
    --autopilot-upgrade-version-tag)
      assert_not_empty "$key" "$2"
      upgrade_version_tag="$2"
      shift
      ;;
    --enable-gossip-encryption)
      enable_gossip_encryption="true"
      ;;
    --gossip-encryption-key-file)
      read_secret_file "$key" "$2"
      gossip_encryption_key="$REPLY"
      shift
      ;;
    --dns-request-token-file)
      read_secret_file "$key" "$2"
      dns_request_token="$REPLY"
      shift
      ;;
    --dns-request-token-version)
      assert_not_empty "$key" "$2"
      dns_request_token_version="$2"
      shift
      ;;
    --nomad-client-token-file)
      read_secret_file "$key" "$2"
      nomad_client_token="$REPLY"
      shift
      ;;
    --nomad-client-token-version)
      assert_not_empty "$key" "$2"
      nomad_client_token_version="$2"
      shift
      ;;
    --worker-autoscaler-token-file)
      read_secret_file "$key" "$2"
      worker_autoscaler_token="$REPLY"
      shift
      ;;
    --worker-autoscaler-token-version)
      assert_not_empty "$key" "$2"
      worker_autoscaler_token_version="$2"
      shift
      ;;
    --enable-rpc-encryption)
      enable_rpc_encryption="true"
      ;;
    --verify-server-hostname)
      verify_server_hostname="true"
      ;;
    --ca-path)
      assert_not_empty "$key" "$2"
      ca_path="$2"
      shift
      ;;
    --cert-file-path)
      assert_not_empty "$key" "$2"
      cert_file_path="$2"
      shift
      ;;
    --key-file-path)
      assert_not_empty "$key" "$2"
      key_file_path="$2"
      shift
      ;;
    --environment)
      assert_not_empty "$key" "$2"
      environment+=("$2")
      shift
      ;;
    --skip-consul-config)
      skip_consul_config="true"
      ;;
    --recursor)
      assert_not_empty "$key" "$2"
      recursors+=("$2")
      shift
      ;;
    --help)
      print_usage
      exit
      ;;
    *)
      log_error "Unrecognized argument: $key"
      print_usage
      exit 1
      ;;
    esac

    shift
  done

  if [[ ("$server" == "true" && "$client" == "true") || ("$server" == "false" && "$client" == "false") ]]; then
    log_error "Exactly one of --server or --client must be set."
    exit 1
  fi

  assert_not_empty "--dns-request-token-file" "$dns_request_token"
  if [[ "$client" == "true" ]]; then
    assert_not_empty "--nomad-client-token-file" "$nomad_client_token"
    consul_agent_token="$nomad_client_token"
  fi

  assert_is_installed "systemctl"
  assert_is_installed "curl"
  assert_is_installed "jq"

  if [[ -z "$config_dir" ]]; then
    config_dir=$(cd "$SCRIPT_DIR/../config" && pwd)
  fi

  if [[ -z "$data_dir" ]]; then
    data_dir=$(cd "$SCRIPT_DIR/../data" && pwd)
  fi

  # If $systemd_stdout and/or $systemd_stderr are empty, we leave them empty so that generate_systemd_config will use systemd's defaults (journal and inherit, respectively)

  if [[ -z "$bin_dir" ]]; then
    bin_dir=$(cd "$SCRIPT_DIR/../bin" && pwd)
  fi

  if [[ -z "$user" ]]; then
    user=$(get_owner_of_path "$config_dir")
  fi

  if [[ -z "$datacenter" ]]; then
    datacenter=$(get_instance_region)
  fi

  if [[ "$skip_consul_config" == "true" ]]; then
    log_info "The --skip-consul-config flag is set, so will not generate a default Consul config file."
  else
    if [[ "$enable_gossip_encryption" == "true" ]]; then
      assert_not_empty "--gossip-encryption-key" "$gossip_encryption_key"
    fi
    if [[ "$enable_rpc_encryption" == "true" ]]; then
      assert_not_empty "--ca-path" "$ca_path"
      assert_not_empty "--cert-file-path" "$cert_file_path"
      assert_not_empty "--key_file_path" "$key_file_path"
    fi

    generate_consul_config "$server" \
      "$dns_request_token" \
      "$config_dir" \
      "$user" \
      "$cluster_tag_name" \
      "$CLUSTER_SIZE_INSTANCE_METADATA_KEY_NAME" \
      "$datacenter" \
      "$enable_gossip_encryption" \
      "$gossip_encryption_key" \
      "$enable_rpc_encryption" \
      "$verify_server_hostname" \
      "$ca_path" \
      "$cert_file_path" \
      "$key_file_path" \
      "$cleanup_dead_servers" \
      "$last_contact_threshold" \
      "$max_trailing_logs" \
      "$server_stabilization_time" \
      "$redundancy_zone_tag" \
      "$disable_upgrade_migration" \
      "$upgrade_version_tag" \
      "$consul_agent_token" \
      "${recursors[@]}"
  fi

  generate_systemd_config "$SYSTEMD_CONFIG_PATH" "$config_dir" "$data_dir" "$systemd_stdout" "$systemd_stderr" "$bin_dir" "$user" "${environment[@]}"
  start_consul

  if [[ "$server" == "true" ]]; then
    bootstrap "$consul_token"
    assert_not_empty "--consul-token-candidate-file" "$consul_token_candidate"
    assert_not_empty "--consul-token-candidate-version" "$consul_token_candidate_version"
    assert_not_empty "--nomad-client-token-file" "$nomad_client_token"
    assert_not_empty "--dns-request-token-version" "$dns_request_token_version"
    assert_not_empty "--nomad-client-token-version" "$nomad_client_token_version"
    assert_not_empty "--worker-autoscaler-token-file" "$worker_autoscaler_token"
    assert_not_empty "--worker-autoscaler-token-version" "$worker_autoscaler_token_version"
    setup_management_access \
      "$consul_token" "$consul_token_candidate" "$consul_token_candidate_version"
    setup_dns_resolving \
      "$consul_token_candidate" \
      "$dns_request_token" "$dns_request_token_version" \
      "$nomad_client_token" "$nomad_client_token_version" \
      "$worker_autoscaler_token" "$worker_autoscaler_token_version"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run "$@"
fi
