resource "terraform_data" "acl_bootstrap_environment_guard" {
  input = var.environment

  lifecycle {
    precondition {
      condition     = var.environment == "dev"
      error_message = "The role-split ACL/Secret Manager foundation migration is dev-only; nondev requires a separately reviewed identity and secret rollout."
    }
  }
}
