#!/usr/bin/env bash

set -euo pipefail

# This rendered script receives only Secret Manager resource names. Never
# enable xtrace: bootstrap still handles fetched secrets in process memory.

# Send the log output from this script to user-data.log, syslog, and the console
# Inspired by https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

bootstrap_complete=false
acl_dir=""
quiesce_orchestrators() {
  set +e
  systemctl stop e2b-consul-agent-refresh.timer e2b-consul-agent-refresh.service >/dev/null 2>&1
  systemctl disable e2b-consul-agent-refresh.timer >/dev/null 2>&1
  systemctl mask --runtime e2b-consul-agent-refresh.timer e2b-consul-agent-refresh.service >/dev/null 2>&1
  rm -f -- /run/e2b-consul-agent/boot-ready.json
  supervisorctl stop nomad >/dev/null 2>&1
  rm -f -- /etc/supervisor/conf.d/run-nomad.conf
  supervisorctl reread >/dev/null 2>&1
  supervisorctl update >/dev/null 2>&1
  systemctl stop consul.service >/dev/null 2>&1
  systemctl disable consul.service >/dev/null 2>&1
  systemctl mask --runtime consul.service >/dev/null 2>&1
  set -e
}
bootstrap_cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$bootstrap_complete" != "true" ]]; then
    quiesce_orchestrators
  fi
  [[ -z "$acl_dir" ]] || rm -rf -- "$acl_dir"
  exit "$status"
}
trap bootstrap_cleanup EXIT
trap 'exit 1' HUP INT TERM
quiesce_orchestrators

ulimit -n 1048576

# --- Mount stateful disk ---
# Needed for ClickHouse to persist data across instance replacement

# Get the GCP instance name
INSTANCE_NAME=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/name" -H "Metadata-Flavor: Google")

# Define the disk and mount point
DISK="/dev/disk/by-id/google-$INSTANCE_NAME-disk"
MOUNT_POINT="/clickhouse"

# Create filesystem if not already formatted
if ! blkid $DISK; then
  mkfs.xfs -f -b size=4096 $DISK
fi

# Create mount point
mkdir -p "$MOUNT_POINT"

# Mount the disk
mount -o noatime "$DISK" "$MOUNT_POINT"

# -------------------------------

sudo tee -a /etc/sysctl.conf <<EOF
# Increase the maximum number of socket connections
net.core.somaxconn = 65535

# Increase the maximum number of backlogged connections
net.core.netdev_max_backlog = 65535

# Increase maximum number of TCP sockets
net.ipv4.tcp_max_syn_backlog = 65535
EOF
sudo sysctl -p

# These variables are passed in via Terraform template interpolation
install_setup_script() {
  local object_stem="$1"
  local expected_sha256="$2"
  local target="$3"
  local tmp=""
  local actual_sha256=""

  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'Refusing invalid setup-script SHA-256 for %s.\n' "$object_stem" >&2
    return 1
  }
  [[ -d "$(dirname "$target")" && ! -L "$(dirname "$target")" ]] || {
    printf 'Refusing unsafe setup-script target directory: %s\n' "$target" >&2
    return 1
  }

  tmp="$(mktemp "$target.tmp.XXXXXX")"
  if ! gsutil cp "gs://${SCRIPTS_BUCKET}/$object_stem-$expected_sha256.sh" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  actual_sha256="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    printf 'Setup-script SHA-256 mismatch for %s.\n' "$object_stem" >&2
    rm -f -- "$tmp"
    return 1
  fi
  chown root:root "$tmp"
  chmod 0755 "$tmp"
  mv -f -- "$tmp" "$target"
}

