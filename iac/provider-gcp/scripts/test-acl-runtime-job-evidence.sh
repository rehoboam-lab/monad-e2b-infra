#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="${script_dir}/assert-acl-runtime-job-evidence.sh"
provider_root="$(cd "${script_dir}/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/acl-runtime-evidence-test.XXXXXX")"
trap 'rm -rf -- "${test_root}"' EXIT

repo_root="${test_root}/repo"
mkdir -p "${repo_root}"
printf '%s\n' source >"${repo_root}/source"
(
  cd "${repo_root}"
  git init -q
  git config user.name fixture
  git config user.email fixture@example.invalid
  git add source
  git commit -qm fixture
)
source_head="$(git -C "${repo_root}" rev-parse HEAD)"
checkpoint="${test_root}/network.checkpoint.json"
printf '%s\n' '{"stage":"network"}' >"${checkpoint}"

runtime="${test_root}/runtime.json"
inventory="${test_root}/inventory.json"
transition_inventory="${test_root}/transition-inventory.json"
transition="${test_root}/transition.json"
convergence="${test_root}/convergence.json"
jobspec_sha="$(printf service-source | shasum -a 256 | awk '{print $1}')"
address='module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server'
jq -nS --arg address "${address}" --arg jobspec_sha "${jobspec_sha}" '[{
  address:$address,
  expected_modify_index:42,
  job_id:"otel-collector-nomad-server",
  job_type:"service",
  requires_exclusive_transition:false,
  jobspec_sha256:$jobspec_sha
}]' >"${runtime}"
jq -nS --arg address "${address}" --arg jobspec_sha "${jobspec_sha}" '[{
  address:$address,
  expected_modify_index:42,
  job_id:"otel-collector-nomad-server",
  job_type:"service",
  inventory_class:"managed-runtime",
  child_mode:"none",
  submission_source_sha256:$jobspec_sha
}]' >"${inventory}"
runtime_static_sha="$(jq -S 'map(.expected_modify_index = null)' "${runtime}" | shasum -a 256 | awk '{print $1}')"
jq -S 'map(.expected_modify_index = null)' \
  "${inventory}" >"${transition_inventory}"
inventory_static_sha="$(shasum -a 256 "${transition_inventory}" | awk '{print $1}')"
runtime_sha="$(shasum -a 256 "${runtime}" | awk '{print $1}')"
inventory_sha="$(shasum -a 256 "${inventory}" | awk '{print $1}')"
jq -nS \
  --arg runtime_static_sha "${runtime_static_sha}" \
  --arg inventory_static_sha "${inventory_static_sha}" '{
    schema_version:1,
    kind:"exclusive-runtime-transition",
    descendant_policy:"observe",
    projection_sha256:$runtime_static_sha,
    inventory_projection_sha256:$inventory_static_sha,
    live_inventory:{
      schema_version:1,
      kind:"live-nomad-job-inventory",
      completeness:"no-unreviewed-top-level-jobs",
      projection_sha256:$inventory_static_sha,
      top_level_jobs:[],
      descendant_jobs:[]
    },
    descendant_quiescence:{
      schema_version:1,
      kind:"nomad-descendant-observation",
      policy:"observe",
      observed_descendants:0,
      observed_active_allocations:0,
      actions:[]
    },
    actions:[]
  }' >"${transition}"
jq -nS \
  --arg runtime_sha "${runtime_sha}" \
  --arg inventory_sha "${inventory_sha}" \
  --arg address "${address}" \
  --arg jobspec_sha "${jobspec_sha}" '{
    schema_version:1,
    kind:"live-nomad-job-convergence",
    projection_sha256:$runtime_sha,
    inventory_projection_sha256:$inventory_sha,
    live_inventory:{
      schema_version:1,
      kind:"live-nomad-job-inventory",
      completeness:"exact-top-level-jobs",
      projection_sha256:$inventory_sha,
      top_level_jobs:[{
        job_id:"otel-collector-nomad-server",
        job_type:"service",
        job_modify_index:42,
        submission_source_sha256:$jobspec_sha
      }],
      descendant_jobs:[]
    },
    jobs:[{
      address:$address,
      job_id:"otel-collector-nomad-server",
      job_type:"service",
      job_modify_index:42,
      jobspec_sha256:$jobspec_sha
    }]
  }' >"${convergence}"

