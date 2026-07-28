# Monad GCP F1.0 — keyless foundation

This fork deliberately separates a zero-workload GCP foundation from the E2B
runtime cluster. Engram's organisation policy forbids long-lived Google
service-account keys. The fork removes those key resources, and a full cluster
plan is blocked until all runtime consumers use attached service accounts,
Application Default Credentials, or Workload Identity.

## F1.0 creates

- the Terraform state bucket;
- required project APIs;
- service-account identities without private keys;
- Secret Manager containers and generated control-plane secrets;
- Artifact Registry repositories;
- GCS buckets and their IAM bindings.

It does not create the Nomad/Consul cluster, API nodes, ClickHouse, build nodes,
sandbox nodes, workload VMs, or Packer image.

## Prerequisites

1. Authenticate both the CLI and Terraform:

   ```bash
   gcloud auth login
   gcloud auth application-default login
   gcloud config set project monad-code
   ```

2. Copy `.env.gcp.template` to an ignored environment file and set only
   non-secret deployment metadata there.

3. Obtain the Cloudflare token, but do not put it in the environment file.
   The foundation creates its empty Secret Manager container; its version is
   added out-of-band only after the reviewed foundation apply. The workload
   creates a dedicated private Cloud SQL database and publishes its generated
   connection URI into the existing Postgres secret container.
4. Request the documented regional SSD quota before the workload phase.
   The current `us-east4` instance quota is 24; model the reviewed smallest
   fleet and request headroom before any workload plan exceeds it.

## Reviewable workflow

```bash
make set-env ENV=dev
make -C iac/provider-gcp foundation-init
make -C iac/provider-gcp foundation-plan
terraform -chdir=iac/provider-gcp show .tfplan.foundation.dev
make -C iac/provider-gcp foundation-apply \
  CONFIRM='APPLY KEYLESS FOUNDATION'
make -C iac/provider-gcp foundation-destroy-plan
terraform -chdir=iac/provider-gcp show .tfplan.foundation-destroy.dev
rm -f iac/provider-gcp/.tfplan.foundation-destroy.dev
```

`foundation-plan` targets only `module.init`. `foundation-apply` consumes the
exact saved plan and requires a literal confirmation. It never invokes Packer
and forces Anywhere Cache off even if an environment file says otherwise.

The legacy `make init` path is disabled in the Monad fork. Workload modules
depend on a hard-fail credential guard which has no variable escape hatch. The
patch that completes and verifies the keyless migration must remove that guard
as an explicit reviewed change.

All generic workload plan/apply/import/move Make targets are disabled during
F1.0, including stale saved-plan apply paths. The supported foundation workflow
also refuses existing state outside `module.init`, long-lived credential state,
changes outside `module.init`, and any destructive plan. Direct targeted
Terraform commands are unsupported in this phase. A later patch should split
foundation and workload into separate Terraform roots/states, removing the
need for `-target`.

## Workload topology safety (not yet enabled)

The first full workload plan remains blocked until the keyless runtime
credential migration is complete. When that gate is removed, save the plan and
inspect its complete topology before apply:

```bash
make -C iac/provider-gcp workload-plan-check \
  WORKLOAD_PLAN=.tfplan.dev
```

The checked-in operator-canary policy expects three Nomad/Consul servers, one
API node, one build node, one sandbox client node, and no ClickHouse or Loki
node. Server and worker regional MIGs have zero automated surge and replace one
instance in place; the API zonal MIG retains one surge instance. The example
environment fixes those counts, machine types, and disks instead of enabling a
worker autoscaler.

The guard derives every role's fixed size, machine type, vCPU count, disk quota
class, local SSD, public-IP requirement, and rollout surge from
`terraform show -json`. `pd-balanced` and `pd-ssd` both count against the SSD
quota. Unknown instance templates, disk types, standalone VM/disk/address
resources, autoscalers, unresolved values, destructive MIG changes, and
in-place capacity reductions are rejected.

The same guard requires exactly one reviewed Cloud SQL canary and its supporting
Private Services Access range, connection, APIs, service identities, IAM roles,
database, user, password generator, and Secret Manager version. It rejects
unknown or duplicate Cloud SQL/private-service resources, destructive database
changes, public database IPv4, plaintext-capable SSL modes, missing backup/PITR
or deletion protection, and drift from the reviewed shared-core tier and disk
bounds.

The base fleet is six VMs and 26 vCPUs. Two transient scenarios are reviewed:

- an API rollout adds one `e2-standard-4` VM and 200 GB standard PD;
- a Packer image build adds one `n1-standard-4` VM, 10 GB SSD PD, and one
  conservatively reserved public IP.

Those scenarios are mutually exclusive. Never run Packer while any MIG rollout
is active. Adding both at once would require eight VMs and 34 vCPUs, exceeding
the reviewed 32-vCPU limit. The guard takes the maximum usage across the two
serialized scenarios, yielding seven VMs, 30 vCPUs, 470 GB SSD PD, 400 GB
standard PD, 750 GB local SSD, and seven regional public IPs.

