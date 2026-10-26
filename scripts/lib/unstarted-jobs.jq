# Reinitialization requires proof that every credential-bearing operation was
# skipped. API-only source/preflight/custody steps may already have executed.
type == "array" and length >= 2
and all(.[];
  .status == "completed" and has("runner_id")
  and has("runner_name") and (.steps | type == "array"))
and ([.[] | select(.name == "Verify original successful main CI artifact")]
  | length == 1 and (.[0].conclusion == "success" or .[0].conclusion == "failure" or .[0].conclusion == "cancelled" or .[0].conclusion == "timed_out"))
and ([.[] | select(.name == "Sign app and notarize named app ZIP and installer DMG")]
  | length == 1 and (.[0].conclusion == "skipped" or .[0].conclusion == "failure" or .[0].conclusion == "cancelled" or .[0].conclusion == "timed_out")
  and (.[0] | if (.steps | length) == 0 then
    (.runner_id == 0 or .runner_id == null) and (.runner_name == "" or .runner_name == null)
  else
    .steps as $steps | [
      "Prepare a signed universal app without rebuilding it",
      "Submit descriptive product-version-build-universal app ZIP",
      "Require app acceptance, fetch its log, staple, and prepare the DMG",
      "Submit descriptive product-version-build-universal installer DMG",
      "Require DMG acceptance, staple, verify Finder copy, and finalize checksums"
    ] | all(.[]; . as $name | [$steps[] | select(.name == $name)]
      | length == 1 and .[0].status == "completed" and .[0].conclusion == "skipped")
  end))
and all(.[] | select(.name != "Verify original successful main CI artifact" and .name != "Sign app and notarize named app ZIP and installer DMG");
  .conclusion == "skipped" and (.steps | length == 0)
  and (.runner_id == 0 or .runner_id == null) and (.runner_name == "" or .runner_name == null))