evidence="${test_root}/evidence.json"
jq -nS \
  --arg source_head "${source_head}" \
  --arg checkpoint_sha "$(shasum -a 256 "${checkpoint}" | awk '{print $1}')" \
  --arg reviewed_plan_sha "$(printf plan | shasum -a 256 | awk '{print $1}')" \
  --arg reviewed_manifest_sha "$(printf manifest | shasum -a 256 | awk '{print $1}')" \
  --arg converged_plan_sha "$(printf converged | shasum -a 256 | awk '{print $1}')" \
  --arg runtime_static_sha "${runtime_static_sha}" \
  --arg runtime_sha "${runtime_sha}" \
  --arg inventory_static_sha "${inventory_static_sha}" \
  --arg inventory_sha "${inventory_sha}" \
  --arg transition_sha "$(shasum -a 256 "${transition}" | awk '{print $1}')" \
  --arg convergence_sha "$(shasum -a 256 "${convergence}" | awk '{print $1}')" \
  --arg address "${address}" \
  --slurpfile runtime "${runtime}" \
  --slurpfile transition_inventory "${transition_inventory}" \
  --slurpfile inventory "${inventory}" \
  --slurpfile transition "${transition}" \
  --slurpfile convergence "${convergence}" '{
    schema_version:1,
    source_sha:$source_head,
    environment:"dev",
    project_id:"monad-code",
    region:"us-east4",
    zone:"us-east4-c",
    prefix:"e2b-",
    phase:"pre-server",
    stage:"network",
    checkpoint_sha256:$checkpoint_sha,
    reviewed_plan_sha256:$reviewed_plan_sha,
    reviewed_manifest_sha256:$reviewed_manifest_sha,
    converged_plan_sha256:$converged_plan_sha,
    job_projection_sha256:$runtime_static_sha,
    live_job_projection_sha256:$runtime_sha,
    job_inventory_projection_sha256:$inventory_static_sha,
    live_job_inventory_projection_sha256:$inventory_sha,
    exclusive_transition_sha256:$transition_sha,
    live_nomad_convergence_sha256:$convergence_sha,
    job_addresses:[$address],
    exclusive_transition:$transition[0],
    live_job_projection:$runtime[0],
    job_inventory_projection:$transition_inventory[0],
    live_job_inventory_projection:$inventory[0],
    live_nomad_convergence:$convergence[0],
    applied_at:"2026-08-07T00:00:00Z"
  }' >"${evidence}"
chmod 0600 "${evidence}"

"${validator}" "${evidence}" pre-server dev "${checkpoint}" monad-code \
  us-east4 us-east4-c e2b- "${repo_root}" >/dev/null

tampered="${test_root}/tampered.json"
jq '.live_nomad_convergence.jobs[0].job_modify_index = 41' \
  "${evidence}" >"${tampered}"
chmod 0600 "${tampered}"
if "${validator}" "${tampered}" pre-server dev "${checkpoint}" monad-code \
  us-east4 us-east4-c e2b- "${repo_root}" >/dev/null 2>&1; then
  printf 'Tampered nested live convergence escaped the evidence guard.\n' >&2
  exit 1
fi

wrong_source="${test_root}/wrong-source.json"
jq '.source_sha = ("0" * 40)' "${evidence}" >"${wrong_source}"
chmod 0600 "${wrong_source}"
if "${validator}" "${wrong_source}" pre-server dev "${checkpoint}" monad-code \
  us-east4 us-east4-c e2b- "${repo_root}" >/dev/null 2>&1; then
  printf 'Wrong-source completion evidence escaped the guard.\n' >&2
  exit 1
fi

if "${validator}" "${evidence}" pre-server prod "${checkpoint}" monad-code \
  us-east4 us-east4-c e2b- "${repo_root}" >/dev/null 2>&1; then
  printf 'Wrong-environment completion evidence escaped the guard.\n' >&2
  exit 1
fi

grep -F '$(MAKE) --no-print-directory acl-runtime-job-pre-server-evidence-guard' \
  "${provider_root}/Makefile" >/dev/null
grep -F '@ $(MAKE) workload-context-guard acl-runtime-job-pre-server-evidence-guard' \
  "${provider_root}/Makefile" >/dev/null
if make -s -C "${provider_root}" acl-runtime-job-pre-server-evidence-guard \
  ENV=dev GCP_PROJECT_ID=monad-code GCP_REGION=us-east4 \
  GCP_ZONE=us-east4-c PREFIX=e2b- \
  ACL_RUNTIME_JOB_PRE_SERVER_CHECKPOINT= >/dev/null 2>&1; then
  printf 'Make sequencing guard accepted a missing pre-server checkpoint/evidence chain.\n' >&2
  exit 1
fi

printf 'ACL runtime-job exact-source and nested live-evidence fixtures passed.\n'
