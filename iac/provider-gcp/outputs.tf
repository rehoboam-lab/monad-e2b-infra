output "api_controller_service_account_email" {
  description = "Email allowlist binding for the TAMS worker-capacity OIDC verifier."
  value       = module.init.api_controller_service_account_email
}

output "nomad_server_service_account_email" {
  description = "Attached identity for Nomad and Consul servers."
  value       = module.init.nomad_server_service_account_email
}

output "worker_build_service_account_email" {
  description = "Attached identity for Nomad worker and build hosts."
  value       = module.init.worker_build_service_account_email
}

output "data_node_service_account_email" {
  description = "Attached identity for Loki and ClickHouse nodes."
  value       = module.init.data_node_service_account_email
}

output "api_controller_service_account_unique_id" {
  description = "Immutable numeric subject allowlist binding for the TAMS worker-capacity OIDC verifier."
  value       = module.init.api_controller_service_account_unique_id
}
