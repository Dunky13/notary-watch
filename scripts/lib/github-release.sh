#!/bin/bash
# Provider transport only; callers must validate tag/source and publication policy.
# Authentication stays entirely with gh. Never retry an ambiguous POST.
nw_gh_release_id() {
  jq -ers 'if length == 1 then .[0] else error("Multiple responses") end |
    .id | select(type == "number" and . > 0 and . <= 9007199254740991 and . == floor)' "$1" || nw_fail 'GitHub release response has no exact positive integer ID.'
}
nw_gh_release_get() {
  local repo=$1 id=$2 output=$3
  [[ $id =~ ^[1-9][0-9]*$ ]] || nw_fail 'Invalid exact release ID.'
  gh api "repos/$repo/releases/$id" > "$output" || nw_fail 'Could not read exact GitHub release ID.'
  [[ $(nw_gh_release_id "$output") == "$id" ]] || nw_fail 'GitHub returned a different release ID.'
}
nw_gh_release_create() {
  local repo=$1 tag=$2 sha=$3 prerelease=$4 title=$5 notes=$6 output=$7
  # A historical target changing workflows may be denied by GitHub. Keep its
  # error, the original source and the existing credential authority intact.
  gh api --method POST "repos/$repo/releases" -f tag_name="$tag" -f target_commitish="$sha" \
    -F draft=true -F prerelease="$prerelease" -f name="$title" -F body="@$notes" > "$output" ||
    nw_fail 'GitHub release creation failed; no retry or source substitution is authorized.'
  nw_gh_release_id "$output" >/dev/null
}
nw_gh_asset_id() {
  local release=$1 name=$2
  jq -er --arg name "$name" '[.assets[] | select(.name == $name)] |
    if length == 1 and (.[0] | .state == "uploaded" and
      (.id | type == "number" and . > 0 and . <= 9007199254740991 and . == floor) and
      (.size | type == "number" and . >= 0 and . == floor))
    then .[0].id else error("Missing, ambiguous or incomplete release asset") end' "$release" ||
    nw_fail "Invalid exact release asset: $name"
}
nw_gh_asset_upload() {
  local repo=$1 release_id=$2 file=$3 output=$4 name
  name=$(basename "$file")
  [[ $release_id =~ ^[1-9][0-9]*$ && $name =~ ^[A-Za-z0-9._-]+$ ]] || nw_fail 'Unsafe exact upload identity.'
  # Use the fixed GitHub upload origin, never a provider-supplied arbitrary URL.
  gh api --method POST "https://uploads.github.com/repos/$repo/releases/$release_id/assets?name=$name" \
    -H 'Content-Type: application/octet-stream' --input "$file" > "$output" || nw_fail 'Immutable exact-ID asset upload failed; refusing overwrite or blind retry.'
  jq -es --arg name "$name" --argjson size "$(wc -c < "$file" | tr -d ' ')" '
    length == 1 and (.[0] | .name == $name and .state == "uploaded" and .size == $size and
      (.id | type == "number" and . > 0 and . <= 9007199254740991 and . == floor))' "$output" >/dev/null ||
    nw_fail 'GitHub upload response differs from the exact asset identity.'
  jq -er '.id' "$output"
}
nw_gh_asset_download() {
  local repo=$1 id=$2 destination=$3
  [[ $id =~ ^[1-9][0-9]*$ ]] || nw_fail 'Invalid exact asset ID.'
  gh api -H 'Accept: application/octet-stream' "repos/$repo/releases/assets/$id" > "$destination" || nw_fail 'Could not download exact GitHub asset ID.'
}
