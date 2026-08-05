#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider_root="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${provider_root}/../.." && pwd)"
network_tf="${provider_root}/nomad-cluster/network/main.tf"
terraform_bin="${1:-terraform}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

extract_resource() {
  local resource_type="$1"
  local resource_name="$2"
  local source_file="$3"

  awk -v resource_type="${resource_type}" -v resource_name="${resource_name}" '
    $0 == "resource \"" resource_type "\" \"" resource_name "\" {" {
      inside = 1
    }
    inside {
      print
      opens = gsub(/\{/, "{")
      closes = gsub(/\}/, "}")
      depth += opens - closes
      if (depth == 0) {
        exit
      }
    }
  ' "${source_file}"
}

extract_variable() {
  local variable_name="$1"
  local source_file="$2"

  awk -v variable_name="${variable_name}" '
    $0 == "variable \"" variable_name "\" {" {
      inside = 1
    }
    inside {
      print
      opens = gsub(/\{/, "{")
      closes = gsub(/\}/, "}")
      depth += opens - closes
      if (depth == 0) {
        exit
      }
    }
  ' "${source_file}"
}

iap_allow="$(extract_resource google_compute_firewall internal_remote_connection_firewall_ingress "${network_tf}")"
internet_deny="$(extract_resource google_compute_firewall remote_connection_firewall_ingress "${network_tf}")"

[[ -n "${iap_allow}" ]] || {
  printf 'IAP administrative allow firewall resource is missing.\n' >&2
  exit 1
}
[[ -n "${internet_deny}" ]] || {
  printf 'Non-IAP administrative deny firewall resource is missing.\n' >&2
  exit 1
}

grep -F 'source_ranges = ["35.235.240.0/20"]' <<<"${iap_allow}" >/dev/null
if grep -F '0.0.0.0/0' <<<"${iap_allow}" >/dev/null; then
  printf 'Administrative allow rule must never admit the public internet.\n' >&2
  exit 1
fi
grep -F 'ports    = ["22", "3389"]' <<<"${iap_allow}" >/dev/null
grep -F 'log_config {' <<<"${iap_allow}" >/dev/null
grep -F 'metadata = "EXCLUDE_ALL_METADATA"' <<<"${iap_allow}" >/dev/null

grep -F 'source_ranges = ["0.0.0.0/0"]' <<<"${internet_deny}" >/dev/null
grep -F 'ports    = ["22", "3389"]' <<<"${internet_deny}" >/dev/null
grep -F 'log_config {' <<<"${internet_deny}" >/dev/null
grep -F 'metadata = "EXCLUDE_ALL_METADATA"' <<<"${internet_deny}" >/dev/null

for role in server api loki clickhouse; do
  template_file="${provider_root}/nomad-cluster/nodepool-${role/server/control-server}.tf"
  grep -F "local.os_login_enabled.${role} ? { enable-oslogin = \"TRUE\" } : {}" \
    "${template_file}" >/dev/null || {
    printf 'Staged OS Login metadata is missing from the %s template.\n' "${role}" >&2
    exit 1
  }
  grep -F 'terraform_data.os_login_operator_access_guard' "${template_file}" >/dev/null
  grep -F 'terraform_data.network_hardening_rollout_stage' "${template_file}" >/dev/null
done
grep -F 'var.enable_os_login ? { enable-oslogin = "TRUE" } : {}' \
  "${provider_root}/nomad-cluster/worker-cluster/nodepool.tf" >/dev/null
test "$(grep -Fc 'terraform_data.os_login_operator_access_guard' \
  "${provider_root}/nomad-cluster/main.tf")" -ge 4
test "$(grep -Fc 'terraform_data.network_hardening_rollout_stage' \
  "${provider_root}/nomad-cluster/main.tf")" -ge 3
grep -F 'var.os_login_operator_access_confirmed' "${network_tf}" >/dev/null
grep -F 'var.network_hardening_rollout_stage != "disabled"' "${network_tf}" >/dev/null

if grep -F 'ignore_changes = [metadata]' "${provider_root}/nomad-cluster/nodepool-api.tf" >/dev/null; then
  printf 'The API template cannot ignore all metadata because that would suppress OS Login rollout.\n' >&2
  exit 1
fi

grep -F 'trimspace(var.allow_sandbox_internal_cidrs) == ""' "${provider_root}/variables.tf" >/dev/null
grep -F 'ALLOW_SANDBOX_INTERNAL_CIDRS is forbidden on GCP' "${provider_root}/variables.tf" >/dev/null
os_login_variable="$(extract_variable os_login_operator_access_confirmed "${provider_root}/variables.tf")"
stage_variable="$(extract_variable network_hardening_rollout_stage "${provider_root}/variables.tf")"
grep -F 'default     = false' <<<"${os_login_variable}" >/dev/null
grep -F 'default     = "disabled"' <<<"${stage_variable}" >/dev/null
grep -F 'resource "terraform_data" "os_login_operator_access_guard"' \
  "${provider_root}/nomad-cluster/main.tf" >/dev/null
grep -F 'roles/iap.tunnelResourceAccessor plus roles/compute.osAdminLogin' \
  "${provider_root}/nomad-cluster/main.tf" >/dev/null
