#!/usr/bin/env bash
set -euo pipefail

template="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/main.pkr.hcl}"
variables="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/variables.pkr.hcl}"

for path in "${template}" "${variables}"; do
  [[ -f "${path}" && ! -L "${path}" ]] || {
    printf 'Packer source must be a regular, non-symlink file: %s\n' "${path}" >&2
    exit 1
  }
done

normalized="$(sed -E 's/[[:space:]]+//g' "${template}")"

require_once() {
  local needle="$1"
  local description="$2"
  local expected_count="${3:-1}"
  local count
  count="$(grep -Fxc "${needle}" <<<"${normalized}" || true)"
  [[ "${count}" -eq "${expected_count}" ]] || {
    printf 'Packer template must contain exactly %s %s entries: %s\n' \
      "${expected_count}" "${description}" "${needle}" >&2
    exit 1
  }
}

[[ "$(grep -Ec '^source "googlecompute" "orch" \{' "${template}")" -eq 1 ]] || {
  printf 'Packer template must declare exactly one reviewed googlecompute source.\n' >&2
  exit 1
}
[[ "$(grep -Ec '^build \{' "${template}")" -eq 1 ]] || {
  printf 'Packer template must declare exactly one build block.\n' >&2
  exit 1
}

if grep -Eqi '(^|[[:space:]])force[[:space:]]*=' "${template}"; then
  printf 'Packer force replacement is forbidden for operator canaries.\n' >&2
  exit 1
fi

require_once 'required_version="=1.13.1"' 'Packer version pin'
require_once 'version="1.0.16"' 'googlecompute plugin pin'
require_once 'source="github.com/hashicorp/googlecompute"' 'plugin source'
require_once 'source_image_project_id=["ubuntu-os-cloud"]' 'source-image project'
require_once 'disable_default_service_account=true' 'default service-account disablement'
require_once 'image_name=var.image_name' 'deterministic image name' 2
require_once 'image_family=var.image_family' 'candidate image family' 2
require_once 'sources=["source.googlecompute.orch"]' 'reviewed source binding'
require_once 'post-processor"manifest"{' 'build manifest'
require_once 'output=var.build_manifest_path' 'explicit manifest output'

for variable_name in \
  build_manifest_path \
  gcp_project_id \
  gcp_zone \
  image_environment \
  image_family \
  image_name \
  network_name \
  source_revision \
  subnet_name; do
  [[ "$(grep -Ec "^variable \"${variable_name}\" \\{" "${variables}")" -eq 1 ]] || {
    printf 'Missing or duplicate required Packer variable: %s\n' \
      "${variable_name}" >&2
    exit 1
  }
done

printf 'Packer template matches the deterministic, service-account-free canary contract.\n'
