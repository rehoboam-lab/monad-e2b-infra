#!/usr/bin/env bash

# Refresh systemd-resolved's Consul DNS upstreams from the exact Terraform-
# owned regional server MIG. Every member is independently admitted by
# immutable instance URL plus role, service account, VPC/subnet, tag, private-
# only networking, and stable RUNNING state. A partial or poisoned result
# leaves the last known-good resolver set installed.

set -euo pipefail
umask 077

if [[ "$#" -ne 5 ]]; then
  echo "usage: refresh-consul-resolvers.sh <region> <server-mig> <server-tag> <role-label> <server-service-account>" >&2
  exit 2
fi

readonly region="$1"
readonly server_mig="$2"
readonly server_tag="$3"
readonly server_role="$4"
readonly server_service_account="$5"
readonly metadata_url="${METADATA_URL:-http://metadata.google.internal/computeMetadata/v1}"
readonly resolved_dropin_dir="${RESOLVED_DROPIN_DIR:-/etc/systemd/resolved.conf.d}"
readonly resolver_file="$resolved_dropin_dir/consul.conf"
readonly lock_file="${LOCK_FILE:-/run/e2b-consul-resolver-refresh.lock}"
readonly gcloud_bin="${GCLOUD_BIN:-gcloud}"
readonly systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"

[[ "$region" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || { echo "invalid region" >&2; exit 2; }
[[ "$server_mig" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || { echo "invalid server MIG" >&2; exit 2; }
[[ "$server_tag" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { echo "invalid server tag" >&2; exit 2; }
[[ "$server_role" =~ ^[a-z0-9_-]{1,63}$ ]] || { echo "invalid server role" >&2; exit 2; }
[[ "$server_service_account" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || {
  echo "invalid server service account" >&2
  exit 2
}

metadata_get() {
  env -u ALL_PROXY -u all_proxy -u HTTP_PROXY -u http_proxy \
    -u HTTPS_PROXY -u https_proxy -u NO_PROXY -u no_proxy \
    curl --fail --silent --show-error --noproxy '*' \
      --header 'Metadata-Flavor: Google' "$metadata_url/$1"
}

install -d -m 0755 "$resolved_dropin_dir"
exec 9>"$lock_file"
if ! flock -n 9; then
  exit 0
fi

project_id="${PROJECT_ID_OVERRIDE:-$(metadata_get project/project-id)}"
network_name="${NETWORK_NAME_OVERRIDE:-$(metadata_get instance/network-interfaces/0/network | awk -F/ '{print $NF}')}"
subnetwork_name="${SUBNETWORK_NAME_OVERRIDE:-$(metadata_get instance/network-interfaces/0/subnetwork | awk -F/ '{print $NF}')}"
[[ "$project_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { echo "invalid GCP project ID" >&2; exit 1; }
[[ "$network_name" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || { echo "invalid VPC name" >&2; exit 1; }
[[ "$subnetwork_name" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || { echo "invalid subnet name" >&2; exit 1; }

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/e2b-consul-resolvers.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
membership="$work_dir/membership.json"
"$gcloud_bin" compute instance-groups managed list-instances "$server_mig" \
  --region "$region" --project "$project_id" --format=json >"$membership"

jq -e --arg project "$project_id" --arg region "$region" '
  type == "array" and length > 0
  and all(.[];
    .instanceStatus == "RUNNING"
    and .currentAction == "NONE"
    and (.instance | type) == "string"
    and (.instance | test(
      "^https://www\\.googleapis\\.com/compute/v1/projects/" + $project
      + "/zones/" + $region + "-[a-z]/instances/[a-z0-9-]+$"
    ))
  )
  and ([.[].instance] | unique | length) == length
' "$membership" >/dev/null

discovered_file="$work_dir/discovered"
: >"$discovered_file"
while IFS= read -r instance_url; do
  [[ -n "$instance_url" ]]
  instance_zone="$(awk -F/ '{print $(NF-2)}' <<<"$instance_url")"
  instance_name="$(awk -F/ '{print $NF}' <<<"$instance_url")"
  instance_file="$work_dir/instance-$instance_name.json"
  "$gcloud_bin" compute instances describe "$instance_name" \
    --zone "$instance_zone" --project "$project_id" --format=json >"$instance_file"
  jq -e \
    --arg project "$project_id" \
    --arg region "$region" \
    --arg zone "$instance_zone" \
    --arg name "$instance_name" \
    --arg instance_url "$instance_url" \
    --arg tag "$server_tag" \
    --arg role "$server_role" \
    --arg service_account "$server_service_account" \
    --arg network "$network_name" \
    --arg subnetwork "$subnetwork_name" '
      (.id | tostring | test("^[0-9]+$"))
      and .name == $name
      and .selfLink == $instance_url
      and .status == "RUNNING"
      and .zone == (
        "https://www.googleapis.com/compute/v1/projects/" + $project
        + "/zones/" + $zone
      )
      and ($zone | test("^" + $region + "-[a-z]$"))
      and .labels.monad_role == $role
      and ((.tags.items // []) | index($tag)) != null
      and (.serviceAccounts | length) == 1
      and .serviceAccounts[0].email == $service_account
      and (.networkInterfaces | length) == 1
      and (.networkInterfaces[0].network | endswith("/networks/" + $network))
      and (.networkInterfaces[0].subnetwork | endswith("/subnetworks/" + $subnetwork))
      and ((.networkInterfaces[0].accessConfigs // []) | length) == 0
      and (.networkInterfaces[0].networkIP | test("^[0-9]+(\\.[0-9]+){3}$"))
    ' "$instance_file" >/dev/null
  jq -r '.networkInterfaces[0].networkIP' "$instance_file" >>"$discovered_file"
done < <(jq -r '.[].instance' "$membership" | LC_ALL=C sort)

LC_ALL=C sort -u "$discovered_file" -o "$discovered_file"
[[ -s "$discovered_file" ]]
[[ "$(wc -l <"$discovered_file" | tr -d ' ')" == "$(jq 'length' "$membership")" ]]
while IFS= read -r ip; do
  awk -F. '
    NF != 4 { exit 1 }
    { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1 }
  ' <<<"$ip" || { echo "invalid Consul DNS server address" >&2; exit 1; }
done <"$discovered_file"

resolver_tmp="$(mktemp "$resolved_dropin_dir/.consul.conf.XXXXXX")"
{
  echo '[Resolve]'
  while IFS= read -r ip; do
    printf 'DNS=%s:8600\n' "$ip"
  done <"$discovered_file"
  echo 'DNSSEC=false'
  echo 'Domains=~consul'
} >"$resolver_tmp"
chmod 0644 "$resolver_tmp"

if [[ -f "$resolver_file" ]] && cmp -s "$resolver_tmp" "$resolver_file"; then
  rm -f -- "$resolver_tmp"
  exit 0
fi

mv -f -- "$resolver_tmp" "$resolver_file"
"$systemctl_bin" restart systemd-resolved
