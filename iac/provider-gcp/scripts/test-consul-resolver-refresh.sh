#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly refresh_script="$script_dir/../nomad-cluster/scripts/refresh-consul-resolvers.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/e2b-consul-resolver-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/resolved" "$test_root/instances"
touch "$test_root/systemctl.calls" "$test_root/gcloud.calls"

cat >"$test_root/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GCLOUD_CALLS"
if [[ "$*" == *"instance-groups managed list-instances"* ]]; then
  cat "$MEMBERSHIP_FILE"
elif [[ "$*" == *"compute instances describe"* ]]; then
  name="${4:?missing instance name}"
  cat "$INSTANCE_DIR/$name.json"
else
  echo "unexpected gcloud command: $*" >&2
  exit 64
fi
EOF
cat >"$test_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SYSTEMCTL_CALLS"
EOF
cat >"$test_root/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_root/bin/gcloud" "$test_root/bin/systemctl" "$test_root/bin/flock"

write_instance() {
  local name="$1" zone="$2" ip="$3" role="${4:-nomad-server}"
  local service_account="${5:-e2b-nomad-server@monad-code.iam.gserviceaccount.com}"
  local access_configs="${6:-[]}"
  jq -n \
    --arg id "${RANDOM}${RANDOM}" \
    --arg name "$name" \
    --arg zone "$zone" \
    --arg ip "$ip" \
    --arg role "$role" \
    --arg service_account "$service_account" \
    --argjson access_configs "$access_configs" '
      {
        id:$id,
        name:$name,
        selfLink:("https://www.googleapis.com/compute/v1/projects/monad-code/zones/"+$zone+"/instances/"+$name),
        status:"RUNNING",
        zone:("https://www.googleapis.com/compute/v1/projects/monad-code/zones/"+$zone),
        labels:{monad_role:$role},
        tags:{items:["e2b-orch-server"]},
        serviceAccounts:[{email:$service_account}],
        networkInterfaces:[{
          network:"https://www.googleapis.com/compute/v1/projects/monad-code/global/networks/e2b-vpc",
          subnetwork:"https://www.googleapis.com/compute/v1/projects/monad-code/regions/us-east4/subnetworks/e2b-private",
          networkIP:$ip,
          accessConfigs:$access_configs
        }]
      }
    ' >"$test_root/instances/$name.json"
}

write_membership() {
  jq -n --args '$ARGS.positional | map({instance:.,instanceStatus:"RUNNING",currentAction:"NONE"})' "$@" \
    >"$test_root/membership.json"
}

instance_url() {
  printf 'https://www.googleapis.com/compute/v1/projects/monad-code/zones/%s/instances/%s\n' "$1" "$2"
}

run_refresh() {
  PROJECT_ID_OVERRIDE=monad-code \
    NETWORK_NAME_OVERRIDE=e2b-vpc \
    SUBNETWORK_NAME_OVERRIDE=e2b-private \
    PATH="$test_root/bin:$PATH" \
    RESOLVED_DROPIN_DIR="$test_root/resolved" \
    LOCK_FILE="$test_root/refresh.lock" \
    GCLOUD_BIN="$test_root/bin/gcloud" \
    SYSTEMCTL_BIN="$test_root/bin/systemctl" \
    SYSTEMCTL_CALLS="$test_root/systemctl.calls" \
    GCLOUD_CALLS="$test_root/gcloud.calls" \
    MEMBERSHIP_FILE="$test_root/membership.json" \
    INSTANCE_DIR="$test_root/instances" \
    bash "$refresh_script" \
      us-east4 e2b-orch-server-rig e2b-orch-server nomad-server \
      e2b-nomad-server@monad-code.iam.gserviceaccount.com
}

write_instance server-a us-east4-a 10.0.0.11
write_instance server-b us-east4-b 10.0.0.12
write_membership "$(instance_url us-east4-b server-b)" "$(instance_url us-east4-a server-a)"
run_refresh
cat >"$test_root/expected" <<'EOF'
[Resolve]
DNS=10.0.0.11:8600
DNS=10.0.0.12:8600
DNSSEC=false
Domains=~consul
EOF
cmp "$test_root/expected" "$test_root/resolved/consul.conf"
[[ "$(wc -l <"$test_root/systemctl.calls" | tr -d ' ')" == 1 ]]
grep -Fq 'instance-groups managed list-instances e2b-orch-server-rig --region us-east4 --project monad-code' "$test_root/gcloud.calls"

# An unchanged exact MIG result does not churn systemd-resolved.
run_refresh
[[ "$(wc -l <"$test_root/systemctl.calls" | tr -d ' ')" == 1 ]]

# A stable MIG replacement atomically swaps the old server addresses.
write_instance server-c us-east4-c 10.0.0.21
write_membership "$(instance_url us-east4-c server-c)"
run_refresh
grep -Fqx 'DNS=10.0.0.21:8600' "$test_root/resolved/consul.conf"
if grep -Fq '10.0.0.11' "$test_root/resolved/consul.conf"; then
  echo 'stale Consul resolver survived server replacement' >&2
  exit 1
fi
[[ "$(wc -l <"$test_root/systemctl.calls" | tr -d ' ')" == 2 ]]
cp "$test_root/resolved/consul.conf" "$test_root/last-good"

assert_rejected_without_change() {
  if run_refresh >/dev/null 2>&1; then
    echo "$1 unexpectedly succeeded" >&2
    exit 1
  fi
  cmp "$test_root/last-good" "$test_root/resolved/consul.conf"
  [[ "$(wc -l <"$test_root/systemctl.calls" | tr -d ' ')" == 2 ]]
}

# Empty, transitional, wrong-region, wrong-role, wrong-service-account, and
# public-IP results all fail closed. A same-tag rogue outside the exact MIG is
# never queried and therefore cannot enter the resolver set.
write_membership
assert_rejected_without_change 'empty MIG'

jq -n --arg instance "$(instance_url us-east4-c server-c)" \
  '[{instance:$instance,instanceStatus:"RUNNING",currentAction:"RECREATING"}]' \
  >"$test_root/membership.json"
assert_rejected_without_change 'transitional MIG member'

write_membership "$(instance_url us-west1-a server-c)"
assert_rejected_without_change 'same-tag wrong-region member'

write_instance server-c us-east4-c 10.0.0.21 api
write_membership "$(instance_url us-east4-c server-c)"
assert_rejected_without_change 'wrong role'

write_instance server-c us-east4-c 10.0.0.21 nomad-server rogue@monad-code.iam.gserviceaccount.com
assert_rejected_without_change 'wrong service account'

write_instance server-c us-east4-c 10.0.0.21 nomad-server \
  e2b-nomad-server@monad-code.iam.gserviceaccount.com '[{"type":"ONE_TO_ONE_NAT","natIP":"34.1.2.3"}]'
assert_rejected_without_change 'public server address'

write_instance rogue us-east4-a 10.0.0.99
if grep -Fq 'rogue' "$test_root/gcloud.calls"; then
  echo 'same-tag non-MIG rogue was queried' >&2
  exit 1
fi

echo 'Consul resolver exact-MIG refresh regression test passed'
