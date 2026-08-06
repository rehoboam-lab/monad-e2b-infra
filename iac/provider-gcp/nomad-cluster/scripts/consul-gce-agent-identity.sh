#!/bin/bash
# GCE-attested Consul agent identity lifecycle.
#
# This file is sourced by run-consul.sh after its metadata and loopback Consul
# helpers are defined. It must not be executed independently.

function get_boot_id {
  local boot_id
  boot_id="$(< /proc/sys/kernel/random/boot_id)"
  [[ "$boot_id" =~ ^[0-9A-Fa-f-]{36}$ ]]
  printf '%s\n' "$boot_id"
}

function generate_gce_agent_recovery_token {
  local token
  token="$(< /proc/sys/kernel/random/uuid)"
  [[ "$token" =~ ^[0-9A-Fa-f-]{36}$ ]]
  printf '%s\n' "$token"
}

function initialize_gce_agent_runtime_config {
  local -r consul_user="$1"
  local runtime_tmp
  local recovery_tmp

  install -d -o root -g "$consul_user" -m 0750 "$GCE_AGENT_RUNTIME_DIR"
  recovery_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/agent-recovery-token.XXXXXX")"
  generate_gce_agent_recovery_token >"$recovery_tmp"
  chmod 0640 "$recovery_tmp"
  chown "root:$consul_user" "$recovery_tmp"
  mv -f -- "$recovery_tmp" "$GCE_AGENT_RECOVERY_TOKEN"
  runtime_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/agent-token.XXXXXX")"
  jq -n --rawfile recovery "$GCE_AGENT_RECOVERY_TOKEN" '
    ($recovery | gsub("[\\r\\n]+$"; "")) as $secret
    | if ($secret | test("^[0-9A-Fa-f-]{36}$")) then
        {acl:{tokens:{agent_recovery:$secret}}}
      else error("invalid Consul agent recovery token") end
  ' >"$runtime_tmp"
  chmod 0640 "$runtime_tmp"
  chown "root:$consul_user" "$runtime_tmp"
  mv -f -- "$runtime_tmp" "$GCE_AGENT_RUNTIME_CONFIG"
  rm -f -- "$GCE_AGENT_RUNTIME_TOKEN" "$GCE_AGENT_RUNTIME_LEASE" "$GCE_AGENT_BOOT_READY"
}

function write_gce_agent_runtime_config {
  local -r token_file="$1"
  local -r consul_user="$2"
  local -r login_response="$3"
  local -r instance_id="$4"
  local runtime_tmp
  local lease_tmp
  local token_tmp
  local token_sha256
  local expiration_epoch
  local accessor_id
  local boot_id

  [[ -f "$token_file" && ! -L "$token_file" ]] || return 1
  [[ -f "$GCE_AGENT_RECOVERY_TOKEN" && ! -L "$GCE_AGENT_RECOVERY_TOKEN" ]] \
    || return 1
  boot_id="$(get_boot_id)" || return 1
  token_sha256="$(sha256sum "$token_file" | awk '{print $1}')" || return 1
  expiration_epoch="$(jq -er '.ExpirationTime | fromdateiso8601' "$login_response")" \
    || return 1
  accessor_id="$(jq -er '.AccessorID | select(test("^[0-9A-Fa-f-]{36}$"))' "$login_response")" \
    || return 1

  # Install the raw token and lease first. The JSON config is the commit point
  # consumed by Consul. A crash before that final rename leaves the old config
  # active and is detected by the digest checks below; it can never silently
  # pair a new config with old lease metadata.
  token_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/agent-token.raw.XXXXXX")" || return 1
  {
    tr -d '\r\n' <"$token_file"
    printf '\n'
  } >"$token_tmp" || return 1
  grep -Eq '^[0-9A-Fa-f-]{36}$' "$token_tmp" || return 1
  chmod 0600 "$token_tmp" || return 1
  chown root:root "$token_tmp" || return 1

  lease_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/lease.XXXXXX")" || return 1
  jq -n \
    --arg token_sha256 "$token_sha256" \
    --arg accessor_id "$accessor_id" \
    --arg node_id "$instance_id" \
    --arg boot_id "$boot_id" \
    --argjson expiration_epoch "$expiration_epoch" '
      {
        schema:2,
        token_sha256:$token_sha256,
        accessor_id:$accessor_id,
        node_id:$node_id,
        boot_id:$boot_id,
        expiration_epoch:$expiration_epoch
      }
    ' >"$lease_tmp" || return 1
  chmod 0600 "$lease_tmp" || return 1
  chown root:root "$lease_tmp" || return 1

  runtime_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/agent-token.XXXXXX")" || return 1
  jq -n --rawfile token "$token_file" --rawfile recovery "$GCE_AGENT_RECOVERY_TOKEN" '
    ($token | gsub("[\\r\\n]+$"; "")) as $secret
    | ($recovery | gsub("[\\r\\n]+$"; "")) as $recovery_secret
    | if (($secret | test("^[0-9A-Fa-f-]{36}$")) and ($recovery_secret | test("^[0-9A-Fa-f-]{36}$"))) then
        {acl:{tokens:{agent:$secret,agent_recovery:$recovery_secret}}}
      else error("invalid Consul agent SecretID") end
  ' >"$runtime_tmp" || return 1
  chmod 0640 "$runtime_tmp" || return 1
  chown "root:$consul_user" "$runtime_tmp" || return 1

  mv -f -- "$token_tmp" "$GCE_AGENT_RUNTIME_TOKEN" || return 1
  mv -f -- "$lease_tmp" "$GCE_AGENT_RUNTIME_LEASE" || return 1
  mv -f -- "$runtime_tmp" "$GCE_AGENT_RUNTIME_CONFIG" || return 1
}

