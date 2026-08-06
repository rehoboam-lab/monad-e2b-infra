#!/usr/bin/env bash
set -euo pipefail

provider_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster="${provider_root}/nomad-cluster"
init="${provider_root}/init"

for identity in \
  infra_instances_service_account \
  nomad_server_service_account \
  data_node_service_account \
  api_controller_service_account; do
  rg -F "resource \"google_service_account\" \"${identity}\"" "$init" >/dev/null
done

grep -F 'email = var.nomad_server_service_account_email' \
  "${cluster}/nodepool-control-server.tf" >/dev/null
grep -F 'email = var.api_controller_service_account_email' \
  "${cluster}/nodepool-api.tf" >/dev/null
grep -F 'email = var.data_node_service_account_email' \
  "${cluster}/nodepool-loki.tf" "${cluster}/nodepool-clickhouse.tf" >/dev/null
test "$(grep -Fc 'google_service_account_email = var.worker_build_service_account_email' \
  "${cluster}/main.tf")" -eq 2

server_block="$(sed -n '/resource "google_secret_manager_secret_iam_member" "bootstrap_server"/,/^}/p' "${cluster}/main.tf")"
worker_block="$(sed -n '/resource "google_secret_manager_secret_iam_member" "bootstrap_worker"/,/^}/p' "${cluster}/main.tf")"
data_block="$(sed -n '/resource "google_secret_manager_secret_iam_member" "bootstrap_data"/,/^}/p' "${cluster}/main.tf")"
api_block="$(sed -n '/resource "google_secret_manager_secret_iam_member" "bootstrap_api"/,/^}/p' "${cluster}/nodepool-api.tf")"
grep -F 'local.bootstrap_server_secrets' <<<"$server_block" >/dev/null
grep -F 'var.nomad_server_service_account_email' <<<"$server_block" >/dev/null
grep -F 'local.bootstrap_worker_secrets' <<<"$worker_block" >/dev/null
grep -F 'var.worker_build_service_account_email' <<<"$worker_block" >/dev/null
grep -F 'local.bootstrap_client_secrets' <<<"$data_block" >/dev/null
grep -F 'var.data_node_service_account_email' <<<"$data_block" >/dev/null
grep -F 'local.bootstrap_client_secrets' <<<"$api_block" >/dev/null
grep -F 'var.api_controller_service_account_email' <<<"$api_block" >/dev/null

worker_startup="${cluster}/scripts/start-client.sh"
if grep -F -e 'CONSUL_TOKEN_SECRET_NAME' -e 'CONSUL_GOSSIP_SECRET_NAME' \
  -e 'CONSUL_DNS_TOKEN_SECRET_NAME' "$worker_startup" >/dev/null; then
  printf 'Worker/build startup crossed the Consul secret boundary.\n' >&2
  exit 1
fi
grep -F 'nomad_server_tag_name' "${cluster}/main.tf" >/dev/null
grep -F 'local.nomad_server_tag_name' "${cluster}/nodepool-control-server.tf" >/dev/null
grep -F 'server_join {' "${cluster}/scripts/run-nomad.sh" >/dev/null

printf 'Role-specific attached identity and exact secret-set guards passed.\n'
