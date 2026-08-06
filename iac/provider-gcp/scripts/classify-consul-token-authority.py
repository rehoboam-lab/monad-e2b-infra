#!/usr/bin/env python3
"""Fail-closed Consul ACLWrite classification for an expanded token response."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ACCESSOR_RE = re.compile(r"^[0-9A-Fa-f-]{36}$")
IDENT_START = re.compile(r"[A-Za-z_]")
IDENT_CONTINUE = re.compile(r"[A-Za-z0-9_-]")


class ClassificationError(ValueError):
    pass


def json_object_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ClassificationError(f"duplicate JSON policy key: {key}")
        result[key] = value
    return result


def json_acl_write(rules: str) -> bool | None:
    try:
        document = json.loads(rules, object_pairs_hook=json_object_no_duplicates)
    except json.JSONDecodeError:
        return None
    if not isinstance(document, dict):
        raise ClassificationError("Consul JSON policy must be an object")
    if "acl" not in document:
        return False
    value = document["acl"]
    if value == "write":
        return True
    if value in ("read", "deny"):
        return False
    raise ClassificationError("unknown JSON ACL policy level")


def hcl_tokens(source: str) -> list[tuple[str, str]]:
    tokens: list[tuple[str, str]] = []
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        if char.isspace():
            index += 1
            continue
        if char == "#" or source.startswith("//", index):
            newline = source.find("\n", index)
            index = length if newline < 0 else newline + 1
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end < 0:
                raise ClassificationError("unterminated HCL block comment")
            index = end + 2
            continue
        if char == '"':
            index += 1
            value: list[str] = []
            while index < length:
                char = source[index]
                if char == '"':
                    index += 1
                    break
                if char == "\\":
                    if index + 1 >= length:
                        raise ClassificationError("unterminated HCL string escape")
                    escape = source[index : index + 2]
                    try:
                        value.append(json.loads(f'"{escape}"'))
                    except json.JSONDecodeError as error:
                        raise ClassificationError("unsupported HCL string escape") from error
                    index += 2
                    continue
                if char in "\r\n":
                    raise ClassificationError("newline in quoted HCL string")
                value.append(char)
                index += 1
            else:
                raise ClassificationError("unterminated HCL string")
            tokens.append(("string", "".join(value)))
            continue
        if IDENT_START.fullmatch(char):
            start = index
            index += 1
            while index < length and IDENT_CONTINUE.fullmatch(source[index]):
                index += 1
            tokens.append(("ident", source[start:index]))
            continue
        if char in "{}[]=,":
            tokens.append((char, char))
            index += 1
            continue
        raise ClassificationError(f"unsupported HCL token at byte {index}")
    return tokens


def hcl_acl_write(rules: str) -> bool:
    tokens = hcl_tokens(rules)
    brace_depth = 0
    bracket_depth = 0
    found: list[str] = []
    index = 0
    while index < len(tokens):
        kind, value = tokens[index]
        if kind == "{":
            brace_depth += 1
        elif kind == "}":
            brace_depth -= 1
            if brace_depth < 0:
                raise ClassificationError("unbalanced HCL braces")
        elif kind == "[":
            bracket_depth += 1
        elif kind == "]":
            bracket_depth -= 1
            if bracket_depth < 0:
                raise ClassificationError("unbalanced HCL brackets")
        elif kind == "ident" and value == "acl" and brace_depth == 0 and bracket_depth == 0:
            if index + 2 >= len(tokens) or tokens[index + 1][0] != "=" or tokens[index + 2][0] != "string":
                raise ClassificationError("unclassifiable top-level HCL acl assignment")
            found.append(tokens[index + 2][1])
            index += 2
        index += 1
    if brace_depth != 0 or bracket_depth != 0:
        raise ClassificationError("unbalanced HCL policy structure")
    if len(found) > 1:
        raise ClassificationError("duplicate top-level HCL acl assignment")
    if not found:
        return False
    if found[0] == "write":
        return True
    if found[0] in ("read", "deny"):
        return False
    raise ClassificationError("unknown HCL ACL policy level")


def policy_acl_write(policy: dict[str, Any]) -> bool:
    if policy.get("Name", "") == "global-management":
        return True
    rules = policy.get("Rules")
    if not isinstance(rules, str):
        raise ClassificationError("expanded Consul policy lacks string Rules")
    json_result = json_acl_write(rules)
    return hcl_acl_write(rules) if json_result is None else json_result


def links(value: Any, label: str) -> list[dict[str, str]]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ClassificationError(f"{label} must be an array")
    result: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict):
            raise ClassificationError(f"{label} entry must be an object")
        identifier = item.get("ID", "")
        name = item.get("Name", "")
        if not isinstance(identifier, str) or not isinstance(name, str):
            raise ClassificationError(f"{label} link fields must be strings")
        result.append({"id": identifier, "name": name})
    return sorted(result, key=lambda item: (item["id"], item["name"]))


def templated(value: Any, label: str) -> list[dict[str, str]]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ClassificationError(f"{label} must be an array")
    result: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict):
            raise ClassificationError(f"{label} entry must be an object")
        name = item.get("TemplateName", "")
        identifier = item.get("TemplateID", "")
        if not isinstance(name, str) or not isinstance(identifier, str):
            raise ClassificationError(f"{label} fields must be strings")
        result.append({"template_name": name, "template_id": identifier})
    return sorted(result, key=lambda item: (item["template_name"], item["template_id"]))


def classify(document: dict[str, Any], expected_accessor: str) -> dict[str, Any]:
    accessor = document.get("AccessorID")
    if accessor != expected_accessor or not isinstance(accessor, str) or not ACCESSOR_RE.fullmatch(accessor):
        raise ClassificationError("expanded token accessor mismatch")
    expanded_policies = document.get("ExpandedPolicies")
    expanded_roles = document.get("ExpandedRoles")
    if not isinstance(expanded_policies, list) or not isinstance(expanded_roles, list):
        raise ClassificationError("expanded token response lacks policy or role expansion")

    policy_rows: list[dict[str, Any]] = []
    acl_write = False
    for policy in expanded_policies:
        if not isinstance(policy, dict):
            raise ClassificationError("expanded policy must be an object")
        identifier = policy.get("ID", "")
        name = policy.get("Name", "")
        if not isinstance(identifier, str) or not isinstance(name, str):
            raise ClassificationError("expanded policy identity must be strings")
        policy_write = policy_acl_write(policy)
        acl_write = acl_write or policy_write
        policy_rows.append({"id": identifier, "name": name, "acl_write": policy_write})

    direct_templates = templated(document.get("TemplatedPolicies"), "TemplatedPolicies")
    expanded_role_rows: list[dict[str, str]] = []
    role_templates: list[dict[str, str]] = []
    for role in expanded_roles:
        if not isinstance(role, dict):
            raise ClassificationError("expanded role must be an object")
        identifier = role.get("ID", "")
        name = role.get("Name", "")
        if not isinstance(identifier, str) or not isinstance(name, str):
            raise ClassificationError("expanded role identity must be strings")
        expanded_role_rows.append({"id": identifier, "name": name})
        role_templates.extend(templated(role.get("TemplatedPolicies"), "ExpandedRoles.TemplatedPolicies"))
    if any(item["template_name"] == "builtin/nomad-server" for item in direct_templates + role_templates):
        acl_write = True

    local = document.get("Local")
    if not isinstance(local, bool):
        raise ClassificationError("token Local must be boolean")
    expiration_ttl = document.get("ExpirationTTL", 0)
    if not isinstance(expiration_ttl, (int, float)) or isinstance(expiration_ttl, bool):
        raise ClassificationError("token ExpirationTTL must be numeric")
    for key in ("Description", "AuthMethod", "AuthMethodNamespace"):
        if not isinstance(document.get(key, ""), str):
            raise ClassificationError(f"token {key} must be a string")

    return {
        "accessor": accessor,
        "description": document.get("Description", ""),
        "local": local,
        "auth_method": document.get("AuthMethod", ""),
        "auth_method_namespace": document.get("AuthMethodNamespace", ""),
        "expiration_ttl": expiration_ttl,
        "expiration_time": document.get("ExpirationTime"),
        "policies": links(document.get("Policies"), "Policies"),
        "roles": links(document.get("Roles"), "Roles"),
        "templated_policies": direct_templates,
        "expanded_policy_ids": sorted(policy_rows, key=lambda item: (item["id"], item["name"])),
        "expanded_role_ids": sorted(expanded_role_rows, key=lambda item: (item["id"], item["name"])),
        "acl_write": acl_write,
    }


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: classify-consul-token-authority.py TOKEN_JSON ACCESSOR", file=sys.stderr)
        return 2
    try:
        document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise ClassificationError("expanded token response must be an object")
        result = classify(document, sys.argv[2])
    except (OSError, json.JSONDecodeError, ClassificationError) as error:
        print(f"Consul ACL authority classification failed closed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