install_setup_script run-consul "${RUN_CONSUL_FILE_HASH}" /opt/consul/bin/run-consul.sh
install_setup_script consul-gce-agent-identity "${CONSUL_GCE_AGENT_FILE_HASH}" /opt/consul/bin/consul-gce-agent-identity.sh
install_setup_script run-nomad "${RUN_NOMAD_FILE_HASH}" /opt/nomad/bin/run-nomad.sh
install_setup_script fetch-gcp-secret "${FETCH_GCP_SECRET_FILE_HASH}" /opt/fetch-gcp-secret.sh
install_setup_script configure-docker-gcp "${CONFIGURE_DOCKER_FILE_HASH}" /opt/configure-docker-gcp.sh

umask 077
acl_dir="$(mktemp -d /run/e2b-bootstrap-acl.XXXXXX)"

/opt/fetch-gcp-secret.sh "${CONSUL_TOKEN_SECRET_NAME}" "$acl_dir/consul" uuid
/opt/fetch-gcp-secret.sh "${CONSUL_GOSSIP_SECRET_NAME}" "$acl_dir/gossip" consul-gossip-key
/opt/fetch-gcp-secret.sh "${CONSUL_DNS_TOKEN_SECRET_NAME}" "$acl_dir/consul-dns" uuid

/opt/configure-docker-gcp.sh "${GCP_REGION}-docker.pkg.dev"

mkdir -p /etc/systemd/resolved.conf.d/
touch /etc/systemd/resolved.conf.d/consul.conf
cat <<EOF >/etc/systemd/resolved.conf.d/consul.conf
[Resolve]
DNS=127.0.0.1:8600
DNSSEC=false
Domains=~consul
EOF

# Expose systemd-resolved’s DNS stub on the Docker bridge so that
# containers can resolve *.consul names.
#
# Context
# -----------------
# systemd-resolved already forwards *.consul → 127.0.0.1:8600
# (configured in /etc/systemd/resolved.conf.d/consul.conf).
# When the host’s /etc/resolv.conf contains only 127.0.0.53,
# Docker copies /run/systemd/resolve/resolve.conf into every container.
# 127.0.0.53 is bound only to the host loopback interface,
# so DNS look-ups fail inside containers on the default bridge network.
#
# Fix
# -----------------
# Make the stub resolver listen on docker0 (typically 172.17.0.1) via DNSStubListenerExtra
# Tell Docker to use that address (Nomad job config):
# network {
#   mode = "bridge"
#     dns {
#       servers = ["172.17.0.1", "8.8.8.8", "8.8.4.4", "169.254.169.254"]
#   }
# }
#
# Ref: https://web.archive.org/web/20250529054655/https://felix.ehrenpfort.de/notes/2022-06-22-use-consul-dns-interface-inside-docker-container/
touch /etc/systemd/resolved.conf.d/docker.conf
cat <<EOF >/etc/systemd/resolved.conf.d/docker.conf
[Resolve]
DNSStubListener=yes
DNSStubListenerExtra=172.17.0.1
EOF
systemctl restart systemd-resolved

# Note: CNI plugins (needed for Nomad bridge-mode networking) are pre-installed
# in the cluster disk image at build time. See
# iac/nomad-cluster-disk-image/setup/install-cni-plugins.sh

# These variables are passed in via Terraform template interpolation
/opt/consul/bin/run-consul.sh --client \
    --cluster-tag-name "${CLUSTER_TAG_NAME}" \
    --enable-gossip-encryption \
    --gossip-encryption-key-file "$acl_dir/gossip" \
    --dns-request-token-file "$acl_dir/consul-dns" \
    --dns-request-token-version "${CONSUL_DNS_TOKEN_SECRET_NAME}"

/opt/nomad/bin/run-nomad.sh --client --consul-token-file "$acl_dir/consul" --nomad-server-tag-name "${NOMAD_SERVER_TAG_NAME}" --node-pool "${NODE_POOL}"
bootstrap_complete=true

# Note: the clickhouse client is pre-installed in the cluster disk image at build
# time (see iac/nomad-cluster-disk-image/setup/install-clickhouse-client.sh).
