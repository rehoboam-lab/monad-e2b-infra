#!/usr/bin/env bash
set -euo pipefail

terraform_bin="${1:-terraform}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider_dir="$(cd "${script_dir}/.." && pwd)"
template_path="${provider_dir}/nomad-cluster/scripts/start-client.sh"
nodepool_path="${provider_dir}/nomad-cluster/worker-cluster/nodepool.tf"
environment_template="${provider_dir}/../../.env.gcp.template"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "${test_dir}"' EXIT

command -v "${terraform_bin}" >/dev/null 2>&1 || {
  printf 'Terraform executable is required to render worker startup: %s\n' \
    "${terraform_bin}" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  printf 'jq is required to inspect the canary worker configuration.\n' >&2
  exit 1
}

build_config="$(
  sed -n "s/^BUILD_CLUSTERS_CONFIG='\\(.*\\)'$/\\1/p" \
    "${environment_template}"
)"
client_config="$(
  sed -n "s/^CLIENT_CLUSTERS_CONFIG='\\(.*\\)'$/\\1/p" \
    "${environment_template}"
)"

jq -e '
  .default.boot_disk
    == {"disk_type": "pd-ssd", "size_gb": 100, "swap_size_gb": 32}
' <<<"${build_config}" >/dev/null
jq -e '
  .default.boot_disk
    == {"disk_type": "pd-ssd", "size_gb": 100, "swap_size_gb": 32}
' <<<"${client_config}" >/dev/null

canary_swap_size_gb="$(
  jq -r '.default.boot_disk.swap_size_gb' <<<"${client_config}"
)"

render_startup() {
  local swap_size_gb="$1"
  local output_path="$2"
  local config_path="${test_dir}/main.tf"

  cat >"${config_path}" <<EOF
locals {
  startup = templatefile("${template_path}", {
    NOMAD_SERVER_TAG_NAME = "test-nomad-server"
    CONSUL_SERVER_MIG_NAME = "test-server-rig"
    CONSUL_SERVER_ROLE_LABEL = "test-nomad-server"
    CONSUL_SERVER_SERVICE_ACCOUNT = "server@test.iam.gserviceaccount.com"
    SCRIPTS_BUCKET = "scripts"
    FC_KERNELS_BUCKET_NAME = "kernels"
    FC_VERSIONS_BUCKET_NAME = "versions"
    FC_ENV_PIPELINE_BUCKET_NAME = "envd"
    FC_BUSYBOX_BUCKET_NAME = "busybox"
    DOCKER_CONTEXTS_BUCKET_NAME = "docker"
    GCP_REGION = "us-east4"
    REFRESH_CONSUL_RESOLVERS_FILE_HASH = "resolver-hash"
    CONFIGURE_DOCKER_FILE_HASH = "docker-hash"
    RUN_NOMAD_FILE_HASH = "nomad-hash"
    NFS_IP_ADDRESS = ""
    NFS_MOUNT_PATH = "/mnt/nfs"
    NFS_MOUNT_SUBDIR = "cache"
    NFS_MOUNT_OPTS = "defaults"
    USE_FILESTORE_CACHE = false
    NODE_POOL = "test"
    BASE_HUGEPAGES_PERCENTAGE = 80
    CACHE_DISK_COUNT = 1
    LOCAL_SSD = "true"
    SWAP_SIZE_GB = ${swap_size_gb}
    NODE_LABELS = ""
    PERSISTENT_VOLUME_TYPES = {}
  })
}
EOF

  printf 'jsonencode(local.startup)\n' \
    | "${terraform_bin}" -chdir="${test_dir}" console \
    | jq -r . \
    | jq -r . >"${output_path}"
}

dev_render="${test_dir}/dev-startup.sh"
render_startup "${canary_swap_size_gb}" "${dev_render}"

bash -n "${dev_render}"

if grep -F -e 'projects/test/secrets/nomad' -e 'fetch-gcp-secret' "${dev_render}" >/dev/null; then
  printf 'Worker startup must not receive or fetch a management secret.\n' >&2
  exit 1
fi
grep -F 'install_setup_script refresh-consul-resolvers "resolver-hash" /opt/e2b/bin/refresh-consul-resolvers.sh' \
  "${dev_render}" >/dev/null
grep -F -- '--nomad-server-tag-name "test-nomad-server"' "${dev_render}" >/dev/null
grep -F 'refresh-consul-resolvers.timer' "${dev_render}" >/dev/null
grep -F 'host consul.service.consul' "${dev_render}" >/dev/null
if grep -F -e 'projects/test/secrets/consul' -e 'projects/test/secrets/gossip' \
  -e 'projects/test/secrets/dns' -e '--consul-token-file' "${dev_render}" >/dev/null; then
  printf 'Worker startup unexpectedly retained a Consul secret dependency.\n' >&2
  exit 1
fi

if grep -Eq '^[[:space:]]*set[[:space:]]+-x([[:space:]]|$)' \
  "${template_path}" "${dev_render}"; then
  printf 'Worker bootstrap must not persist rendered ACL material through shell tracing.\n' >&2
  exit 1
fi

grep -F 'readonly SWAP_SIZE_GB=32' "${dev_render}" >/dev/null
grep -F 'fallocate --length "${SWAP_SIZE_GB}G" "$SWAPFILE"' \
  "${dev_render}" >/dev/null
grep -F 'active swapfile size ${active_swap_size_bytes} does not match configured size ${SWAP_SIZE_BYTES}' \
  "${dev_render}" >/dev/null
grep -F '[[ -L "$SWAPFILE" || ( -e "$SWAPFILE" && ! -f "$SWAPFILE" ) ]]' \
  "${dev_render}" >/dev/null
grep -E 'SWAP_SIZE_GB[[:space:]]*=[[:space:]]*var\.boot_disk\.swap_size_gb' \
  "${nodepool_path}" >/dev/null
if grep -F -e '[Fetching orchestrator version from Nomad servers' \
  -e '--orchestrator-job-version' "${dev_render}" >/dev/null; then
  printf 'Dev-only worker startup retained the removed management-token pinning path.\n' >&2
  exit 1
fi
test "$(grep -c '/opt/nomad/bin/run-nomad.sh --client' "${dev_render}")" -eq 1

if grep -F 'fallocate -l 100G' "${dev_render}" >/dev/null; then
  printf 'Worker startup still contains the legacy hard-coded 100 GB swap allocation.\n' >&2
  exit 1
fi

if grep -F -- '--show=NAME,SIZE' "${dev_render}" >/dev/null; then
  printf 'Worker startup must validate the backing file size, not the smaller usable swap area.\n' >&2
  exit 1
fi

printf 'Worker startup swap and orchestrator metadata rendering passed.\n'
