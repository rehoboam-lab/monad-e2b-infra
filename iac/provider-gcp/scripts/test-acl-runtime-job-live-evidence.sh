#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="${script_dir}/assert-acl-runtime-job-live-evidence.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/acl-runtime-live-test.XXXXXX")"
trap 'rm -rf -- "${test_root}"' EXIT

evidence="${test_root}/evidence.json"
live_index="${test_root}/live-index"
lease_live="${test_root}/lease-live.json"
fake_gcloud="${test_root}/gcloud"
fake_lease="${test_root}/lease"
fake_gate="${test_root}/gate"
address='module.nomad.module.otel_collector_nomad_server.nomad_job.otel_collector_nomad_server'
source_sha="$(printf fixture-source | shasum -a 256 | awk '{print $1}')"

jq -nS \
  --arg address "${address}" \
  --arg source_sha "${source_sha}" '{
    live_job_projection:[{
      address:$address,
      expected_modify_index:42,
      job_id:"otel-collector-nomad-server",
      job_type:"service",
      requires_exclusive_transition:false,
      jobspec_sha256:$source_sha
    }],
    live_job_inventory_projection:[{
      address:$address,
      expected_modify_index:42,
      job_id:"otel-collector-nomad-server",
      job_type:"service",
      inventory_class:"managed-runtime",
      child_mode:"none",
      submission_source_sha256:$source_sha
    }],
    job_inventory_projection:[{
      address:$address,
      expected_modify_index:null,
      job_id:"otel-collector-nomad-server",
      job_type:"service",
      inventory_class:"managed-runtime",
      child_mode:"none",
      submission_source_sha256:$source_sha
    }],
    exclusive_transition:{
      schema_version:1,
      kind:"exclusive-runtime-transition",
      descendant_policy:"observe"
    }
  }' >"${evidence}"
chmod 0600 "${evidence}"
printf '%s\n' 42 >"${live_index}"

cat >"${fake_gcloud}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == "secrets versions access" ]]
printf '%s\n' 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
EOF

cat >"${fake_lease}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="$1"
shift
case "$mode" in
  acquire)
    token="${6:?}"
    [[ ! -e "${FAKE_LEASE_LIVE:?}" ]]
    jq -nS '{schema_version:1,generation:"1"}' >"$token"
    cp "$token" "${FAKE_LEASE_LIVE}"
    chmod 0600 "$token" "${FAKE_LEASE_LIVE}"
    ;;
  assert-held)
    cmp -s "${5:?}" "${FAKE_LEASE_LIVE:?}"
    ;;
  release)
    cmp -s "${2:?}" "${FAKE_LEASE_LIVE:?}"
    rm -f -- "$2" "${FAKE_LEASE_LIVE}"
    ;;
  *) exit 2 ;;
esac
EOF

cat >"${fake_gate}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == wait ]]
[[ -f "${FAKE_LEASE_LIVE:?}" ]]
if [[ "${FAKE_GATE_SIGNAL_PARENT:-false}" == true ]]; then
  kill -TERM "${PPID}"
  exit 0
fi
[[ "$(cat <&"${NOMAD_JOB_GATE_TOKEN_FD:?}")" \
  == aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa ]]
[[ "${NOMAD_JOB_GATE_DESCENDANT_POLICY:?}" == observe ]]
expected_index="$(jq -er '.[0].expected_modify_index' \
  "${NOMAD_JOB_GATE_INVENTORY_PROJECTION:?}")"
if [[ "$expected_index" != "$(<"${FAKE_LIVE_INDEX:?}")" ]]; then
  exit 91
fi
jq -e '.[0].expected_modify_index == null' \
  "${NOMAD_JOB_GATE_TRANSITION_INVENTORY_PROJECTION:?}" >/dev/null
jq -e '.descendant_policy == "observe"' \
  "${NOMAD_JOB_GATE_TRANSITION_EVIDENCE:?}" >/dev/null
jq -nS '{schema_version:1,kind:"live-nomad-job-convergence"}' \
  >"${NOMAD_JOB_GATE_EVIDENCE:?}"
chmod 0600 "${NOMAD_JOB_GATE_EVIDENCE}"
EOF

chmod 0700 "${fake_gcloud}" "${fake_lease}" "${fake_gate}"
export FAKE_LEASE_LIVE="${lease_live}"
export FAKE_LIVE_INDEX="${live_index}"

ACL_RUNTIME_JOB_LIVE_CURL_BIN=/usr/bin/curl \
  ACL_RUNTIME_JOB_LIVE_TIMEOUT_SECONDS=1 \
  ACL_RUNTIME_JOB_LIVE_POLL_SECONDS=0 \
  "${guard}" "${evidence}" dev monad-code us-east4 e2b- \
    monad-code-terraform-state example.invalid \
    projects/monad-code/secrets/e2b-nomad-secret-id/versions/7 \
    "${fake_gcloud}" "${fake_lease}" "${fake_gate}" >/dev/null
