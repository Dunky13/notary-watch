#!/bin/bash
# Private draft assets retain exact candidate bytes beyond workflow-artifact expiry.
set -euo pipefail
umask 077
export LC_ALL=C
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
# shellcheck source=scripts/lib/github-release.sh
source "$(dirname -- "$0")/../lib/github-release.sh"
[[ $# -ge 2 ]] || nw_fail 'Usage: durable-state.sh save directory slot | restore distribution-run slot new-directory | save-source|save-final directory | restore-source|restore-final new-directory'
operation=$1
shift
repo=${GH_REPO:-${GITHUB_REPOSITORY:-}}
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ${BUILD_SHA:-} =~ ^[a-f0-9]{40}$ && ${BUILD_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'Exact repository and original CI source identity are required.'
tag="notary-state-ci-$BUILD_RUN_ID"
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-custody.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case $operation in
  save)
    [[ $# == 2 && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ && $2 =~ ^(00|05|10|11|12|20|30|31|32|40)$ ]] || nw_fail 'Save requires an exact distribution run and checkpoint slot.'
    input=$1
    name="state-r$GITHUB_RUN_ID-s$2.tar"
    mode=state
    ;;
  restore)
    [[ $# == 3 && $1 =~ ^[1-9][0-9]*$ && $2 =~ ^(00|05|10|11|12|20|30|31|32|40)$ ]] || nw_fail 'Restore requires an exact distribution run and checkpoint slot.'
    name="state-r$1-s$2.tar"
    output=$3
    mode=state
    ;;
  save-source)
    [[ $# == 1 ]] || nw_fail 'Save-source requires the exact original CI directory.'
    input=$1
    name=source.tar
    mode=source
    ;;
  restore-source)
    [[ $# == 1 ]] || nw_fail 'Restore-source requires a new directory.'
    output=$1
    name=source.tar
    mode=source
    ;;
  save-final)
    [[ $# == 1 ]] || nw_fail 'Save-final requires the exact accepted final asset directory.'
    input=$1
    name=final.tar
    mode=final
    ;;
  restore-final)
    [[ $# == 1 ]] || nw_fail 'Restore-final requires a new directory.'
    output=$1
    name=final.tar
    mode=final
    ;;
  *) nw_fail 'Unknown custody operation.' ;;
esac
allowed_name() {
  local file=$1
  if [[ $mode == source ]]; then
    [[ $file == build-metadata.json || $file == SHA256SUMS || $file =~ ^Notary-Watch-(App|Installer)-[0-9]+\.[0-9]+\.[0-9]+-universal-development\.(zip|dmg)$ ]]
  elif [[ $mode == final ]]; then
    [[ $file == release-manifest.json || $file == SHA256SUMS || $file =~ ^Notary-Watch-(App|Installer)-[0-9]+\.[0-9]+\.[0-9]+-build\.[1-9][0-9]*-[1-9][0-9]*-universal\.(zip|dmg)$ ]]
  else
    [[ $file == origin.json || $file =~ ^(app|installer)\.(intent\.json|submission\.json|archive\.sha256|prepared\.sha256|status\.json|log\.json|recovery\.json)$ || $file =~ ^Notary-Watch-(App|Installer)-[0-9]+\.[0-9]+\.[0-9]+-build\.[1-9][0-9]*-[1-9][0-9]*-universal\.(zip|dmg)$ ]]
  fi
}
validate_directory() {
  local directory=$1 file version build archive dmg
  [[ -d $directory && ! -L $directory ]] || nw_fail 'Custody input must be a regular directory.'
  shopt -s nullglob dotglob
  for file in "$directory/"*; do
    if [[ ! -f $file || -L $file ]] || ! allowed_name "$(basename "$file")"; then
      nw_fail 'Custody contains an unexpected path or nonregular file.'
    fi
  done
  shopt -u nullglob dotglob
  if [[ $mode == state ]]; then
    jq -e --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" \
      '.schema == 2 and .commit == $sha and .run_id == $run and .architecture == "universal"' \
      "$directory/origin.json" >/dev/null || nw_fail 'Custody checkpoint belongs to another source candidate.'
    # The canonical exporter verifies every archive, receipt, digest and recovery classification.
    "$NW_ROOT/scripts/checkpoint-macos.sh" "$directory" "$work/validated"
    diff -qr "$directory" "$work/validated" >/dev/null || nw_fail 'Custody checkpoint is not the canonical safe export.'
    rm -rf -- "$work/validated"
  elif [[ $mode == source ]]; then
    jq -e --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" --arg attempt "${BUILD_ATTEMPT:-}" \
      '.schema == 1 and .commit == $sha and .run_id == $run and .architecture == "universal"
       and (.run_attempt | type == "string" and test("^[1-9][0-9]*$"))
       and ($attempt == "" or .run_attempt == $attempt)
       and (.build_number | type == "string" and test("^[1-9][0-9]*$"))
       and (.archive_sha256 | type == "string" and test("^[a-f0-9]{64}$"))' \
      "$directory/build-metadata.json" >/dev/null || nw_fail 'Durable source differs from the original CI identity.'
    version=$(jq -er '.version' "$directory/build-metadata.json")
    nw_validate_version "$version"
    archive="Notary-Watch-App-$version-universal-development.zip"
    dmg="Notary-Watch-Installer-$version-universal-development.dmg"
    jq -e --arg archive "$archive" --arg dmg "$dmg" '.archive == $archive and .dmg == $dmg' "$directory/build-metadata.json" >/dev/null || nw_fail 'Unexpected durable source archive names.'
    [[ -f $directory/$archive && -f $directory/$dmg && $(nw_sha "$directory/$archive") == "$(jq -er '.archive_sha256' "$directory/build-metadata.json")" ]] || nw_fail 'Durable original archive bytes changed.'
    (cd "$directory" && shasum -a 256 "$archive" "$dmg") > "$work/expected-source-sums"
    cmp -s "$work/expected-source-sums" "$directory/SHA256SUMS" || nw_fail 'Durable source checksums differ from the exact original asset set.'
    [[ $(find "$directory" -type f | wc -l | tr -d ' ') == 4 ]] || nw_fail 'Unexpected durable original asset count.'
  else
    jq -e --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" --arg build "${BUILD_NUMBER:-}" \
      '.product == "Notary Watch" and .commit == $sha and .source_run_id == $run and .architecture == "universal"
       and (.build_number | type == "string" and test("^[1-9][0-9]*$"))
       and ($build == "" or .build_number == $build)
       and (.team_id | type == "string" and test("^[A-Z0-9]{10}$"))
       and (.notarization.app | type == "string" and test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))
       and (.notarization.installer | type == "string" and test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))
       and ((.notarization.app | ascii_downcase) != (.notarization.installer | ascii_downcase))
       and (.submitted_sha256.app | type == "string" and test("^[a-f0-9]{64}$"))
       and (.submitted_sha256.installer | type == "string" and test("^[a-f0-9]{64}$"))' \
      "$directory/release-manifest.json" >/dev/null || nw_fail 'Durable final assets differ from the accepted source candidate.'
    version=$(jq -er '.version' "$directory/release-manifest.json")
    nw_validate_version "$version"
    build=$(jq -er '.build_number' "$directory/release-manifest.json")
    archive="Notary-Watch-App-$version-build.$build-$BUILD_RUN_ID-universal.zip"
    dmg="Notary-Watch-Installer-$version-build.$build-$BUILD_RUN_ID-universal.dmg"
    [[ -f $directory/$archive && -f $directory/$dmg ]] || nw_fail 'Durable final asset names differ from their manifest.'
    (cd "$directory" && shasum -a 256 "$archive" "$dmg" release-manifest.json) > "$work/expected-final-sums"
    cmp -s "$work/expected-final-sums" "$directory/SHA256SUMS" || nw_fail 'Durable final checksums differ from the exact accepted asset set.'
    [[ $(find "$directory" -type f | wc -l | tr -d ' ') == 4 ]] || nw_fail 'Unexpected durable final asset count.'
  fi
}
lookup_release() {
  if [[ -n ${NW_CUSTODY_RELEASE_ID:-} ]]; then
    release_id=$NW_CUSTODY_RELEASE_ID
    nw_gh_release_get "$repo" "$release_id" "$work/release.json"
    return 0
  fi
  gh api --paginate "repos/$repo/releases?per_page=100" --jq '.[]' > "$work/releases.json" || nw_fail 'Could not inventory durable candidate drafts.'
  jq -se 'all(.[]; type == "object" and (.tag_name | type == "string") and
    (.draft | type == "boolean") and (.prerelease | type == "boolean"))' "$work/releases.json" >/dev/null || nw_fail 'Durable release inventory is malformed.'
  jq -s --arg tag "$tag" '[.[] | select(.tag_name == $tag)]' "$work/releases.json" > "$work/matches.json" || nw_fail 'Durable release inventory is malformed.'
  [[ $(jq length "$work/matches.json") -le 1 ]] || nw_fail 'Ambiguous durable candidate draft.'
  jq '.[0]' "$work/matches.json" > "$work/release.json"
  [[ $(jq type "$work/release.json") == '"object"' ]] || return 1
  release_id=$(nw_gh_release_id "$work/release.json")
  nw_gh_release_get "$repo" "$release_id" "$work/release.json"
}
validate_release() {
  jq -e --arg sha "$BUILD_SHA" --arg tag "$tag" \
    '.tag_name == $tag and .target_commitish == $sha and .draft == true and .prerelease == true and
     (.assets | type == "array") and ([.assets[].id] | length == (unique | length))' \
    "$work/release.json" >/dev/null || nw_fail 'Durable draft was published or belongs to another source candidate.'
}
asset_id() {
  nw_gh_asset_id "$work/release.json" "$1"
}
download_asset() {
  local asset=$1 destination=$2 id
  id=$(asset_id "$asset") || nw_fail "Missing or ambiguous durable asset: $asset"
  nw_gh_asset_download "$repo" "$id" "$destination"
}
if [[ $operation == save || $operation == save-source || $operation == save-final ]]; then
  validate_directory "$input"
  mkdir "$work/files"
  while IFS= read -r file; do
    cp "$input/$file" "$work/files/$file"
    chmod 600 "$work/files/$file"
    TZ=UTC touch -t 200001010000 "$work/files/$file"
  done < <(find "$input" -type f -depth 1 -exec basename '{}' \; | LC_ALL=C sort)
  # macOS bsdtar, with fixed ownership/modes/times and no Apple metadata.
  # Entry names are already restricted to flat ASCII basenames.
  (cd "$work/files" && LC_ALL=C COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root -cf "$work/$name" ./*)
  digest=$(nw_sha "$work/$name")
  printf '%s  %s\n' "$digest" "$name" > "$work/$name.sha256"
  if ! lookup_release; then
    printf 'Private recovery custody for original CI %s, source %s. Never publish this draft.\n' "$BUILD_RUN_ID" "$BUILD_SHA" > "$work/notes.txt"
    nw_gh_release_create "$repo" "$tag" "$BUILD_SHA" true "Notary Watch recovery CI $BUILD_RUN_ID" "$work/notes.txt" "$work/release.json"
    release_id=$(nw_gh_release_id "$work/release.json")
    validate_release
    nw_gh_release_get "$repo" "$release_id" "$work/release.json"
  fi
  validate_release
  : > "$work/asset-ids"
  for asset in "$name" "$name.sha256"; do
    nw_gh_release_get "$repo" "$release_id" "$work/release.json"
    validate_release
    count=$(jq --arg name "$asset" '[.assets[] | select(.name == $name)] | length' "$work/release.json")
    if [[ $count == 0 ]]; then
      id=$(nw_gh_asset_upload "$repo" "$release_id" "$work/$asset" "$work/upload.json")
    elif [[ $count == 1 ]]; then
      download_asset "$asset" "$work/existing"
      cmp -s "$work/$asset" "$work/existing" || nw_fail 'Existing durable bytes differ; refusing overwrite.'
      id=$(asset_id "$asset")
    else
      nw_fail 'Duplicate immutable custody asset names.'
    fi
    printf '%s %s\n' "$id" "$asset" >> "$work/asset-ids"
  done
  nw_gh_release_get "$repo" "$release_id" "$work/release.json"
  validate_release
  while read -r id asset; do
    [[ $(asset_id "$asset") == "$id" ]] || nw_fail 'Durable asset ID changed after upload.'
    download_asset "$asset" "$work/verified"
    cmp -s "$work/$asset" "$work/verified" || nw_fail 'Durable upload verification failed.'
  done < "$work/asset-ids"
  # A pointer for subsequent steps only; every use requires a fresh bound GET.
  if [[ -n ${GITHUB_ENV:-} ]]; then printf 'NW_CUSTODY_RELEASE_ID=%s\n' "$release_id" >> "$GITHUB_ENV"; fi
  printf 'Verified durable custody: %s, %s, SHA256 %s.\n' "$tag" "$name" "$digest"
else
  [[ ! -e $output && ! -L $output ]] || nw_fail 'Restore destination must not exist.'
  lookup_release || nw_fail 'No durable candidate draft exists.'
  validate_release
  download_asset "$name" "$work/$name"
  download_asset "$name.sha256" "$work/$name.sha256"
  printf '%s  %s\n' "$(nw_sha "$work/$name")" "$name" > "$work/expected-sha"
  cmp -s "$work/expected-sha" "$work/$name.sha256" || nw_fail 'Durable archive checksum mismatch.'
  tar -tf "$work/$name" > "$work/entries"
  tar -tvf "$work/$name" > "$work/types"
  [[ -s $work/entries && $(wc -l < "$work/entries") == "$(LC_ALL=C sort -u "$work/entries" | wc -l)" ]] || nw_fail 'Empty or duplicate durable archive entries.'
  while IFS= read -r file; do
    if [[ $file != ./* || $file == *'/'*'/'* ]] || ! allowed_name "${file#./}"; then
      nw_fail 'Unsafe durable archive path.'
    fi
  done < "$work/entries"
  while IFS= read -r line; do
    [[ $line == -* ]] || nw_fail 'Durable archive contains a link or nonregular entry.'
  done < "$work/types"
  mkdir "$work/restored"
  # Stream each regular member to a new flat file; never honor archive links,
  # ownership, extended attributes or extraction paths.
  while IFS= read -r file; do
    tar -xOf "$work/$name" "$file" > "$work/restored/${file#./}"
  done < "$work/entries"
  validate_directory "$work/restored"
  mkdir -p "$(dirname -- "$output")"
  mv "$work/restored" "$output"
  printf 'Restored exact durable custody: %s, %s.\n' "$tag" "$name"
fi
