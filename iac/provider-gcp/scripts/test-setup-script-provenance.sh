#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider_root="$(cd "${script_dir}/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/bin" "${test_root}/payloads" "${test_root}/targets"
printf 'reviewed setup bytes\n' >"${test_root}/payloads/reviewed"
printf 'unreviewed setup bytes\n' >"${test_root}/payloads/unreviewed"
reviewed_sha="$(sha256sum "${test_root}/payloads/reviewed" | awk '{print $1}')"

cat >"${test_root}/bin/gsutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "cp" && "$#" == 3 ]]
cp -- "${SETUP_TEST_PAYLOAD:?}" "$3"
EOF
cat >"${test_root}/bin/chown" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 2 && "$1" == "root:root" ]]
EOF
chmod 0700 "${test_root}/bin/gsutil" "${test_root}/bin/chown"

templates=(
  "${provider_root}/modules/nodepool-api/scripts/start-api.sh"
  "${provider_root}/nomad-cluster/scripts/start-server.sh"
  "${provider_root}/nomad-cluster/scripts/start-client.sh"
  "${provider_root}/nomad-cluster/scripts/start-clickhouse.sh"
)

for template in "${templates[@]}"; do
  name="$(basename "${template}")"
  function_file="${test_root}/${name}.function.sh"
  awk '
    /^install_setup_script\(\) \{/ {copy=1}
    copy {print}
    copy && /^}$/ {exit}
  ' "${template}" \
    | sed 's/${SCRIPTS_BUCKET}/reviewed-bucket/g' \
    >"${function_file}"

  grep -F '^[0-9a-f]{64}$' "${function_file}" >/dev/null
  grep -F 'sha256sum "$tmp"' "${function_file}" >/dev/null
  grep -F 'mv -f -- "$tmp" "$target"' "${function_file}" >/dev/null

  target="${test_root}/targets/${name}"
  printf 'previous installed bytes\n' >"${target}"

  PATH="${test_root}/bin:${PATH}" \
    SETUP_TEST_PAYLOAD="${test_root}/payloads/reviewed" \
    bash -euo pipefail -c '
      source "$1"
      install_setup_script reviewed "$2" "$3"
    ' bash "${function_file}" "${reviewed_sha}" "${target}"
  cmp "${test_root}/payloads/reviewed" "${target}"

  printf 'previous installed bytes\n' >"${target}"
  if PATH="${test_root}/bin:${PATH}" \
    SETUP_TEST_PAYLOAD="${test_root}/payloads/unreviewed" \
    bash -euo pipefail -c '
      source "$1"
      install_setup_script reviewed "$2" "$3"
    ' bash "${function_file}" "${reviewed_sha}" "${target}" \
      >"${test_root}/${name}.mismatch.out" 2>&1; then
    printf 'Expected %s to reject mismatched setup bytes.\n' "${name}" >&2
    exit 1
  fi
  grep -F 'Setup-script SHA-256 mismatch' "${test_root}/${name}.mismatch.out" >/dev/null
  grep -Fx 'previous installed bytes' "${target}" >/dev/null
  if compgen -G "${target}.tmp.*" >/dev/null; then
    printf '%s left a temporary setup script after digest rejection.\n' "${name}" >&2
    exit 1
  fi

  if PATH="${test_root}/bin:${PATH}" \
    SETUP_TEST_PAYLOAD="${test_root}/payloads/reviewed" \
    bash -euo pipefail -c '
      source "$1"
      install_setup_script reviewed abc12 "$2"
    ' bash "${function_file}" "${target}" \
      >"${test_root}/${name}.short.out" 2>&1; then
    printf 'Expected %s to reject a short setup digest.\n' "${name}" >&2
    exit 1
  fi
  grep -F 'Refusing invalid setup-script SHA-256' "${test_root}/${name}.short.out" >/dev/null
done

sed -n '/^  file_hash = {$/,/^  }$/p' "${provider_root}/nomad-cluster/main.tf" \
  | grep -F '= filesha256(' \
  | wc -l | tr -d ' ' \
  | grep -Fx '6' >/dev/null
if grep -F 'substr(filesha256' "${provider_root}/nomad-cluster/main.tf" >/dev/null; then
  printf 'Setup object provenance still truncates SHA-256.\n' >&2
  exit 1
fi

printf 'Full-SHA setup-script provenance and atomic installation tests passed.\n'
