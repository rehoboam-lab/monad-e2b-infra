#!/usr/bin/env bash
set -euo pipefail

project_id="${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
region="${GCP_REGION:?GCP_REGION is required}"
zone="${GCP_ZONE:?GCP_ZONE is required}"
prefix="${PREFIX:?PREFIX is required}"
stage="${NETWORK_HARDENING_ROLLOUT_STAGE:?NETWORK_HARDENING_ROLLOUT_STAGE is required}"
gcloud_bin="${GCLOUD_BIN:-gcloud}"
max_seconds="${NETWORK_HARDENING_WAIT_SECONDS:-1800}"
poll_seconds="${NETWORK_HARDENING_POLL_SECONDS:-15}"

case "${stage}" in
  disabled)
    printf 'Network-hardening rollout is disabled; no convergence wait is required.\n'
    exit 0
    ;;
  network | server | api | worker | build) ;;
  *)
    printf 'Unknown network-hardening convergence stage: %s\n' "${stage}" >&2
    exit 2
    ;;
esac

[[ "${zone}" == "${region}-"* ]] || {
  printf 'Network-hardening zone must belong to region %s: %s\n' "${region}" "${zone}" >&2
  exit 2
}
if [[ ! "${max_seconds}" =~ ^[0-9]+$ ]] || ((max_seconds < 1 || max_seconds > 3600)); then
  printf 'Network-hardening wait must be between 1 and 3600 seconds: %s\n' "${max_seconds}" >&2
  exit 2
fi
if [[ ! "${poll_seconds}" =~ ^[0-9]+$ ]] || ((poll_seconds > 60)); then
  printf 'Network-hardening poll interval must be between 0 and 60 seconds: %s\n' "${poll_seconds}" >&2
  exit 2
fi
if [[ ! -x "${gcloud_bin}" ]] && ! command -v "${gcloud_bin}" >/dev/null 2>&1; then
  printf 'Required gcloud command is unavailable: %s\n' "${gcloud_bin}" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || {
  printf 'jq is required to verify network-hardening convergence.\n' >&2
  exit 2
}

iap_firewall="${prefix}orch-internal-remote-connection-firewall-ingress"
public_deny_firewall="${prefix}orch-remote-connection-firewall-ingress"
last_check="starting"

firewall_ready() {
  local name="$1"
  local mode="$2"
  local document

  last_check="firewall ${name}"
  document="$(
    "${gcloud_bin}" compute firewall-rules describe "${name}" \
      --project="${project_id}" \
      --format=json 2>/dev/null
  )" || return 1

  case "${mode}" in
    iap)
      jq -e '
        .direction == "INGRESS"
        and .disabled != true
        and .priority == 900
        and (.sourceRanges | sort) == ["35.235.240.0/20"]
        and (.targetTags | sort) == ["orch"]
        and ([.allowed[]? | select(.IPProtocol == "tcp") | .ports[]?] | sort)
          == ["22", "3389"]
        and ((.denied // []) | length) == 0
        and .logConfig.enable == true
        and .logConfig.metadata == "EXCLUDE_ALL_METADATA"
      ' <<<"${document}" >/dev/null
      ;;
    public-deny)
      jq -e '
        .direction == "INGRESS"
        and .disabled != true
        and .priority == 1000
        and (.sourceRanges | sort) == ["0.0.0.0/0"]
        and (.targetTags | sort) == ["orch"]
        and ([.denied[]? | select(.IPProtocol == "tcp") | .ports[]?] | sort)
          == ["22", "3389"]
        and ((.allowed // []) | length) == 0
        and .logConfig.enable == true
        and .logConfig.metadata == "EXCLUDE_ALL_METADATA"
      ' <<<"${document}" >/dev/null
      ;;
  esac
}

managed_group_ready() {
  local name="$1"
  local scope_flag="$2"
  local scope_value="$3"
  local document

  last_check="managed group ${name}"
  document="$(
    "${gcloud_bin}" compute instance-groups managed describe "${name}" \
      "${scope_flag}=${scope_value}" \
      --project="${project_id}" \
      --format=json 2>/dev/null
  )" || return 1

  jq -e '
    (.targetSize | type) == "number"
    and .status.isStable == true
    and .status.versionTarget.isReached == true
    and ((.currentActions.none // 0) == .targetSize)
    and (
      (.currentActions // {})
      | to_entries
      | all(.key == "none" or .value == 0)
    )
  ' <<<"${document}" >/dev/null
}

stage_ready() {
  firewall_ready "${iap_firewall}" iap || return 1
  firewall_ready "${public_deny_firewall}" public-deny || return 1

  case "${stage}" in
    network)
      return 0
      ;;
    server)
      managed_group_ready "${prefix}orch-server-rig" --region "${region}"
      ;;
    api)
      managed_group_ready "${prefix}orch-api-ig" --zone "${zone}"
      ;;
    worker)
      managed_group_ready "${prefix}orch-client-rig" --region "${region}"
      ;;
    build)
      managed_group_ready "${prefix}orch-build-default-rig" --region "${region}" || return 1
      managed_group_ready "${prefix}orch-loki-ig" --zone "${zone}" || return 1
      managed_group_ready "${prefix}clickhouse-ig" --zone "${zone}"
      ;;
  esac
}

start_time="$(date +%s)"
deadline=$((start_time + max_seconds))

while true; do
  if stage_ready; then
    printf 'Network-hardening stage converged: %s.\n' "${stage}"
    exit 0
  fi

  now="$(date +%s)"
  if ((now >= deadline)); then
    printf 'Network-hardening stage %s did not converge within %s seconds at %s.\n' \
      "${stage}" "${max_seconds}" "${last_check}" >&2
    exit 1
  fi

  printf 'Waiting for network-hardening stage %s at %s (%ss elapsed).\n' \
    "${stage}" "${last_check}" "$((now - start_time))" >&2
  sleep "${poll_seconds}"
done
