#!/bin/bash
# This script is meant to be run in the Startup Script of each Compute Instance while it's booting. The script uses the
# run-nomad and run-consul scripts to configure and start Consul and Nomad in server mode. Note that this script
# assumes it's running in a Google IMage built from the Packer template in examples/nomad-consul-image/nomad-consul.json.

set -euo pipefail

# Send the log output from this script to user-data.log, syslog, and the console
# Inspired by https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# A previous successful boot leaves ACL-bearing agent configs on the boot
# disk. Quiesce both supervisors before doing any network or secret work so a
# reboot or failed credential refresh cannot run on stale credentials.
bootstrap_complete=false
acl_dir=""
health_token_dir='/run/e2b-nomad-health'
health_token_path="$health_token_dir/token"
health_token_tmp=""
health_script_tmp=""
quiesce_orchestrators() {
  set +e
  supervisorctl stop nomad-voter-health >/dev/null 2>&1
  supervisorctl stop nomad >/dev/null 2>&1
  rm -f -- \
    /etc/supervisor/conf.d/nomad-voter-health.conf \
    /etc/supervisor/conf.d/run-nomad.conf \
    "$health_token_path"
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
  [[ -z "$health_token_tmp" ]] || rm -f -- "$health_token_tmp"
  [[ -z "$health_script_tmp" ]] || rm -f -- "$health_script_tmp"
  [[ -z "$acl_dir" ]] || rm -rf -- "$acl_dir"
  exit "$status"
}
trap bootstrap_cleanup EXIT
trap 'exit 1' HUP INT TERM
quiesce_orchestrators

ulimit -n 65536
export GOMAXPROCS='nproc'

gsutil cp "gs://${SCRIPTS_BUCKET}/run-consul-${RUN_CONSUL_FILE_HASH}.sh" /opt/consul/bin/run-consul.sh
gsutil cp "gs://${SCRIPTS_BUCKET}/run-nomad-${RUN_NOMAD_FILE_HASH}.sh" /opt/nomad/bin/run-nomad.sh
gsutil cp "gs://${SCRIPTS_BUCKET}/fetch-gcp-secret-${FETCH_GCP_SECRET_FILE_HASH}.sh" /opt/fetch-gcp-secret.sh

chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh /opt/fetch-gcp-secret.sh

# Keep the Nomad credential out of argv, logs, process-wide environment, and
# Supervisor configuration. Populate the reviewed /run contract directly from
# Secret Manager through the attached server identity. /run is cleared on
# reboot, and both bootstrap and voter health reject unsafe ownership, mode,
# links, path, or content.
umask 077
install -d -o root -g root -m 0700 "$health_token_dir"
health_token_tmp="$(mktemp "$health_token_dir/token.XXXXXX")"
/opt/fetch-gcp-secret.sh "${NOMAD_TOKEN_SECRET_NAME}" "$health_token_tmp" uuid
chmod 0600 "$health_token_tmp"
chown root:root "$health_token_tmp"
mv -f -- "$health_token_tmp" "$health_token_path"
health_token_tmp=""

health_script_path='/opt/nomad/bin/nomad-voter-health.py'
health_script_tmp="$(mktemp "$health_script_path.XXXXXX")"
cat >"$health_script_tmp" <<'PY'
${NOMAD_VOTER_HEALTH_SCRIPT}
PY
chown root:root "$health_script_tmp"
chmod 0755 "$health_script_tmp"
mv -f -- "$health_script_tmp" "$health_script_path"
health_script_tmp=""

acl_dir="$(mktemp -d /run/e2b-bootstrap-acl.XXXXXX)"
/opt/fetch-gcp-secret.sh "${CONSUL_TOKEN_SECRET_NAME}" "$acl_dir/consul" uuid
/opt/fetch-gcp-secret.sh "${CONSUL_GOSSIP_SECRET_NAME}" "$acl_dir/gossip" consul-gossip-key

/opt/consul/bin/run-consul.sh --server --cluster-tag-name "${CLUSTER_TAG_NAME}" --consul-token-file "$acl_dir/consul" --enable-gossip-encryption --gossip-encryption-key-file "$acl_dir/gossip"
/opt/nomad/bin/run-nomad.sh --server --num-servers "${NUM_SERVERS}" --consul-token-file "$acl_dir/consul" --nomad-token-file "$health_token_path"

cat >/etc/supervisor/conf.d/nomad-voter-health.conf <<'EOF'
[program:nomad-voter-health]
command=/usr/bin/python3 /opt/nomad/bin/nomad-voter-health.py
user=root
autostart=true
autorestart=true
startsecs=2
startretries=30
stopsignal=TERM
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/nomad-voter-health.log
stdout_logfile_maxbytes=10485760
stdout_logfile_backups=3
EOF

supervisorctl reread
supervisorctl update
bootstrap_complete=true
