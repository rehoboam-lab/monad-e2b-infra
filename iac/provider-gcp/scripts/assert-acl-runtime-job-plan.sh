#!/usr/bin/env bash
set -euo pipefail

plan_path="${1:?usage: assert-acl-runtime-job-plan.sh PLAN TERRAFORM_BIN PHASE PROJECT ZONE PREFIX}"
terraform_bin="${2:?usage: assert-acl-runtime-job-plan.sh PLAN TERRAFORM_BIN PHASE PROJECT ZONE PREFIX}"
phase="${3:?usage: assert-acl-runtime-job-plan.sh PLAN TERRAFORM_BIN PHASE PROJECT ZONE PREFIX}"
project_id="${4:?usage: assert-acl-runtime-job-plan.sh PLAN TERRAFORM_BIN PHASE PROJECT ZONE PREFIX}"
zone="${5:?usage: assert-acl-runtime-job-plan.sh PLAN TERRAFORM_BIN PHASE PROJECT ZONE PREFIX}"
prefix="${6:?usage: assert-acl-runtime-job-plan.sh PLAN TERRAFORM_BIN PHASE PROJECT ZONE PREFIX}"

case "$phase" in
  pre-server)
    required_addresses='[
      "module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server"
    ]'
    ;;
  post-api)
    required_addresses='[]'
    ;;
  *)
    printf 'Unknown ACL runtime-job phase: %s\n' "$phase" >&2
    exit 2
    ;;
esac

plan_json="$($terraform_bin show -json "$plan_path")"
jq -e '.errored != true' <<<"$plan_json" >/dev/null || {
  printf 'Refusing errored ACL runtime-job plan.\n' >&2
  exit 1
}

environment_guard='module.cluster.terraform_data.acl_bootstrap_environment_guard'
handoff_address='module.cluster.terraform_data.consul_management_handoff_candidate[0]'
jq -e --arg address "$environment_guard" '
  [.resource_changes[]? | select(.address == $address)] as $guard
  | ($guard | length) == 1
    and $guard[0].type == "terraform_data"
    and $guard[0].change.actions == ["no-op"]
    and $guard[0].change.before.input == "dev"
    and $guard[0].change.after.input == "dev"
' <<<"$plan_json" >/dev/null || {
  printf 'ACL runtime-job plan must traverse the clean dev-only cluster guard.\n' >&2
  exit 1
}

if [[ "$phase" == "pre-server" ]]; then
  rollout_ledger='[
    {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"}
  ]'
  if jq -e --arg address "$handoff_address" \
    'any(.resource_changes[]?; .address == $address)' <<<"$plan_json" >/dev/null; then
    printf 'Pre-server job plan cannot claim or remove a Consul candidate handoff marker.\n' >&2
    exit 1
  fi
else
  rollout_ledger='[
    {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_network","input":"network"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_network","input":"network"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_safety[0]","input":"server-safety"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_safety[0]","input":"server-safety"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_template[0]","input":"server"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_template[0]","input":"server"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_server_health[0]","input":"server-health"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_server_health[0]","input":"server-health"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_completion_api[0]","input":"api"},
    {"address":"module.cluster.terraform_data.network_hardening_rollout_stage_api[0]","input":"api"}
  ]'
  jq -e --arg address "$handoff_address" \
    --arg candidate_prefix "projects/${project_id}/secrets/${prefix}consul-management-candidate-token/versions/" '
      [.resource_changes[]? | select(.address == $address)] as $handoff
      | ($handoff | length) == 1
        and $handoff[0].type == "terraform_data"
        and $handoff[0].change.actions == ["no-op"]
        and $handoff[0].change.before == $handoff[0].change.after
        and $handoff[0].change.after.input.phase == "candidate"
        and $handoff[0].change.after.input.server_stage == "server"
        and ($handoff[0].change.after.input.candidate_ref | startswith($candidate_prefix))
        and ($handoff[0].change.after.input.candidate_ref | test("/versions/[1-9][0-9]*$"))
    ' <<<"$plan_json" >/dev/null || {
    printf 'Post-API job plan requires the persisted, immutable Consul candidate handoff marker.\n' >&2
    exit 1
  }
fi

jq -e --argjson expected "$rollout_ledger" '
  . as $plan
  | all($expected[];
      . as $want
      | [$plan.resource_changes[]? | select(.address == $want.address)] as $matches
      | ($matches | length) == 1
        and $matches[0].type == "terraform_data"
        and $matches[0].change.actions == ["no-op"]
        and $matches[0].change.before.input == $want.input
        and $matches[0].change.after.input == $want.input
    )
' <<<"$plan_json" >/dev/null || {
  printf 'ACL runtime-job plan is not bound to the required clean cumulative rollout ledger.\n' >&2
  exit 1
}

