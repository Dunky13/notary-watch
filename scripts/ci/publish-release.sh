#!/bin/bash
set -euo pipefail
# Only the protected publication job may call this after both acceptance jobs pass.
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
# shellcheck source=scripts/lib/github-release.sh
source "$(dirname -- "$0")/../lib/github-release.sh"
[[ $# == 1 ]] || nw_fail 'Usage: publish-release.sh signed-release-directory'
directory=$(cd "$1" && pwd -P)
[[ ${GH_REPO:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ${BUILD_SHA:-} =~ ^[a-f0-9]{40}$ && ${BUILD_NUMBER:-} =~ ^[1-9][0-9]*$ && ${SOURCE_RUN:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'Exact production source and repository are required.'
manifest="$directory/release-manifest.json"
jq -e --arg sha "$BUILD_SHA" --arg run "$SOURCE_RUN" --arg build "$BUILD_NUMBER" \
  '.product == "Notary Watch" and .commit == $sha and .source_run_id == $run and .build_number == $build and .architecture == "universal" and
   (.notarization.app | type == "string" and test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$")) and
   (.notarization.installer | type == "string" and test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))' \
  "$manifest" >/dev/null || nw_fail 'Release manifest differs from the accepted production candidate.'
version=$(jq -er '.version' "$manifest")
nw_validate_version "$version"
tag="v$version"
suffix="$version-build.$BUILD_NUMBER-$SOURCE_RUN-universal"
assets=("Notary-Watch-App-$suffix.zip" "Notary-Watch-Installer-$suffix.dmg" release-manifest.json SHA256SUMS)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-publish.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
for asset in "${assets[@]}"; do
  [[ -f $directory/$asset && ! -L $directory/$asset ]] || nw_fail "Missing regular release asset: $asset"
done
for path in "$directory/"*; do
  name=$(basename "$path")
  allowed=false
  for asset in "${assets[@]}"; do [[ $name != "$asset" ]] || allowed=true; done
  [[ $allowed == true ]] || nw_fail "Unexpected file in final assets: $name"
done
(cd "$directory" && shasum -a 256 "${assets[0]}" "${assets[1]}" release-manifest.json) > "$work/SHA256SUMS"
cmp -s "$work/SHA256SUMS" "$directory/SHA256SUMS" || nw_fail 'Final checksums do not exactly match the approved asset set.'
fetch() {
  local endpoint=$1 output=$2
  if gh api "$endpoint" > "$output" 2> "$work/api.stderr"; then return 0; fi
  if grep -Eq '\(HTTP 404\)|HTTP 404:' "$work/api.stderr"; then return 4; fi
  cat "$work/api.stderr" >&2
  nw_fail 'GitHub lookup failed; refusing to assume a release or tag is absent.'
}
if fetch "repos/$GH_REPO/git/ref/tags/$tag" "$work/tag.json"; then
  gh api "repos/$GH_REPO/commits/$tag" > "$work/tag-commit.json"
  [[ $(jq -er '.sha' "$work/tag-commit.json") == "$BUILD_SHA" ]] || nw_fail 'The version tag already identifies a different source commit. Bump the app version.'
fi
inventory_releases() {
  # Listing includes private drafts; the by-tag REST endpoint only promises published releases.
  gh api --paginate "repos/$GH_REPO/releases?per_page=100" --jq '.[]' > "$work/releases.json" || nw_fail 'Could not inventory existing releases.'
  jq -se 'all(.[]; type == "object" and (.tag_name | type == "string") and
    (.draft | type == "boolean") and (.prerelease | type == "boolean"))' "$work/releases.json" >/dev/null || nw_fail 'Release inventory is malformed; latest ordering is unknown.'
}
lookup_release() {
  inventory_releases
  jq -s --arg tag "$tag" '[.[] | select(.tag_name == $tag)]' "$work/releases.json" > "$work/matches.json" || nw_fail 'Release inventory is malformed.'
  [[ $(jq length "$work/matches.json") -le 1 ]] || nw_fail 'Multiple releases use this version tag.'
  jq '.[0]' "$work/matches.json" > "$work/release.json"
  [[ $(jq type "$work/release.json") == '"object"' ]] || return 1
  release_id=$(nw_gh_release_id "$work/release.json")
  nw_gh_release_get "$GH_REPO" "$release_id" "$work/release.json"
}
validate_release() {
  jq -e --arg sha "$BUILD_SHA" --arg tag "$tag" \
    '.tag_name == $tag and .target_commitish == $sha and .prerelease == false and
     (.draft | type == "boolean") and (.assets | type == "array") and
     ([.assets[].id] | length == (unique | length))' "$work/release.json" >/dev/null || nw_fail 'Release belongs to a different production candidate or has invalid state.'
}
if ! lookup_release; then
  printf 'Notary Watch %s for macOS 14 or later.\n\nDownload the universal DMG, open it, and drag Notary Watch to Applications. Apple Silicon and Intel are supported.\n\nBoth the app and installer are signed with Developer ID, accepted by Apple, stapled, and verified on both architectures. SHA256SUMS contains final download checksums.\n\nSource commit: %s\nSource CI: https://github.com/%s/actions/runs/%s\n' \
    "$version" "$BUILD_SHA" "$GH_REPO" "$SOURCE_RUN" > "$work/notes.md"
  nw_gh_release_create "$GH_REPO" "$tag" "$BUILD_SHA" false "Notary Watch $version" "$work/notes.md" "$work/release.json"
  release_id=$(nw_gh_release_id "$work/release.json")
  validate_release
  jq -e '.draft == true' "$work/release.json" >/dev/null || nw_fail 'Created release is not a draft.'
  nw_gh_release_get "$GH_REPO" "$release_id" "$work/release.json"
fi
validate_release
draft=$(jq -r '.draft' "$work/release.json")
: > "$work/asset-ids"
# Never overwrite an existing asset. A retry may only fill missing draft assets.
for asset in "${assets[@]}"; do
  nw_gh_release_get "$GH_REPO" "$release_id" "$work/release.json"
  validate_release
  [[ $(jq -r '.draft' "$work/release.json") == "$draft" ]] || nw_fail 'Release publication state changed during staging.'
  count=$(jq --arg name "$asset" '[.assets[] | select(.name == $name)] | length' "$work/release.json")
  if [[ $count == 0 ]]; then
    [[ $draft == true ]] || nw_fail 'A published release is incomplete; refusing to mutate it.'
    id=$(nw_gh_asset_upload "$GH_REPO" "$release_id" "$directory/$asset" "$work/upload.json")
  elif [[ $count == 1 ]]; then
    id=$(nw_gh_asset_id "$work/release.json" "$asset")
    nw_gh_asset_download "$GH_REPO" "$id" "$work/existing"
    cmp -s "$directory/$asset" "$work/existing" || nw_fail 'Existing release bytes differ; refusing overwrite.'
  else nw_fail 'Release contains duplicate asset names.'; fi
  printf '%s %s\n' "$id" "$asset" >> "$work/asset-ids"
done
nw_gh_release_get "$GH_REPO" "$release_id" "$work/release.json"
validate_release
[[ $(jq -r '.draft' "$work/release.json") == "$draft" ]] || nw_fail 'Release publication state changed during verification.'
jq -e '.assets | length == 4' "$work/release.json" >/dev/null || nw_fail 'Release contains an unexpected asset set.'
while read -r id asset; do
  [[ $(nw_gh_asset_id "$work/release.json" "$asset") == "$id" ]] || nw_fail 'Release asset ID changed during verification.'
  nw_gh_asset_download "$GH_REPO" "$id" "$work/verified"
  cmp -s "$work/verified" "$directory/$asset" || nw_fail "Uploaded asset differs from the accepted candidate: $asset"
done < "$work/asset-ids"
if [[ $draft == true ]]; then
  # A delayed older candidate may complete after a newer one. Publish its
  # immutable version without moving the consumer's latest pointer backwards.
  latest=true
  inventory_releases
  if jq -se --arg version "$version" '[.[] | select(.draft == false and .prerelease == false and (.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
    | .tag_name[1:] | split(".") | map(tonumber)] | any(.[]; . > ($version | split(".") | map(tonumber)))' "$work/releases.json" >/dev/null; then latest=false; fi
  gh api --method PATCH "repos/$GH_REPO/releases/$release_id" -F draft=false -F prerelease=false -f make_latest="$latest" > "$work/published.json" || nw_fail 'Exact-ID stable publication failed.'
  [[ $(nw_gh_release_id "$work/published.json") == "$release_id" ]] || nw_fail 'Publication returned a different release ID.'
fi
nw_gh_release_get "$GH_REPO" "$release_id" "$work/release.json"
validate_release
jq -e '.draft == false and .prerelease == false' "$work/release.json" >/dev/null || nw_fail 'Release is not publicly stable.'
jq -e '.assets | length == 4' "$work/release.json" >/dev/null || nw_fail 'Published release asset set changed.'
while read -r id asset; do
  [[ $(nw_gh_asset_id "$work/release.json" "$asset") == "$id" ]] || nw_fail 'Published release asset ID changed.'
done < "$work/asset-ids"
gh api "repos/$GH_REPO/commits/$tag" > "$work/tag-commit.json"
[[ $(jq -er '.sha' "$work/tag-commit.json") == "$BUILD_SHA" ]] || nw_fail 'Published tag does not identify the accepted source commit.'
printf 'Verified production release: https://github.com/%s/releases/tag/%s\n' "$GH_REPO" "$tag"
