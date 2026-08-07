#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider_root="$(cd "${script_dir}/.." && pwd)"
handoff_script="${script_dir}/consul-management-handoff.sh"
classifier="${script_dir}/classify-consul-token-authority.py"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT

bash -n "${handoff_script}"
python3 -m py_compile "${classifier}"
rm -rf -- "${script_dir}/__pycache__"

grep -F 'compute ssh "${selected_server}"' "${handoff_script}" >/dev/null
grep -F -- '--tunnel-through-iap' "${handoff_script}" >/dev/null
grep -F -- '-L127.0.0.1:${local_port}:127.0.0.1:8500' "${handoff_script}" >/dev/null
grep -F 'consul-management-handoff-stage:' "${provider_root}/Makefile" >/dev/null
grep -F 'consul-management-handoff-verify-staged:' "${provider_root}/Makefile" >/dev/null
grep -F 'consul-management-handoff-retire:' "${provider_root}/Makefile" >/dev/null
grep -F 'consul-management-handoff-verify:' "${provider_root}/Makefile" >/dev/null
grep -F 'consul-management-handoff-post-plan:' "${provider_root}/Makefile" >/dev/null

cat >"${test_root}/token.json" <<'JSON'
{
  "AccessorID": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "Policies": [],
  "Roles": [],
  "ExpandedPolicies": [
    {
      "ID": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "Name": "global-management",
      "Rules": "acl = \"write\""
    }
  ],
  "ExpandedRoles": [],
  "TemplatedPolicies": [],
  "Local": false,
  "ExpirationTTL": 0,
  "Description": "fixture",
  "AuthMethod": "",
  "AuthMethodNamespace": ""
}
JSON

classification="$(python3 "${classifier}" "${test_root}/token.json" \
  aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa)"
jq -e '
  .accessor == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  and .acl_write == true
' <<<"${classification}" >/dev/null

if python3 "${classifier}" "${test_root}/token.json" \
  cccccccc-cccc-4ccc-8ccc-cccccccccccc >/dev/null 2>&1; then
  printf 'Consul authority classifier accepted the wrong accessor.\n' >&2
  exit 1
fi

if grep -E 'curl[^\n]*(X-Consul-Token|[?&]token=)|consul[^\n]*-token[ =]' \
  "${handoff_script}" >/dev/null; then
  printf 'Consul handoff exposes token material in an argument vector.\n' >&2
  exit 1
fi

printf 'Consul management handoff static and authority-classification guards passed.\n'
