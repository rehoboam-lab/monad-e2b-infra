#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_id="${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
region="${GCP_REGION:?GCP_REGION is required}"
prefix="${PREFIX:?PREFIX is required}"
expected_size="${SERVER_CLUSTER_SIZE:?SERVER_CLUSTER_SIZE is required}"
gcloud_bin="${GCLOUD_BIN:-gcloud}"
max_seconds="${SERVER_SAFETY_WAIT_SECONDS:-600}"
poll_seconds="${SERVER_SAFETY_POLL_SECONDS:-5}"
health_source="${script_dir}/../nomad-cluster/scripts/nomad-voter-health.py"
installer_source="${script_dir}/../nomad-cluster/scripts/install-nomad-voter-health.sh"

[[ "${project_id}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "${region}" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]
[[ "${prefix}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?-$ ]]
[[ "${expected_size}" =~ ^[1-9][0-9]*$ ]]
[[ "${max_seconds}" =~ ^[1-9][0-9]*$ ]] && ((max_seconds <= 1800))
[[ "${poll_seconds}" =~ ^[0-9]+$ ]] && ((poll_seconds <= 60))

server_pool="${prefix}orch-server-rig"
legacy_health="${prefix}orch-server-nomad-check"
strict_health="${prefix}orch-server-voter-check"
health_sha256="$(shasum -a 256 "${health_source}" | awk '{print $1}')"
installer_sha256="$(shasum -a 256 "${installer_source}" | awk '{print $1}')"

[[ -f "${health_source}" && ! -L "${health_source}" ]]
[[ -f "${installer_source}" && ! -L "${installer_source}" ]]
[[ "${health_sha256}" =~ ^[0-9a-f]{64}$ ]]
[[ "${installer_sha256}" =~ ^[0-9a-f]{64}$ ]]

gcloud_direct() {
  env \
    -u ALL_PROXY -u all_proxy \
    -u HTTP_PROXY -u http_proxy \
    -u HTTPS_PROXY -u https_proxy \
    -u NO_PROXY -u no_proxy \
    "${gcloud_bin}" "$@"
}

describe_pool() {
  gcloud_direct compute instance-groups managed describe "${server_pool}" \
    --region="${region}" \
    --project="${project_id}" \
    --format=json
}

managed_inventory() {
  local expected_template="$1"

  gcloud_direct compute instance-groups managed list-instances "${server_pool}" \
    --region="${region}" \
    --project="${project_id}" \
    --format=json \
    | jq -ceS \
      --argjson size "${expected_size}" \
      --arg template "${expected_template}" '
        if (
          type == "array"
          and length == $size
          and ([.[].id] | unique | length) == $size
          and ([.[].name] | unique | length) == $size
          and all(.[];
            .currentAction == "NONE"
            and .instanceStatus == "RUNNING"
            and .version.instanceTemplate == $template
          )
        ) then
          map({
            id,
            name,
            instance,
            zone:(.instance | capture("/zones/(?<zone>[^/]+)/instances/").zone),
            currentAction,
            instanceStatus,
            instanceTemplate:.version.instanceTemplate
          })
          | sort_by(.name)
        else
          error("server MIG inventory is not stable, unique, running, and on the exact preserved template")
        end
      '
}

assert_health_check() {
  local name="$1"
  local port="$2"
  local path="$3"

  gcloud_direct compute health-checks describe "${name}" \
    --project="${project_id}" \
    --format=json \
    | jq -e \
      --argjson port "${port}" \
      --arg path "${path}" '
        .type == "HTTP"
        and .checkIntervalSec == 5
        and .timeoutSec == 5
        and .healthyThreshold == 2
        and .unhealthyThreshold == 10
        and .httpHealthCheck.port == $port
        and .httpHealthCheck.requestPath == $path
      ' >/dev/null
}

pool_contract() {
  local document="$1"
  local mode="$2"

  jq -e \
    --argjson size "${expected_size}" \
    --arg legacy_suffix "/global/healthChecks/${legacy_health}" \
    --arg strict_suffix "/global/healthChecks/${strict_health}" \
    --arg mode "${mode}" '
      .targetSize == $size
      and (.versions | length) == 1
      and (.versions[0].instanceTemplate | type) == "string"
      and (.versions[0].instanceTemplate | test("/global/instanceTemplates/[^/]+$"))
      and (.autoHealingPolicies | length) == 1
      and .autoHealingPolicies[0].initialDelaySec == 120
      and .updatePolicy.type == "PROACTIVE"
      and .updatePolicy.minimalAction == "REPLACE"
      and .updatePolicy.replacementMethod == "SUBSTITUTE"
      and .instanceLifecyclePolicy.defaultActionOnFailure == "REPAIR"
      and .instanceLifecyclePolicy.forceUpdateOnRepair == "NO"
      and (
        if $mode == "before" then
          (
            (.autoHealingPolicies[0].healthCheck | endswith($legacy_suffix))
            and
            .updatePolicy.maxSurge.fixed == 0
            and .updatePolicy.maxUnavailable.fixed == 1
            and .instanceLifecyclePolicy.onFailedHealthCheck == "DEFAULT_ACTION"
          )
          or (
            (.autoHealingPolicies[0].healthCheck | endswith($strict_suffix))
            and
            .updatePolicy.maxSurge.fixed == 1
            and .updatePolicy.maxUnavailable.fixed == 0
            and .instanceLifecyclePolicy.onFailedHealthCheck == "DO_NOTHING"
          )
        else
          (.autoHealingPolicies[0].healthCheck | endswith($strict_suffix))
          and .updatePolicy.maxSurge.fixed == 1
          and .updatePolicy.maxUnavailable.fixed == 0
          and .instanceLifecyclePolicy.onFailedHealthCheck == "DO_NOTHING"
          and .status.isStable == true
          and .status.versionTarget.isReached == true
        end
      )
    ' <<<"${document}" >/dev/null
}

install_strict_endpoint() {
  local inventory="$1"
  local instance_name
  local instance_zone
  local remote_health
  local remote_installer
  local remote_command

  while IFS=$'\t' read -r instance_name instance_zone; do
    [[ "${instance_name}" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]
    [[ "${instance_zone}" == "${region}-"* ]]
    remote_health="/tmp/e2b-nomad-voter-health.${health_sha256}.py"
    remote_installer="/tmp/e2b-install-nomad-voter-health.${installer_sha256}.sh"

    gcloud_direct compute scp "${health_source}" \
      "${instance_name}:${remote_health}" \
      --project="${project_id}" \
      --zone="${instance_zone}" \
      --tunnel-through-iap \
      --quiet \
      --scp-flag='-o ConnectTimeout=10' \
      --scp-flag='-o ConnectionAttempts=1' >/dev/null
    gcloud_direct compute scp "${installer_source}" \
      "${instance_name}:${remote_installer}" \
      --project="${project_id}" \
      --zone="${instance_zone}" \
      --tunnel-through-iap \
      --quiet \
      --scp-flag='-o ConnectTimeout=10' \
      --scp-flag='-o ConnectionAttempts=1' >/dev/null
    remote_command="sudo -- '${remote_installer}' '${remote_health}' '${health_sha256}' '${installer_sha256}'"
    gcloud_direct compute ssh "${instance_name}" \
      --project="${project_id}" \
      --zone="${instance_zone}" \
      --tunnel-through-iap \
      --quiet \
      --strict-host-key-checking=no \
      --ssh-flag='-o ConnectTimeout=10' \
      --ssh-flag='-o ConnectionAttempts=1' \
      --command="${remote_command}" >/dev/null
  done < <(jq -er '.[] | [.name, .zone] | @tsv' <<<"${inventory}")
}

strict_managed_health() {
  local expected_inventory="$1"
  local health_document

  health_document="$(
    gcloud_direct compute instance-groups managed list-instances "${server_pool}" \
      --region="${region}" \
      --project="${project_id}" \
      --format=json
  )" || return 1
  jq -e \
    --argjson expected "${expected_inventory}" '
      ([.[] | {id,name,instance}] | sort_by(.name))
        == ([$expected[] | {id,name,instance}] | sort_by(.name))
      and all(.[];
        .currentAction == "NONE"
        and .instanceStatus == "RUNNING"
        and (.instanceHealth | length) == 1
        and .instanceHealth[0].detailedHealthState == "HEALTHY"
      )
    ' <<<"${health_document}" >/dev/null
}

command -v jq >/dev/null
if [[ ! -x "${gcloud_bin}" ]] && ! command -v "${gcloud_bin}" >/dev/null 2>&1; then
  printf 'Required gcloud command is unavailable: %s\n' "${gcloud_bin}" >&2
  exit 2
fi

assert_health_check "${legacy_health}" 4646 /v1/agent/health
assert_health_check "${strict_health}" 50001 /healthz

before="$(describe_pool)"
pool_contract "${before}" before || {
  printf 'Server MIG is not in the exact legacy-or-safe pre-template state.\n' >&2
  exit 1
}
before_template="$(jq -er '.versions[0].instanceTemplate' <<<"${before}")"
before_inventory="$(managed_inventory "${before_template}")" || {
  printf 'Server MIG instance identity is not stable before the safety update.\n' >&2
  exit 1
}

# The live legacy template has no local-voter sidecar. Install and prove the
# exact service on every stable old instance before attaching the strict check.
# A replacement or template change at any point aborts before the MIG update.
install_strict_endpoint "${before_inventory}" || {
  printf 'Strict local-voter preinstallation failed before the MIG health switch.\n' >&2
  exit 1
}
pre_switch="$(describe_pool)"
pre_switch_template="$(jq -er '.versions[0].instanceTemplate' <<<"${pre_switch}")"
[[ "${pre_switch_template}" == "${before_template}" ]] || {
  printf 'Server template changed during strict local-voter preinstallation.\n' >&2
  exit 1
}
pre_switch_inventory="$(managed_inventory "${pre_switch_template}")" || {
  printf 'Server inventory became unstable during strict local-voter preinstallation.\n' >&2
  exit 1
}
[[ "${pre_switch_inventory}" == "${before_inventory}" ]] || {
  printf 'Server identity changed during strict local-voter preinstallation.\n' >&2
  exit 1
}

if ! jq -e '
  (.autoHealingPolicies[0].healthCheck | endswith("/global/healthChecks/'"${strict_health}"'"))
  and
  .updatePolicy.maxSurge.fixed == 1
  and .updatePolicy.maxUnavailable.fixed == 0
  and .instanceLifecyclePolicy.onFailedHealthCheck == "DO_NOTHING"
' <<<"${pre_switch}" >/dev/null; then
  gcloud_direct compute instance-groups managed update "${server_pool}" \
    --region="${region}" \
    --project="${project_id}" \
    --update-policy-type=proactive \
    --update-policy-minimal-action=replace \
    --update-policy-replacement-method=substitute \
    --update-policy-max-surge=1 \
    --update-policy-max-unavailable=0 \
    --health-check="${strict_health}" \
    --initial-delay=120 \
    --default-action-on-vm-failure=repair \
    --action-on-vm-failed-health-check=do-nothing \
    --no-force-update-on-repair \
    --quiet >/dev/null
fi

deadline=$(($(date +%s) + max_seconds))
last_check='MIG safety policy'
while true; do
  after="$(describe_pool)"
  after_template="$(jq -er '.versions[0].instanceTemplate' <<<"${after}")"
  [[ "${after_template}" == "${before_template}" ]] || {
    printf 'Server safety update changed the MIG template: %s -> %s\n' \
      "${before_template}" "${after_template}" >&2
    exit 1
  }
  after_inventory="$(managed_inventory "${after_template}")" || {
    printf 'Server MIG instance identity became unstable during the safety update.\n' >&2
    exit 1
  }
  [[ "${after_inventory}" == "${before_inventory}" ]] || {
    printf 'Server safety update replaced or changed a managed server instance.\n' >&2
    exit 1
  }
  if pool_contract "${after}" after; then
    if strict_managed_health "${before_inventory}"; then
      printf 'Server MIG safety policy converged without changing template: %s\n' \
        "${before_template}"
      exit 0
    fi
    last_check='strict GCE health on every exact old voter'
  else
    last_check='MIG safety policy'
  fi
  if (($(date +%s) >= deadline)); then
    printf 'Server MIG safety policy did not converge within %s seconds at %s.\n' \
      "${max_seconds}" "${last_check}" >&2
    exit 1
  fi
  printf 'Waiting for strict GCE health on every exact old voter.\n' >&2
  sleep "${poll_seconds}"
done
