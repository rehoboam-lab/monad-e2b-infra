
resource "google_secret_manager_secret" "cloudflare_api_token" {
  secret_id = "${var.prefix}cloudflare-api-token"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret" "consul_acl_token" {
  secret_id = "${var.prefix}consul-secret-id"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "random_password" "consul_acl_token_seed" {
  length  = 64
  special = false
}

locals {
  # Consul accepts an opaque UUID SecretID. Deriving it from a sensitive seed
  # preserves that format without putting the token in a Terraform resource ID.
  consul_acl_token = uuidv5("dns", random_password.consul_acl_token_seed.result)
}

resource "google_secret_manager_secret_version" "consul_acl_token_legacy" {
  secret      = google_secret_manager_secret.consul_acl_token.name
  secret_data = sensitive("retired-legacy-consul-acl-token")
  enabled     = false

  deletion_policy = "DISABLE"

  lifecycle {
    # The explicit post-build retirement workflow owns the live enablement
    # transition. Ignoring that field prevents a targeted prerequisite or
    # staged host plan from disabling a still-in-use legacy credential before
    # every old allocation and GCE client has been replaced.
    ignore_changes = [secret_data, enabled]
  }
}

resource "google_secret_manager_secret_version" "consul_acl_token_active" {
  secret      = google_secret_manager_secret.consul_acl_token.name
  secret_data = local.consul_acl_token
  enabled     = false

  deletion_policy = "DISABLE"

  # Existing foundations retain this exact payload only for the explicit
  # IAP-local handoff. New servers use the separately registered candidate.
  # Keep the old version declaratively disabled so a later Terraform apply
  # cannot undo quarantine performed by the recovery workflow.
  lifecycle {
    # See the legacy version above. Both historical pins remain quarantined by
    # the handoff workflow after retirement without Terraform re-enabling them.
    ignore_changes = [secret_data, enabled]
  }
}

# A separately versioned global-management SecretID supports an explicit
# register -> prove -> switch -> revoke handoff. The current active SecretID
# remains enabled until every legacy allocation and host has migrated; merely
# changing a job spec does not invalidate copies retained in Nomad history.
resource "random_password" "consul_acl_token_candidate_seed" {
  length  = 64
  special = false

  depends_on = [terraform_data.acl_bootstrap_environment_guard]
}

resource "google_secret_manager_secret" "consul_acl_token_candidate" {
  secret_id = "${var.prefix}consul-management-candidate-token"

  replication {
    auto {}
  }

  depends_on = [
    terraform_data.acl_bootstrap_environment_guard,
    time_sleep.secrets_api_wait_60_seconds,
  ]
}

locals {
  consul_acl_token_candidate = uuidv5("dns", random_password.consul_acl_token_candidate_seed.result)
}

resource "google_secret_manager_secret_version" "consul_acl_token_candidate" {
  secret      = google_secret_manager_secret.consul_acl_token_candidate.name
  secret_data = local.consul_acl_token_candidate

  deletion_policy = "DISABLE"

  depends_on = [
    terraform_data.acl_bootstrap_environment_guard,
    google_secret_manager_secret_version.consul_acl_token_active,
  ]
}

resource "google_secret_manager_secret" "nomad_acl_token" {
  secret_id = "${var.prefix}nomad-secret-id"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "random_password" "nomad_acl_token_seed" {
  length  = 64
  special = false
}

locals {
  # Nomad's bootstrap API requires a UUID token. uuidv5 preserves the contract
  # while sensitivity propagates from the random_password seed.
  nomad_acl_token = uuidv5("dns", random_password.nomad_acl_token_seed.result)
}

resource "google_secret_manager_secret_version" "nomad_acl_token_legacy" {
  secret      = google_secret_manager_secret.nomad_acl_token.name
  secret_data = sensitive("retired-legacy-nomad-acl-token")
  enabled     = false

  deletion_policy = "DISABLE"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "nomad_acl_token_active" {
  secret      = google_secret_manager_secret.nomad_acl_token.name
  secret_data = local.nomad_acl_token

  deletion_policy = "DISABLE"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "random_password" "api_admin_secret" {
  length  = 32
  special = true
}

resource "google_secret_manager_secret" "api_admin_token" {
  secret_id = "${var.prefix}api-admin-token"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "api_admin_token_value" {
  secret      = google_secret_manager_secret.api_admin_token.id
  secret_data = random_password.api_admin_secret.result
}

resource "random_password" "dashboard_api_admin_secret" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "dashboard_api_admin_token" {
  secret_id = "${var.prefix}dashboard-api-admin-token"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "dashboard_api_admin_token_value" {
  secret      = google_secret_manager_secret.dashboard_api_admin_token.id
  secret_data = random_password.dashboard_api_admin_secret.result
}



# grafana api key
resource "google_secret_manager_secret" "grafana_api_key" {
  secret_id = "${var.prefix}grafana-api-key"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret" "launch_darkly_api_key" {
  secret_id = "${var.prefix}launch-darkly-api-key"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "launch_darkly_api_key" {
  secret      = google_secret_manager_secret.launch_darkly_api_key.name
  secret_data = " "

  lifecycle {
    ignore_changes = [secret_data]
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "grafana_api_key" {
  secret      = google_secret_manager_secret.grafana_api_key.name
  secret_data = " "

  lifecycle {
    ignore_changes = [secret_data]
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}
resource "google_secret_manager_secret" "analytics_collector_host" {
  secret_id = "${var.prefix}analytics-collector-host"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "analytics_collector_host" {
  secret      = google_secret_manager_secret.analytics_collector_host.name
  secret_data = " "

  lifecycle {
    ignore_changes = [secret_data]
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret" "analytics_collector_api_token" {
  secret_id = "${var.prefix}analytics-collector-api-token"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "analytics_collector_api_token" {
  secret      = google_secret_manager_secret.analytics_collector_api_token.name
  secret_data = " "

  lifecycle {
    ignore_changes = [secret_data]
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret" "routing_domains" {
  secret_id = "${var.prefix}routing-domains"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "routing_domains" {
  secret      = google_secret_manager_secret.routing_domains.name
  secret_data = jsonencode([])

  lifecycle {
    ignore_changes = [secret_data]
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret" "postgres_connection_string" {
  secret_id = "${var.prefix}postgres-connection-string"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}


resource "google_secret_manager_secret" "posthog_api_key" {
  secret_id = "${var.prefix}posthog-api-key"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "posthog_api_key" {
  secret      = google_secret_manager_secret.posthog_api_key.name
  secret_data = " "

  lifecycle {
    ignore_changes = [secret_data]
  }
}

locals {
  ory_project_api_key_secret_id = "${var.prefix}ory-project-api-key"
}

data "google_secret_manager_secrets" "ory_project_api_key" {
  project = var.gcp_project_id
  filter  = "name:${local.ory_project_api_key_secret_id}"

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

locals {
  ory_project_api_key_secret_exists = try(length(data.google_secret_manager_secrets.ory_project_api_key.secrets) > 0, false)
}

resource "google_secret_manager_secret" "redis_cluster_url" {
  secret_id = "${var.prefix}redis-cluster-url"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "redis_cluster_url" {
  secret      = google_secret_manager_secret.redis_cluster_url.name
  secret_data = " "

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret" "redis_tls_ca_base64" {
  secret_id = "${var.prefix}redis-tls-ca-base64"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "redis_tls_ca_base64" {
  secret      = google_secret_manager_secret.redis_tls_ca_base64.name
  secret_data = " "

  lifecycle {
    ignore_changes = [secret_data]
  }
}


resource "google_secret_manager_secret" "notification_email" {
  secret_id = "${var.prefix}security-notification-email"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "notification_email_value" {
  secret = google_secret_manager_secret.notification_email.id

  secret_data = "placeholder@example.com"
}

resource "google_secret_manager_secret" "dockerhub_username" {
  secret_id = "${var.prefix}dockerhub-remote-repo-username"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "dockerhub_username" {
  secret      = google_secret_manager_secret.dockerhub_username.name
  secret_data = " "

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret" "dockerhub_password" {
  secret_id = "${var.prefix}dockerhub-remote-repo-password"

  replication {
    auto {}
  }

  depends_on = [time_sleep.secrets_api_wait_60_seconds]
}

resource "google_secret_manager_secret_version" "dockerhub_password" {
  secret      = google_secret_manager_secret.dockerhub_password.name
  secret_data = " "

  lifecycle {
    ignore_changes = [secret_data]
  }
}
