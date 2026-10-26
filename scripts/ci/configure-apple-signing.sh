#!/bin/bash
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ $# == 1 ]] || nw_fail 'Usage: configure-apple-signing.sh private-configuration.json'
file=$1
[[ -f $file && ! -L $file && -O $file ]] || nw_fail 'Configuration must be an owned regular private file.'
[[ $(stat -f '%Lp' "$file") == 600 ]] || nw_fail 'Configuration file permissions must be 600.'
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
# Inspect only policy and names; never print credential values or raw parser errors.
gh api "repos/$repo/environments/apple-signing" > "$work/environment.json"
jq -e '.deployment_branch_policy.custom_branch_policies == true and .deployment_branch_policy.protected_branches == false' \
  "$work/environment.json" >/dev/null || nw_fail 'Configure selected-main branch restrictions before installing signing secrets.'
gh api "repos/$repo/environments/apple-signing/deployment-branch-policies" > "$work/branches.json"
jq -e '.branch_policies | length == 1 and .[0].name == "main" and .[0].type == "branch"' "$work/branches.json" >/dev/null || nw_fail 'Signing secrets require the exact main-only deployment policy.'
gh api "repos/$repo/branches/main/protection" > "$work/protection.json"
jq -e '.enforce_admins.enabled == true and .required_status_checks.strict == true and
  (.required_status_checks.contexts | index("ci-required") != null)' "$work/protection.json" >/dev/null || nw_fail 'Protected main must enforce the required fresh CI gate.'
jq -e 'type == "object" and
  (keys | sort) == (["APPLE_DEVELOPER_ID_P12_BASE64","APPLE_DEVELOPER_ID_P12_PASSWORD","APPLE_NOTARY_KEY_P8","APPLE_NOTARY_KEY_ID","APPLE_NOTARY_ISSUER_ID"] | sort) and
  all(.[]; type == "string" and length > 0) and
  (.APPLE_DEVELOPER_ID_P12_BASE64 | test("^[A-Za-z0-9+/=\\r\\n]+$")) and
  (.APPLE_DEVELOPER_ID_P12_PASSWORD | length <= 1024) and
  (.APPLE_DEVELOPER_ID_P12_PASSWORD | test("[\\r\\n]") | not) and
  (.APPLE_NOTARY_KEY_ID | test("^[A-Z0-9]{10}$")) and
  (.APPLE_NOTARY_ISSUER_ID | test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$")) and
  (.APPLE_NOTARY_KEY_P8 | startswith("-----BEGIN PRIVATE KEY-----") and contains("-----END PRIVATE KEY-----"))' \
  "$file" >/dev/null 2>&1 || nw_fail 'Private configuration is missing or has invalid fields.'
for name in APPLE_DEVELOPER_ID_P12_BASE64 APPLE_DEVELOPER_ID_P12_PASSWORD APPLE_NOTARY_KEY_P8; do
  jq -jr --arg name "$name" '.[$name]' "$file" | gh secret set "$name" --repo "$repo" --env apple-signing
done
for name in APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID; do
  jq -jr --arg name "$name" '.[$name]' "$file" | gh variable set "$name" --repo "$repo" --env apple-signing
done
printf 'Installed Apple signing configuration into the protected environment. Remove the private input file when finished.\n'