grep -F 'terraform_data.os_login_operator_access_guard' \
  "${provider_root}/nomad-cluster/worker-cluster/nodepool.tf" >/dev/null || \
  grep -F 'terraform_data.os_login_operator_access_guard' \
    "${provider_root}/nomad-cluster/main.tf" >/dev/null
grep -F "\$(call tfvar, OS_LOGIN_OPERATOR_ACCESS_CONFIRMED)" "${provider_root}/Makefile" >/dev/null
# This intentionally matches literal Make syntax.
# shellcheck disable=SC2016
grep -F 'TF_VAR_network_hardening_rollout_stage="$(WORKLOAD_CLUSTER_STAGE)"' \
  "${provider_root}/Makefile" >/dev/null
grep -F 'OS_LOGIN_OPERATOR_ACCESS_CONFIRMED=false' "${repo_root}/.env.gcp.template" >/dev/null
grep -F 'NETWORK_HARDENING_ROLLOUT_STAGE=disabled' "${repo_root}/.env.gcp.template" >/dev/null

mkdir "${test_dir}/cluster"
{
  printf '%s\n' "${os_login_variable}" "${stage_variable}"
  printf '%s\n' \
    'module "cluster" {' \
    '  source = "./cluster"' \
    '  os_login_operator_access_confirmed = var.os_login_operator_access_confirmed' \
    '  network_hardening_rollout_stage = var.network_hardening_rollout_stage' \
    '}'
} >"${test_dir}/main.tf"
{
  extract_variable os_login_operator_access_confirmed \
    "${provider_root}/nomad-cluster/variables.tf"
  extract_variable network_hardening_rollout_stage \
    "${provider_root}/nomad-cluster/variables.tf"
  extract_resource terraform_data os_login_operator_access_guard \
    "${provider_root}/nomad-cluster/main.tf"
  extract_resource terraform_data network_hardening_rollout_stage \
    "${provider_root}/nomad-cluster/main.tf"
  printf '%s\n' \
    'resource "terraform_data" "targeted_replacement" {' \
    '  input = var.network_hardening_rollout_stage' \
    '  depends_on = [' \
    '    terraform_data.os_login_operator_access_guard,' \
    '    terraform_data.network_hardening_rollout_stage,' \
    '  ]' \
    '}'
} >"${test_dir}/cluster/main.tf"
"${terraform_bin}" -chdir="${test_dir}" init -backend=false -input=false -no-color >/dev/null
if "${terraform_bin}" -chdir="${test_dir}" plan -input=false -lock=false -no-color \
  -target=module.cluster.terraform_data.targeted_replacement \
  -var='network_hardening_rollout_stage=server' \
  >"${test_dir}/guard-closed.log" 2>&1; then
  printf 'In-module OS Login plan guard was omitted from a targeted replacement graph.\n' >&2
  exit 1
fi
grep -F 'OS Login rollout is gated' "${test_dir}/guard-closed.log" >/dev/null
"${terraform_bin}" -chdir="${test_dir}" plan -input=false -lock=false -no-color \
  -target=module.cluster.terraform_data.targeted_replacement \
  -var='network_hardening_rollout_stage=server' \
  -var='os_login_operator_access_confirmed=true' >/dev/null

shared_firewall="${repo_root}/packages/shared/pkg/sandbox-network/firewall.go"
slot_firewall="${repo_root}/packages/orchestrator/pkg/sandbox/network/firewall.go"
slot_network="${repo_root}/packages/orchestrator/pkg/sandbox/network/network.go"
for cidr in \
  '10.0.0.0/8' \
  '100.64.0.0/10' \
  '127.0.0.0/8' \
  '169.254.0.0/16' \
  '172.16.0.0/12' \
  '192.168.0.0/16'; do
  grep -F "\"${cidr}\"" "${shared_firewall}" >/dev/null || {
    printf 'Required guest deny range %s is missing.\n' "${cidr}" >&2
    exit 1
  }
done
grep -F 'fw.predefinedDenySet.ClearAndAddElements(fw.conn, sandbox_network.DeniedSandboxSetData)' "${slot_firewall}" >/dev/null
grep -F 'expr.MetaKeyIIFNAME' "${slot_firewall}" >/dev/null
grep -F 'fw.tapIfaceMatch()' "${slot_firewall}" >/dev/null
grep -F 'err = s.InitializeFirewall()' "${slot_network}" >/dev/null

deny_rule_line="$(grep -n 'fw.addSetFilterRule(fw.predefinedDenySet.Set(), true)' "${slot_firewall}" | head -n 1 | cut -d: -f1)"
user_allow_line="$(grep -n 'fw.addNonTCPSetFilterRule(fw.userAllowSet.Set(), false)' "${slot_firewall}" | head -n 1 | cut -d: -f1)"
[[ -n "${deny_rule_line}" && -n "${user_allow_line}" && "${deny_rule_line}" -lt "${user_allow_line}" ]] || {
  printf 'Predefined private/control-plane deny must precede tenant allow rules.\n' >&2
  exit 1
}

printf 'GCP network security guards passed.\n'
