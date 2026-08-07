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

output "nomad_acl_token_secret_version_name" {
  description = "Immutable promoted Nomad ACL Secret Manager version used by guarded rollout waiters."
  value       = module.init.nomad_acl_token_secret_version_name
}

output "nomad_acl_token_legacy_secret_version_name" {
  description = "Exact disabled prior Nomad ACL version used by the retirement replay-proof workflow."
  value       = module.init.nomad_acl_token_legacy_secret_version_name
}

output "consul_acl_token_secret_version_name" {
  description = "Immutable prior Consul management version used only by the audited handoff workflow."
  value       = module.init.consul_acl_token_secret_version_name
}

output "consul_acl_token_legacy_secret_version_name" {
  description = "Exact disabled registered Consul version used by the handoff replay-proof workflow."
  value       = module.init.consul_acl_token_legacy_secret_version_name
}

output "consul_acl_token_candidate_secret_version_name" {
  description = "Immutable promoted Consul management version used by new control servers."
  value       = module.init.consul_acl_token_candidate_secret_version_name
}
