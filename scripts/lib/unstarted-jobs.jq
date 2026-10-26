# No absent checkpoint may be replaced unless every job is affirmatively known
# to have had no runner and no steps. In particular, signing must be skipped.
type == "array" and length >= 2
and all(.[];
  .status == "completed" and has("runner_id")
  and (.runner_id == 0 or .runner_id == null)
  and has("runner_name") and (.runner_name == "" or .runner_name == null)
  and (.steps | type == "array" and length == 0))
and ([.[] | select(.name == "Verify original successful main CI artifact")]
  | length == 1 and (.[0].conclusion == "failure" or .[0].conclusion == "cancelled" or .[0].conclusion == "timed_out"))
and ([.[] | select(.name == "Sign app and notarize named app ZIP and installer DMG")]
  | length == 1 and .[0].conclusion == "skipped")
and all(.[] | select(.name != "Verify original successful main CI artifact"); .conclusion == "skipped")