function gce_agent_generation_is_valid {
  (
  local -r config_file="$1"
  local -r agent_token_file="$2"
  local -r recovery_token_file="$3"
  local -r lease_file="$4"
  local -r minimum_seconds="$5"
  local token_file
  local token_sha256
  local raw_token_sha256
  local recovery_sha256
  local config_recovery_sha256
  local recorded_sha256
  local expiration_epoch
  local recorded_boot_id
  local recorded_node_id
  local boot_id
  local instance_id
  local now

  [[ "$minimum_seconds" == ignore || "$minimum_seconds" =~ ^[0-9]+$ ]] || return 1
  [[ -f "$config_file" && ! -L "$config_file" ]] || return 1
  [[ -f "$agent_token_file" && ! -L "$agent_token_file" ]] || return 1
  [[ -f "$recovery_token_file" && ! -L "$recovery_token_file" ]] || return 1
  [[ -f "$lease_file" && ! -L "$lease_file" ]] || return 1
  token_file="$(mktemp "$(dirname "$config_file")/current-token.XXXXXX")" || return 1
  trap 'rm -f -- "$token_file"' EXIT
  jq -er '.acl.tokens.agent | select(test("^[0-9A-Fa-f-]{36}$"))' \
    "$config_file" >"$token_file" || return 1
  token_sha256="$(sha256sum "$token_file" | awk '{print $1}')" || return 1
  raw_token_sha256="$(sha256sum "$agent_token_file" | awk '{print $1}')" || return 1
  recovery_sha256="$(sha256sum "$recovery_token_file" | awk '{print $1}')" || return 1
  jq -er '.acl.tokens.agent_recovery | select(test("^[0-9A-Fa-f-]{36}$"))' \
    "$config_file" >"$token_file" || return 1
  config_recovery_sha256="$(sha256sum "$token_file" | awk '{print $1}')" || return 1
  recorded_sha256="$(jq -er '.token_sha256 | select(test("^[0-9a-f]{64}$"))' \
    "$lease_file")" || return 1
  expiration_epoch="$(jq -er '.expiration_epoch | select(type == "number")' \
    "$lease_file")" || return 1
  recorded_boot_id="$(jq -er '.boot_id | select(test("^[0-9A-Fa-f-]{36}$"))' \
    "$lease_file")" || return 1
  recorded_node_id="$(jq -er '.node_id | select(test("^[0-9]+$"))' \
    "$lease_file")" || return 1
  jq -e '.schema == 2' "$lease_file" >/dev/null || return 1
  boot_id="$(get_boot_id)" || return 1
  instance_id="$(get_instance_id)" || return 1
  now="$(date -u +%s)" || return 1
  [[ "$token_sha256" == "$recorded_sha256" && "$raw_token_sha256" == "$recorded_sha256" ]] \
    || return 1
  [[ "$recovery_sha256" == "$config_recovery_sha256" ]] || return 1
  [[ "$recorded_boot_id" == "$boot_id" ]] || return 1
  [[ "$recorded_node_id" == "$instance_id" ]] || return 1
  if [[ "$minimum_seconds" != ignore ]]; then
    ((expiration_epoch > now + minimum_seconds)) || return 1
  fi
  )
}

function gce_agent_runtime_has_headroom {
  gce_agent_generation_is_valid \
    "$GCE_AGENT_RUNTIME_CONFIG" "$GCE_AGENT_RUNTIME_TOKEN" \
    "$GCE_AGENT_RECOVERY_TOKEN" "$GCE_AGENT_RUNTIME_LEASE" "$1"
}

function acquire_gce_agent_bootstrap_lock {
  local -r wait_mode="$1"
  install -d -o root -g root -m 0700 "$GCE_AGENT_LOCK_DIR"
  exec {GCE_AGENT_BOOTSTRAP_LOCK_FD}>"$GCE_AGENT_BOOTSTRAP_LOCK"
  if [[ "$wait_mode" == "wait" ]]; then
    flock --exclusive --timeout 300 "$GCE_AGENT_BOOTSTRAP_LOCK_FD"
  else
    flock --exclusive --nonblock "$GCE_AGENT_BOOTSTRAP_LOCK_FD"
  fi
}

function mark_gce_agent_boot_ready {
  local -r instance_id="$1"
  local boot_id
  local marker_tmp

  boot_id="$(get_boot_id)" || return 1
  gce_agent_runtime_has_headroom "$GCE_AGENT_MINIMUM_HEADROOM_SECONDS" \
    || return 1
  marker_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/boot-ready.XXXXXX")" || return 1
  jq -n --arg boot_id "$boot_id" --arg node_id "$instance_id" \
    '{schema:1,boot_id:$boot_id,node_id:$node_id}' >"$marker_tmp" || return 1
  chmod 0644 "$marker_tmp" || return 1
  chown root:root "$marker_tmp" || return 1
  mv -f -- "$marker_tmp" "$GCE_AGENT_BOOT_READY" || return 1
}

function gce_agent_boot_is_ready {
  local boot_id
  local instance_id

  [[ -f "$GCE_AGENT_BOOT_READY" && ! -L "$GCE_AGENT_BOOT_READY" ]] \
    || return 1
  boot_id="$(get_boot_id)" || return 1
  instance_id="$(get_instance_id)" || return 1
  jq -e --arg boot_id "$boot_id" --arg node_id "$instance_id" '
    .schema == 1 and .boot_id == $boot_id and .node_id == $node_id
  ' "$GCE_AGENT_BOOT_READY" >/dev/null || return 1
}

function snapshot_gce_agent_runtime {
  local -r destination="$1"
  install -d -o root -g root -m 0700 "$destination"
  gce_agent_runtime_has_headroom 0
  cp -- "$GCE_AGENT_RUNTIME_CONFIG" "$destination/agent-token.json"
  cp -- "$GCE_AGENT_RUNTIME_TOKEN" "$destination/agent-token"
  cp -- "$GCE_AGENT_RECOVERY_TOKEN" "$destination/agent-recovery-token"
  cp -- "$GCE_AGENT_RUNTIME_LEASE" "$destination/lease.json"
  chmod 0600 \
    "$destination/agent-token.json" "$destination/agent-token" \
    "$destination/agent-recovery-token" "$destination/lease.json"
  chown root:root \
    "$destination/agent-token.json" "$destination/agent-token" \
    "$destination/agent-recovery-token" "$destination/lease.json"
  gce_agent_generation_is_valid \
    "$destination/agent-token.json" "$destination/agent-token" \
    "$destination/agent-recovery-token" "$destination/lease.json" 0
}

function restore_gce_agent_runtime {
  local -r source="$1"
  local -r consul_user="$2"
  local token_tmp
  local recovery_tmp
  local lease_tmp
  local config_tmp

  for name in agent-token.json agent-token agent-recovery-token lease.json; do
    [[ -f "$source/$name" && ! -L "$source/$name" ]]
  done
  gce_agent_generation_is_valid \
    "$source/agent-token.json" "$source/agent-token" \
    "$source/agent-recovery-token" "$source/lease.json" 0
  token_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/agent-token.raw.XXXXXX")"
  recovery_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/agent-recovery-token.XXXXXX")"
  lease_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/lease.XXXXXX")"
  config_tmp="$(mktemp "$GCE_AGENT_RUNTIME_DIR/agent-token.XXXXXX")"
  cp -- "$source/agent-token" "$token_tmp"
  cp -- "$source/agent-recovery-token" "$recovery_tmp"
  cp -- "$source/lease.json" "$lease_tmp"
  cp -- "$source/agent-token.json" "$config_tmp"
  chmod 0600 "$token_tmp" "$lease_tmp"
  chown root:root "$token_tmp" "$lease_tmp"
  chmod 0640 "$recovery_tmp"
  chown "root:$consul_user" "$recovery_tmp"
  chmod 0640 "$config_tmp"
  chown "root:$consul_user" "$config_tmp"
  mv -f -- "$token_tmp" "$GCE_AGENT_RUNTIME_TOKEN"
  mv -f -- "$recovery_tmp" "$GCE_AGENT_RECOVERY_TOKEN"
  mv -f -- "$lease_tmp" "$GCE_AGENT_RUNTIME_LEASE"
  mv -f -- "$config_tmp" "$GCE_AGENT_RUNTIME_CONFIG"
  gce_agent_runtime_has_headroom 0
}

function decode_jwt_segment {
  local -r segment="$1"
  local padding=""
  case $((${#segment} % 4)) in
    0) ;;
    2) padding='==' ;;
    3) padding='=' ;;
    *) return 1 ;;
  esac
  printf '%s%s' "$segment" "$padding" \
    | tr '_-' '/+' \
    | openssl base64 -d -A
}