[[ ! -e "${lease_live}" ]]

# A caller that already owns the shared lease retains it across the read-only
# live assertion so no other mutator can enter before its next operation.
"${fake_lease}" acquire "${fake_gcloud}" monad-code-terraform-state \
  monad-code us-east4 caller "${test_root}/caller-lease.json"
ACL_RUNTIME_JOB_LIVE_LEASE_TOKEN="${test_root}/caller-lease.json" \
  ACL_RUNTIME_JOB_LIVE_CURL_BIN=/usr/bin/curl \
  ACL_RUNTIME_JOB_LIVE_TIMEOUT_SECONDS=1 \
  ACL_RUNTIME_JOB_LIVE_POLL_SECONDS=0 \
  "${guard}" "${evidence}" dev monad-code us-east4 e2b- \
    monad-code-terraform-state example.invalid \
    projects/monad-code/secrets/e2b-nomad-secret-id/versions/7 \
    "${fake_gcloud}" "${fake_lease}" "${fake_gate}" >/dev/null
[[ -e "${lease_live}" && -e "${test_root}/caller-lease.json" ]]
"${fake_lease}" release "${fake_gcloud}" "${test_root}/caller-lease.json"
[[ ! -e "${lease_live}" ]]

# A signal delivered while the live gate is the foreground child must never
# inherit that child's successful status. The guard fails closed and releases
# a lease it acquired itself.
set +e
FAKE_GATE_SIGNAL_PARENT=true \
  ACL_RUNTIME_JOB_LIVE_CURL_BIN=/usr/bin/curl \
  ACL_RUNTIME_JOB_LIVE_TIMEOUT_SECONDS=1 \
  ACL_RUNTIME_JOB_LIVE_POLL_SECONDS=0 \
  "${guard}" "${evidence}" dev monad-code us-east4 e2b- \
    monad-code-terraform-state example.invalid \
    projects/monad-code/secrets/e2b-nomad-secret-id/versions/7 \
    "${fake_gcloud}" "${fake_lease}" "${fake_gate}" >/dev/null 2>&1
signal_status=$?
set -e
[[ "${signal_status}" -eq 143 ]]
[[ ! -e "${lease_live}" ]]

# The same fail-closed signal path cannot release authority borrowed from the
# caller; the caller remains the sole owner until it explicitly releases it.
"${fake_lease}" acquire "${fake_gcloud}" monad-code-terraform-state \
  monad-code us-east4 caller "${test_root}/caller-lease.json"
set +e
FAKE_GATE_SIGNAL_PARENT=true \
  ACL_RUNTIME_JOB_LIVE_LEASE_TOKEN="${test_root}/caller-lease.json" \
  ACL_RUNTIME_JOB_LIVE_CURL_BIN=/usr/bin/curl \
  ACL_RUNTIME_JOB_LIVE_TIMEOUT_SECONDS=1 \
  ACL_RUNTIME_JOB_LIVE_POLL_SECONDS=0 \
  "${guard}" "${evidence}" dev monad-code us-east4 e2b- \
    monad-code-terraform-state example.invalid \
    projects/monad-code/secrets/e2b-nomad-secret-id/versions/7 \
    "${fake_gcloud}" "${fake_lease}" "${fake_gate}" >/dev/null 2>&1
borrowed_signal_status=$?
set -e
[[ "${borrowed_signal_status}" -eq 143 ]]
[[ -e "${lease_live}" && -e "${test_root}/caller-lease.json" ]]
"${fake_lease}" release "${fake_gcloud}" "${test_root}/caller-lease.json"
[[ ! -e "${lease_live}" ]]

printf '%s\n' 43 >"${live_index}"
if ACL_RUNTIME_JOB_LIVE_CURL_BIN=/usr/bin/curl \
  ACL_RUNTIME_JOB_LIVE_TIMEOUT_SECONDS=1 \
  ACL_RUNTIME_JOB_LIVE_POLL_SECONDS=0 \
  "${guard}" "${evidence}" dev monad-code us-east4 e2b- \
    monad-code-terraform-state example.invalid \
    projects/monad-code/secrets/e2b-nomad-secret-id/versions/7 \
    "${fake_gcloud}" "${fake_lease}" "${fake_gate}" >/dev/null 2>&1; then
  printf 'Drifted live Nomad index escaped archived-evidence verification.\n' >&2
  exit 1
fi
[[ ! -e "${lease_live}" ]]

printf 'ACL runtime-job live evidence lease and drift fixtures passed.\n'
