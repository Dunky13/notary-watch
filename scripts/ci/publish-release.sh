#!/bin/bash
set -euo pipefail
# Only the protected publication job may call this after both acceptance jobs pass.
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
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
lookup_release() {
  # Listing includes private drafts; the by-tag REST endpoint only promises published releases.
  gh api --paginate "repos/$GH_REPO/releases?per_page=100" --jq '.[]' > "$work/releases.json" || nw_fail 'Could not inventory existing releases.'
  jq -s --arg tag "$tag" '[.[] | select(.tag_name == $tag)]' "$work/releases.json" > "$work/matches.json" || nw_fail 'Release inventory is malformed.'
  [[ $(jq length "$work/matches.json") -le 1 ]] || nw_fail 'Multiple releases use this version tag.'
  jq '.[0]' "$work/matches.json" > "$work/release.json"
  [[ $(jq type "$work/release.json") == '"object"' ]]
}
if ! lookup_release; then
  printf 'Notary Watch %s for macOS 14 or later.\n\nDownload the universal DMG, open it, and drag Notary Watch to Applications. Apple Silicon and Intel are supported.\n\nBoth the app and installer are signed with Developer ID, accepted by Apple, stapled, and verified on both architectures. SHA256SUMS contains final download checksums.\n\nSource commit: %s\nSource CI: https://github.com/%s/actions/runs/%s\n' \
    "$version" "$BUILD_SHA" "$GH_REPO" "$SOURCE_RUN" > "$work/notes.md"
  gh release create "$tag" --repo "$GH_REPO" --target "$BUILD_SHA" --draft \
    --title "Notary Watch $version" --notes-file "$work/notes.md"
  lookup_release || nw_fail 'Created draft is unavailable.'
fi
jq -e --arg sha "$BUILD_SHA" --arg tag "$tag" \
  '.tag_name == $tag and .target_commitish == $sha and .prerelease == false' "$work/release.json" >/dev/null || nw_fail 'Existing release belongs to a different production candidate.'
draft=$(jq -r '.draft' "$work/release.json")
# Never overwrite an existing asset. A retry may only fill missing draft assets.
for asset in "${assets[@]}"; do
  count=$(jq --arg name "$asset" '[.assets[] | select(.name == $name)] | length' "$work/release.json")
  if [[ $count == 0 ]]; then
    [[ $draft == true ]] || nw_fail 'A published release is incomplete; refusing to mutate it.'
    gh release upload "$tag" "$directory/$asset" --repo "$GH_REPO"
  elif [[ $count != 1 ]]; then nw_fail 'Release contains duplicate asset names.'; fi
done
lookup_release || nw_fail 'Release disappeared during asset verification.'
jq -e '.assets | length == 4' "$work/release.json" >/dev/null || nw_fail 'Release contains an unexpected asset set.'
mkdir "$work/download"
gh release download "$tag" --repo "$GH_REPO" --dir "$work/download"
for asset in "${assets[@]}"; do
  [[ -f $work/download/$asset && $(nw_sha "$work/download/$asset") == "$(nw_sha "$directory/$asset")" ]] || nw_fail "Uploaded asset differs from the accepted candidate: $asset"
done
if [[ $draft == true ]]; then
  gh release edit "$tag" --repo "$GH_REPO" --draft=false --prerelease=false --latest
fi
lookup_release || nw_fail 'Published release is unavailable.'
jq -e '.draft == false and .prerelease == false' "$work/release.json" >/dev/null || nw_fail 'Release is not publicly stable.'
gh api "repos/$GH_REPO/commits/$tag" > "$work/tag-commit.json"
[[ $(jq -er '.sha' "$work/tag-commit.json") == "$BUILD_SHA" ]] || nw_fail 'Published tag does not identify the accepted source commit.'
printf 'Verified production release: https://github.com/%s/releases/tag/%s\n' "$GH_REPO" "$tag"
