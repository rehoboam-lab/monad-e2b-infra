#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider_root="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${provider_root}/../.." && pwd)"
terraform_bin="${1:-terraform}"
test_root="$(mktemp -d)"
server_pid=""

cleanup() {
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

provider_block="$({
  awk '
    /^provider "nomad" \{/ { inside = 1 }
    inside {
      print
      opens = gsub(/\{/, "{")
      closes = gsub(/\}/, "}")
      depth += opens - closes
      if (depth == 0) exit
    }
  ' "${provider_root}/nomad/main.tf"
})"

[[ "$(grep -Fc 'address   = "https://nomad.${var.domain_name}"' <<<"${provider_block}")" -eq 1 ]]
[[ "$(grep -Fc 'secret_id = var.nomad_acl_token_secret' <<<"${provider_block}")" -eq 1 ]]
if grep -F 'consul_token' <<<"${provider_block}" >/dev/null; then
  printf 'Nomad provider configuration still has a provider-wide Consul token.\n' >&2
  exit 1
fi
if grep -REn 'variable "consul_acl_token_secret"|consul_acl_token_secret[[:space:]]*=' \
  "${provider_root}/nomad" "${provider_root}/main.tf" >/dev/null; then
  printf 'The GCP Nomad module still accepts a provider-wide Consul management token.\n' >&2
  exit 1
fi
grep -F 'unexport CONSUL_HTTP_TOKEN' "${provider_root}/Makefile" >/dev/null || {
  printf 'The guarded Make workflow must strip inherited CONSUL_HTTP_TOKEN.\n' >&2
  exit 1
}

jobspec_count=0
while IFS= read -r jobspec; do
  jobspec_count=$((jobspec_count + 1))
  marker_count="$(grep -Fc 'monad_acl_handoff_revision = "1"' "${jobspec}" || true)"
  if grep -Eq '^[[:space:]]*(type[[:space:]]*=[[:space:]]*"batch"|periodic[[:space:]]*\{|parameterized[[:space:]]*\{)' "${jobspec}"; then
    if [[ "${marker_count}" -ne 0 ]]; then
      printf 'Triggered batch jobspec must not carry the handoff marker or be force-rerun: %s\n' "${jobspec}" >&2
      exit 1
    fi
  elif [[ "${marker_count}" -ne 1 ]]; then
    printf 'Long-running Nomad jobspec lacks the unique ACL handoff marker: %s\n' "${jobspec}" >&2
    exit 1
  fi
done < <(
  find "${repo_root}/iac/modules" "${provider_root}/nomad" -type f -name '*.hcl' \
    -exec grep -lE '^job[[:space:]]+"' {} + | sort
)
(( jobspec_count > 0 ))

capture_file="${test_root}/request.json"
port_file="${test_root}/port"
capture_server="${test_root}/nomad-request-capture"
go build -o "${capture_server}" \
  "${script_dir}/testdata/nomad-request-capture/main.go"
"${capture_server}" \
  "${capture_file}" "${port_file}" >"${test_root}/server.log" 2>&1 &
server_pid=$!
for _ in {1..200}; do
  [[ -s "${port_file}" ]] && break
  kill -0 "${server_pid}" >/dev/null 2>&1 || {
    sed -n '1,120p' "${test_root}/server.log" >&2
    exit 1
  }
  sleep 0.05
done
[[ -s "${port_file}" ]] || {
  printf 'Nomad request-capture server did not become ready within 10 seconds.\n' >&2
  sed -n '1,120p' "${test_root}/server.log" >&2
  exit 1
}
port="$(tr -d '[:space:]' <"${port_file}")"
[[ "${port}" =~ ^[1-9][0-9]*$ ]]

write_fixture() {
  local directory="$1"
  local provider_token_line="$2"

  mkdir -p "${directory}"
  cat >"${directory}/main.tf" <<EOF
terraform {
  required_providers {
    nomad = {
      source  = "hashicorp/nomad"
      version = "2.1.0"
    }
  }
}

provider "nomad" {
  address = "http://127.0.0.1:${port}"
${provider_token_line}
}

resource "nomad_job" "capture" {
  detach                = true
  deregister_on_destroy = false
  jobspec = <<-EOT
job "request-capture" {
  datacenters = ["dc1"]
  type        = "batch"

  meta {
    monad_acl_handoff_revision = "1"
  }

  group "capture" {
    task "capture" {
      driver = "raw_exec"
      config {
        command = "/bin/true"
      }
    }
  }
}
EOT
}
EOF
}

run_apply() {
  local directory="$1"
  env -u CONSUL_HTTP_TOKEN "${terraform_bin}" -chdir="${directory}" init \
    -backend=false -input=false -no-color >"${directory}/init.log"
  if ! env -u CONSUL_HTTP_TOKEN "${terraform_bin}" -chdir="${directory}" apply \
    -auto-approve -input=false -lock=false -no-color >"${directory}/apply.log" 2>&1; then
    sed -n '1,160p' "${directory}/apply.log" >&2
    sed -n '1,160p' "${test_root}/server.log" >&2
    exit 1
  fi
  [[ -s "${capture_file}" ]] || {
    sed -n '1,160p' "${directory}/apply.log" >&2
    printf 'Pinned Nomad provider did not register a captured job.\n' >&2
    exit 1
  }
}

write_fixture "${test_root}/tokenless" ""
run_apply "${test_root}/tokenless"
jq -e '(.Job.ConsulToken // "") == ""' "${capture_file}" >/dev/null || {
  printf 'Tokenless provider injected a Consul token into the Nomad registration request.\n' >&2
  exit 1
}

sentinel='GLOBAL-MANAGEMENT-SENTINEL'
write_fixture "${test_root}/control" "  consul_token = \"${sentinel}\""
run_apply "${test_root}/control"
jq -e --arg sentinel "${sentinel}" '.Job.ConsulToken == $sentinel' \
  "${capture_file}" >/dev/null || {
  printf 'Request-capture control did not detect provider-level Consul injection.\n' >&2
  exit 1
}

printf 'Pinned Nomad 2.1.0 request capture proved tokenless job registration.\n'