function persist_gce_agent_pending_revoke {
  local -r token_file="$1"
  local -r endpoint="$2"
  local token_sha256
  local pending_path
  local pending_tmp

  [[ -f "$token_file" && ! -L "$token_file" ]] || return 1
  grep -Eq '^[0-9A-Fa-f-]{36}$' "$token_file" || return 1
  [[ "$endpoint" == '127.0.0.1' ]] || return 1
  install -d -o root -g root -m 0700 "$GCE_AGENT_PENDING_REVOKE_DIR" \
    || return 1
  token_sha256="$(sha256sum "$token_file" | awk '{print $1}')" || return 1
  pending_path="$GCE_AGENT_PENDING_REVOKE_DIR/token-$token_sha256.json"
  pending_tmp="$(mktemp "$GCE_AGENT_PENDING_REVOKE_DIR/pending.XXXXXX")" || return 1
  jq -n \
    --rawfile token "$token_file" \
    --arg token_sha256 "$token_sha256" \
    --arg endpoint "$endpoint" \
    --arg boot_id "$(get_boot_id)" \
    --arg node_id "$(get_instance_id)" '
      ($token | gsub("[\\r\\n]+$"; "")) as $secret
      | if ($secret | test("^[0-9A-Fa-f-]{36}$")) then
          {
            schema:1,
            token:$secret,
            token_sha256:$token_sha256,
            endpoint:$endpoint,
            boot_id:$boot_id,
            node_id:$node_id
          }
        else error("invalid pending Consul token") end
    ' >"$pending_tmp" || return 1
  chmod 0600 "$pending_tmp" || return 1
  chown root:root "$pending_tmp" || return 1
  if [[ -e "$pending_path" ]]; then
    rm -f -- "$pending_tmp"
  else
    mv -- "$pending_tmp" "$pending_path" || return 1
  fi
  REPLY="$pending_path"
}

function validate_gce_agent_pending_revoke {
  local -r pending_path="$1"
  local expected_sha256

  [[ "$pending_path" == "$GCE_AGENT_PENDING_REVOKE_DIR/"*.json ]] || return 1
  [[ -f "$pending_path" && ! -L "$pending_path" ]] || return 1
  expected_sha256="${pending_path##*/token-}"
  expected_sha256="${expected_sha256%.json}"
  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -e \
    --arg expected_sha256 "$expected_sha256" \
    --arg boot_id "$(get_boot_id)" \
    --arg node_id "$(get_instance_id)" '
      .schema == 1
      and (.token | test("^[0-9A-Fa-f-]{36}$"))
      and .token_sha256 == $expected_sha256
      and .endpoint == "127.0.0.1"
      and .boot_id == $boot_id
      and .node_id == $node_id
    ' "$pending_path" >/dev/null || return 1
  jq -er '.token' "$pending_path" \
    | sha256sum | awk '{print $1}' | grep -Fqx "$expected_sha256" || return 1
}

function pending_gce_agent_token_file {
  local -r pending_path="$1"
  local -r destination="$2"

  validate_gce_agent_pending_revoke "$pending_path" || return 1
  jq -er '.token' "$pending_path" >"$destination" || return 1
  chmod 0600 "$destination" || return 1
  chown root:root "$destination" || return 1
}

function revoke_gce_agent_pending_revoke {
  local -r pending_path="$1"
  local token_file
  local endpoint

  validate_gce_agent_pending_revoke "$pending_path" || return 1
  token_file="$(mktemp "$GCE_AGENT_PENDING_REVOKE_DIR/token.XXXXXX")" || return 1
  pending_gce_agent_token_file "$pending_path" "$token_file" || return 1
  endpoint="$(jq -er '.endpoint' "$pending_path")" || return 1
  if ! revoke_gce_agent_login_token "$token_file" "$endpoint"; then
    rm -f -- "$token_file"
    return 1
  fi
  rm -f -- "$pending_path" "$token_file"
}

function acknowledge_gce_agent_login_token {
  local -r token_file="$1"
  local token_sha256
  local pending_path
  local pending_token

  [[ -f "$token_file" && ! -L "$token_file" ]] || return 1
  token_sha256="$(sha256sum "$token_file" | awk '{print $1}')" || return 1
  pending_path="$GCE_AGENT_PENDING_REVOKE_DIR/token-$token_sha256.json"
  [[ -e "$pending_path" ]] || return 0
  validate_gce_agent_pending_revoke "$pending_path" || return 1
  pending_token="$(mktemp "$GCE_AGENT_PENDING_REVOKE_DIR/ack.XXXXXX")" || return 1
  pending_gce_agent_token_file "$pending_path" "$pending_token" || return 1
  if ! cmp -s "$token_file" "$pending_token"; then
    rm -f -- "$pending_token"
    return 1
  fi
  rm -f -- "$pending_path" "$pending_token"
}

function reconcile_gce_agent_pending_revokes {
  local pending_path
  local pending_token

  [[ -d "$GCE_AGENT_PENDING_REVOKE_DIR" ]] || return 0
  [[ ! -L "$GCE_AGENT_PENDING_REVOKE_DIR" ]] || return 1
  while IFS= read -r pending_path; do
    [[ -n "$pending_path" ]] || continue
    validate_gce_agent_pending_revoke "$pending_path" || return 1
    pending_token="$(mktemp "$GCE_AGENT_PENDING_REVOKE_DIR/reconcile.XXXXXX")" || return 1
    pending_gce_agent_token_file "$pending_path" "$pending_token" || return 1
    if [[ -f "$GCE_AGENT_RUNTIME_TOKEN" && ! -L "$GCE_AGENT_RUNTIME_TOKEN" ]] \
      && cmp -s "$GCE_AGENT_RUNTIME_TOKEN" "$pending_token"; then
      rm -f -- "$pending_token"
      log_error "Refusing a new GCE agent login while the current runtime token is still pending acknowledgement"
      return 1
    fi
    rm -f -- "$pending_token"
    revoke_gce_agent_pending_revoke "$pending_path" || return 1
  done < <(find "$GCE_AGENT_PENDING_REVOKE_DIR" -mindepth 1 -maxdepth 1 \
    -type f -name 'token-*.json' -print | sort)
}

function abort_gce_agent_identity_acquisition {
  local -r pending_path="$1"
  local -r work_dir="$2"

  if [[ -n "$pending_path" && -f "$pending_path" ]]; then
    # A failed logout deliberately leaves the mode-0600 journal in place. The
    # next acquire must reconcile it before issuing another login request.
    revoke_gce_agent_pending_revoke "$pending_path" || true
  fi
  rm -rf -- "$work_dir"
}

