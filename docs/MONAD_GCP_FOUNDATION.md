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

3. Obtain the Cloudflare token and Postgres connection string, but do not put
   either value in the environment file. The foundation creates their empty
   Secret Manager containers; versions are added out-of-band only after the
   reviewed foundation apply.
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

The checked-in minimal-workload policy expects these maximum role counts:
three Nomad/Consul servers, one API node, one ClickHouse node, one build node,
up to two sandbox client nodes, and no Loki node. The worker regional MIGs use
the GCP default three-zone distribution. Their fixed rollout surge is capped
at three—the minimum valid non-zero fixed value for a default regional MIG
according to [Google's regional MIG update rules](https://cloud.google.com/compute/docs/instance-groups/rolling-out-updates-to-managed-instance-groups#updating_a_regional_managed_instance_group).

The plan guard derives autoscaler maxima, fixed role sizes, and every MIG's
rollout surge from `terraform show -json`. For the minimal policy it permits
eight maximum steady-state instances plus ten rollout instances, for a peak of
18. The policy's 24-instance planning assumption therefore reserves six
instances of headroom. This is not live quota evidence: immediately before
apply, re-check the selected region's instance, CPU, SSD, local SSD, address,
and relevant per-machine-family quotas. Increase the policy only through a
reviewed change supported by updated cost and capacity evidence.

Read-only quota inspection on 2026-07-28 found the following current limits
with zero usage in both candidate regions:

- `australia-southeast1`: 24 instances, 100 vCPUs, 500 GB persistent SSD, and
  eight in-use addresses;
- `us-east4`: 24 instances, 200 vCPUs, 500 GB persistent SSD, and eight in-use
  addresses.

The instance guard does not imply that those other quotas are sufficient.
Using the checked-in machine and disk defaults, the maximal steady topology is
approximately 38 vCPUs and 1,160 GB of persistent SSD; a full simultaneous MIG
rollout can reach approximately 96 vCPUs and 2,620 GB of persistent SSD. The
maximal steady topology also uses eight public addresses before any substitute
instances are created. These are configuration-derived estimates, not a
replacement for reviewing the real saved plan. The workload apply remains
blocked until SSD and address quota or network/disk choices are changed, and
the saved plan proves adequate headroom for every quota dimension.

The capacity limit does not make worker replacement safe. Snapshot or pause
every active sandbox, wait for snapshot uploads to become durable, stop new
placement on the affected Nomad nodes, drain allocations, and verify the MIG
is stable before replacing a worker template. That orchestration is not yet
implemented, so any workload rollout remains an operator-blocked procedure.

After the foundation apply, add the first secret versions directly over stdin
so values never enter shell history. Replace `<prefix>` with the configured
prefix (the template default is `e2b-`), paste one value, then send EOF:

```bash
gcloud secrets versions add <prefix>cloudflare-api-token --data-file=-
gcloud secrets versions add <prefix>postgres-connection-string --data-file=-
```

These versions are workload prerequisites. They are not inputs to the F1.0
foundation plan and their values must not appear in Terraform state.

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
