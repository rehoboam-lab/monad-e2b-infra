#!/usr/bin/env bash

set -euo pipefail

readonly metadata_url="http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
readonly runtime_root="/run"

die() {
  printf 'Secret Manager bootstrap failed: %s\n' "$1" >&2
  exit 1
}

[[ "$#" -eq 3 ]] || die 'expected SECRET_RESOURCE, OUTPUT_FILE, and SECRET_KIND'

secret_resource="$1"
output_file="$2"
secret_kind="$3"

[[ "$secret_resource" =~ ^projects/[0-9A-Za-z._:-]+/secrets/[0-9A-Za-z._-]+$ ]] \
  || die 'invalid Secret Manager resource name'
[[ "$output_file" == /* ]] || die 'output path must be absolute'
[[ "$secret_kind" == "uuid" || "$secret_kind" == "consul-gossip-key" ]] \
  || die 'invalid secret kind'
[[ -d "$runtime_root" ]] || die 'secure runtime directory is unavailable'

umask 077
work_dir="$(mktemp -d "$runtime_root/e2b-gcp-secret-fetch.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

token_response="$work_dir/metadata-token.json"
secret_response="$work_dir/secret-response.json"
curl_config="$work_dir/secret-manager.curl"
secret_tmp="$work_dir/secret"

if ! curl \
  --fail \
  --silent \
  --show-error \
  --retry 5 \
  --retry-all-errors \
  --connect-timeout 5 \
  --max-time 20 \
  --header 'Metadata-Flavor: Google' \
  --output "$token_response" \
  "$metadata_url"; then
  die 'attached-service-account token request failed'
fi

access_token="$(jq -er '.access_token | select(type == "string" and length > 0)' "$token_response")" \
  || die 'metadata server returned no access token'

cat >"$curl_config" <<EOF
fail
silent
show-error
retry = 5
retry-all-errors
connect-timeout = 5
max-time = 30
header = "Authorization: Bearer $access_token"
url = "https://secretmanager.googleapis.com/v1/$secret_resource/versions/latest:access"
output = "$secret_response"
EOF
unset access_token
rm -f -- "$token_response"

if ! curl --config "$curl_config"; then
  die 'secret access request failed'
fi
rm -f -- "$curl_config"

jq -er '.payload.data | select(type == "string" and length > 0)' "$secret_response" \
  | base64 --decode >"$secret_tmp" \
  || die 'secret response payload was missing or invalid'

[[ -s "$secret_tmp" ]] || die 'secret payload was empty'
case "$secret_kind" in
uuid)
  if [[ "$(wc -c <"$secret_tmp" | tr -d '[:space:]')" != "36" ]] \
    || ! grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' "$secret_tmp"; then
    die 'UUID secret payload was invalid'
  fi
  ;;
consul-gossip-key)
  decoded_gossip="$work_dir/gossip.decoded"
  if [[ "$(wc -c <"$secret_tmp" | tr -d '[:space:]')" != "44" ]] \
    || ! grep -Eq '^[A-Za-z0-9+/]{43}=$' "$secret_tmp" \
    || ! base64 --decode <"$secret_tmp" >"$decoded_gossip" 2>/dev/null \
    || [[ "$(wc -c <"$decoded_gossip" | tr -d '[:space:]')" != "32" ]]; then
    die 'Consul gossip key was not an exact base64-encoded 32-byte value'
  fi
  ;;
esac

if [[ -L "$output_file" || ( -e "$output_file" && ! -f "$output_file" ) ]]; then
  die 'refusing to replace a non-regular output path'
fi

install -m 0600 "$secret_tmp" "$output_file"
