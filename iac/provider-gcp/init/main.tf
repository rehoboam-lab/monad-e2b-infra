
# Enable Secrets Manager API
resource "google_project_service" "secrets_manager_api" {
  service = "secretmanager.googleapis.com"

  disable_on_destroy = false
}

# Enable Certificate Manager API
resource "google_project_service" "certificate_manager_api" {
  #project = var.gcp_project_id
  service = "certificatemanager.googleapis.com"

  disable_on_destroy = false
}

# Enable Compute Engine API
resource "google_project_service" "compute_engine_api" {
  #project = var.gcp_project_id
  service = "compute.googleapis.com"

  disable_on_destroy = false
}

# Enable Artifact Registry API
resource "google_project_service" "artifact_registry_api" {
  #project = var.gcp_project_id
  service = "artifactregistry.googleapis.com"

  disable_on_destroy = false
}

# Enable IAM Service Account Credentials API for short-lived signBlob calls.
resource "google_project_service" "iam_credentials_api" {
  service = "iamcredentials.googleapis.com"

  disable_on_destroy = false
}

# Enable OS Config API
resource "google_project_service" "os_config_api" {
  #project = var.gcp_project_id
  service = "osconfig.googleapis.com"

  disable_on_destroy = false
}

# Enable Stackdriver Monitoring API
resource "google_project_service" "monitoring_api" {
  #project = var.gcp_project_id
  service = "monitoring.googleapis.com"

  disable_on_destroy = false
}

# Enable Stackdriver Logging API
resource "google_project_service" "logging_api" {
  #project = var.gcp_project_id
  service = "logging.googleapis.com"

  disable_on_destroy = false
}

# Enable Filestore API
resource "google_project_service" "filestore_api" {
  #project = var.gcp_project_id
  service = "file.googleapis.com"

  disable_on_destroy = false
}

resource "time_sleep" "secrets_api_wait_60_seconds" {
  depends_on = [google_project_service.secrets_manager_api]

  create_duration = "60s"
}

resource "google_service_account" "infra_instances_service_account" {
  account_id   = "${var.prefix}infra-instances"
  display_name = "Worker and Build Instances Service Account"
}

# Split the attached workload identities at the node-role boundary. The
# existing infra-instances identity is retained for worker/build hosts so the
# migration does not replace that principal in-place; control servers and data
# nodes receive new principals with disjoint Secret Manager grants.
resource "google_service_account" "nomad_server_service_account" {
  account_id   = "${var.prefix}nomad-server"
  display_name = "Nomad and Consul Server Service Account"

  depends_on = [terraform_data.acl_bootstrap_environment_guard]
}

resource "google_service_account" "data_node_service_account" {
  account_id   = "${var.prefix}data-node"
  display_name = "Loki and ClickHouse Data Node Service Account"

  depends_on = [terraform_data.acl_bootstrap_environment_guard]
}

# Let the attached identity sign only as itself. This is required for GCS
# signed upload URLs and does not create or export any private key material.
resource "google_service_account_iam_member" "infra_instances_self_token_creator" {
  service_account_id = google_service_account.infra_instances_service_account.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.infra_instances_service_account.email}"

  depends_on = [google_project_service.iam_credentials_api]
}

// todo: delete after migration period
resource "google_artifact_registry_repository" "orchestration_repository" {
  format        = "DOCKER"
  repository_id = "e2b-orchestration"
  labels        = var.labels

  depends_on = [time_sleep.artifact_registry_api_wait_90_seconds]
}

resource "time_sleep" "artifact_registry_api_wait_90_seconds" {
  depends_on = [google_project_service.artifact_registry_api]

  create_duration = "90s"
}

resource "google_artifact_registry_repository_iam_member" "orchestration_repository_member" {
  repository = google_artifact_registry_repository.orchestration_repository.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.infra_instances_service_account.email}"

  depends_on = [time_sleep.artifact_registry_api_wait_90_seconds]
}

resource "google_artifact_registry_repository_iam_member" "data_node_orchestration_repository_member" {
  repository = google_artifact_registry_repository.orchestration_repository.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.data_node_service_account.email}"

  depends_on = [
    terraform_data.acl_bootstrap_environment_guard,
    time_sleep.artifact_registry_api_wait_90_seconds,
  ]
}

resource "google_artifact_registry_repository" "core" {
  format        = "DOCKER"
  repository_id = "${var.prefix}core"
  labels        = var.labels

  depends_on = [time_sleep.artifact_registry_api_wait_90_seconds]
}

resource "google_artifact_registry_repository_iam_member" "core" {
  repository = google_artifact_registry_repository.core.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.infra_instances_service_account.email}"

  depends_on = [time_sleep.artifact_registry_api_wait_90_seconds]
}


resource "google_artifact_registry_repository_iam_member" "data_node_core_reader" {
  repository = google_artifact_registry_repository.core.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.data_node_service_account.email}"

  depends_on = [
    terraform_data.acl_bootstrap_environment_guard,
    time_sleep.artifact_registry_api_wait_90_seconds,
  ]
}

locals {
  non_api_runtime_service_accounts = {
    server = google_service_account.nomad_server_service_account.email
    data   = google_service_account.data_node_service_account.email
  }

  common_runtime_project_roles = toset([
    "roles/compute.networkViewer",
    "roles/logging.logWriter",
    "roles/monitoring.editor",
  ])

  common_runtime_project_role_bindings = {
    for binding in setproduct(keys(local.non_api_runtime_service_accounts), local.common_runtime_project_roles) :
    "${binding[0]}:${binding[1]}" => {
      service_account_email = local.non_api_runtime_service_accounts[binding[0]]
      role                  = binding[1]
    }
  }
}

resource "google_project_iam_member" "non_api_runtime" {
  for_each = local.common_runtime_project_role_bindings

  project = var.gcp_project_id
  role    = each.value.role
  member  = "serviceAccount:${each.value.service_account_email}"

  depends_on = [terraform_data.acl_bootstrap_environment_guard]
}
