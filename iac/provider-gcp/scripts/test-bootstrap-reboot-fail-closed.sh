#!/usr/bin/env bash
set -euo pipefail

provider_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

startup_scripts=(
  "${provider_root}/nomad-cluster/scripts/start-server.sh"
  "${provider_root}/modules/nodepool-api/scripts/start-api.sh"
  "${provider_root}/nomad-cluster/scripts/start-clickhouse.sh"
  "${provider_root}/nomad-cluster/scripts/start-client.sh"
)

mkdir -p "${work_dir}/bin"
cat >"${work_dir}/bin/supervisorctl" <<'EOF'
#!/usr/bin/env bash
printf 'supervisorctl %s\n' "$*" >>"${BOOT_TEST_CALLS:?}"
exit 0
EOF
cat >"${work_dir}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${BOOT_TEST_CALLS:?}"
exit 0
EOF
chmod 0755 "${work_dir}/bin/supervisorctl" "${work_dir}/bin/systemctl"

for startup_script in "${startup_scripts[@]}"; do
  role="$(basename "$startup_script" .sh)"
  fixture="${work_dir}/${role}"
  mkdir -p "$fixture"
  calls="${fixture}/calls"
  persisted_config="${fixture}/run-nomad.conf"
  acl_fixture="${fixture}/acl"
  printf '%s\n' 'autostart=true' 'environment=CONSUL_HTTP_TOKEN=stale' >"$persisted_config"
  mkdir -p "$acl_fixture"
  printf '%s' stale >"${acl_fixture}/token"

  # Execute the exact gate embedded at the start of each template, then model
  # a Secret Manager/ADC failure. Rewrite only the test's Supervisor path so
  # the host running this regression test is never mutated.
  gate_script="${fixture}/gate.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    sed -n '/^bootstrap_complete=false$/,/^quiesce_orchestrators$/p' "$startup_script" \
      | sed 's#/etc/supervisor/conf.d/run-nomad.conf#${BOOT_TEST_SUPERVISOR_CONFIG}#g'
    printf '%s\n' 'acl_dir="$BOOT_TEST_ACL_DIR"' 'false # simulated required-secret fetch failure'
  } >"$gate_script"
  chmod 0755 "$gate_script"

  if PATH="${work_dir}/bin:$PATH" \
    BOOT_TEST_CALLS="$calls" \
    BOOT_TEST_SUPERVISOR_CONFIG="$persisted_config" \
    BOOT_TEST_ACL_DIR="$acl_fixture" \
    "$gate_script" >/dev/null 2>&1; then
    printf '%s unexpectedly survived a required-secret fetch failure.\n' "$role" >&2
    exit 1
  fi

  test ! -e "$persisted_config"
  test ! -e "$acl_fixture"
  grep -Fqx 'supervisorctl stop nomad' "$calls"
  grep -Fqx 'systemctl stop consul.service' "$calls"
  grep -Fqx 'systemctl disable consul.service' "$calls"
  grep -Fqx 'systemctl mask --runtime consul.service' "$calls"
  if grep -E '(supervisorctl|systemctl) (start|restart|enable)' "$calls" >/dev/null; then
    printf '%s started an orchestrator after the simulated credential failure.\n' "$role" >&2
    exit 1
  fi

  quiesce_line="$(grep -n '^quiesce_orchestrators$' "$startup_script" | head -1 | cut -d: -f1)"
  fetch_line="$(grep -n '/opt/fetch-gcp-secret.sh ' "$startup_script" | head -1 | cut -d: -f1)"
  [[ -n "$quiesce_line" && -n "$fetch_line" ]] && ((quiesce_line < fetch_line))
  grep -F 'bootstrap_complete=true' "$startup_script" >/dev/null
done

consul_runner="${provider_root}/nomad-cluster/scripts/run-consul.sh"
nomad_runner="${provider_root}/nomad-cluster/scripts/run-nomad.sh"
grep -F 'systemctl disable consul.service' "$consul_runner" >/dev/null
grep -F 'systemctl unmask --runtime consul.service' "$consul_runner" >/dev/null
if grep -F 'systemctl enable consul.service' "$consul_runner" >/dev/null; then
  printf 'Consul runner must not enable boot-time autostart.\n' >&2
  exit 1
fi
grep -Fqx 'autostart=false' "$nomad_runner"
grep -F 'supervisorctl start nomad' "$nomad_runner" >/dev/null

printf 'Persisted-config reboot and credential-failure gates passed for every GCE role.\n'
