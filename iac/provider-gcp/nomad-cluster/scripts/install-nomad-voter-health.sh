#!/usr/bin/env bash
set -euo pipefail

# Install the strict local-voter endpoint on an already-running Nomad server
# without moving its management token off the host. This is a one-time bridge
# for the live pre-keyless template: the token is recovered from that VM's own
# immutable startup-script metadata, written only to root-owned tmpfs, and never
# printed, passed in argv, or exported. New templates create the same contract
# directly from Secret Manager during boot.

source_path="${1:?usage: install-nomad-voter-health.sh SOURCE EXPECTED_SOURCE_SHA256 EXPECTED_INSTALLER_SHA256}"
expected_sha256="${2:?usage: install-nomad-voter-health.sh SOURCE EXPECTED_SOURCE_SHA256 EXPECTED_INSTALLER_SHA256}"
expected_installer_sha256="${3:?usage: install-nomad-voter-health.sh SOURCE EXPECTED_SOURCE_SHA256 EXPECTED_INSTALLER_SHA256}"
curl_bin="${CURL_BIN:-curl}"

[[ "${EUID}" -eq 0 ]] || {
  printf 'Nomad voter-health installation must run as root.\n' >&2
  exit 2
}
[[ "${source_path}" == /tmp/e2b-nomad-voter-health.*.py ]] || {
  printf 'Nomad voter-health source path is outside the bounded staging contract.\n' >&2
  exit 2
}
[[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'Nomad voter-health source digest is not canonical.\n' >&2
  exit 2
}
[[ "${expected_installer_sha256}" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'Nomad voter-health installer digest is not canonical.\n' >&2
  exit 2
}
[[ "$0" == "/tmp/e2b-install-nomad-voter-health.${expected_installer_sha256}.sh" ]] || {
  printf 'Nomad voter-health installer path does not bind the expected digest.\n' >&2
  exit 1
}
[[ -f "${source_path}" && ! -L "${source_path}" ]] || {
  printf 'Nomad voter-health source must be a regular non-symlink file.\n' >&2
  exit 1
}

health_dir='/run/e2b-nomad-health'
token_path="${health_dir}/token"
consul_token_path="${health_dir}/consul-token"
consul_identity_mode_path="${health_dir}/consul-identity-mode"
script_path='/opt/nomad/bin/nomad-voter-health.py'
refresh_path='/opt/nomad/bin/refresh-nomad-voter-health-token.sh'
launcher_path='/opt/nomad/bin/run-nomad-voter-health.sh'
supervisor_path='/etc/supervisor/conf.d/nomad-voter-health.conf'
script_tmp=''
refresh_tmp=''
launcher_tmp=''
supervisor_tmp=''
cleanup() {
  rm -f -- \
    "${script_tmp:-}" "${refresh_tmp:-}" "${launcher_tmp:-}" \
    "${supervisor_tmp:-}" \
    "${source_path}" "$0"
}
trap cleanup EXIT

command -v python3 >/dev/null
command -v sha256sum >/dev/null
command -v supervisorctl >/dev/null
if [[ ! -x "${curl_bin}" ]] && ! command -v "${curl_bin}" >/dev/null 2>&1; then
  printf 'curl is required for metadata and local health verification.\n' >&2
  exit 2
fi

actual_sha256="$(sha256sum "${source_path}" | awk '{print $1}')"
[[ "${actual_sha256}" == "${expected_sha256}" ]] || {
  printf 'Nomad voter-health source digest mismatch.\n' >&2
  exit 1
}
actual_installer_sha256="$(sha256sum "$0" | awk '{print $1}')"
[[ "${actual_installer_sha256}" == "${expected_installer_sha256}" ]] || {
  printf 'Nomad voter-health installer digest mismatch.\n' >&2
  exit 1
}

curl_direct() {
  env \
    -u ALL_PROXY -u all_proxy \
    -u HTTP_PROXY -u http_proxy \
    -u HTTPS_PROXY -u https_proxy \
    -u NO_PROXY -u no_proxy \
    "${curl_bin}" --disable --noproxy '*' "$@"
}

install -d -o root -g root -m 0755 /opt/nomad/bin

# /run is tmpfs. Install a root-only refresh helper and make it the launcher's
# first operation so a reboot or Supervisor restart recreates the token from
# authenticated instance metadata without persisting it on disk.
refresh_tmp="$(mktemp /opt/nomad/bin/refresh-nomad-voter-health-token.sh.XXXXXX)"
cat >"${refresh_tmp}" <<'REFRESH'
#!/usr/bin/env bash
set -euo pipefail

[[ "${EUID}" -eq 0 ]] || exit 2
curl_bin="${CURL_BIN:-/usr/bin/curl}"
[[ -x "${curl_bin}" ]] || command -v "${curl_bin}" >/dev/null

health_dir='/run/e2b-nomad-health'
token_path="${health_dir}/token"
consul_token_path="${health_dir}/consul-token"
consul_identity_mode_path="${health_dir}/consul-identity-mode"
metadata_body="$(mktemp /run/e2b-nomad-startup.XXXXXX)"
metadata_headers="$(mktemp /run/e2b-nomad-startup-headers.XXXXXX)"
token_tmp=''
consul_token_tmp=''
consul_identity_mode_tmp=''
cleanup_refresh() {
  rm -f -- "${metadata_body}" "${metadata_headers}" \
    "${token_tmp:-}" "${consul_token_tmp:-}" \
    "${consul_identity_mode_tmp:-}"
}
trap cleanup_refresh EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

curl_direct() {
  env \
    -u ALL_PROXY -u all_proxy \
    -u HTTP_PROXY -u http_proxy \
    -u HTTPS_PROXY -u https_proxy \
    -u NO_PROXY -u no_proxy \
    "${curl_bin}" --disable --noproxy '*' "$@"
}

curl_direct --proto '=http' --fail --silent --show-error \
  --connect-timeout 2 --max-time 10 \
  --header 'Metadata-Flavor: Google' \
  --dump-header "${metadata_headers}" \
  --output "${metadata_body}" \
  'http://169.254.169.254/computeMetadata/v1/instance/attributes/startup-script'
tr -d '\r' <"${metadata_headers}" | grep -Fx 'Metadata-Flavor: Google' >/dev/null || {
  printf 'Startup-script metadata response lacks the Google authentication header.\n' >&2
  exit 1
}
metadata_size="$(stat -c '%s' "${metadata_body}")"
[[ "${metadata_size}" =~ ^[0-9]+$ ]] \
  && ((metadata_size >= 1 && metadata_size <= 1048576)) || {
  printf 'Startup-script metadata is empty or exceeds the bounded parser input.\n' >&2
  exit 1
}

if [[ -e "${health_dir}" || -L "${health_dir}" ]]; then
  [[ -d "${health_dir}" && ! -L "${health_dir}" ]] || {
    printf 'Nomad voter-health runtime path is not a real directory.\n' >&2
    exit 1
  }
fi
install -d -o root -g root -m 0700 "${health_dir}"
[[ "$(stat -c '%u:%g:%a' "${health_dir}")" == '0:0:700' ]] || {
  printf 'Nomad voter-health runtime directory ownership or mode is unsafe.\n' >&2
  exit 1
}
token_tmp="$(mktemp "${health_dir}/token.XXXXXX")"
consul_token_tmp="$(mktemp "${health_dir}/consul-token.XXXXXX")"
consul_identity_mode_tmp="$(mktemp "${health_dir}/consul-identity-mode.XXXXXX")"
chmod 0600 "${token_tmp}"
chmod 0600 "${consul_token_tmp}"
chmod 0600 "${consul_identity_mode_tmp}"
chown root:root "${token_tmp}"
chown root:root "${consul_token_tmp}"
chown root:root "${consul_identity_mode_tmp}"
python3 - "${metadata_body}" "${token_tmp}" "${consul_token_tmp}" <<'PY'
import os
import re
import sys

metadata_path, nomad_token_path, consul_token_path = sys.argv[1:]
with open(metadata_path, "rb") as metadata_file:
    payload = metadata_file.read(1048577)
if not payload or len(payload) > 1048576:
    raise SystemExit("legacy startup metadata is outside the bounded contract")
nomad_matches = re.findall(
    rb'--nomad-token[ \t]+"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"',
    payload,
)
consul_matches = re.findall(
    rb'--consul-token[ \t]+"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"',
    payload,
)
if len(nomad_matches) != 1:
    raise SystemExit("legacy startup metadata must contain exactly one quoted Nomad UUID")
if len(consul_matches) != 1:
    raise SystemExit("legacy startup metadata must contain exactly one quoted Consul UUID")
for token_path, token, label in (
    (nomad_token_path, nomad_matches[0], "Nomad"),
    (consul_token_path, consul_matches[0], "Consul"),
):
    descriptor = os.open(
        token_path,
        os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        if os.write(descriptor, token) != len(token):
            raise SystemExit(f"short {label} token write")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
mv -f -- "${token_tmp}" "${token_path}"
token_tmp=''
mv -f -- "${consul_token_tmp}" "${consul_token_path}"
consul_token_tmp=''
chown root:root "${token_path}"
chown root:root "${consul_token_path}"
chmod 0600 "${token_path}"
chmod 0600 "${consul_token_path}"
printf '%s' 'legacy-instance-name-or-id' >"${consul_identity_mode_tmp}"
mv -f -- "${consul_identity_mode_tmp}" "${consul_identity_mode_path}"
consul_identity_mode_tmp=''
chown root:root "${consul_identity_mode_path}"
chmod 0600 "${consul_identity_mode_path}"
REFRESH
chown root:root "${refresh_tmp}"
chmod 0700 "${refresh_tmp}"
mv -f -- "${refresh_tmp}" "${refresh_path}"
refresh_tmp=''

script_tmp="$(mktemp /opt/nomad/bin/nomad-voter-health.py.XXXXXX)"
install -o root -g root -m 0755 "${source_path}" "${script_tmp}"
[[ "$(sha256sum "${script_tmp}" | awk '{print $1}')" == "${expected_sha256}" ]]
mv -f -- "${script_tmp}" "${script_path}"
script_tmp=''

launcher_tmp="$(mktemp /opt/nomad/bin/run-nomad-voter-health.sh.XXXXXX)"
cat >"${launcher_tmp}" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
/opt/nomad/bin/refresh-nomad-voter-health-token.sh
exec /usr/bin/python3 /opt/nomad/bin/nomad-voter-health.py
LAUNCHER
chown root:root "${launcher_tmp}"
chmod 0700 "${launcher_tmp}"
mv -f -- "${launcher_tmp}" "${launcher_path}"
launcher_tmp=''

CURL_BIN="${curl_bin}" "${refresh_path}"
[[ -f "${token_path}" && ! -L "${token_path}" ]]
[[ -f "${consul_token_path}" && ! -L "${consul_token_path}" ]]
[[ -f "${consul_identity_mode_path}" && ! -L "${consul_identity_mode_path}" ]]

supervisor_tmp="$(mktemp /etc/supervisor/conf.d/nomad-voter-health.conf.XXXXXX)"
cat >"${supervisor_tmp}" <<'EOF'
[program:nomad-voter-health]
command=/opt/nomad/bin/run-nomad-voter-health.sh
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
chown root:root "${supervisor_tmp}"
chmod 0644 "${supervisor_tmp}"
mv -f -- "${supervisor_tmp}" "${supervisor_path}"
supervisor_tmp=''

supervisorctl reread >/dev/null
supervisorctl update >/dev/null
supervisorctl restart nomad-voter-health >/dev/null

for _attempt in $(seq 1 60); do
  if response="$(curl_direct --proto '=http' --fail --silent --show-error \
    --connect-timeout 1 --max-time 2 'http://127.0.0.1:50001/healthz' 2>/dev/null)" \
    && [[ "${response}" == '{"ok":true}' ]]; then
    printf 'Nomad strict local-voter endpoint is healthy.\n'
    exit 0
  fi
  sleep 2
done

printf 'Nomad strict local-voter endpoint did not become healthy.\n' >&2
exit 1
