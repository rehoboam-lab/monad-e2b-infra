output "shared_chunk_cache_path" {
  value = var.filestore_cache_enabled ? "${local.nfs_mount_path}/${local.nfs_mount_subdir}" : ""
}

output "consul_catalog_read_token" {
  description = "Read-only Consul catalog token used by the API-pool ingress job."
  value       = local.consul_catalog_read_token
  sensitive   = true
}

output "consul_worker_autoscaler_token" {
  description = "Consul session and bounded KV token used only by the worker autoscaler job."
  value       = local.consul_worker_autoscaler_token
  sensitive   = true
}

output "nomad_server_name_discovery_filter" {
  description = "Compute-API-compatible filter that matches both legacy and replacement instances in the server MIG."
  value       = "name eq ${local.server_pool_name}-.*"
}

output "nomad_server_label_discovery_filter" {
  description = "Compute-API-compatible post-roll filter restricted to running instances with the immutable server-role label."
  value       = "(status = RUNNING) (labels.monad_role = ${local.nomad_server_role_label})"
}

output "consul_management_handoff_phase" {
  description = "State-backed Consul management handoff phase. Candidate is available only after server convergence."
  value = (
    length(terraform_data.consul_management_handoff_candidate) == 1
    ? terraform_data.consul_management_handoff_candidate[0].output.phase
    : "legacy"
  )
}