# A job stage may mutate only Nomad jobs. Secrets, IAM, hosts, network, and
# scheduler configuration must already have converged in guarded stages. The
# post-API phase targets the whole module, so this dynamic inventory includes
# every active long-running conditional job without a brittle hand-maintained
# allowlist. Batch, periodic, and parameterized jobs are explicitly immutable:
# even metadata-only registration creates a new Nomad evaluation and can rerun
# completed migrations or maintenance work.
if [[ "$phase" == "post-api" ]]; then
  jq -e '
    [
      .resource_changes[]?
      | select(
          .mode == "managed"
          and .type == "nomad_job"
          and (.address | startswith("module.nomad."))
        )
    ] as $jobs
    | [
        $jobs[]
        | select(.change.after.jobspec | test("(?m)^[[:space:]]*type[[:space:]]*=[[:space:]]*\\\"batch\\\""))
      ] as $batch_jobs
    | [
        $jobs[]
        | select(.change.after.jobspec | test("(?m)^[[:space:]]*type[[:space:]]*=[[:space:]]*\\\"batch\\\"") | not)
      ] as $runtime_jobs
    | ($runtime_jobs | length) > 0
      and all(.resource_changes[]?;
        .change.actions == ["no-op"]
        or (.mode == "data" and .change.actions == ["read"])
        or (
          .mode == "managed"
          and .type == "nomad_job"
          and (.address | startswith("module.nomad."))
          and (.change.after.jobspec | test("(?m)^[[:space:]]*type[[:space:]]*=[[:space:]]*\\\"batch\\\"") | not)
          and (.change.actions == ["create"] or .change.actions == ["update"])
        )
      )
      and all($batch_jobs[];
        .change.actions == ["no-op"]
        and .change.before == .change.after
        and (.change.after.jobspec | contains("monad_acl_handoff_revision") | not)
      )
      and all($runtime_jobs[];
        (.change.actions == ["create"]
          or .change.actions == ["update"]
          or .change.actions == ["no-op"])
        and (.change.after.jobspec | contains("monad_acl_handoff_revision = \"1\""))
        and (
          .change.actions != ["no-op"]
          or (.change.before.jobspec | contains("monad_acl_handoff_revision = \"1\""))
        )
      )
  ' <<<"$plan_json" >/dev/null || {
    printf 'ACL post-api job plan contains a non-job mutation or an active job without the handoff marker.\n' >&2
    exit 1
  }
else
  jq -e --argjson required "$required_addresses" '
    . as $plan
    | all(.resource_changes[]?;
        .change.actions == ["no-op"]
        or (.mode == "data" and .change.actions == ["read"])
        or (
          .mode == "managed"
          and .type == "nomad_job"
          and (.address as $address | ($required | index($address)) != null)
          and (.change.actions == ["create"] or .change.actions == ["update"])
        )
      )
      and all($required[];
        . as $address
        | any($plan.resource_changes[]?;
            .address == $address
            and (
              .change.actions == ["create"]
              or .change.actions == ["update"]
              or .change.actions == ["no-op"]
            )
            and (.change.after.jobspec | contains("monad_acl_handoff_revision = \"1\""))
            and (
              .change.actions != ["no-op"]
              or (.change.before.jobspec | contains("monad_acl_handoff_revision = \"1\""))
            )
          )
      )
  ' <<<"$plan_json" >/dev/null || {
    printf 'ACL pre-server job plan contains an unreviewed mutation or lacks its handoff-marked collector.\n' >&2
    exit 1
  }
fi

if [[ "$phase" == "pre-server" ]]; then
  jq -e \
    --arg project "$project_id" \
    --arg zone "$zone" \
    --arg name_filter "name eq ${prefix}orch-server-.*" '
      .resource_changes[]
      | select(.address == "module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server")
      | .change.after.jobspec as $jobspec
      | ($jobspec | contains("gce_sd_configs:"))
        and ($jobspec | contains("project: \"" + $project + "\""))
        and ($jobspec | contains("zone: \"" + $zone + "\""))
        and ($jobspec | contains($name_filter))
        and ($jobspec | contains("labels.monad_role") | not)
        and ($jobspec | contains("tags.items") | not)
        and ($jobspec | contains("consul_sd_configs:") | not)
    ' <<<"$plan_json" >/dev/null || {
    printf 'Pre-server collector job must use exact attached-ADC GCE discovery and no Consul catalog discovery.\n' >&2
    exit 1
  }
else
  # Token-bearing jobspecs must remain marked sensitive throughout the plan;
  # their rendered values may never appear in human plan output.
  jq -e '
    . as $plan
    |
    [
      "module.nomad.module.ingress.nomad_job.ingress",
      "module.nomad.module.orchestrator[0].nomad_job.orchestrator",
      "module.nomad.module.template_manager.nomad_job.template_manager",
      "module.nomad.module.template_manager_autoscaler[0].nomad_job.nomad_nodepool_apm",
      "module.nomad.module.monad_worker_autoscaler[0].nomad_job.shadow"
    ] as $sensitive_jobs
    | ($sensitive_jobs | map(. as $address |
        any($plan.resource_changes[]?;
          .address == $address
          and .change.after_sensitive.jobspec == true
        )
      ) | all)
    and all(
      .resource_changes[]?
      | select(.address == "module.nomad.module.logs_collector.nomad_job.logs_collector"
          or .address == "module.nomad.module.otel_collector.nomad_job.otel_collector")
      | .change.after.jobspec;
      contains("provider = \"nomad\"")
    )
  ' <<<"$plan_json" >/dev/null || {
    printf 'Post-API job plan lost secret redaction or tokenless-host Nomad service registration.\n' >&2
    exit 1
  }

  jq -e \
    --arg role_filter "(status = RUNNING) (labels.monad_role = ${prefix}nomad-server)" '
      .resource_changes[]
      | select(.address == "module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server")
      | .change.after.jobspec as $jobspec
      | ($jobspec | contains("gce_sd_configs:"))
        and ($jobspec | contains($role_filter))
        and ($jobspec | contains("tags.items") | not)
        and ($jobspec | contains("name eq ") | not)
        and ($jobspec | contains("consul_sd_configs:") | not)
    ' <<<"$plan_json" >/dev/null || {
    printf 'Post-API server collector must switch to the exact running role-label filter.\n' >&2
    exit 1
  }
fi

human_plan="$($terraform_bin show -no-color "$plan_path")"
if grep -E '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}' <<<"$human_plan" >/dev/null; then
  printf 'ACL runtime-job human plan exposed a UUID-shaped credential.\n' >&2
  exit 1
fi

printf 'ACL %s runtime-job plan assertions passed.\n' "$phase"