function acquire_gce_agent_identity {
  local -r datacenter="$1"
  local -r consul_user="$2"
  local project_id
  local instance_id
  local instance_zone
  local service_account_email
  local audience
  local work_dir
  local identity_jwt
  local jwt_header
  local jwt_payload
  local jwt_signature
  local login_payload
  local login_response
  local agent_token_file
  local endpoints_file
  local endpoint
  local login_code
  local login_endpoint
  local token_probe
  local token_curl_config
  local probe_endpoints
  local probe_code
  local verified_endpoint
  local now
  local pending_revoke=""

  if ! reconcile_gce_agent_pending_revokes; then
    return 1
  fi

  project_id="$(get_instance_project_id)" || return 1
  instance_id="$(get_instance_id)" || return 1
  instance_zone="$(get_instance_zone)" || return 1
  service_account_email="$(get_instance_service_account_email)" || return 1
  [[ "$instance_zone" =~ ^${datacenter}-[a-z]$ ]] || return 1
  [[ "$service_account_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] \
    || return 1
  audience="https://consul.$project_id.internal/e2b/gce-agent"

  work_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-agent-login.XXXXXX")" \
    || return 1
  trap 'rm -rf -- "$work_dir"' RETURN
  identity_jwt="$work_dir/identity.jwt"
  jwt_header="$work_dir/header.json"
  jwt_payload="$work_dir/payload.json"
  login_payload="$work_dir/login.json"
  login_response="$work_dir/login-response.json"
  agent_token_file="$work_dir/agent-token"
  endpoints_file="$work_dir/endpoints"
  token_probe="$work_dir/token-self.json"
  token_curl_config="$work_dir/token.curl"
  probe_endpoints="$work_dir/probe-endpoints"

  curl_direct --proto '=http' --get --silent --show-error --fail \
    --header "$GOOGLE_CLOUD_METADATA_REQUEST_HEADER" \
    --data-urlencode "audience=$audience" --data 'format=full' \
    --output "$identity_jwt" \
    "$COMPUTE_INSTANCE_METADATA_URL/instance/service-accounts/default/identity" \
    || return 1
  chmod 0600 "$identity_jwt" || return 1
  IFS='.' read -r jwt_header_segment jwt_payload_segment jwt_signature \
    <"$identity_jwt" || return 1
  [[ -n "$jwt_header_segment" && -n "$jwt_payload_segment" && -n "$jwt_signature" \
    && "$jwt_signature" != *.* ]] || return 1
  decode_jwt_segment "$jwt_header_segment" >"$jwt_header" || return 1
  decode_jwt_segment "$jwt_payload_segment" >"$jwt_payload" || return 1
  chmod 0600 "$jwt_header" "$jwt_payload" || return 1
  now="$(date -u +%s)" || return 1
  jq -e '
    .alg == "RS256"
    and (.kid | type) == "string"
    and (.kid | length) > 0
  ' "$jwt_header" >/dev/null || return 1
  jq -e \
    --arg audience "$audience" \
    --arg project "$project_id" \
    --arg zone "$instance_zone" \
    --arg instance "$instance_id" \
    --arg email "$service_account_email" \
    --argjson now "$now" '
      .iss == "https://accounts.google.com"
      and .aud == $audience
      and .email == $email
      and .email_verified == true
      and .google.compute_engine.project_id == $project
      and .google.compute_engine.zone == $zone
      and (.google.compute_engine.instance_id | tostring) == $instance
      and (.iat | type) == "number" and .iat <= ($now + 60)
      and (.exp | type) == "number" and .exp > $now and .exp <= ($now + 3700)
    ' "$jwt_payload" >/dev/null || return 1

  jq -n --rawfile bearer "$identity_jwt" \
    --arg auth_method "$GCE_AGENT_AUTH_METHOD" '
      {AuthMethod:$auth_method,BearerToken:($bearer | gsub("[\\r\\n]+$"; ""))}
    ' >"$login_payload" || return 1
  # Never send the signed GCE identity JWT or the derived Consul SecretID to a
  # remote HTTP listener. Bootstrap starts the recovery-only local agent first
  # and the exchange is accepted only through the loopback HTTP listener.
  printf '%s\n' '127.0.0.1' >"$endpoints_file" || return 1

  login_code=""
  login_endpoint=""
  for _ in {1..60}; do
    while IFS= read -r endpoint; do
      [[ -n "$endpoint" ]] || continue
      [[ "$endpoint" == '127.0.0.1' ]] || return 1
      login_code="$(curl_direct --proto '=http' --connect-timeout 2 --max-time 5 \
        --silent --show-error --output "$login_response" --write-out '%{http_code}' \
        --request POST --header 'Content-Type: application/json' \
        --data-binary "@$login_payload" "http://$endpoint:8500/v1/acl/login" \
        2>/dev/null || true)"
      if [[ "$login_code" == 200 ]]; then
        login_endpoint="$endpoint"
        break 2
      fi
    done <"$endpoints_file"
    sleep 1
  done
  [[ "$login_code" == 200 && -n "$login_endpoint" ]] || return 1
  if ! jq -er '.SecretID | select(test("^[0-9A-Fa-f-]{36}$"))' \
    "$login_response" >"$agent_token_file"; then
    return 1
  fi
  chmod 0600 "$agent_token_file" || return 1
  if ! persist_gce_agent_pending_revoke "$agent_token_file" "$login_endpoint"; then
    revoke_gce_agent_login_token "$agent_token_file" "$login_endpoint" || true
    return 1
  fi
  pending_revoke="$REPLY"
  if ! jq -e --arg node "$instance_id" --arg dc "$datacenter" '
    .Local == true
    and ((.Policies // []) | length) == 0
    and ((.Roles // []) | length) == 0
    and ((.ServiceIdentities // []) | length) == 0
    and .NodeIdentities == [{NodeName:$node,Datacenter:$dc}]
    and (.SecretID | test("^[0-9A-Fa-f-]{36}$"))
    and (.AccessorID | test("^[0-9A-Fa-f-]{36}$"))
    and (.ExpirationTime | fromdateiso8601) > now
    and (.ExpirationTime | fromdateiso8601) <= (now + 3700)
  ' "$login_response" >/dev/null; then
    abort_gce_agent_identity_acquisition "$pending_revoke" "$work_dir"
    trap - RETURN
    return 1
  fi
  # The signed JWT is needed only for the login exchange. Remove every copy
  # before installing or probing the derived, least-privilege token.
  rm -f -- "$identity_jwt" "$login_payload"

  {
    printf 'fail\nsilent\nshow-error\nheader = "X-Consul-Token: '
    tr -d '\r\n' <"$agent_token_file"
    printf '"\n'
  } >"$token_curl_config"
  chmod 0600 "$token_curl_config"
  {
    printf '%s\n' "$login_endpoint"
    grep -Fvx "$login_endpoint" "$endpoints_file" || true
  } >"$probe_endpoints"
  verified_endpoint=""
  for _ in {1..60}; do
    while IFS= read -r endpoint; do
      [[ -n "$endpoint" ]] || continue
      [[ "$endpoint" == '127.0.0.1' ]] || return 1
      probe_code="$(curl_direct --proto '=http' --connect-timeout 2 --max-time 5 \
        --config "$token_curl_config" --output "$token_probe" \
        --write-out '%{http_code}' "http://$endpoint:8500/v1/acl/token/self" \
        2>/dev/null || true)"
      if [[ "$probe_code" == 200 ]] && jq -e \
        --arg node "$instance_id" --arg dc "$datacenter" '
          .NodeIdentities == [{NodeName:$node,Datacenter:$dc}]
          and ((.Policies // []) | length) == 0
          and ((.Roles // []) | length) == 0
          and ((.ServiceIdentities // []) | length) == 0
          and (.ExpirationTime | fromdateiso8601) > now
        ' "$token_probe" >/dev/null; then
        verified_endpoint="$endpoint"
        break 2
      fi
    done <"$probe_endpoints"
    sleep 1
  done
  if [[ -z "$verified_endpoint" ]]; then
    abort_gce_agent_identity_acquisition "$pending_revoke" "$work_dir"
    trap - RETURN
    return 1
  fi
  if ! write_gce_agent_runtime_config \
    "$agent_token_file" "$consul_user" "$login_response" "$instance_id"; then
    abort_gce_agent_identity_acquisition "$pending_revoke" "$work_dir"
    trap - RETURN
    return 1
  fi
  rm -rf -- "$work_dir"
  trap - RETURN
}

function revoke_gce_agent_login_token {
  (
  local -r token_file="$1"
  local -r endpoint="${2:-127.0.0.1}"
  local work_dir
  local curl_config
  local response
  local code=""

  [[ -f "$token_file" && ! -L "$token_file" ]]
  [[ "$endpoint" == '127.0.0.1' ]]
  work_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-agent-logout.XXXXXX")"
  trap 'rm -rf -- "$work_dir"' EXIT
  curl_config="$work_dir/logout.curl"
  response="$work_dir/response"
  {
    printf 'fail\nsilent\nshow-error\nheader = "X-Consul-Token: '
    tr -d '\r\n' <"$token_file"
    printf '"\n'
  } >"$curl_config"
  chmod 0600 "$curl_config"
  for _ in {1..3}; do
    code="$(curl_direct --proto '=http' --connect-timeout 2 --max-time 5 \
      --config "$curl_config" --output "$response" --write-out '%{http_code}' \
      --request POST "http://$endpoint:8500/v1/acl/logout" 2>/dev/null || true)"
    [[ "$code" == 200 ]] && return 0
    code="$(curl_direct --proto '=http' --connect-timeout 2 --max-time 5 \
      --config "$curl_config" --output "$response" --write-out '%{http_code}' \
      "http://$endpoint:8500/v1/acl/token/self" 2>/dev/null || true)"
    # Logout is complete if Consul positively rejects the old SecretID. A
    # transport failure is never evidence of revocation and is retried.
    [[ "$code" == 403 || "$code" == 404 ]] && return 0
    sleep 1
  done
  log_error "Failed to revoke the superseded GCE-attested Consul agent login token"
  return 1
  )
}

function reload_gce_agent_identity {
  # Agent recovery is a random, per-boot, unregistered local credential. It is
  # the only token Consul accepts synchronously for AgentReload without giving
  # the GCE node identity broad agent:write privileges. The API response is the
  # positive reload acknowledgement; SIGHUP alone cannot report parse failure.
  gce_agent_boot_is_ready
  [[ -f "$GCE_AGENT_RECOVERY_TOKEN" && ! -L "$GCE_AGENT_RECOVERY_TOKEN" ]]
  consul_local_with_token "$GCE_AGENT_RECOVERY_TOKEN" reload
}

function fail_close_consul_agent {
  log_error "Fail-closing Consul without graceful leave because its attested agent identity is inside the expiry safety window"
  systemctl mask --runtime consul.service >/dev/null 2>&1 || true
  systemctl kill --kill-who=main --signal=KILL consul.service >/dev/null 2>&1 || true
  for _ in {1..30}; do
    systemctl is-active --quiet consul.service || break
    sleep 1
  done
  systemctl is-active --quiet consul.service && return 1
  systemctl stop consul.service >/dev/null 2>&1 || true
}

function prepare_gce_agent_rotation_journal {
  (
  local journal_tmp
  local transaction_tmp
  local old_accessor
  local old_token_sha256
  local boot_id
  local node_id

  [[ ! -e "$GCE_AGENT_ROTATION_JOURNAL" && ! -L "$GCE_AGENT_ROTATION_JOURNAL" ]]
  journal_tmp="$(mktemp -d "$GCE_AGENT_RUNTIME_DIR/rotation-transaction.XXXXXX")"
  trap 'rm -rf -- "$journal_tmp"' EXIT
  chmod 0700 "$journal_tmp"
  chown root:root "$journal_tmp"
  snapshot_gce_agent_runtime "$journal_tmp" || return 1
  old_accessor="$(jq -er '.accessor_id | select(test("^[0-9A-Fa-f-]{36}$"))' \
    "$journal_tmp/lease.json")"
  old_token_sha256="$(sha256sum "$journal_tmp/agent-token" | awk '{print $1}')"
  boot_id="$(get_boot_id)"
  node_id="$(get_instance_id)"
  transaction_tmp="$(mktemp "$journal_tmp/transaction.XXXXXX")"
  jq -n \
    --arg boot_id "$boot_id" \
    --arg node_id "$node_id" \
    --arg old_accessor "$old_accessor" \
    --arg old_token_sha256 "$old_token_sha256" '
      {
        schema:1,
        state:"prepared",
        boot_id:$boot_id,
        node_id:$node_id,
        old_accessor:$old_accessor,
        old_token_sha256:$old_token_sha256
      }
    ' >"$transaction_tmp"
  chmod 0600 "$transaction_tmp"
  chown root:root "$transaction_tmp"
  mv -f -- "$transaction_tmp" "$journal_tmp/transaction.json"
  mv -- "$journal_tmp" "$GCE_AGENT_ROTATION_JOURNAL"
  trap - EXIT
  )
}

function validate_gce_agent_rotation_journal {
  local old_token_sha256

  [[ -d "$GCE_AGENT_ROTATION_JOURNAL" && ! -L "$GCE_AGENT_ROTATION_JOURNAL" ]]
  [[ -f "$GCE_AGENT_ROTATION_JOURNAL/transaction.json" \
    && ! -L "$GCE_AGENT_ROTATION_JOURNAL/transaction.json" ]]
  gce_agent_generation_is_valid \
    "$GCE_AGENT_ROTATION_JOURNAL/agent-token.json" \
    "$GCE_AGENT_ROTATION_JOURNAL/agent-token" \
    "$GCE_AGENT_ROTATION_JOURNAL/agent-recovery-token" \
    "$GCE_AGENT_ROTATION_JOURNAL/lease.json" ignore
  old_token_sha256="$(sha256sum \
    "$GCE_AGENT_ROTATION_JOURNAL/agent-token" | awk '{print $1}')"
  jq -e \
    --arg boot_id "$(get_boot_id)" \
    --arg node_id "$(get_instance_id)" \
    --arg old_accessor "$(jq -er '.accessor_id' \
      "$GCE_AGENT_ROTATION_JOURNAL/lease.json")" \
    --arg old_token_sha256 "$old_token_sha256" '
      .schema == 1
      and (.state == "prepared" or .state == "candidate-installed")
      and .boot_id == $boot_id
      and .node_id == $node_id
      and .old_accessor == $old_accessor
      and .old_token_sha256 == $old_token_sha256
    ' "$GCE_AGENT_ROTATION_JOURNAL/transaction.json" >/dev/null
  if [[ -e "$GCE_AGENT_ROTATION_JOURNAL/candidate-token" ]]; then
    [[ -f "$GCE_AGENT_ROTATION_JOURNAL/candidate-token" \
      && ! -L "$GCE_AGENT_ROTATION_JOURNAL/candidate-token" ]]
    grep -Eq '^[0-9A-Fa-f-]{36}$' \
      "$GCE_AGENT_ROTATION_JOURNAL/candidate-token"
  fi
}

function record_gce_agent_rotation_candidate {
  local candidate_tmp
  local transaction_tmp
  local candidate_accessor
  local candidate_token_sha256

  validate_gce_agent_rotation_journal
  gce_agent_runtime_has_headroom 0
  candidate_accessor="$(jq -er \
    '.accessor_id | select(test("^[0-9A-Fa-f-]{36}$"))' \
    "$GCE_AGENT_RUNTIME_LEASE")"
  candidate_token_sha256="$(sha256sum "$GCE_AGENT_RUNTIME_TOKEN" | awk '{print $1}')"
  candidate_tmp="$(mktemp "$GCE_AGENT_ROTATION_JOURNAL/candidate-token.XXXXXX")"
  cp -- "$GCE_AGENT_RUNTIME_TOKEN" "$candidate_tmp"
  chmod 0600 "$candidate_tmp"
  chown root:root "$candidate_tmp"
  mv -f -- "$candidate_tmp" "$GCE_AGENT_ROTATION_JOURNAL/candidate-token"
  transaction_tmp="$(mktemp "$GCE_AGENT_ROTATION_JOURNAL/transaction.XXXXXX")"
  jq \
    --arg candidate_accessor "$candidate_accessor" \
    --arg candidate_token_sha256 "$candidate_token_sha256" '
      .state = "candidate-installed"
      | .candidate_accessor = $candidate_accessor
      | .candidate_token_sha256 = $candidate_token_sha256
    ' "$GCE_AGENT_ROTATION_JOURNAL/transaction.json" >"$transaction_tmp"
  chmod 0600 "$transaction_tmp"
  chown root:root "$transaction_tmp"
  mv -f -- "$transaction_tmp" "$GCE_AGENT_ROTATION_JOURNAL/transaction.json"
}

function activate_current_gce_agent_generation {
  local temporary_boot_marker=false

  # The first per-node generation is installed before the startup path can
  # publish its final boot-ready marker. ExecReload itself is constrained to
  # that marker, so create it only after validating the complete current-boot
  # runtime tuple. Bootstrap cleanup removes it if any later step fails.
  if ! gce_agent_boot_is_ready; then
    mark_gce_agent_boot_ready "$(get_instance_id)" || return 1
    temporary_boot_marker=true
  fi
  if systemctl is-active --quiet consul.service; then
    if ! systemctl reload consul.service; then
      [[ "$temporary_boot_marker" != true ]] || rm -f -- "$GCE_AGENT_BOOT_READY"
      return 1
    fi
  else
    if ! systemctl unmask --runtime consul.service \
      || ! systemctl daemon-reload \
      || ! systemctl start consul.service; then
      [[ "$temporary_boot_marker" != true ]] || rm -f -- "$GCE_AGENT_BOOT_READY"
      return 1
    fi
  fi
  if ! systemctl is-active --quiet consul.service; then
    [[ "$temporary_boot_marker" != true ]] || rm -f -- "$GCE_AGENT_BOOT_READY"
    return 1
  fi
}

function adopt_unacknowledged_current_gce_agent_generation {
  local token_sha256
  local pending_path

  REPLY=absent
  # acquire_gce_agent_identity persists the self-revocation record before it
  # installs the returned generation. A SIGKILL after that atomic install but
  # before activation therefore leaves an otherwise valid runtime tuple whose
  # token is deliberately still marked pending. Adopt only that exact tuple,
  # and only after Consul synchronously acknowledges it; otherwise the pending
  # record remains the fail-closed retry barrier.
  gce_agent_runtime_has_headroom "$GCE_AGENT_MINIMUM_HEADROOM_SECONDS" \
    || return 0
  token_sha256="$(sha256sum "$GCE_AGENT_RUNTIME_TOKEN" | awk '{print $1}')"
  pending_path="$GCE_AGENT_PENDING_REVOKE_DIR/token-$token_sha256.json"
  [[ -e "$pending_path" ]] || return 0
  validate_gce_agent_pending_revoke "$pending_path"
  if ! activate_current_gce_agent_generation \
    || ! systemctl is-active --quiet consul.service \
    || ! gce_agent_runtime_has_headroom \
      "$GCE_AGENT_MINIMUM_HEADROOM_SECONDS" \
    || ! acknowledge_gce_agent_login_token "$GCE_AGENT_RUNTIME_TOKEN"; then
    fail_close_consul_agent
    return 1
  fi
  REPLY=adopted
}

function capture_current_candidate_for_revocation {
  local candidate_tmp

  [[ -f "$GCE_AGENT_RUNTIME_TOKEN" && ! -L "$GCE_AGENT_RUNTIME_TOKEN" ]] \
    || return 0
  grep -Eq '^[0-9A-Fa-f-]{36}$' "$GCE_AGENT_RUNTIME_TOKEN" || return 0
  cmp -s "$GCE_AGENT_RUNTIME_TOKEN" \
    "$GCE_AGENT_ROTATION_JOURNAL/agent-token" && return 0
  candidate_tmp="$(mktemp "$GCE_AGENT_ROTATION_JOURNAL/candidate-token.XXXXXX")"
  cp -- "$GCE_AGENT_RUNTIME_TOKEN" "$candidate_tmp"
  chmod 0600 "$candidate_tmp"
  chown root:root "$candidate_tmp"
  mv -f -- "$candidate_tmp" "$GCE_AGENT_ROTATION_JOURNAL/candidate-token"
}

function reconcile_interrupted_gce_agent_rotation {
  local -r consul_user="$1"
  local old_has_headroom=false
  local current_is_valid=false
  local current_is_old=false

  REPLY=complete
  validate_gce_agent_rotation_journal
  if gce_agent_generation_is_valid \
    "$GCE_AGENT_ROTATION_JOURNAL/agent-token.json" \
    "$GCE_AGENT_ROTATION_JOURNAL/agent-token" \
    "$GCE_AGENT_ROTATION_JOURNAL/agent-recovery-token" \
    "$GCE_AGENT_ROTATION_JOURNAL/lease.json" 0; then
    old_has_headroom=true
  fi
  if gce_agent_runtime_has_headroom 0; then
    current_is_valid=true
    if cmp -s "$GCE_AGENT_RUNTIME_TOKEN" \
      "$GCE_AGENT_ROTATION_JOURNAL/agent-token"; then
      current_is_old=true
    fi
  fi

  capture_current_candidate_for_revocation
  if [[ "$current_is_valid" == true && "$current_is_old" == false ]]; then
    # A previous process may have died after installing or reloading the new
    # tuple. Synchronously acknowledge the on-disk generation before the old
    # self-authorized token is ever logged out.
    if ! activate_current_gce_agent_generation; then
      log_error "Interrupted Consul agent rotation could not activate its candidate; restoring the journaled generation"
      if [[ "$old_has_headroom" != true ]] \
        || ! restore_gce_agent_runtime "$GCE_AGENT_ROTATION_JOURNAL" "$consul_user" \
        || ! activate_current_gce_agent_generation; then
        fail_close_consul_agent
        return 1
      fi
      if [[ -f "$GCE_AGENT_ROTATION_JOURNAL/candidate-token" ]]; then
        revoke_gce_agent_login_token \
          "$GCE_AGENT_ROTATION_JOURNAL/candidate-token" || return 1
        acknowledge_gce_agent_login_token \
          "$GCE_AGENT_ROTATION_JOURNAL/candidate-token"
      fi
      rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
      gce_agent_runtime_has_headroom "$GCE_AGENT_MINIMUM_HEADROOM_SECONDS" \
        || REPLY=rotate
      return 0
    fi
    acknowledge_gce_agent_login_token "$GCE_AGENT_RUNTIME_TOKEN"
    revoke_gce_agent_login_token \
      "$GCE_AGENT_ROTATION_JOURNAL/agent-token" || return 1
    rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
    return 0
  fi

  if [[ "$current_is_valid" == false ]]; then
    if [[ "$old_has_headroom" != true ]] \
      || ! restore_gce_agent_runtime "$GCE_AGENT_ROTATION_JOURNAL" "$consul_user" \
      || ! activate_current_gce_agent_generation; then
      fail_close_consul_agent
      return 1
    fi
  fi
  if ! systemctl is-active --quiet consul.service \
    && ! activate_current_gce_agent_generation; then
    fail_close_consul_agent
    return 1
  fi
  if [[ -f "$GCE_AGENT_ROTATION_JOURNAL/candidate-token" ]]; then
    revoke_gce_agent_login_token \
      "$GCE_AGENT_ROTATION_JOURNAL/candidate-token" || return 1
    acknowledge_gce_agent_login_token \
      "$GCE_AGENT_ROTATION_JOURNAL/candidate-token"
  fi
  rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
  gce_agent_runtime_has_headroom "$GCE_AGENT_MINIMUM_HEADROOM_SECONDS" \
    || REPLY=rotate
}

function refresh_gce_agent_identity {
  (
  local -r datacenter="$1"
  local -r consul_user="$2"
  local journal_created=false
  local was_active=false
  local old_accessor=""
  local new_accessor=""

  # A timer left behind by an earlier boot is never authority to start Consul.
  # The metadata startup path creates this generation only after every required
  # secret, auth exchange, and initial Consul start has succeeded.
  gce_agent_boot_is_ready || {
    log_error "Refusing Consul agent refresh without this boot's readiness generation"
    return 1
  }

  if [[ -e "$GCE_AGENT_ROTATION_JOURNAL" ]]; then
    reconcile_interrupted_gce_agent_rotation "$consul_user"
    [[ "$REPLY" == complete ]] && return 0
  fi
  adopt_unacknowledged_current_gce_agent_generation || return 1
  [[ "$REPLY" == adopted ]] && return 0
  if systemctl is-active --quiet consul.service; then
    was_active=true
  fi
  if gce_agent_runtime_has_headroom 0; then
    if ! prepare_gce_agent_rotation_journal; then
      log_error "Refusing Consul agent rotation without a complete validated rollback journal"
      return 1
    fi
    journal_created=true
    old_accessor="$(jq -er '.accessor_id' \
      "$GCE_AGENT_ROTATION_JOURNAL/lease.json")"
  elif [[ "$was_active" == true ]]; then
    # An active process with no complete current generation cannot be safely
    # mutated because a rejected reload would have no proven rollback tuple.
    fail_close_consul_agent
    return 1
  fi

  if ! acquire_gce_agent_identity \
    "$datacenter" "$consul_user"; then
    # Never let a node continue silently after its last proven token approaches
    # expiry. The timer keeps retrying; a later successful login starts Consul
    # again from the atomically replaced runtime config.
    if [[ "$journal_created" == true ]] \
      && cmp -s "$GCE_AGENT_RUNTIME_TOKEN" \
        "$GCE_AGENT_ROTATION_JOURNAL/agent-token"; then
      rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
      journal_created=false
    fi
    if ! gce_agent_runtime_has_headroom "$GCE_AGENT_MINIMUM_HEADROOM_SECONDS"; then
      fail_close_consul_agent
    fi
    return 1
  fi
  new_accessor="$(jq -er '.accessor_id' "$GCE_AGENT_RUNTIME_LEASE")"
  if [[ "$journal_created" == true ]]; then
    record_gce_agent_rotation_candidate
  fi

  if ! activate_current_gce_agent_generation; then
    log_error "Consul rejected the refreshed agent generation; restoring the previous proven runtime generation"
    if [[ "$journal_created" != true ]] \
      || ! restore_gce_agent_runtime "$GCE_AGENT_ROTATION_JOURNAL" "$consul_user" \
      || ! activate_current_gce_agent_generation; then
      # A rollback that cannot be synchronously acknowledged is not a
      # rollback. Preserve the journal and kill the process without leave.
      fail_close_consul_agent
      return 1
    fi
    if ! revoke_gce_agent_login_token \
      "$GCE_AGENT_ROTATION_JOURNAL/candidate-token"; then
      if ! gce_agent_runtime_has_headroom "$GCE_AGENT_MINIMUM_HEADROOM_SECONDS"; then
        fail_close_consul_agent
      fi
      return 1
    fi
    acknowledge_gce_agent_login_token \
      "$GCE_AGENT_ROTATION_JOURNAL/candidate-token"
    rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
    return 1
  fi
  if ! systemctl is-active --quiet consul.service \
    || ! gce_agent_runtime_has_headroom "$GCE_AGENT_MINIMUM_HEADROOM_SECONDS"; then
    fail_close_consul_agent
    return 1
  fi
  acknowledge_gce_agent_login_token "$GCE_AGENT_RUNTIME_TOKEN"

  # Re-login must not leave the superseded auth-method token usable until TTL.
  # Logout is self-authorized by the old short-lived token and carries no token
  # in argv, process environment, logs, or artifacts. The root-only journal is
  # intentionally retained across process death or logout failure, so the next
  # timer invocation resumes this revocation before acquiring another token.
  if [[ "$journal_created" == true ]]; then
    if [[ -n "$old_accessor" && "$old_accessor" != "$new_accessor" ]]; then
      if ! revoke_gce_agent_login_token \
        "$GCE_AGENT_ROTATION_JOURNAL/agent-token"; then
        return 1
      fi
    fi
    rm -rf -- "$GCE_AGENT_ROTATION_JOURNAL"
  fi
  )
}

function install_gce_agent_refresh_timer {
  local -r datacenter="$1"
  local -r consul_user="$2"
  local service_tmp
  local timer_tmp

  [[ "$consul_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
  service_tmp="$(mktemp "${GCE_AGENT_REFRESH_SERVICE}.XXXXXX")"
  timer_tmp="$(mktemp "${GCE_AGENT_REFRESH_TIMER}.XXXXXX")"
  cat >"$service_tmp" <<EOF
[Unit]
Description=Refresh the GCE-attested Consul agent ACL identity
After=network-online.target consul.service
Wants=network-online.target
ConditionPathExists=$GCE_AGENT_BOOT_READY

[Service]
Type=oneshot
User=root
UMask=0077
ExecStart=$SCRIPT_DIR/run-consul.sh --refresh-gce-agent --datacenter $datacenter --user $consul_user
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$GCE_AGENT_RUNTIME_DIR
EOF
  cat >"$timer_tmp" <<'EOF'
[Unit]
Description=Renew the GCE-attested Consul agent ACL identity before expiry

[Timer]
OnBootSec=5m
OnUnitInactiveSec=10m
RandomizedDelaySec=2m
AccuracySec=30s
Persistent=false
Unit=e2b-consul-agent-refresh.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$service_tmp" "$timer_tmp"
  chown root:root "$service_tmp" "$timer_tmp"
  mv -f -- "$service_tmp" "$GCE_AGENT_REFRESH_SERVICE"
  mv -f -- "$timer_tmp" "$GCE_AGENT_REFRESH_TIMER"
  systemctl daemon-reload
  # Deliberately do not persistently enable this timer. Metadata startup must
  # revalidate this boot and start it only after writing boot-ready.json.
  systemctl disable e2b-consul-agent-refresh.timer >/dev/null 2>&1 || true
  systemctl unmask --runtime e2b-consul-agent-refresh.service e2b-consul-agent-refresh.timer
  systemctl start e2b-consul-agent-refresh.timer
}

function setup_gce_agent_auth {
  (
    local -r management_token="$1"
    local project_id="$2"
    local region="$3"
    shift 3
    local -a service_accounts=("$@")
    local work_dir
    local auth_method_payload
    local auth_method_readback
    local binding_payload
    local binding_rules
    local binding_response
    local selected_binding_id
    local selector
    local service_account
    local account_clause=""

    [[ "$project_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
    [[ "$region" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]
    [[ "${#service_accounts[@]}" -gt 0 ]]
    for service_account in "${service_accounts[@]}"; do
      [[ "$service_account" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]
      if [[ -n "$account_clause" ]]; then
        account_clause+=" or "
      fi
      account_clause+="value.service_account_email == \"$service_account\""
    done
    selector="value.project_id == \"$project_id\" and value.zone matches \"^$region-[a-z]$\" and value.email_verified == \"true\" and ($account_clause)"

    work_dir="$(mktemp -d "$BOOTSTRAP_RUNTIME_ROOT/e2b-consul-gce-auth.XXXXXX")"
    trap 'rm -rf -- "$work_dir"' EXIT
    auth_method_payload="$work_dir/auth-method.json"
    auth_method_readback="$work_dir/auth-method-readback.json"
    binding_payload="$work_dir/binding-rule.json"
    binding_rules="$work_dir/binding-rules.json"
    binding_response="$work_dir/binding-response.json"

    jq -n \
      --arg name "$GCE_AGENT_AUTH_METHOD" \
      --arg description "$GCE_AGENT_AUTH_DESCRIPTION" \
      --arg max_token_ttl "$GCE_AGENT_TOKEN_TTL" \
      --arg audience "https://consul.$project_id.internal/e2b/gce-agent" '
        {
          Name:$name,
          Type:"jwt",
          Description:$description,
          TokenLocality:"local",
          MaxTokenTTL:$max_token_ttl,
          Config:{
            OIDCDiscoveryURL:"https://accounts.google.com",
            BoundAudiences:[$audience],
            BoundIssuer:"https://accounts.google.com",
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
      ' >"$auth_method_payload"
    consul_api_put_file "$management_token" \
      "/v1/acl/auth-method/$GCE_AGENT_AUTH_METHOD" "$auth_method_payload"
    consul_api_get_file "$management_token" \
      "/v1/acl/auth-method/$GCE_AGENT_AUTH_METHOD" "$auth_method_readback"
    jq -e --slurpfile expected "$auth_method_payload" '
      .Name == $expected[0].Name
      and .Type == $expected[0].Type
      and .Description == $expected[0].Description
      and .TokenLocality == $expected[0].TokenLocality
      and .MaxTokenTTL == $expected[0].MaxTokenTTL
      and .Config.OIDCDiscoveryURL == $expected[0].Config.OIDCDiscoveryURL
      and .Config.BoundAudiences == $expected[0].Config.BoundAudiences
      and .Config.BoundIssuer == $expected[0].Config.BoundIssuer
      and .Config.JWTSupportedAlgs == $expected[0].Config.JWTSupportedAlgs
      and .Config.ClaimMappings == $expected[0].Config.ClaimMappings
    ' "$auth_method_readback" >/dev/null

    jq -n \
      --arg description "$GCE_AGENT_BINDING_DESCRIPTION" \
      --arg auth_method "$GCE_AGENT_AUTH_METHOD" \
      --arg selector "$selector" '
        {
          Description:$description,
          AuthMethod:$auth_method,
          Selector:$selector,
          BindType:"node",
          BindName:"${value.instance_id}"
        }
      ' >"$binding_payload"

    for _ in {1..10}; do
      consul_api_get_file "$management_token" \
        "/v1/acl/binding-rules?authmethod=$GCE_AGENT_AUTH_METHOD" "$binding_rules"
      jq -e --arg auth "$GCE_AGENT_AUTH_METHOD" '
        type == "array" and all(.[]; .AuthMethod == $auth)
      ' "$binding_rules" >/dev/null
      if [[ "$(jq 'length' "$binding_rules")" -eq 0 ]]; then
        consul_api_put_file_result "$management_token" '/v1/acl/binding-rule' \
          "$binding_payload" "$binding_response"
        sleep 0.2
        continue
      fi
      if ! jq -e --arg description "$GCE_AGENT_BINDING_DESCRIPTION" '
        all(.[]; .Description == $description)
      ' "$binding_rules" >/dev/null; then
        log_error "Unexpected binding rule exists for the GCE agent auth method"
        return 1
      fi
      selected_binding_id="$(jq -er 'map(.ID) | sort | first' "$binding_rules")"
      while IFS= read -r duplicate_id; do
        [[ "$duplicate_id" == "$selected_binding_id" ]] || \
          consul_api_delete "$management_token" "/v1/acl/binding-rule/$duplicate_id"
      done < <(jq -r '.[].ID' "$binding_rules")
      jq --arg id "$selected_binding_id" '. + {ID:$id}' \
        "$binding_payload" >"$binding_response"
      consul_api_put_file "$management_token" \
        "/v1/acl/binding-rule/$selected_binding_id" "$binding_response"
      consul_api_get_file "$management_token" \
        "/v1/acl/binding-rules?authmethod=$GCE_AGENT_AUTH_METHOD" "$binding_rules"
      if jq -e --slurpfile expected "$binding_payload" '
        length == 1
        and .[0].Description == $expected[0].Description
        and .[0].AuthMethod == $expected[0].AuthMethod
        and .[0].Selector == $expected[0].Selector
        and .[0].BindType == $expected[0].BindType
        and .[0].BindName == $expected[0].BindName
      ' "$binding_rules" >/dev/null; then
        return 0
      fi
      sleep 0.2
    done
    log_error "GCE agent auth binding rule did not converge"
    return 1
  )
}