The reviewed hard limits are 24 instances, 32 global vCPUs, 500 GB SSD PD,
4,096 GB standard PD, 6,000 GB N1 local SSD, and eight regional public IPs.
The policy and the Packer source are both checked in CI, including the static
Packer machine/disk/IP reserve. Any policy limit change or plan usage drift
fails closed. These values remain a reviewed snapshot rather than live quota
evidence: immediately before apply, re-check every limit and current usage in
the selected project and region. Do not raise the checked-in limits without
updated quota evidence and review.

The capacity limit does not make worker replacement safe. Snapshot or pause
every active sandbox, wait for snapshot uploads to become durable, stop new
placement on the affected Nomad nodes, drain allocations, and verify the MIG
is stable before replacing a worker template. That orchestration is not yet
implemented, so any workload rollout remains an operator-blocked procedure.

After the foundation apply, add the Cloudflare secret version directly over
stdin so its value never enters shell history. Replace `<prefix>` with the
configured prefix (the template default is `e2b-`), paste the value, then send
EOF:

```bash
gcloud secrets versions add <prefix>cloudflare-api-token --data-file=-
```

The Cloudflare version is a workload prerequisite. It is not an input to the
F1.0 foundation plan and its value must not appear in Terraform state.

The operator-canary workload creates a dedicated PostgreSQL 16 Cloud SQL
instance instead of accepting an external connection string:

- it reuses the VPC selected by `network_name` and allocates one private
  services `/24` for the single database type and region;
- it has no public IPv4 address and accepts only encrypted connections;
- it uses the shared-core, zonal `db-f1-micro` tier with a 10 GB HDD that may
  auto-grow only to 20 GB;
- it enables seven retained backups, seven days of PITR logs, and both
  Terraform and GCP deletion protection;
- it creates a dedicated `e2b` database and user with a generated password,
  then writes an IPv4 URI ending in `sslmode=require` as a new version of the
  foundation-created `<prefix>postgres-connection-string` secret.

`db-f1-micro` has no Cloud SQL SLA and is suitable only for the one-workcell
operator canary. The database adds no Compute Engine VM, vCPU, external-IP, or
workcell quota usage, so the reviewed seven-instance/30-vCPU peak is unchanged.
The database password and rendered URI are sensitive Terraform values held in
the access-controlled remote state and Secret Manager; neither is output.

The GCP API defaults are six primary-pool and three auth-pool connections, with
one idle connection in each pool. The always-deployed docker reverse proxy has
two fixed three-connection pools, and the migrator has a fixed four-connection
pool. The admission guard therefore requires exactly one API allocation, no
dashboard API, and caps the configured application-side aggregate at
`6 + 3 + 6 + 4 = 19`. Dashboard API is modeled as 16 connections per
allocation but remains disabled for this canary. This is a conservative fork
policy for the shared-core canary, not a claim about PostgreSQL's server-side
maximum. Cloud SQL sizes PostgreSQL
`max_connections` from instance memory; after provisioning, verify it with
`SELECT setting FROM pg_settings WHERE name = 'max_connections'` before
starting the API. Google's separately documented `db-f1-micro` limit of 20
concurrent **Cloud SQL operations** is an administrative operation limit, not
a PostgreSQL session limit. See [Cloud SQL connection
limits](https://cloud.google.com/sql/docs/postgres/quotas#maximum_concurrent_connections)
and [operations
limits](https://cloud.google.com/sql/docs/postgres/quotas#operations_limit).
Changing pool ceilings within the aggregate budget remains supported. Raising
the aggregate requires a reviewed tier and policy update.

To tear the database down, first make a separately reviewed change that
disables both Terraform and GCP deletion protection, then remove the database
resources while retaining the Private Services Access connection and allocated
range. Terraform abandons the connection and `prevent_destroy` protects the
range, so a broad destroy cannot release an allocation that the producer still
uses. Cloud SQL producer cleanup can take up to four days after instance
deletion. Only after that cleanup and proof that no other managed service uses
the peering may a second reviewed change remove the range from the connection,
delete the allocation, and delete the private connection. Follow Google's
[Private Services Access deletion
order](https://cloud.google.com/vpc/docs/configure-private-services-access#delete-connection);
do not release an in-use allocation or delete the VPC Network Peering directly.

Saved Terraform plans contain cleartext configuration and input values,
including sensitive values. `foundation-plan` creates its plan with mode 0600.
Keep it on the trusted operator machine, do not upload it or persist
`terraform show -json` output, and remove an abandoned plan with:

```bash
rm -f iac/provider-gcp/.tfplan.foundation.dev
rm -f iac/provider-gcp/.tfplan.foundation-destroy.dev
```

## Exit evidence

- Terraform state is remote, versioned, and recoverable.
- No `google_service_account_key` resource exists in state.
- No workload VM or external IP exists.
- Secret values are out-of-band and absent from Git and plan output.
- The plan contains only reviewed foundation resources.
- A destroy plan has been inspected.

The next milestone is the keyless runtime credential migration, followed by the
smallest reference fleet and stock SDK create/pause/resume/fork canary.
