# Monad beta handoff — 2026-07-29

This is the continuation point for a new Codex session. Do not restart the
architecture audit or redo completed GCP cluster work.

## Product intent

The immediate goal is a reliable invited beta using the functionality TAMS
already contains. Promotion order:

1. current product reliability;
2. isolated cloud workcells;
3. useful team task and trusted Git delivery;
4. computer use and visual QA;
5. OpenCode and capability/plugin floor;
6. scoped memory and Slack;
7. invited web beta;
8. local Mac, mobile dispatch, then Windows.

The gate number is not a measure of how much product code exists. Team, task,
browser/computer, Apps/plugins, memory, Slack, desktop, and mobile surfaces
already exist in varying states. They cannot be promoted until the cloud
workcell substrate is real.

There are no active TAMS users or customer workloads beyond founder/operator
testing. Preserve existing features and record regressions; default-off does
not mean delete. OpenCode is the only promoted harness through the mobile gate.
Unphish is a synthetic customer-shaped golden project, not a generic
Requester-role product requirement.

Canonical roadmap:

- `/Users/Shared/engram/tams-worktrees/beta-plan-live-status/MONAD-PLAN.md`
- `/Users/Shared/engram/tams-worktrees/beta-plan-live-status/specs/0004-beta-platform/tasks.md`
- TAMS roadmap/status merge:
  `72f02f38e0b5ed592177e15e9837f738095a6a45`
  ([TAMS PR #167](https://github.com/rehoboam-lab/tams/pull/167))

## Repository and live state

### TAMS

- Remote `main`: `72f02f38e0b5ed592177e15e9837f738095a6a45`.
- Live API readiness on 2026-07-29: `status=ready`.
- Live API version:
  `3791c8afeaa213ff6a070bbbeaeb21335b4cbf8a`.
- Live provider is still only `local_docker`.
- Database, schema, and durable queue reported ready.
- Do not use `/Users/Shared/engram/tams` as a clean release checkout: it is on
  `monadex/ultra` with unrelated user changes.

### GCP E2B infrastructure

- Repository: `/Users/Shared/engram/monad-e2b-infra`
- Remote `main`: `7aca8601976ca6fe2d8a679ab3c4696e456a0906`
  ([infra PR #24](https://github.com/rehoboam-lab/monad-e2b-infra/pull/24)).
- Project/placement: `monad-code`, `us-east4`, `us-east4-c`.
- Cluster is live and stable:
  - `e2b-orch-server-rig`: target 3;
  - `e2b-orch-build-default-rig`: target 1;
  - `e2b-orch-client-rig`: target 1;
  - all three regional MIGs reported stable.
- DNS/TLS and the bounded cluster wait passed previously.
- The main checkout intentionally contains untracked
  `packages/db/scripts/canary/`. Preserve it.
- No phase-two workload has been applied.
- Cloud SQL Admin API is still disabled, which is expected before the
  prerequisite apply.
- The custom-environments Artifact Registry repository is not present.

## Completed deployment safety work

Infrastructure PR #24 is merged and remote CI passed. It:

- accepts Terraform's exact stable prior-state representation for fully
  resolved core Artifact Registry data sources while rejecting deferred reads;
- binds provider/module configuration and exact digest image identities;
- parses concrete core jobspecs with pinned Nomad `1.8.4`;
- requires every core task to use the Docker driver;
- compares the complete Docker image multiset;
- rejects group- and task-level Nomad Connect sidecar/gateway injection; and
- installs the pinned Nomad parser in CI.

Do not weaken this back to regex/text inspection.

## Exact current blocker

An untargeted phase-two plan has repeatedly produced:

```text
Plan: 58 to add, 0 to change, 0 to destroy.
```

Nothing was saved or applied. The rollout lease was released.

The full guard now fails for a legitimate reason:

- `module.nomad.module.api.nomad_job.api`
  - `change.after.jobspec = null`
  - `change.after_unknown.jobspec = true`
- `module.nomad.nomad_job.docker_reverse_proxy`
  - `change.after.jobspec = null`
  - `change.after_unknown.jobspec = true`
- `module.nomad.module.client_proxy.nomad_job.client_proxy`
  - jobspec is concrete and parseable.

API and reverse-proxy embed values created in the same apply: the Cloud SQL
connection, read-replica placeholder, sandbox access-token hash seed, volume
signing key/time, and custom-environments repository identity. Source-template
attestation is not sufficient because secret-derived interpolation can change
the final HCL. The correct path is a coherent prerequisite apply, followed by
an ordinary full replan whose three core jobspecs must all be concrete and
Nomad-parsed.

## Independently confirmed prerequisite plan

Six fixed terminal targets produce exactly 23 absent managed resources, all
`["create"]`, with zero data-resource changes and zero Nomad resources:

```text
google_secret_manager_secret_version.postgres_connection_string
google_secret_manager_secret_version.postgres_read_replica_connection_string
google_secret_manager_secret_version.sandbox_access_token_hash_seed
time_static.volume_token_generation
tls_private_key.volume_token[0]
google_artifact_registry_repository_iam_member.custom_environments_repository_member
```

The exact 23-resource closure is:

```text
google_artifact_registry_repository.custom_environments_repository
google_artifact_registry_repository_iam_member.custom_environments_repository_member
google_compute_global_address.cloud_sql_private_services
google_project_iam_member.cloud_sql_service_agent
google_project_iam_member.service_networking_service_agent
google_project_service.cloud_sql_admin_api
google_project_service.service_networking_api
google_project_service_identity.cloud_sql
google_project_service_identity.service_networking
google_secret_manager_secret.postgres_read_replica_connection_string
google_secret_manager_secret.sandbox_access_token_hash_seed
google_secret_manager_secret_version.postgres_connection_string
google_secret_manager_secret_version.postgres_read_replica_connection_string
google_secret_manager_secret_version.sandbox_access_token_hash_seed
google_service_networking_connection.cloud_sql
google_sql_database.operator_canary
google_sql_database_instance.operator_canary
google_sql_user.operator_canary
random_password.cloud_sql_operator_canary
random_password.sandbox_access_token_hash_seed
terraform_data.cloud_sql_connection_budget
time_static.volume_token_generation
tls_private_key.volume_token[0]
```

Reject any 24th mutation, update/delete/replace, data read, or Nomad resource.
Provider-computed IDs and generated secret values are expected to be unknown;
identity/topology fields are not.

## Unfinished implementation worktree

Continue here:

```text
/Users/Shared/engram/monad-e2b-infra-worktrees/workload-prerequisites
branch: agent/workload-prerequisites
base: 7aca8601976ca6fe2d8a679ab3c4696e456a0906
```

Current uncommitted files:

```text
M  iac/provider-gcp/Makefile
M  iac/provider-gcp/scripts/workload-plan-metadata.sh
?? iac/provider-gcp/scripts/assert-workload-prerequisite-plan.sh
?? iac/provider-gcp/scripts/test-workload-prerequisite-plan.sh
```

What is already implemented:

- fixed six-target `workload-prerequisite-plan`;
- private saved plan and manifest;
- rollout mutation lease;
- before/after artifact fingerprint;
- exact 23-create plan assertion;
- `workload-prerequisite-plan-check`;
- confirmation-gated `workload-prerequisite-apply`;
- exact-byte verification and targeted post-apply convergence;
- plan/manifest cleanup and recovery handling;
- workload metadata exclusions for private temporary directories;
- all three assertion calls now receive
  `WORKLOAD_GCP_PROJECT_ID`, `WORKLOAD_GCP_REGION`, and `WORKLOAD_PREFIX`.

The assertion passed a real read-only targeted plan:

```text
Workload prerequisite plan passed: exactly 23 reviewed creates,
zero data reads, and zero Nomad resources.
```

## Unfinished checks before publishing the prerequisite lane

The focused fixture test currently fails:

```text
jq: error (at <stdin>:632): Cannot index string with string "address"
```

This occurs in:

```text
iac/provider-gcp/scripts/test-workload-prerequisite-plan.sh
```

Fix the fixture/topology shape; do not weaken the live assertion.

An independent review also identified these remaining assertion bindings:

1. Require the custom repository's effective location to be the expected
   region through exact provider/config wiring, and bind repository IAM
   project/location/repository plus the exact infrastructure service account,
   not merely a `serviceAccount:` prefix.
2. Bind both created Secret Manager containers to the expected project.
3. Bind each secret-version `secret` configuration reference to its own
   container.
4. Bind sandbox seed `secret_data` to
   `random_password.sandbox_access_token_hash_seed.result`; require the result
   to be null/unknown/sensitive in the plan.
5. Require both `time_static` `rfc3339` and `unix` to be null/unknown.
6. Ensure the Cloud SQL checks use the exact reviewed policy contract, not a
   silently loosened replacement.

Keep these narrow. Do not add a source-template fallback or refactor the
release system.

Run before commit:

```bash
cd /Users/Shared/engram/monad-e2b-infra-worktrees/workload-prerequisites
bash -n iac/provider-gcp/scripts/assert-workload-prerequisite-plan.sh
bash -n iac/provider-gcp/scripts/test-workload-prerequisite-plan.sh
./iac/provider-gcp/scripts/test-workload-prerequisite-plan.sh
mise exec -- make -C iac/provider-gcp workload-plan-assertions-test
mise exec -- make -C iac/provider-gcp workload-release-test
mise exec -- terraform -chdir=iac/provider-gcp fmt -check -recursive
mise exec -- terraform -chdir=iac/provider-gcp validate
git diff --check
```

Then obtain one independent adversarial review, commit, push a PR, wait for
keyless GCP CI, merge, and fast-forward
`/Users/Shared/engram/monad-e2b-infra` while preserving its untracked canary
helper.

## Deployment sequence after merge

From `/Users/Shared/engram/monad-e2b-infra`:

```bash
mise exec -- make -C iac/provider-gcp workload-prerequisite-plan
mise exec -- make -C iac/provider-gcp workload-prerequisite-plan-check
```

Review that the saved plan is exactly the 23 creates above, with no data reads,
updates, replacements, deletes, or Nomad resources. Then:

```bash
mise exec -- make -C iac/provider-gcp workload-prerequisite-apply \
  CONFIRM='APPLY WORKLOAD PREREQUISITES'
```

Next regenerate the ordinary full plan:

```bash
mise exec -- make -C iac/provider-gcp workload-plan
mise exec -- make -C iac/provider-gcp workload-plan-check
```

Do not assume the remaining count; inspect it. It should be add-only, and all
three core jobspecs must now be concrete and structurally parsed. Apply only
the saved reviewed bytes:

```bash
mise exec -- make -C iac/provider-gcp workload-apply \
  CONFIRM='APPLY ONE WORKCELL CANARY'
```

Then verify:

1. phase-two API and Nomad jobs are healthy;
2. public application connectivity, DNS/TLS, logs, network policy, and
   metadata isolation;
3. no secret appears in logs, plan manifests, or command output;
4. cleanup and recovery paths;
5. raw lifecycle with exact `e2b@2.21.0`:
   create, execute, pause/connect, snapshot, fork, divergence, destroy;
6. hard maximum of two simultaneous sandboxes: source plus one child;
7. delete every explicit snapshot and sandbox.

Only after the raw canary passes should TAMS register the GCP provider. The
TAMS adapter must keep failing closed until trusted placement attestation,
durable cross-replica create serialization, snapshot/fork operation lineage,
and bounded warm-pool semantics are present.

## Safety notes

- Never print or commit plan JSON: prerequisite plans contain generated
  passwords/private keys, and the later full plan contains database/signing
  values inside sensitive jobspecs.
- Keep saved plans, parser temporaries, and manifests mode `0600`.
- Do not expose static provider/GitHub/model credentials to workcells.
- Do not delete or modify `packages/db/scripts/canary/`.
- Do not enable customer traffic or production credentials during the raw
  operator canary.
- Do not mark Gate 2 complete until the lifecycle and cleanup canary passes.
